# Plan: Dual VapourSynth / AviSynth+ Source Plugin for Blackmagic RAW (Zig)

> **Historical document.** This is the original implementation plan (v1,
> CPU-only). The shipped architecture has moved on — GPU pipelines
> (CUDA/Metal/OpenCL), `fmParallel`, deferred plane copies and requester-side
> readback are documented in `doc/gpu-benchmark.md` and the module doc
> comments, which are authoritative. Kept for the ABI research notes.

Status: M0–M8 implemented (2026-07-02). Linux fully tested (56 integration
checks incl. byte-exact oracle comparison); Windows (VS + AviSynth) and macOS
artifacts cross-compile, runtime validation on real hosts pending. GitHub
repo + CI intentionally deferred. Deviations from the original plan are
recorded in the git history (notably: f16 decodes via f32 — the CPU pipeline
rejects half-float resource formats; `sidecar` param dropped — the SDK always
auto-applies sidecars on open).
Targets: VapourSynth win/linux/mac x86_64 + mac aarch64 · AviSynth+ win x86_64 only
Language: Zig 0.16.0 · VS binding: dnjulek/vapoursynth-zig (pinned commit, same as autoadjuster)

## 1. Goal

A source plugin that opens `.braw` clips in VapourSynth and AviSynth+:

- Video 8/16-bit integer, 16/32-bit float RGB, optional alpha, decoded via the official
  Blackmagic RAW SDK 5.1 (CPU pipeline in v1).
- Audio (PCM, typically 24-bit/48kHz) as VS audio node / attached AVS audio track.
- Frame-exact random access: frame N always returns frame N (BRAW is intra-only and
  index-addressed, so this is structurally guaranteed — tests enforce it).
- Frame props from SDK metadata (standard `_...` props + `BRAW...` props).
- Sensible processing control (as-shot by default, explicit overrides).

## 2. Verified findings (research phase, all confirmed locally)

### SDK acquisition
- The zips in `SDK-Sources/` are the *desktop software* installers (Player/SpeedTest),
  not the developer SDK. **The full SDK for all platforms hides inside the Mac zip**:
  `Blackmagic_RAW_5.1.dmg → Install Blackmagic RAW 5.1.pkg → BlackmagicRawSDK.pkg →
  cpio payload → "Blackmagic RAW SDK/{Win,Linux,Mac,iPadOS}/{Include,Samples}"` plus
  `Documents/` (SDK PDF, Gen5 color science paper) and `Media/sample.braw` (1-frame
  4.6K test clip + `.sidecar`). Extraction is scriptable with `7z` + `cpio`.
- Headers carry a Boost-style license (free to use/distribute/derive with notice) →
  vendoring `Include/` in the repo is fine. Runtime libraries are NOT committed.
- Linux runtime libs come from the Linux desktop tar:
  `BlackmagicRAW/BlackmagicRawAPI/{libBlackmagicRawAPI.so, libDecoderCUDA.so,
  libDecoderOpenCL.so, libInstructionSetServicesAVX{,2}.so, libc++{,abi}.so.1}`.
  `libBlackmagicRawAPI.so` has `RUNPATH=$ORIGIN` (siblings resolve automatically),
  needs `libGL.so.1`, and exports exactly 12 symbols:
  `CreateBlackmagicRawFactoryInstance`, `VariantInit`, `VariantClear`, 7× `SafeArray*`.
- RPM installs to `/usr/lib64/blackmagic/BlackmagicRAWPlayer/BlackmagicRawAPI/`.
- Mac framework is universal x86_64+arm64 → both mac targets are viable.

### API shape (from `BlackmagicRawAPI.h` / `.idl`, 905 lines, fully read)
- COM-style `IUnknown` interfaces, created via exported C function
  `CreateBlackmagicRawFactoryInstance` (dlopen/LoadLibrary — the SDK's own
  `BlackmagicRawAPIDispatch.cpp` does exactly this; we reimplement it in Zig).
- Decode flow (verified by compiling+running SDK samples locally with g++):
  `factory → CreateCodec → codec.SetCallback(cb) → codec.OpenClip(path) → clip`
  `clip.CreateJobReadFrame(frameIndex) → Submit()` → callback `ReadComplete(job, hr, frame)`
  → `frame.SetResourceFormat/SetResolutionScale` → `frame.CreateJobDecodeAndProcessFrame`
  → `Submit()` → callback `ProcessComplete(job, hr, processedImage)` → copy pixels.
  Multiple jobs in flight are fine (official sample uses 3); FIFO per codec;
  `FlushJobs()` blocks until all complete. `ReadComplete` gets `E_UNEXPECTED` for
  dropped frames (partial multicard recordings).
- The callback object's `AddRef/Release` may be no-op stubs returning 0 (official
  samples do exactly that) → a static Zig struct with hand-built vtable suffices.
- Audio: `clip QI IBlackmagicRawClipAudio` → `GetAudioBitDepth/ChannelCount/SampleRate/
  SampleCount(per channel)` + synchronous `GetAudioSamples(sampleFrameIndex, buf, ...)`,
  packed interleaved little-endian PCM (24-bit = 3 bytes). Outside the job system.
- Resolution scale: full/half/quarter/eighth per frame; `IBlackmagicRawClipResolutions`
  reports resulting dimensions up front. Read-job hint can skip bitstream reads.
- Processing attributes: clip-level (gamma, gamut, color science gen, tone curve,
  highlight recovery, gamut compression, 3D LUT mode) + frame-level (kelvin, tint,
  exposure, ISO) via `CloneClipProcessingAttributes` / `CloneFrameProcessingAttributes`
  and `SetClipAttribute`/`SetFrameAttribute`; valid value lists queryable at runtime.
  Defaults = "read from metadata" (as shot). Sidecar files auto-apply at `OpenClip`.

### Platform ABI differences (the core porting risk, now fully mapped)
| Aspect | Linux | macOS | Windows |
|---|---|---|---|
| Strings | `const char*` (UTF-8) | `CFStringRef` (CoreFoundation) | `BSTR` (UTF-16, oleaut32) |
| Variant | own 16-byte struct | own struct, `bstrVal: CFStringRef` | OLE `VARIANT` (24 B) |
| SafeArray | own struct + 7 exported fns | same as Linux | OLE `SAFEARRAY` (oleaut32) |
| `QueryInterface` iid | 16-byte struct **by value** | by value | `REFIID` = **pointer** to GUID (LE layout!) |
| `AddRef/Release` return | `c_ulong` (64-bit) | `c_ulong` | `ULONG` (32-bit) |
| `bool` outs | `bool` (1 B) | `bool` (1 B) | `BOOL` (4 B) |
| vtable tail | +2 virtual-dtor slots (Itanium; declared last → public method slots unaffected) | same | none (MIDL-generated, no dtor) |
- Vtable order = declaration order, identical across platforms. `IBlackmagicRawReadJobHints`
  has no virtual dtor anywhere.
- Zig models interfaces as `extern struct { vtable: *const VTable }`; we implement
  `IBlackmagicRawCallback` with a hand-built vtable (incl. 2 no-op dtor slots on
  ELF/Mach-O). All methods use C calling convention on x86_64/aarch64.

### Frame rate / metadata ground truth (dumped from `sample.braw` locally)
- Frame metadata contains **`sensor_rate` as a rational array** (`24 1`) → exact fps.
  Clip `GetFrameRate()` is float-only. Strategy: rational from metadata when consistent
  with the float, else snap-table (24000/1001 family), else float×1000/1000.
- Real clip keys: `camera_type, camera_id, firmware_version, braw_compression_ratio,
  crop_origin, crop_size, clip_number, reel_name, scene, take, good_take, environment,
  day_night, lens_type, camera_number, tone_curve_*, post_3dlut_*, viewing_gamma,
  viewing_gamut, viewing_bmdgen, date_recorded, manufacturer`.
- Real frame keys: `sensor_rate, shutter_value, internal_nd, analog_gain,
  as_shot_kelvin, as_shot_tint, aperture, exposure, focal_length, distance, iso,
  white_balance_kelvin, white_balance_tint, lens_*`.
- The SDK PDF (Aug 2025) documents interfaces but **no metadata key tables, no stride
  rules, no callback-thread rules, no processed-image lifetime** → we copy pixels
  inside `ProcessComplete` (before releasing the job) and treat buffers as tightly
  packed, verified against `GetResourceSizeBytes` at runtime.

### Reuse from autoadjuster (same author, same stack — patterns adopted 1:1)
- Dual-plugin layout `src/{core,vapoursynth,avisynth}` with host-free core.
- AviSynth-from-Zig solution: `@cImport` with `AVSC_NO_DECLSPEC` + minimal windows
  stub header (translate-c chokes on real `windows.h`), C shim (`avs_loader.c`) for
  `avs_load_library()` and **by-value `AVS_Value` marshalling** (Zig mislowers small
  by-value structs on Windows), hand-typed `callconv(.winapi)` API table filled via
  `@ptrCast`, `exports.def` pinning `avisynth_c_plugin_init{,2}`.
- Build: `-Dvs`/`-Davs` toggles, `release_targets` array loop installing to
  `zig-out/<label>/`, `check` step for ZLS, `zig build test` for core tests.
- AviSynth+ pulls frames synchronously and can re-enter on one thread; wine is NOT a
  valid AVS test host (false ABI faults) — test on real Windows.
- vendored `avisynth_c.h` (V12) reused from `autoadjuster/vendor/avisynth_sdk`.

### Environment
- Zig 0.16.0 installed; VapourSynth R77 / API 4.2 in `encode_test/.venv`
  (plugins installable with `uv pip install <name>`).
- vapoursynth-zig has full audio bindings (`createAudioFilter`, `newAudioFrame`,
  `queryAudioFormat`, 24-bit int supported) — high-level ZAPI is video-centric, raw
  API suffices for the audio node.
- AviSynth+ C API: `AVS_SAMPLE_INT24` is packed 3-byte (= BRAW native layout, zero
  conversion), planar RGBA (`AVS_CS_RGBAP8/16/PS`) available, `get_audio` callback on
  `AVS_FilterInfo`.
- Test material: `Media/sample.braw` (SDK, 1 frame) + 3 URSA Mini Pro clips from 2018
  with sidecars in `Video_samples/` (154–745 MB zipped).

## 3. Architecture

```
build.zig / build.zig.zon          # vapoursynth-zig dep pinned by commit
src/
  core/                            # host-free: no VS/AVS imports, fully unit-testable
    braw/
      api.zig                      # per-OS interface vtables, enums, IIDs, Variant
      strings.zig                  # BrawString: char* / CFStringRef / BSTR backends
      loader.zig                   # dlopen/LoadLibraryExW + search-path logic
      variant.zig                  # Variant/SafeArray → neutral zig values
    decoder.zig                    # codec/clip lifecycle, callback, sync job bridge
    audio.zig                      # audio reader (sample-addressed, packed PCM)
    formats.zig                    # resource-format choice + interleaved→planar copies
    meta.zig                       # metadata → neutral prop list, fps rationalization
    core.zig                       # public surface + test aggregation
  vapoursynth/plugin.zig           # braw.Source + braw.AudioSource (ZAPI + raw API)
  avisynth/
    plugin.zig                     # BRAWSource (video + attached audio)
    avs.zig, avs_win_min.h, avs_loader.c, exports.def   # adapted from autoadjuster
tools/
  extract-sdk.sh                   # SDK-Sources/*.zip → third_party/braw/{include,runtime}
  braw-probe/main.zig              # CLI: open clip, dump info/metadata, decode frame N to .ppm/.raw
third_party/                       # gitignored: extracted SDK headers+runtime for dev/tests
vendor/
  braw-sdk/{Linux,Mac,Win}/Include # committed SDK headers (Boost-style license kept)
  avisynth_sdk/avisynth_c.h        # V12 header (same license terms as autoadjuster copy)
test/
  python/                          # pytest suite run inside encode_test/.venv
  oracle/                          # C++ oracle tools built from SDK samples (gitignored bins)
encode_test/                       # existing venv; test entry scripts
```

### Decode bridge (sync-over-async)
Per source instance: one factory handle (process-global, refcounted), one codec, one
clip, one static callback object. Per frame request:

1. `getFrame` allocates the destination host frame (VS `newVideoFrame` / AVS
   `avs_new_video_frame_a`) — planes + strides become the copy target.
2. Build request ctx `{ dst planes/strides, format, wanted scale, ResetEvent, hr,
   prop snapshot }`, `CreateJobReadFrame(n)`, `SetUserData(ctx)`, `Submit()`, wait.
3. `ReadComplete` (SDK thread): harvest per-frame metadata → ctx, set resource format
   + resolution scale, chain `CreateJobDecodeAndProcessFrame` with same userdata.
4. `ProcessComplete` (SDK thread): validate dims/format/sizeBytes, convert
   interleaved→planar (or plane-copy for `*Planar` formats) directly into dst planes,
   set `ctx.hr`, signal event. Never touches host APIs beyond raw memory.
5. `getFrame` wakes, attaches frame props, returns. On error: host error message with
   frame index + HRESULT (dropped frames report `E_UNEXPECTED` distinctly).

VS filter mode `fmUnordered`; parallel `getFrame`s map to parallel SDK jobs (bounded
by VS thread count; SDK decodes FIFO internally). AVS side is the same bridge behind
its synchronous `get_frame`. Audio bypasses jobs entirely (`GetAudioSamples` is
synchronous) guarded by a mutex.

### Format mapping
| plugin `format` | SDK resource format | VS | AVS | copy |
|---|---|---|---|---|
| `u8` (+alpha) | RGBAU8 | RGB24 (+Gray8 `_Alpha`) | RGBP8/RGBAP8 | deinterleave 4→3(+1) |
| `u16` | RGBU16Planar / RGBAU16 if alpha | RGB48 (+Gray16) | RGBP16/RGBAP16 | plane copy / deinterleave |
| `f16` | RGBF16Planar / RGBAF16 | RGBH (+GrayH) | — (AVS has no f16) | plane copy / deinterleave |
| `f32` | RGBF32Planar / RGBAF32 | RGBS (+GrayS) | RGBPS/RGBAPS | plane copy / deinterleave |

Note: BRAW carries no real alpha (sensor raw); SDK alpha is constant opaque. We still
offer it (as requested) and document that it's constant.
VS alpha follows the imwri convention: `_Alpha` frame prop holding the alpha frame
(extract with `std.PropToClip`). Default `alpha=false`.

### Frame props (VS; AVS sets the equivalent per-frame props via `avs_prop_*` V11 API)
- Standard: `_DurationNum/_DurationDen` (from rational fps), `_Matrix=0` (RGB),
  `_ColorRange=0` (full), `_FieldBased=0`, `_SARNum/_SARDen` (from anamorphic ratio
  metadata when present), `_Primaries/_Transfer` only when gamma/gamut is cleanly
  mappable (e.g. Rec.709), else unset.
- BRAW per-frame: `BRAWTimecode` (string), `BRAWSensorRateNum/Den`, `BRAWISO`,
  `BRAWExposure`, `BRAWWhiteBalanceKelvin`, `BRAWWhiteBalanceTint`, `BRAWAperture`,
  `BRAWFocalLength`, `BRAWShutterValue`.
- BRAW clip-level (same on every frame): `BRAWCameraType`, `BRAWClipNumber`,
  `BRAWReelName`, `BRAWScene`, `BRAWTake`, `BRAWGamma`, `BRAWGamut`,
  `BRAWColorScienceGen`, `BRAWCompressionRatio`.
- `allmetaprops=true`: additionally dump every metadata key generically as
  `BRAW_<key>` (typed: int/float/string/int-array/float-array).

### Plugin surface (proposal)
VapourSynth (`com.thechaoscoder.braw`, namespace `braw`):
```
braw.Source(source, format="u16", alpha=False, scale=1,            # 1|2|4|8
            kelvin=None, tint=None, exposure=None, iso=None,       # frame overrides
            gamma=None, gamut=None, colorscience=None,             # clip overrides
            highlightrecovery=None, gamutcompression=None,
            sidecar=True, allmetaprops=False, threads=0, libpath=None) -> vnode
braw.AudioSource(source, libpath=None) -> anode
```
AviSynth+ (V11/12 C interface, x64):
```
BRAWSource(string source, string "format"="u16", bool "alpha"=false, bool "audio"=true,
           int "scale"=1, int "kelvin", int "tint", float "exposure", int "iso",
           string "gamma", string "gamut", int "colorscience", bool "highlightrecovery",
           bool "gamutcompression", bool "sidecar"=true, int "threads", string "libpath")
```

### Runtime library discovery (order)
1. `libpath` param (file or directory), 2. `$BRAW_LIBRARY` env, 3. next to the plugin
binary (and `<plugindir>/BlackmagicRawAPI/`), 4. OS defaults: Linux
`/usr/lib64/blackmagic/BlackmagicRAWPlayer/BlackmagicRawAPI/`, `/opt/resolve/libs/`;
Windows `%ProgramFiles%\Blackmagic Design\...` + Resolve dir (exact paths verified
during M6); macOS `/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/...`
+ Resolve app bundle. Errors list every searched path.

## 4. Testing strategy

- **Zig unit tests** (`zig build test`, no SDK needed): interleaved→planar conversions
  (golden patterns, all depths), fps rationalization table, variant→prop mapping,
  UTF-8↔UTF-16/BSTR helpers, loader candidate-path logic, comptime vtable/ABI asserts
  (struct sizes, slot counts per OS).
- **Oracle tools** (built locally from vendored SDK samples with g++/zig c++):
  raw-plane dumper (ProcessClipCPU derivative) + WAV extractor (ExtractAudio).
  Integration tests compare plugin output byte-exactly against these — same SDK, so
  any mismatch is our bug.
- **Python integration tests** (pytest in `encode_test/.venv`; SDK runtime + samples
  extracted via `tools/extract-sdk.sh`; tests skip cleanly when material is missing):
  - clip info: dims, fps (rational!), frame count, format/bit depth per `format` arg
  - determinism: same frame decoded twice → identical checksum
  - **random access == sequential**: shuffled request order produces identical frames
  - frame props present + plausible (ISO, kelvin, timecode monotonic, sensor rate)
  - alpha node (constant opaque), scale dims (1/2/4/8), sidecar on/off difference
  - audio: format/samplecount vs oracle WAV, byte-exact PCM slices, VS audio-frame
    boundary behavior (first/last frame, EOF short read)
  - process-level: open→decode→close leak smoke via repeated runs
- **AviSynth**: cross-compile always; local smoke test on Linux AviSynth+ build
  (optional, reusing the autoadjuster AviSynth checkout) since wine is unreliable;
  definitive validation on the user's real Windows (AVSMeter + script), later CI.

## 5. Milestones

- **M0 scaffold**: repo layout, build.zig (+`-Dvs/-Davs`, release matrix, check/test
  steps), vendored headers, `tools/extract-sdk.sh`, gitignore, README stub. First commit.
- **M1 core binding (Linux)**: loader, vtables, strings/variant, decoder bridge,
  `braw-probe` CLI (open/info/metadata/decode-to-file). Zig unit tests green;
  probe verified against `sample.braw` + one big user sample.
- **M2 VS video source (Linux)**: `braw.Source` u16 full-res + standard props;
  python integration tests (info/determinism/random access).
- **M3 formats**: u8/f16/f32, alpha, scale; oracle pixel comparison; prop completion
  (`BRAW*`, `allmetaprops`).
- **M4 audio**: `braw.AudioSource` + oracle WAV tests.
- **M5 processing params**: kelvin/tint/exposure/iso/gamma/gamut/colorscience/
  highlightrecovery/gamutcompression/sidecar + validation via runtime value lists.
- **M6 Windows**: BSTR/VARIANT/GUID layer (oleaut32), VS win-x64 build, AviSynth
  plugin (video+audio, planar RGB(A), INT24 passthrough), user validates on Windows.
- **M7 macOS**: CFStringRef layer, framework loader, x86_64+aarch64 builds
  (compile-verified; runtime validation deferred to CI/user hardware).
- **M8 polish**: README (params, props, install, runtime discovery), release step
  producing per-target zips, version stamping. GitHub CI intentionally later.

Each milestone ends with: tests green locally + a commit (no co-author trailer).

## 6. Risks & mitigations

- **COM ABI from Zig** (by-value REFIID on Unix, GUID-pointer + LE layout on Windows,
  dtor slots): comptime asserts, `braw-probe` early smoke, one interface at a time.
- **Undocumented buffer lifetime/stride**: copy inside `ProcessComplete`, validate
  `GetResourceSizeBytes == w*h*bpp` (abort with clear error if padded).
- **Callback-thread discipline**: callbacks only touch request ctx memory; all host
  API calls stay on the requesting thread.
- **Windows by-value struct mislowering (AVS)**: C trampolines (proven pattern).
- **fps float**: sensor_rate rational + snap table; integration test asserts exact
  rationals for the NTSC-rate user samples.
- **Old files vs SDK 5.1**: 2018 URSA clips in the test set cover legacy color science.
- **Mac untestable locally**: strictest-typed layer, compile-only gate now, CI later.

## 7. Open questions → user

1. Default `format` (proposal: `u16` = RGB48/RGBP16 — fast plane-copy path, common
   grading depth; alternatives: f32 for max fidelity, u8 for speed).
2. Scope v1 processing params: full override set in v1 vs. as-shot+scale only.
3. GitHub repo: create now (private/public?) or keep local until M2.
