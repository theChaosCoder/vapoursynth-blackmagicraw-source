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

**In the plugin, via VapourSynth** (`test/bench/bench_vs.py`):

| clip / resolution | CPU fps | Metal fps | speedup |
|---|---|---|---|
| 4608×2592 (4.6K, u16) | 48 | 95 | **1.99×** |
| 2304×1296 (scale=2) | 177 | 208 | **1.18×** |
| 6048×4032 (6K, u16) | 22.4 | 41.3 | **1.84×** |

And the CPU is left nearly idle: at 4.6K the CPU pipeline burns ~120 ms of
CPU time per frame (~5 cores busy), the Metal pipeline ~21 ms (~1.7 cores) —
**~6× less CPU work at 2× the throughput**, so the cores stay free for
downstream filters.

Two properties of Apple Silicon make Metal a clear win where CUDA isn't:
the readback blit stays on-chip (unified memory, no PCIe round-trip), and
the M1 CPU decode is comparatively slow (~80 fps vs ~110 on the Ryzen).
Even at half resolution — where CUDA loses to the CPU — Metal stays ahead.

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

*(The CUDA numbers above predate the staging-pool rework that lifted Metal
from 1.0× to 2× in-plugin; the CUDA path always pooled its pinned buffers,
so its numbers should stand, but re-measuring on the PC would confirm.)*

## Where the remaining ceiling is

The SDK delivers job-completion callbacks serially, and the plugin does its
per-frame heavy lifting (GPU readback + plane copy into the VapourSynth
frame) inside that callback. That serial section caps in-plugin throughput
regardless of VapourSynth's thread count — which is why `bench_vs.py` shows
flat fps across threads. Moving the plane copy out of the callback into the
requesting thread (retaining the processed image / staging buffer until
then) would let frame copies run in parallel and is the next optimization
candidate if more source throughput is needed.

## Takeaway

- **macOS / Apple Silicon**: use `pipeline="metal"` for full- or
  half-resolution decodes — ~2× the source throughput *and* an almost idle
  CPU. The CPU pipeline only makes sense if the GPU is busy elsewhere.
- **Linux/Windows + NVIDIA**: `pipeline="cuda"` is worth it when decoding
  full-resolution BRAW **and** you want the CPU cores free for downstream
  filters (~1.35× at 4.6K). For a pure source→disk pass, or at reduced
  resolutions, the CPU pipeline is as fast or faster.
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
