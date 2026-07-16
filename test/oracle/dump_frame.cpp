/* Oracle tool: decode one frame with the Blackmagic RAW SDK directly and
 * write the raw packed resource buffer to a file. Used by the integration
 * tests to byte-compare the plugin's output against an independent decode
 * of the same SDK (any mismatch is a bug in the plugin's copy paths).
 *
 * Usage: dump_frame <clip.braw> <frame> <u8|u16|f32> <out.raw>
 *        dump_frame <clip.braw> audio <out.raw>   (all packed PCM)
 * The library directory comes from $BRAW_LIBRARY.
 */

#include "BlackmagicRawAPI.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static BlackmagicRawResourceFormat parseFormat(const char* s)
{
    if (strcmp(s, "u8") == 0) return blackmagicRawResourceFormatRGBAU8;
    if (strcmp(s, "u16") == 0) return blackmagicRawResourceFormatRGBU16Planar;
    if (strcmp(s, "f32") == 0) return blackmagicRawResourceFormatRGBF32Planar;
    fprintf(stderr, "bad format %s\n", s);
    exit(2);
}

static BlackmagicRawResourceFormat g_format;
static const char* g_outPath = nullptr;
static int g_result = 1;

class Callback : public IBlackmagicRawCallback
{
public:
    virtual void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result, IBlackmagicRawFrame* frame)
    {
        IBlackmagicRawJob* decodeJob = nullptr;
        if (result == S_OK)
            result = frame->SetResourceFormat(g_format);
        if (result == S_OK)
            result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
        if (result == S_OK)
            result = decodeJob->Submit();
        if (result != S_OK && decodeJob)
            decodeJob->Release();
        readJob->Release();
    }

    virtual void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* image)
    {
        if (result == S_OK) {
            void* resource = nullptr;
            uint32_t sizeBytes = 0;
            if (image->GetResource(&resource) == S_OK &&
                image->GetResourceSizeBytes(&sizeBytes) == S_OK) {
                FILE* f = fopen(g_outPath, "wb");
                if (f) {
                    // short write / failed flush must not exit 0 (a truncated
                    // dump silently passes the byte-exact comparison setup)
                    size_t written = fwrite(resource, 1, sizeBytes, f);
                    int rc = fclose(f);
                    if (written == sizeBytes && rc == 0) g_result = 0;
                }
            }
        }
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

static int dumpAudio(IBlackmagicRawClip* clip, const char* outPath)
{
    IBlackmagicRawClipAudio* audio = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio) != S_OK) {
        fprintf(stderr, "no audio\n");
        return 1;
    }
    uint32_t bitDepth = 0, channelCount = 0;
    uint64_t sampleCount = 0;
    audio->GetAudioBitDepth(&bitDepth);
    audio->GetAudioChannelCount(&channelCount);
    audio->GetAudioSampleCount(&sampleCount);

    const uint32_t chunk = 48000;
    const uint32_t bufSize = chunk * channelCount * (bitDepth / 8);
    char* buf = (char*)malloc(bufSize);
    FILE* f = fopen(outPath, "wb");
    if (!f) return 1;

    uint64_t index = 0;
    bool write_ok = true;
    while (index < sampleCount) {
        uint32_t samplesRead = 0, bytesRead = 0;
        if (audio->GetAudioSamples((int64_t)index, buf, bufSize, chunk, &samplesRead, &bytesRead) != S_OK)
            break;
        if (samplesRead == 0)
            break;
        if (fwrite(buf, 1, bytesRead, f) != bytesRead) { write_ok = false; break; }
        index += samplesRead;
    }
    if (fclose(f) != 0) write_ok = false; // flush errors (e.g. ENOSPC) count
    free(buf);
    audio->Release();
    return (index == sampleCount && write_ok) ? 0 : 1;
}

int main(int argc, const char** argv)
{
    bool audioMode = argc == 4 && strcmp(argv[2], "audio") == 0;
    if (argc != 5 && !audioMode) {
        fprintf(stderr, "usage: %s <clip.braw> <frame> <u8|u16|f32> <out.raw>\n"
                        "       %s <clip.braw> audio <out.raw>\n", argv[0], argv[0]);
        return 2;
    }
    const char* clipPath = argv[1];
    uint64_t frameIndex = 0;
    if (!audioMode) {
        frameIndex = strtoull(argv[2], nullptr, 10);
        g_format = parseFormat(argv[3]);
        g_outPath = argv[4];
    }

    const char* libDir = getenv("BRAW_LIBRARY");
    if (!libDir) {
        fprintf(stderr, "BRAW_LIBRARY not set\n");
        return 2;
    }
    char libPath[4096];
    snprintf(libPath, sizeof(libPath), "%s/", libDir);

    IBlackmagicRawFactory* factory = CreateBlackmagicRawFactoryInstanceFromPath(libPath);
    if (!factory) {
        fprintf(stderr, "factory failed\n");
        return 1;
    }
    IBlackmagicRaw* codec = nullptr;
    if (factory->CreateCodec(&codec) != S_OK) return 1;

    Callback callback;
    codec->SetCallback(&callback);

    IBlackmagicRawClip* clip = nullptr;
    if (codec->OpenClip(clipPath, &clip) != S_OK) {
        fprintf(stderr, "open failed\n");
        return 1;
    }

    if (audioMode) {
        int rc = dumpAudio(clip, argv[3]);
        clip->Release();
        codec->Release();
        factory->Release();
        return rc;
    }

    IBlackmagicRawJob* readJob = nullptr;
    if (clip->CreateJobReadFrame(frameIndex, &readJob) != S_OK) return 1;
    if (readJob->Submit() != S_OK) return 1;

    codec->FlushJobs();

    clip->Release();
    codec->Release();
    factory->Release();
    return g_result;
}
