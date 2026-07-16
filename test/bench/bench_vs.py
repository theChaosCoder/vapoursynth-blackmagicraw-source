#!/usr/bin/env python3
"""Multi-threaded plugin benchmark: CPU vs GPU pipeline via VapourSynth.

Requests every frame through VapourSynth's threaded prefetch (real plugin
usage: several decodeFrame calls run concurrently, so the SDK has jobs in
flight). Sweeps VS thread counts and reports fps per pipeline. The GPU
pipeline is picked per platform: CUDA on Linux/Windows, Metal on macOS —
or forced with the second argument (e.g. `opencl`).

    encode_test/.venv/bin/python test/bench/bench_vs.py [clip.braw] [pipeline]
"""
import sys
import time
from pathlib import Path

import vapoursynth as vs

REPO = Path(__file__).resolve().parent.parent.parent
if sys.platform == "darwin":
    PLUGIN = REPO / "zig-out/vapoursynth/libbrawsource.dylib"
    LIBPATH = REPO / "third_party/braw/runtime/macos-universal"
    GPU_PIPELINE = "metal"
elif sys.platform == "win32":
    PLUGIN = REPO / "zig-out/vapoursynth/brawsource.dll"
    LIBPATH = REPO / "third_party/braw/runtime/windows-x86_64"
    GPU_PIPELINE = "cuda"
else:
    PLUGIN = REPO / "zig-out/vapoursynth/libbrawsource.so"
    LIBPATH = REPO / "third_party/braw/runtime/linux-x86_64"
    GPU_PIPELINE = "cuda"
DEFAULT_CLIP = REPO / "third_party/samples/Blackmagic_RAW_Note_Suwanchote_Wedding_Portrait/A054_08251201_C159.braw"

core = vs.core
core.std.LoadPlugin(path=str(PLUGIN))

clip_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CLIP
if len(sys.argv) > 2:
    GPU_PIPELINE = sys.argv[2]
LOOPS = 4  # lengthen the clip for a stable measurement


def bench(pipeline, threads):
    core.num_threads = threads
    src = core.braw.Source(source=str(clip_path), libpath=str(LIBPATH), pipeline=pipeline)
    src = core.std.Loop(src, LOOPS)
    n = src.num_frames
    # warmup
    for i, _ in zip(range(threads * 2), src.frames(close=True)):
        pass
    t0 = time.perf_counter()
    count = 0
    for _f in src.frames(close=True):
        count += 1
    dt = time.perf_counter() - t0
    return count, dt, count / dt


def main():
    info = core.braw.Source(source=str(clip_path), libpath=str(LIBPATH))
    print(f"clip: {clip_path.name}  {info.width}x{info.height}  {info.num_frames} frames x{LOOPS}")
    print(f"{'pipeline':<8} {'threads':>7} {'frames':>7} {'time':>8} {'fps':>8}")
    results = {}
    for pipeline in ("cpu", GPU_PIPELINE):
        for threads in (1, 3, 6, 12):
            try:
                count, dt, fps = bench(pipeline, threads)
            except vs.Error as e:
                print(f"{pipeline:<8} {threads:>7}  ERROR: {str(e)[:60]}")
                continue
            print(f"{pipeline:<8} {threads:>7} {count:>7} {dt:>7.3f}s {fps:>7.1f}")
            results[(pipeline, threads)] = fps
    # summary
    cpu_best = max((v for k, v in results.items() if k[0] == "cpu"), default=0)
    gpu_best = max((v for k, v in results.items() if k[0] == GPU_PIPELINE), default=0)
    if cpu_best and gpu_best:
        print(f"\nbest CPU: {cpu_best:.1f} fps   best {GPU_PIPELINE.upper()}: {gpu_best:.1f} fps   "
              f"speedup: {gpu_best / cpu_best:.2f}x")


if __name__ == "__main__":
    main()
