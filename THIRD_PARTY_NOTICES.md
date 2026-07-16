# Third-party notices

The brawsource plugin (MIT, see `LICENSE`) is distributed together with, or
built from, the following third-party components.

## Blackmagic RAW SDK runtime libraries

The release packages and wheels bundle the Blackmagic RAW API libraries
(`libBlackmagicRawAPI`, the `libDecoder*` GPU decoders, the
`libInstructionSetServices*` CPU kernels and, on Linux, the `libc++`/
`libc++abi` builds they ship with), Copyright Blackmagic Design Pty. Ltd.
They are redistributed under the Blackmagic RAW SDK Developer License,
clause 1.1(d) (<https://www.blackmagicdesign.com/developer>). The SDK's own
license and third-party attribution documents are included alongside the
bundled libraries as `License.rtf` and `Third Party Licenses.rtf`.

## libc++ / libc++abi (Linux runtime bundle)

The `libc++.so.1`/`libc++abi.so.1` shipped in the Linux runtime bundle are
Blackmagic's builds of LLVM's libc++, licensed under the Apache License
v2.0 with LLVM Exceptions. Full text:
`THIRD_PARTY_LICENSES/libcxx.LICENSE`. Source:
<https://github.com/llvm/llvm-project>.

## vapoursynth-zig (compiled into the VapourSynth plugin)

The VapourSynth plugin statically compiles the `vapoursynth-zig` binding by
dnjulek, licensed under the GNU Lesser General Public License v2.1. Full
text: `THIRD_PARTY_LICENSES/vapoursynth-zig.LICENSE`.

- Source: <https://github.com/dnjulek/vapoursynth-zig>
- Exact revision: pinned in `build.zig.zon`
  (commit `7554e4f46950771cc77bc5c1fc3bc6bbb5a2ea40`)

The complete source of this plugin (including the build system needed to
relink it against a modified version of the library, per LGPL-2.1 §6) is
available at the project repository named in `README.md`.

## AviSynth+ C interface headers (compile time only)

The AviSynth plugin is compiled against the AviSynth+ `avisynth_c.h`
headers (`vendor/avisynth_sdk/`), GPL-2.0 with the AviSynth linking
exception: distributing plugins that merely link against AviSynth through
these headers is permitted without placing the plugin under the GPL, see
the header preamble and
<https://avisynthplus.readthedocs.io/en/latest/avisynthdoc/license.html>.
No AviSynth code is bundled in the release packages.

## VapourSynth (dynamic interface)

The VapourSynth plugin talks to a host-provided VapourSynth core at
runtime; no VapourSynth code is bundled.
