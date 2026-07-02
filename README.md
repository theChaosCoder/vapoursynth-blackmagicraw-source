# brawsource (beta)

Dual VapourSynth / AviSynth+ source plugin for Blackmagic RAW (`.braw`),
written in Zig against the official Blackmagic RAW SDK (CPU decode).
Frame-exact random access, audio, frame properties from clip/frame metadata.

- **VapourSynth**: `braw.Source` + `braw.AudioSource` — Linux, Windows, macOS (x64/arm64)
- **AviSynth+**: `BRAWSource` (video + audio track) — Windows x64

## Runtime

The plugin loads the Blackmagic RAW runtime at run time. Easiest setup: put
the runtime libraries (`BlackmagicRawAPI` + sibling decoder libs) into a
folder next to the plugin named **`blackmagic_win_deps`** /
**`blackmagic_linux_deps`** / **`blackmagic_mac_deps`**. Alternatively an
installed Blackmagic RAW / DaVinci Resolve is found automatically, or use
the `libpath` parameter / `BRAW_LIBRARY` env var.

## Usage

```python
clip  = core.braw.Source(source="clip.braw")        # bit depth automatic
audio = core.braw.AudioSource(source="clip.braw")
```

```
BRAWSource("clip.braw", bitdepth=32)                 # AviSynth, audio attached
```

Parameters (both frameworks):

| Parameter | Description |
|---|---|
| `bitdepth` | 8, 16 or 32 (32 = float). Unset = auto: 16-bit, or 32-bit float for Linear gamma. `fp=true` with 16 = half float (VapourSynth only) |
| `alpha` | add alpha (constant opaque; `_Alpha` frame in VS, 4th plane in AviSynth) |
| `audio` | AviSynth only: attach audio track (default true) |
| `scale` | decode at 1/2/4/8 resolution |
| `kelvin, tint, exposure, iso` | per-frame processing overrides |
| `gamma, gamut, colorscience` | color science overrides (e.g. `gamma="Rec.709"`); invalid values error at open |
| `highlightrecovery, gamutcompression` | processing toggles |
| `allmetaprops` | expose every metadata key as `BRAW_<key>` frame prop |
| `threads` | SDK CPU threads (0 = default) |
| `libpath` | Blackmagic RAW library file or directory |

Defaults decode "as shot": camera metadata plus an auto-applied
`<clipname>.sidecar` next to the file (reported via the
`BRAWSidecarAttached` prop; parameters override both).

Frame props: `_DurationNum/Den`, `_AbsoluteTime`, `_Matrix`, `_Range`
(+`_Transfer`/`_Primaries` when the gamma/gamut has a standard code), plus
`BRAWTimecode`, `BRAWISO`, `BRAWWhiteBalanceKelvin/Tint`, `BRAWExposure`,
camera/clip info as `BRAW*`. Inspect everything with
`braw-probe --list-attrs --all-meta clip.braw`.

## Building

Zig 0.16; SDK headers are vendored, nothing else needed.

```sh
zig build                  # plugins into zig-out/{vapoursynth,avisynth}, braw-probe into zig-out/bin
zig build test             # unit tests
zig build release          # all targets, ReleaseFast, into zig-out/release/
tools/extract-sdk.sh       # unpack SDK/runtime into third_party/ (dev/tests)
```

## License

Plugin code: see LICENSE. Vendored SDK headers (`vendor/`) are Copyright
Blackmagic Design, license in their file headers. The Blackmagic RAW
runtime libraries are not distributed with this plugin.
