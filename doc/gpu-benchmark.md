# GPU decoding — implementation & benchmarks

The `gpu-cuda` branch adds a `pipeline` option to `braw.Source`:
`cuda` (NVIDIA, Linux/Windows) and `metal` (Apple GPU, macOS) decode on the
GPU via the Blackmagic RAW SDK's respective pipelines instead of the CPU.

Correctness is verified on both: a GPU-decoded frame matches the CPU decode
to within <0.6 % of the 16-bit range (GPU vs CPU rounding, the same order of
difference seen between the Linux and Windows CPU builds). CUDA was measured
on an RTX 3080 (Ryzen 5 9600X, PCIe gen4 x16), Metal on an Apple M1 Pro
(16-core GPU, macOS 26).

## How it works

- **CUDA**: a context is created via the driver API (`libcuda.so`, no toolkit
  needed — `src/core/braw/cuda.zig` dlopens it) and handed to
  `IBlackmagicRawConfiguration::SetPipeline(CUDA, ctx, null)` before
  `OpenClip`. The decoded `IBlackmagicRawProcessedImage` lives in GPU memory;
  the decoder reads it back with `cuMemcpyDtoH` into a **pinned** host
  staging buffer (pooled, since pinned allocation is expensive), then the
  existing plane-copy path writes it into the host frame.
- **Metal**: the SDK creates the device (`CreatePipelineDeviceIterator(Metal,
  InteropNone)` → `CreateDevice` → `SetFromDevice`). The decoded image is a
  private (GPU-only) `MTLBuffer`; `src/core/braw/metal.zig` blits it into a
  **managed staging `MTLBuffer`** (pooled — allocating 68 MB per frame costs
  more than the decode) via the device's command queue, waits, and feeds the
  staging buffer's contents pointer straight into the plane copy — no
  intermediate host copy. The Objective-C runtime is dlopened, so the plugin
  still cross-compiles from Linux without a macOS SDK.

## Results — Metal (Apple M1 Pro, unified memory)

**Raw decode throughput** (standalone `test/bench/braw_bench_mac.mm`,
pipelined, 6 jobs in flight, reused staging buffer):

| clip | CPU | Metal + readback | Metal, no readback |
|---|---|---|---|
| 4.6K (4608×2592, u16) | 80 fps | 202 fps (**2.5×**) | 342 fps (4.3×) |
| 6K (6048×4032, u16) | 32 fps | 86 fps (**2.7×**) | 155 fps (4.8×) |

**In the plugin, via VapourSynth** (`test/bench/bench_vs.py`, best thread
count):

| clip / resolution | CPU fps | Metal fps | speedup |
|---|---|---|---|
| 4608×2592 (4.6K, u16) | 81 | 185 | **2.28×** |
| 2304×1296 (scale=2) | 271 | 441 | **1.63×** |
| 6048×4032 (6K, u16) | 32 | 49 | **1.55×** |

At 4.6K both pipelines run at ~90 % of their raw standalone decode rate —
the plugin adds almost no overhead anymore (see "How the plugin keeps up"
below). And the CPU is left nearly idle with Metal: at 4.6K the CPU pipeline
burns ~120 ms of CPU time per frame (~5 cores busy), the Metal pipeline
~21 ms — **~6× less CPU work at 2× the throughput**, so the cores stay free
for downstream filters.

Two properties of Apple Silicon make Metal a clear win where CUDA isn't:
the readback blit stays on-chip (unified memory, no PCIe round-trip), and
the M1 CPU decode is comparatively slow (~80 fps vs ~110 on the Ryzen).
Even at half resolution — where CUDA lost to the CPU in the pre-parallel
measurements — Metal stays well ahead.

## Results — CUDA (RTX 3080, discrete, PCIe)

**Raw decode throughput** (standalone `test/bench/braw_bench.cpp`, pipelined,
reused buffer, pinned readback):

| pipeline | fps |
|---|---|
| CPU | ~110 |
| CUDA | ~550 |

The GPU decoder itself is roughly **5× faster**.

Raw decode scales with resolution — at 6K (6048×4032) the CPU falls to
~53 fps while CUDA holds ~207 fps (**3.9×**).

**In the plugin, via VapourSynth** (`test/bench/bench_vs.py`, real multi-threaded
frameserver use):

| clip / resolution | CPU fps | CUDA fps | speedup |
|---|---|---|---|
| 4608×2592 (4.6K, u16) | 74 | 100 | **1.35×** |
| 2304×1296 (scale=2) | 242 | 209 | 0.86× |
| 6048×4032 (6K, u16) | 25.8 | 26.2 | **1.02×** |

The 6K row is the clearest illustration: the raw GPU decode is 3.9× faster
there, yet in the plugin the two pipelines are identical (~26 fps). Each 6K
frame is 146 MB, so allocating the VapourSynth frame and copying the decoded
pixels into it dwarfs the decode entirely — and that cost is the same
whether the decode ran on the CPU or GPU. The bigger the frame, the more the
copy dominates, so the in-plugin GPU advantage *shrinks* as resolution grows
even though the raw decode advantage grows.

*(The CUDA table predates two plugin-side fixes made during the Metal
bring-up — the parallel filter mode and the deferred plane copy, see below —
which lifted Metal from 1.0× to 2.3×. Both also apply to CUDA, so the PC
numbers should improve when re-measured; the raw 5× is the upper bound.)*

## How the plugin keeps up (two fixes)

Initially the plugin capped both pipelines at the latency of ONE sequential
request (~45 fps CPU / ~95 fps Metal at 4.6K, flat across VS thread counts)
while the raw standalone benchmarks pipelined to 80/202 fps. Two changes
closed the gap:

1. **`fmParallel` filter mode.** The source was registered `fmUnordered`,
   which makes VapourSynth serialize `getFrame` calls — only one decode
   request was ever in flight, so the SDK could never pipeline and extra VS
   threads did nothing. `decodeFrame` is fully thread-safe (per-request
   state, mutexed job submission, pooled staging), so the filter is now
   `fmParallel`: N VS threads = N SDK jobs in flight.
2. **Deferred plane copy.** The SDK dispatches completion callbacks
   serially; the plugin used to do the GPU readback wait *and* the 68 MB
   plane copy inside `ProcessComplete`, making that the serial bottleneck
   under concurrency. The callback now only validates and parks the decoded
   image (retained `IBlackmagicRawProcessedImage` on CPU, committed-but-not-
   awaited blit + staging buffer on Metal, pinned buffer on CUDA) in the
   request; the REQUESTING thread waits for the blit and copies the planes —
   in parallel across VS worker threads.

Remaining ceilings: at 4.6K both pipelines sit near their raw decode rates.
At 6K the Metal path reaches ~57 % of raw (49 vs 86 fps) — each frame moves
146 MB through blit, plane copy and VS frame allocation, so memory traffic
and allocation dominate; the CPU pipeline is already at its raw limit.

## Takeaway

- **macOS / Apple Silicon**: use `pipeline="metal"` — 1.5–2.3× the source
  throughput at every resolution tested *and* an almost idle CPU. The CPU
  pipeline only makes sense if the GPU is busy elsewhere.
- **Linux/Windows + NVIDIA**: `pipeline="cuda"` is worth it when decoding
  full-resolution BRAW **and** you want the CPU cores free for downstream
  filters (~1.35× at 4.6K measured pre-fmParallel; likely more now). For a
  pure source→disk pass at reduced resolution the CPU pipeline may still
  win — re-measure.
- Neither is the default: `cpu` behaves identically everywhere.

Reproduce:

```sh
# raw decode, Linux/Windows (CUDA)
g++ -O2 -std=c++11 -Ithird_party/braw/sdk/Linux/Include test/bench/braw_bench.cpp \
    third_party/braw/sdk/Linux/Include/BlackmagicRawAPIDispatch.cpp -o braw_bench -lcuda -ldl -lpthread
BRAW_LIBRARY=$PWD/third_party/braw/runtime/linux-x86_64 ./braw_bench <clip.braw> cuda 6 3

# raw decode, macOS (Metal)
clang++ -O2 -std=c++14 -fobjc-arc -Ivendor/braw-sdk/Mac test/bench/braw_bench_mac.mm \
    vendor/braw-sdk/Mac/BlackmagicRawAPIDispatch.cpp -framework CoreFoundation -framework Metal -o braw_bench_mac
BRAW_LIBRARY=$PWD/third_party/braw/runtime/macos-universal ./braw_bench_mac <clip.braw> metal 6 3

# plugin, via VapourSynth (picks the platform's GPU pipeline automatically)
encode_test/.venv/bin/python test/bench/bench_vs.py <clip.braw>
```
