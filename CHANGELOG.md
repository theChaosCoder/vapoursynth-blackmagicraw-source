# Changelog

## 0.4.0 — 2026-07-16

### Added
- **OpenCL GPU pipeline**: `pipeline="opencl"` decodes on any OpenCL GPU —
  the option for AMD/Intel, where neither CUDA nor Metal applies
  (~1.6× CPU at 4.6K on an RTX 3080; on NVIDIA prefer `cuda`).
- License notices: `THIRD_PARTY_NOTICES.md` plus full license texts
  (LGPL-2.1 for the compiled-in vapoursynth-zig binding, Apache-2.0 for
  the bundled libc++, the SDK's own license documents) now ship in all
  release zips and wheels.

### Fixed
- **CUDA survives close + reopen in one process** (editor preview
  reload): page-locking VS frame planes left orphaned mappings and the
  next open failed with `CUDA_ERROR_ALREADY_MAPPED`. Pinning is now
  opt-in (`BRAW_CUDA_PIN=1`, ~25% faster readback, single-open use only).
- macOS wheels are tagged `macosx_12_0` and built with a matching
  minimum OS — the 0.3.x wheels claimed macOS 11 but contained
  binaries dyld refused to load below 13.
- Rare SDK error paths could hang a frame request forever; they now fail
  with a clear message. AviSynth hosts older than 3.6 (interface V8) get
  an error message instead of a crash at plugin load.
- Invalid parameters (`kelvin`/`iso` = 0, non-finite `exposure`,
  negative `threads`) are rejected at open instead of failing at the
  first frame.

### Changed
- Wheels are byte-reproducible, release binaries are stripped, the SDK
  archives are SHA-256-verified at extraction, and `zig build release`
  runs the unit tests first.
