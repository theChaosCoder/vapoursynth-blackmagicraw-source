#!/usr/bin/env python3
"""Integration tests for braw.Source against real .braw material.

Run inside the encode_test venv:
    encode_test/.venv/bin/python test/python/test_source.py

Material comes from third_party/ (tools/extract-sdk.sh --samples); tests
that need missing material are skipped.
"""

import hashlib
import os
import random
import sys
from fractions import Fraction
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
PLUGIN = REPO / "zig-out/vapoursynth/libbrawsource.so"
LIBPATH = REPO / "third_party/braw/runtime/linux-x86_64"
SDK_SAMPLE = REPO / "third_party/braw/sdk/Media/sample.braw"
PORTRAIT = (
    REPO
    / "third_party/samples/Blackmagic_RAW_Note_Suwanchote_Wedding_Portrait/A054_08251201_C159.braw"
)

import vapoursynth as vs

core = vs.core

passed = 0
skipped = 0


def check(cond, msg):
    global passed
    if not cond:
        raise AssertionError(msg)
    passed += 1


def frame_digest(frame):
    h = hashlib.sha256()
    for p in range(frame.format.num_planes):
        h.update(bytes(frame[p]))
    return h.hexdigest()


def open_clip(path, **kw):
    return core.braw.Source(source=str(path), libpath=str(LIBPATH), **kw)


def test_sdk_sample():
    clip = open_clip(SDK_SAMPLE)
    check(clip.width == 4608 and clip.height == 2592, f"dims {clip.width}x{clip.height}")
    check(clip.num_frames == 1, f"num_frames {clip.num_frames}")
    check(clip.fps == Fraction(24, 1), f"fps {clip.fps}")
    check(clip.format.id == vs.RGB48, f"format {clip.format}")

    f = clip.get_frame(0)
    p = f.props
    check(p["_DurationNum"] == 1 and p["_DurationDen"] == 24, "duration props")
    check(p["_Matrix"] == 0, "_Matrix")
    check(p["_Range"] == 1, "_Range full")
    check(p["BRAWISO"] == 800, f"BRAWISO {p.get('BRAWISO')}")
    check(p["BRAWTimecode"] == b"22:23:40:20" or p["BRAWTimecode"] == "22:23:40:20",
          f"timecode {p.get('BRAWTimecode')}")
    check(p["BRAWWhiteBalanceKelvin"] == 6870, "kelvin prop")
    check(p["BRAWSidecarAttached"] == 1, "sidecar attached prop")
    check(p["BRAWCameraType"] in (b"Blackmagic URSA Mini Pro 4.6K", "Blackmagic URSA Mini Pro 4.6K"),
          "camera type prop")
    check(abs(p["BRAWExposure"] - (-1.995)) < 1e-3, "exposure prop")
    # image content sanity: not all-black, not all-white
    data = bytes(f[0])
    check(any(b != 0 for b in data[:65536]), "R plane has content")


def test_portrait_ntsc_and_random_access():
    clip = open_clip(PORTRAIT)
    check(clip.fps == Fraction(24000, 1001), f"NTSC fps {clip.fps}")
    check(clip.num_frames == 99, f"num_frames {clip.num_frames}")

    # determinism: same frame decoded twice is identical
    d1 = frame_digest(clip.get_frame(42))
    d2 = frame_digest(clip.get_frame(42))
    check(d1 == d2, "determinism frame 42")

    # random access == sequential: shuffled requests yield the same content
    indices = [0, 7, 42, 63, 98]
    sequential = {n: frame_digest(clip.get_frame(n)) for n in indices}
    shuffled = indices[:]
    random.seed(1234)
    random.shuffle(shuffled)
    # fresh instance to defeat any caching
    clip2 = open_clip(PORTRAIT)
    for n in shuffled:
        check(frame_digest(clip2.get_frame(n)) == sequential[n], f"random access frame {n}")

    # timecode advances monotonically
    tc0 = clip.get_frame(0).props["BRAWTimecode"]
    tc1 = clip.get_frame(24).props["BRAWTimecode"]
    check(tc0 != tc1, "timecode advances")


def test_formats():
    # bitdepth selects the output depth (each variant must also decode)
    clip8 = open_clip(SDK_SAMPLE, bitdepth=8)
    check(clip8.format.id == vs.RGB24, "bitdepth=8 -> RGB24")
    clip8.get_frame(0)

    check(open_clip(SDK_SAMPLE, bitdepth=16).format.id == vs.RGB48, "bitdepth=16 -> RGB48")

    clipf = open_clip(SDK_SAMPLE, bitdepth=32)
    check(clipf.format.id == vs.RGBS, "bitdepth=32 -> RGBS")
    clipf.get_frame(0)

    cliph = open_clip(SDK_SAMPLE, bitdepth=16, fp=True)
    check(cliph.format.id == vs.RGBH, "bitdepth=16 fp -> RGBH")
    cliph.get_frame(0)

    # automatic: 16-bit int normally, 32-bit float for Linear gamma
    check(open_clip(SDK_SAMPLE).format.id == vs.RGB48, "auto -> RGB48")
    check(open_clip(SDK_SAMPLE, gamma="Linear").format.id == vs.RGBS,
          "auto + Linear gamma -> RGBS")

    # invalid combinations are rejected
    for kw in (dict(bitdepth=8, fp=True), dict(bitdepth=12), dict(fp=True)):
        try:
            open_clip(SDK_SAMPLE, **kw)
            raise AssertionError(f"expected error for {kw}")
        except vs.Error:
            global passed
            passed += 1

def test_scale():
    clip = open_clip(SDK_SAMPLE, scale=2)
    check(clip.width == 4608 // 2 and clip.height == 2592 // 2,
          f"half scale dims {clip.width}x{clip.height}")
    clip.get_frame(0)
    clip4 = open_clip(SDK_SAMPLE, scale=4)
    check(clip4.width == 4608 // 4, "quarter scale width")
    clip4.get_frame(0)


def test_oracle_byte_exact():
    """Byte-compare plugin output against an independent SDK decode."""
    import subprocess
    import tempfile

    oracle = REPO / "test/oracle/bin/dump_frame"
    env = dict(os.environ, BRAW_LIBRARY=str(LIBPATH))

    def dump(fmt):
        f = tempfile.NamedTemporaryFile(suffix=".raw", delete=False)
        f.close()
        subprocess.run(
            [str(oracle), str(SDK_SAMPLE), "0", fmt, f.name],
            check=True, env=env,
        )
        data = Path(f.name).read_bytes()
        os.unlink(f.name)
        return data

    # u16: SDK planar buffer == plugin planes concatenated
    ref = dump("u16")
    f = open_clip(SDK_SAMPLE, bitdepth=16).get_frame(0)
    got = b"".join(bytes(f[p]) for p in range(3))
    check(got == ref, "u16 planar byte-exact vs oracle")

    # f32: same, planar float
    ref = dump("f32")
    f = open_clip(SDK_SAMPLE, bitdepth=32).get_frame(0)
    got = b"".join(bytes(f[p]) for p in range(3))
    check(got == ref, "f32 planar byte-exact vs oracle")

    # u8: SDK interleaved RGBA -> per-channel stride slicing
    ref = dump("u8")
    f = open_clip(SDK_SAMPLE, bitdepth=8).get_frame(0)
    for p in range(3):
        check(bytes(f[p]) == ref[p::4], f"u8 deinterleave plane {p} byte-exact")
    check(set(ref[3::4]) == {255}, "SDK alpha channel is constant opaque")


def test_audio():
    import subprocess
    import tempfile

    clip = core.braw.AudioSource(source=str(SDK_SAMPLE), libpath=str(LIBPATH))
    check(clip.sample_rate == 48000, f"sample rate {clip.sample_rate}")
    check(clip.bits_per_sample == 24, f"bits {clip.bits_per_sample}")
    check(clip.num_channels == 2, f"channels {clip.num_channels}")
    check(clip.num_samples == 2000, f"samples {clip.num_samples}")

    # oracle: full packed PCM dumped independently via the SDK
    oracle = REPO / "test/oracle/bin/dump_frame"
    env = dict(os.environ, BRAW_LIBRARY=str(LIBPATH))
    tmp = tempfile.NamedTemporaryFile(suffix=".raw", delete=False)
    tmp.close()
    subprocess.run([str(oracle), str(SDK_SAMPLE), "audio", tmp.name], check=True, env=env)
    ref = Path(tmp.name).read_bytes()
    os.unlink(tmp.name)
    check(len(ref) == 2000 * 2 * 3, f"oracle pcm size {len(ref)}")

    # reconstruct packed interleaved 24-bit from the VS planes
    # (VS stores 24-bit MSB-aligned in i32, little-endian: bytes 1..3)
    got = bytearray()
    n_frames = clip.num_frames
    for fi in range(n_frames):
        f = clip.get_frame(fi)
        planes = [bytes(f[c]) for c in range(2)]
        nsamp = len(planes[0]) // 4
        for s in range(nsamp):
            for c in range(2):
                got += planes[c][s * 4 + 1 : s * 4 + 4]
    check(bytes(got) == ref, "24-bit PCM byte-exact vs oracle")

    # portrait clip: EOF/last-frame length
    if PORTRAIT.exists():
        a2 = core.braw.AudioSource(source=str(PORTRAIT), libpath=str(LIBPATH))
        check(a2.num_samples == 198198, f"portrait samples {a2.num_samples}")
        last = a2.get_frame(a2.num_frames - 1)
        expect_last = a2.num_samples - (a2.num_frames - 1) * 3072
        check(len(bytes(last[0])) == expect_last * 4, "last audio frame length")


def test_processing_overrides():
    base = frame_digest(open_clip(SDK_SAMPLE).get_frame(0))

    # each override must change the image AND stay deterministic
    for kw in (dict(kelvin=3200), dict(exposure=1.5), dict(iso=1600),
               dict(gamma="Blackmagic Design Film"), dict(gamut="Rec.709")):
        c1 = open_clip(SDK_SAMPLE, **kw)
        d1 = frame_digest(c1.get_frame(0))
        d2 = frame_digest(open_clip(SDK_SAMPLE, **kw).get_frame(0))
        check(d1 != base, f"override changes output: {kw}")
        check(d1 == d2, f"override deterministic: {kw}")

    # tint alone
    ct = open_clip(SDK_SAMPLE, tint=-20)
    check(frame_digest(ct.get_frame(0)) != base, "tint changes output")

    # invalid gamma must be rejected at open time
    try:
        open_clip(SDK_SAMPLE, gamma="Definitely Not A Gamma")
        raise AssertionError("expected error for invalid gamma")
    except vs.Error as e:
        check("gamma" in str(e), "invalid gamma error names the parameter")

    # CICP tagging: standard spaces get _Transfer/_Primaries, native BM none
    p709 = open_clip(SDK_SAMPLE, gamma="Rec.709", gamut="Rec.709").get_frame(0).props
    check(p709["_Transfer"] == 1 and p709["_Primaries"] == 1, "709 decode tagged 1/1")
    pnat = open_clip(SDK_SAMPLE).get_frame(0).props
    check("_Transfer" not in pnat and "_Primaries" not in pnat,
          "native BM spaces stay untagged")


def test_plugin_dir_deps_discovery():
    """Without libpath, the runtime is found in <plugindir>/blackmagic_linux_deps.

    Runs in a fresh subprocess: the loader caches the library process-wide,
    so discovery can't be exercised after other tests loaded it explicitly.
    """
    import subprocess

    deps_link = PLUGIN.parent / "blackmagic_linux_deps"
    if not deps_link.exists():
        deps_link.symlink_to(LIBPATH.resolve(), target_is_directory=True)

    snippet = (
        "import vapoursynth as vs\n"
        f"vs.core.std.LoadPlugin(path={str(PLUGIN)!r})\n"
        f"c = vs.core.braw.Source(source={str(SDK_SAMPLE)!r})\n"  # no libpath!
        "c.get_frame(0)\n"
        "print('deps-dir discovery OK')\n"
    )
    env = {k: v for k, v in os.environ.items() if k != "BRAW_LIBRARY"}
    res = subprocess.run(
        [sys.executable, "-c", snippet],
        capture_output=True, text=True, env=env,
    )
    check(res.returncode == 0 and "deps-dir discovery OK" in res.stdout,
          f"plugin-dir deps discovery (stderr: {res.stderr.strip()[:300]})")


def test_cuda_pipeline():
    """CUDA decode must produce a visually identical image to the CPU path.

    GPU and CPU rounding differ slightly (like Windows vs Linux), so this
    asserts a small bound, not byte-equality. Skipped when no CUDA device.
    """
    import array

    try:
        gpu = open_clip(PORTRAIT, pipeline="cuda")
        gf = gpu.get_frame(0)
    except vs.Error as e:
        if "CUDA" in str(e) or "unavailable" in str(e).lower():
            print("  SKIP: no CUDA device")
            return
        raise

    cf = open_clip(PORTRAIT, pipeline="cpu").get_frame(0)
    check(gpu.format.id == vs.RGB48, "cuda -> RGB48")
    maxdiff = 0
    for p in range(3):
        a = array.array("H"); a.frombytes(bytes(cf[p]))
        b = array.array("H"); b.frombytes(bytes(gf[p]))
        for i in range(0, len(a), 101):  # sample every 101st for speed
            d = abs(a[i] - b[i])
            if d > maxdiff:
                maxdiff = d
    # GPU vs CPU color science: well under 1% of the 16-bit range
    check(maxdiff < 655, f"cuda vs cpu max diff {maxdiff} < 655 (1%)")
    # determinism on the GPU path too
    check(frame_digest(gpu.get_frame(0)) == frame_digest(gpu.get_frame(0)),
          "cuda determinism")


def test_errors():
    try:
        core.braw.Source(source="/nonexistent/foo.braw", libpath=str(LIBPATH))
        raise AssertionError("expected error for missing file")
    except vs.Error:
        global passed
        passed += 1


def main():
    global skipped
    if not PLUGIN.exists():
        print("plugin not built (zig build)", file=sys.stderr)
        return 2
    core.std.LoadPlugin(path=str(PLUGIN))

    tests = []
    if SDK_SAMPLE.exists() and LIBPATH.exists():
        tests += [test_sdk_sample, test_formats, test_scale, test_errors,
                  test_processing_overrides, test_plugin_dir_deps_discovery]
        if (REPO / "test/oracle/bin/dump_frame").exists():
            tests += [test_oracle_byte_exact, test_audio]
        else:
            print("SKIP: oracle not built (run tools/build-oracle.sh)")
            skipped += 1
    else:
        print("SKIP: SDK sample/runtime missing (run tools/extract-sdk.sh)")
        skipped += 1
    if PORTRAIT.exists() and LIBPATH.exists():
        tests += [test_portrait_ntsc_and_random_access, test_cuda_pipeline]
    else:
        print("SKIP: Portrait sample missing (run tools/extract-sdk.sh --samples)")
        skipped += 1

    for t in tests:
        print(f"-- {t.__name__}")
        t()

    print(f"OK: {passed} checks passed, {skipped} suites skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
