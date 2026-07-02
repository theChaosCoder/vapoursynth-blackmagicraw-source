/* Standalone CPU-vs-CUDA decode benchmark for the Blackmagic RAW SDK.
 *
 * Decodes every frame of a clip on the given pipeline, copying each result
 * back to host memory (the readback a frameserver needs), and reports fps.
 * Proves GPU decode works on this machine and gives an independent baseline
 * for the plugin comparison.
 *
 * Usage: braw_bench <clip.braw> <cpu|cuda> [maxJobsInFlight]
 * $BRAW_LIBRARY points at the runtime directory.
 */
#include "BlackmagicRawAPI.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

// --- minimal CUDA driver API (no toolkit headers needed) -------------------
extern "C" {
typedef int CUresult;
typedef int CUdevice;
typedef void* CUcontext;
typedef unsigned long long CUdeviceptr;
CUresult cuInit(unsigned int);
CUresult cuDeviceGetCount(int*);
CUresult cuDeviceGet(CUdevice*, int);
CUresult cuDeviceGetName(char*, int, CUdevice);
CUresult cuCtxCreate_v2(CUcontext*, unsigned int, CUdevice);
CUresult cuCtxDestroy_v2(CUcontext);
CUresult cuCtxPushCurrent_v2(CUcontext);
CUresult cuCtxPopCurrent_v2(CUcontext*);
CUresult cuMemcpyDtoH_v2(void*, CUdeviceptr, size_t);
CUresult cuMemAllocHost_v2(void**, size_t);
CUresult cuMemFreeHost(void*);
}
static const unsigned CU_CTX_SCHED_BLOCKING_SYNC = 0x04;
static const unsigned CU_CTX_MAP_HOST = 0x08;

static const BlackmagicRawResourceFormat s_format = blackmagicRawResourceFormatRGBU16Planar;
static int s_maxJobs = 3;
static std::atomic<int> s_inFlight{0};
static std::atomic<int> s_done{0};
static CUcontext s_cudaCtx = nullptr;
static bool s_cuda = false;
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
        if (result == S_OK && image) {
            void* resource = nullptr;
            uint32_t size = 0;
            image->GetResourceSizeBytes(&size);
            image->GetResource(&resource);
            if (size > s_hostBufSize) {
                if (s_cuda) {
                    if (s_hostBuf) cuMemFreeHost(s_hostBuf);
                    void* p = nullptr;
                    cuMemAllocHost_v2(&p, size); // pinned host memory: faster DtoH
                    s_hostBuf = (uint8_t*)p;
                } else {
                    free(s_hostBuf);
                    s_hostBuf = (uint8_t*)malloc(size);
                }
                s_hostBufSize = size;
            }
            if (s_cuda) {
                // GPU result: copy device -> host (context current on this thread)
                cuCtxPushCurrent_v2(s_cudaCtx);
                cuMemcpyDtoH_v2(s_hostBuf, (CUdeviceptr)resource, size);
                CUcontext prev;
                cuCtxPopCurrent_v2(&prev);
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
    virtual void SidecarMetadataParseWarning(IBlackmagicRawClip*, const char*, uint32_t, const char*) {}
    virtual void SidecarMetadataParseError(IBlackmagicRawClip*, const char*, uint32_t, const char*) {}
    virtual void PreparePipelineComplete(void*, HRESULT) {}
    virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) { return E_NOTIMPL; }
    virtual ULONG STDMETHODCALLTYPE AddRef() { return 0; }
    virtual ULONG STDMETHODCALLTYPE Release() { return 0; }
};

static bool setupCuda(void** ctxOut) {
    if (cuInit(0) != 0) { fprintf(stderr, "cuInit failed\n"); return false; }
    int n = 0;
    if (cuDeviceGetCount(&n) != 0 || n == 0) { fprintf(stderr, "no CUDA device\n"); return false; }
    CUdevice dev;
    if (cuDeviceGet(&dev, 0) != 0) return false;
    char name[256] = {0};
    cuDeviceGetName(name, 255, dev);
    CUcontext ctx;
    if (cuCtxCreate_v2(&ctx, CU_CTX_MAP_HOST | CU_CTX_SCHED_BLOCKING_SYNC, dev) != 0) {
        fprintf(stderr, "cuCtxCreate failed\n");
        return false;
    }
    fprintf(stderr, "CUDA device: %s\n", name);
    *ctxOut = ctx;
    return true;
}

int main(int argc, const char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <clip.braw> <cpu|cuda> [maxJobs]\n", argv[0]); return 2; }
    const char* clipName = argv[1];
    s_cuda = strcmp(argv[2], "cuda") == 0;
    if (argc > 3) s_maxJobs = atoi(argv[3]);
    int loops = (argc > 4) ? atoi(argv[4]) : 1;

    const char* libDir = getenv("BRAW_LIBRARY");
    char libPath[4096];
    snprintf(libPath, sizeof(libPath), "%s/", libDir ? libDir : "./");

    IBlackmagicRawFactory* factory = CreateBlackmagicRawFactoryInstanceFromPath(libPath);
    if (!factory) { fprintf(stderr, "factory failed\n"); return 1; }
    IBlackmagicRaw* codec = nullptr;
    if (factory->CreateCodec(&codec) != S_OK) return 1;

    if (s_cuda) {
        if (!setupCuda(&s_cudaCtx)) return 1;
        IBlackmagicRawConfiguration* config = nullptr;
        if (codec->QueryInterface(IID_IBlackmagicRawConfiguration, (void**)&config) != S_OK) return 1;
        if (config->SetPipeline(blackmagicRawPipelineCUDA, s_cudaCtx, nullptr) != S_OK) {
            fprintf(stderr, "SetPipeline(CUDA) failed\n");
            return 1;
        }
        config->Release();
    }

    IBlackmagicRawClip* clip = nullptr;
    if (codec->OpenClip(clipName, &clip) != S_OK) { fprintf(stderr, "open failed\n"); return 1; }
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
    printf("%-4s %ux%u frames=%d jobs=%-2d time=%.3fs fps=%.2f\n",
           s_cuda ? "CUDA" : "CPU", w, h, done, s_maxJobs, sec, done / sec);

    clip->Release();
    codec->Release();
    if (s_cudaCtx) cuCtxDestroy_v2(s_cudaCtx);
    factory->Release();
    free(s_hostBuf);
    return 0;
}
