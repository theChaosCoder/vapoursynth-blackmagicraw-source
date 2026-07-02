# CUDA decoding — implementation & benchmark

The `gpu-cuda` branch adds a `pipeline="cuda"` option to `braw.Source` that
decodes on the GPU via the Blackmagic RAW SDK's CUDA pipeline instead of the
CPU. Correctness is verified: a CUDA-decoded frame matches the CPU decode to
within <0.4 % of the 16-bit range (GPU vs CPU rounding, the same order of
difference seen between the Linux and Windows CPU builds).

## How it works

- A CUDA context is created via the driver API (`libcuda.so`, no toolkit
  needed — `src/core/braw/cuda.zig` dlopens it) and handed to
  `IBlackmagicRawConfiguration::SetPipeline(CUDA, ctx, null)` before
  `OpenClip`.
- The decoded `IBlackmagicRawProcessedImage` now lives in GPU memory; the
  decoder reads it back with `cuMemcpyDtoH` into a **pinned** host staging
  buffer (pooled, since pinned allocation is expensive), then the existing
  plane-copy path writes it into the host frame.

## Results (RTX 3080, Ryzen 5 9600X, PCIe gen4 x16, 4608×2592 clip, u16)

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

## Why the plugin gain is smaller than the raw 5×

At full resolution each frame is 68 MB (RGB u16). Once decoded, that data
still has to be copied into a VapourSynth frame on the CPU and handed through
the frameserver — and that per-frame memory traffic plus VS frame handling
caps throughput at ~90–100 fps regardless of where the decode happened. So
the GPU's 5× decode advantage is largely masked: the bottleneck moves from
*decoding* to *moving the decoded pixels around*.

At reduced resolution (scale=2) there is far less to decode, so the fixed GPU
overhead (readback latency, PCIe round-trips, context switches) makes CUDA
**slower** than the CPU.

## Takeaway

`pipeline="cuda"` is worth using when decoding full-resolution BRAW **and**
you want the CPU cores free for downstream filters in the graph — the decode
work moves off the CPU for a ~1.3× source-throughput gain at 4.6K. For a
pure source→disk pass, or at reduced resolutions, the CPU pipeline is as fast
or faster. It is not the default for that reason.

Reproduce:

```sh
# raw decode
g++ -O2 -std=c++11 -Ithird_party/braw/sdk/Linux/Include test/bench/braw_bench.cpp \
    third_party/braw/sdk/Linux/Include/BlackmagicRawAPIDispatch.cpp -o braw_bench -lcuda -ldl -lpthread
BRAW_LIBRARY=$PWD/third_party/braw/runtime/linux-x86_64 ./braw_bench <clip.braw> cuda 6 3

# plugin, via VapourSynth
encode_test/.venv/bin/python test/bench/bench_vs.py <clip.braw>
```
