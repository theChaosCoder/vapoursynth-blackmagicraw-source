/* Standalone CPU-vs-Metal decode benchmark for the Blackmagic RAW SDK (macOS).
 *
 * Objective-C++ sibling of braw_bench.cpp: decodes every frame of a clip on
 * the given pipeline, copying each result back to host memory (the readback a
 * frameserver needs), and reports fps. The Metal readback mirrors the
 * plugin's src/core/braw/metal.zig: blit the private MTLBuffer into a managed
 * staging buffer, synchronize, wait, memcpy — one reused staging buffer.
 *
 * Usage: braw_bench_mac <clip.braw> <cpu|metal> [maxJobsInFlight] [loops] [--no-readback]
 * $BRAW_LIBRARY points at the directory containing BlackmagicRawAPI.framework.
 *
 * Build:
 *   clang++ -O2 -std=c++14 -fobjc-arc -Ivendor/braw-sdk/Mac \
 *       test/bench/braw_bench_mac.mm vendor/braw-sdk/Mac/BlackmagicRawAPIDispatch.cpp \
 *       -framework CoreFoundation -framework Metal -o braw_bench_mac
 */
#import <Metal/Metal.h>

#include "BlackmagicRawAPI.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

static const BlackmagicRawResourceFormat s_format = blackmagicRawResourceFormatRGBU16Planar;
static int s_maxJobs = 3;
static std::atomic<int> s_inFlight{0};
static std::atomic<int> s_done{0};
static bool s_metal = false;
static bool s_readback = true;
static id<MTLCommandQueue> s_queue = nil;
static IBlackmagicRawPipelineDevice* s_device = nullptr;
static id<MTLBuffer> s_staging = nil;
static uint8_t* s_hostBuf = nullptr;
static uint32_t s_hostBufSize = 0;

class Callback : public IBlackmagicRawCallback {
public:
    virtual void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result, IBlackmagicRawFrame* frame) {
        IBlackmagicRawJob* job = nullptr;
        if (result == S_OK) result = frame->SetResourceFormat(s_format);
        if (result == S_OK) result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &job);
        if (result == S_OK) result = job->Submit();
        if (result != S_OK) { if (job) job->Release(); --s_inFlight; }
        readJob->Release();
    }
    virtual void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* image) {
        if (result == S_OK && image && s_readback) {
            void* resource = nullptr;
            uint32_t size = 0;
            image->GetResourceSizeBytes(&size);
            image->GetResource(&resource);
            if (size > s_hostBufSize) {
                free(s_hostBuf);
                s_hostBuf = (uint8_t*)malloc(size);
                s_hostBufSize = size;
            }
            if (s_metal) {
                @autoreleasepool {
                    id<MTLBuffer> src = (__bridge id<MTLBuffer>)resource;
                    if (s_staging == nil || s_staging.length < size)
                        s_staging = [s_queue.device newBufferWithLength:size
                                                                options:MTLResourceStorageModeManaged];
                    id<MTLCommandBuffer> cb = [s_queue commandBuffer];
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit copyFromBuffer:src sourceOffset:0 toBuffer:s_staging destinationOffset:0 size:size];
                    [blit synchronizeResource:s_staging];
                    [blit endEncoding];
                    [cb commit];
                    [cb waitUntilCompleted];
                    memcpy(s_hostBuf, s_staging.contents, size);
                }
            } else {
                memcpy(s_hostBuf, resource, size);
            }
        }
        ++s_done;
        --s_inFlight;
        job->Release();
    }
    virtual void DecodeComplete(IBlackmagicRawJob*, HRESULT) {}
    virtual void TrimProgress(IBlackmagicRawJob*, float) {}
    virtual void TrimComplete(IBlackmagicRawJob*, HRESULT) {}
    virtual void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) {}
    virtual void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) {}
    virtual void PreparePipelineComplete(void*, HRESULT) {}
    virtual HRESULT QueryInterface(REFIID, LPVOID*) { return E_NOTIMPL; }
    virtual ULONG AddRef() { return 0; }
    virtual ULONG Release() { return 0; }
};

static bool setupMetal(IBlackmagicRawFactory* factory, IBlackmagicRaw* codec) {
    IBlackmagicRawPipelineDeviceIterator* it = nullptr;
    if (factory->CreatePipelineDeviceIterator(blackmagicRawPipelineMetal, blackmagicRawInteropNone, &it) != S_OK || !it) {
        fprintf(stderr, "CreatePipelineDeviceIterator(Metal, None) failed\n");
        return false;
    }
    IBlackmagicRawPipelineDevice* device = nullptr;
    HRESULT hr = it->CreateDevice(&device);
    it->Release();
    if (hr != S_OK || !device) { fprintf(stderr, "CreateDevice failed\n"); return false; }

    CFStringRef name = nullptr;
    if (device->GetName(&name) == S_OK && name) {
        char buf[256] = {0};
        CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8);
        fprintf(stderr, "Metal device: %s\n", buf);
        CFRelease(name);
    }

    IBlackmagicRawConfiguration* config = nullptr;
    if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (void**)&config) != S_OK) return false;
    hr = config->SetFromDevice(device);
    config->Release();
    if (hr != S_OK) { fprintf(stderr, "SetFromDevice failed\n"); return false; }

    BlackmagicRawPipeline pipeline;
    void* ctx = nullptr;
    void* queue = nullptr;
    if (device->GetPipeline(&pipeline, &ctx, &queue) != S_OK || !queue) {
        fprintf(stderr, "GetPipeline failed\n");
        return false;
    }
    s_queue = (__bridge id<MTLCommandQueue>)queue;
    // keep the device alive until after the codec is released: the codec's
    // pipeline (and our borrowed queue) are backed by it
    s_device = device;
    return true;
}

int main(int argc, const char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <clip.braw> <cpu|metal> [maxJobs] [loops] [--no-readback]\n", argv[0]); return 2; }
    const char* clipName = argv[1];
    s_metal = strcmp(argv[2], "metal") == 0;
    if (argc > 3) s_maxJobs = atoi(argv[3]);
    if (s_maxJobs < 1) { fprintf(stderr, "maxJobs must be >= 1\n"); return 2; } // 0 spins forever
    int loops = (argc > 4) ? atoi(argv[4]) : 1;
    if (loops < 1) loops = 1;
    for (int i = 3; i < argc; i++)
        if (strcmp(argv[i], "--no-readback") == 0) s_readback = false;

    const char* libDir = getenv("BRAW_LIBRARY");
    char libPath[4096];
    snprintf(libPath, sizeof(libPath), "%s/", libDir ? libDir : "./");

    IBlackmagicRawFactory* factory = CreateBlackmagicRawFactoryInstanceFromPath(
        CFStringCreateWithCString(kCFAllocatorDefault, libPath, kCFStringEncodingUTF8));
    if (!factory) { fprintf(stderr, "factory failed\n"); return 1; }
    IBlackmagicRaw* codec = nullptr;
    if (factory->CreateCodec(&codec) != S_OK) return 1;

    if (s_metal && !setupMetal(factory, codec)) return 1;

    CFStringRef clipStr = CFStringCreateWithCString(kCFAllocatorDefault, clipName, kCFStringEncodingUTF8);
    IBlackmagicRawClip* clip = nullptr;
    if (codec->OpenClip(clipStr, &clip) != S_OK) { fprintf(stderr, "open failed\n"); return 1; }
    CFRelease(clipStr);
    Callback cb;
    codec->SetCallback(&cb);

    uint64_t frameCount = 0;
    clip->GetFrameCount(&frameCount);
    uint32_t w = 0, h = 0;
    clip->GetWidth(&w);
    clip->GetHeight(&h);

    // warmup pass (excluded from timing): amortizes context/JIT/first-frame
    for (uint64_t i = 0; i < frameCount && i < 8; ) {
        if (s_inFlight >= s_maxJobs) { std::this_thread::sleep_for(std::chrono::microseconds(50)); continue; }
        IBlackmagicRawJob* rj = nullptr;
        if (clip->CreateJobReadFrame(i, &rj) != S_OK) break;
        ++s_inFlight;
        if (rj->Submit() != S_OK) { --s_inFlight; rj->Release(); break; }
        i++;
    }
    codec->FlushJobs();
    s_done = 0;

    auto t0 = std::chrono::steady_clock::now();
    for (int loop = 0; loop < loops; loop++) {
        uint64_t idx = 0;
        while (idx < frameCount) {
            if (s_inFlight >= s_maxJobs) { std::this_thread::sleep_for(std::chrono::microseconds(50)); continue; }
            IBlackmagicRawJob* readJob = nullptr;
            if (clip->CreateJobReadFrame(idx, &readJob) != S_OK) break;
            ++s_inFlight;
            if (readJob->Submit() != S_OK) { --s_inFlight; readJob->Release(); break; }
            idx++;
        }
        codec->FlushJobs();
    }
    auto t1 = std::chrono::steady_clock::now();

    double sec = std::chrono::duration<double>(t1 - t0).count();
    int done = s_done.load();
    printf("%-5s %ux%u frames=%d jobs=%-2d readback=%s time=%.3fs fps=%.2f\n",
           s_metal ? "Metal" : "CPU", w, h, done, s_maxJobs,
           s_readback ? "yes" : "no", sec, done / sec);

    clip->Release();
    codec->Release();
    if (s_device) s_device->Release();
    factory->Release();
    free(s_hostBuf);
    return 0;
}
