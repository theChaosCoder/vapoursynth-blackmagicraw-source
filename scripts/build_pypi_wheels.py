#!/usr/bin/env python3
"""Assemble platform-tagged wheels from the `zig build release` output.

vapoursynth-brawsource ships as four binary wheels — one per (OS, arch)
VapourSynth target — plus a thin source distribution. The wheels are
*not* built by an upstream Python toolchain (hatchling / meson-python /
cibuildwheel) because the actual compile is done by `zig build`. This
script takes the already-built plugin from `zig-out/release/<label>/`,
adds the redistributable Blackmagic RAW runtime from
`third_party/braw/runtime/` (the same batteries-included layout as the
GitHub release zips), packages everything into a PEP 427 wheel by hand,
and drops the result under `dist/`.

Layout inside each wheel::

    vapoursynth_brawsource-<ver>.dist-info/
        METADATA      (Python project metadata)
        WHEEL         (wheel format declaration)
        RECORD        (sha256 + size of every file)
        licenses/LICENSE
    vapoursynth/plugins/
        libbrawsource.so | libbrawsource.dylib | brawsource.dll
    vapoursynth_brawsource.libs/...   (BRAW runtime + NOTICE.txt)

`vapoursynth/plugins/` is the convention VapourSynth's Python bindings
use to auto-discover pip-installed plugins. The runtime lives in the
sibling `vapoursynth_brawsource.libs/` directory (auditwheel-style, like
BestSource) because the autoloader recursively tries every *.so under
plugins/ and would warn about each runtime library; the plugin's loader
probes `../vapoursynth_brawsource.libs/` relative to its own directory.
So after `pip install vapoursynth-brawsource`, `core.braw.Source(...)`
Just Works, no DaVinci Resolve install required.

The wheels are baseline x86-64 (SSE2): PEP 425 platform tags cannot
express micro-architecture levels, so the faster `-v3` (AVX2/F16C)
builds exist only as GitHub release zips.

macOS note: wheels cannot contain symlinks, so the framework's symlink
farm (top-level aliases, `Versions/Current`) is materialised — symlinked
files become real copies, and the redundant `Versions/Current` subtree
is dropped.

Pre-conditions:
  * `tools/extract-sdk.sh` has been run (BRAW runtime in third_party/).
  * `zig build release` has been run.

Usage:
  python scripts/build_pypi_wheels.py
"""

from __future__ import annotations

import base64
import hashlib
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASE = ROOT / "zig-out/release"
RUNTIME = ROOT / "third_party/braw/runtime"
DIST = ROOT / "dist"

PROJECT_NAME = "vapoursynth-brawsource"
DIST_NAME = "vapoursynth_brawsource"  # PEP 503-normalised + underscore

NOTICE = """This folder contains the Blackmagic RAW API Libraries,
Copyright Blackmagic Design Pty. Ltd.
Redistributed together with the brawsource plugin under the
Blackmagic RAW SDK Developer License, clause 1.1(d)
(https://www.blackmagicdesign.com/developer).
"""

# (release label, plugin binary, runtime dir, platform tag)
#
# Platform tags follow PEP 425. Zig cross-compiles the Linux build
# against glibc 2.17, hence manylinux2014/manylinux_2_17 for the plugin
# itself; the bundled BRAW runtime additionally needs system libGL and
# libuuid at dlopen time (see README). The macOS floor is Monterey
# (12.0): the BRAW 5.1 runtime is built with minos 12.0 and the plugin
# dylibs are built with os_version_min 12.0 (build.zig) — the tag, the
# plugin and the runtime must agree or dyld refuses to load.
PLATFORMS = [
    ("vapoursynth-linux-x86_64", "libbrawsource.so",
     "linux-x86_64", "manylinux2014_x86_64.manylinux_2_17_x86_64"),
    ("vapoursynth-windows-x86_64", "brawsource.dll",
     "windows-x86_64", "win_amd64"),
    ("vapoursynth-macos-x86_64", "libbrawsource.dylib",
     "macos-universal", "macosx_12_0_x86_64"),
    ("vapoursynth-macos-arm64", "libbrawsource.dylib",
     "macos-universal", "macosx_12_0_arm64"),
]

# Fixed timestamp for all zip members so two builds of the same inputs
# produce byte-identical wheels (1980-01-01 is the zip format's epoch).
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


def project_version() -> str:
    """Single source of truth: build.zig.zon. pyproject.toml must agree
    (it is metadata for the sdist), so mismatches abort the build."""
    zon = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
    m = re.search(r'\.version\s*=\s*"([^"]+)"', zon)
    if not m:
        raise SystemExit("cannot find .version in build.zig.zon")
    version = m.group(1)
    pyproject = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    if f'version = "{version}"' not in pyproject:
        raise SystemExit(
            f"version mismatch: build.zig.zon says {version}, "
            "pyproject.toml disagrees -- update pyproject.toml"
        )
    return version


def _sha256_b64(data: bytes) -> str:
    """PEP 376 RECORD format: `sha256=<urlsafe base64, no padding>`."""
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _metadata(version: str) -> str:
    """Core metadata 2.4; long description from README.md."""
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    url = "https://github.com/theChaosCoder/vapoursynth-blackmagicraw-source"
    return (
        "Metadata-Version: 2.4\n"
        f"Name: {PROJECT_NAME}\n"
        f"Version: {version}\n"
        "Summary: Blackmagic RAW (.braw) source plugin for VapourSynth — "
        "batteries included (bundles the Blackmagic RAW runtime)\n"
        f"Home-page: {url}\n"
        "Author: theChaosCoder\n"
        "License-Expression: MIT\n"
        "License-File: LICENSE\n"
        f"Project-URL: Repository, {url}\n"
        f"Project-URL: Issues, {url}/issues\n"
        f"Project-URL: Releases, {url}/releases\n"
        "Keywords: video,vapoursynth,braw,blackmagic,raw,source,decoder\n"
        "Classifier: Development Status :: 4 - Beta\n"
        "Classifier: Environment :: Plugins\n"
        "Classifier: Operating System :: MacOS\n"
        "Classifier: Operating System :: Microsoft :: Windows\n"
        "Classifier: Operating System :: POSIX :: Linux\n"
        "Classifier: Topic :: Multimedia :: Video\n"
        "Requires-Python: >=3.9\n"
        "Requires-Dist: VapourSynth>=66\n"
        "Description-Content-Type: text/markdown\n"
        "\n"
        f"{readme}"
    )


def _wheel_file(plat_tag: str) -> str:
    # PEP 427 allows repeated Tag headers; dotted plat_tags expand to one
    # line per compatibility alias so older pips still match the wheel.
    tags = "".join(f"Tag: py3-none-{t}\n" for t in plat_tag.split("."))
    return (
        "Wheel-Version: 1.0\n"
        "Generator: brawsource/build_pypi_wheels.py\n"
        "Root-Is-Purelib: false\n"
        f"{tags}"
    )


def _runtime_entries(runtime_dir: Path, deps_prefix: str) -> list[tuple[str, bytes]]:
    """Collect the BRAW runtime as (archive name, bytes), materialising
    symlinks and skipping the redundant framework `Versions/Current`
    subtree (wheels cannot represent symlinks)."""
    entries: list[tuple[str, bytes]] = []
    stack = [runtime_dir]
    files: list[Path] = []
    while stack:
        d = stack.pop()
        for child in sorted(d.iterdir()):
            if child.name == "Current" and child.is_symlink():
                continue
            if child.is_dir():  # follows symlinked dirs (materialise)
                stack.append(child)
            elif child.is_file():
                files.append(child)
    for f in sorted(files):
        rel = f.relative_to(runtime_dir)
        entries.append((f"{deps_prefix}/{rel.as_posix()}", f.read_bytes()))
    return entries


def _macho_minos(data: bytes) -> tuple[int, int] | None:
    """Minimum macOS version from LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX
    (thin Mach-O only)."""
    import struct
    if len(data) < 32 or struct.unpack_from("<I", data)[0] not in (0xFEEDFACF,):
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    pos = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmd in (0x32, 0x24):  # LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX
            v = struct.unpack_from("<I", data, pos + (12 if cmd == 0x32 else 8))[0]
            return (v >> 16, (v >> 8) & 0xFF)
        pos += cmdsize
    return None


def _check_macos_tag(src: Path, plat_tag: str) -> None:
    """A macosx_X_Y tag on a binary that needs a newer macOS makes pip
    install wheels that dyld then refuses to load — hard error."""
    m = re.match(r"macosx_(\d+)_(\d+)_", plat_tag)
    if not m:
        return
    tag_ver = (int(m.group(1)), int(m.group(2)))
    minos = _macho_minos(src.read_bytes())
    if minos is None:
        raise SystemExit(f"cannot read LC_BUILD_VERSION from {src}")
    if minos > tag_ver:
        raise SystemExit(
            f"{src.name}: minos {minos[0]}.{minos[1]} exceeds wheel tag "
            f"macosx_{tag_ver[0]}_{tag_ver[1]} - fix os_version_min in build.zig "
            "or the tag in PLATFORMS"
        )


def build_wheel(version: str, label: str, binname: str,
                runtime: str, plat_tag: str) -> Path:
    src = RELEASE / label / binname
    if not src.exists():
        raise SystemExit(f"missing artefact: {src}\n  run `zig build release` first.")
    _check_macos_tag(src, plat_tag)
    runtime_dir = RUNTIME / runtime
    if not runtime_dir.exists():
        raise SystemExit(f"missing runtime: {runtime_dir}\n  run tools/extract-sdk.sh first.")
    DIST.mkdir(exist_ok=True)

    primary = plat_tag.split(".")[0]
    out = DIST / f"{DIST_NAME}-{version}-py3-none-{primary}.whl"

    distinfo = f"{DIST_NAME}-{version}.dist-info"
    libs = f"{DIST_NAME}.libs"

    entries: list[tuple[str, bytes]] = [(f"vapoursynth/plugins/{binname}", src.read_bytes())]
    entries += _runtime_entries(runtime_dir, libs)
    entries += [
        (f"{libs}/NOTICE.txt", NOTICE.encode("utf-8")),
        (f"{distinfo}/METADATA", _metadata(version).encode("utf-8")),
        (f"{distinfo}/WHEEL", _wheel_file(plat_tag).encode("utf-8")),
        (f"{distinfo}/licenses/LICENSE", (ROOT / "LICENSE").read_bytes()),
        (f"{distinfo}/licenses/THIRD_PARTY_NOTICES.md",
         (ROOT / "THIRD_PARTY_NOTICES.md").read_bytes()),
    ]
    for lic in sorted((ROOT / "THIRD_PARTY_LICENSES").iterdir()):
        entries.append((f"{distinfo}/licenses/THIRD_PARTY_LICENSES/{lic.name}", lic.read_bytes()))
    # the SDK's own license + attribution documents belong next to its libs
    sdk_docs = ROOT / "third_party/braw/sdk/Documents"
    for doc in ("License.rtf", "Third Party Licenses.rtf"):
        p = sdk_docs / doc
        if not p.exists():
            raise SystemExit(f"missing SDK license document: {p} (rerun tools/extract-sdk.sh)")
        entries.append((f"{libs}/{doc}", p.read_bytes()))

    # Build RECORD last — it indexes everything else.
    record_lines = [f"{name},{_sha256_b64(data)},{len(data)}" for name, data in entries]
    record_lines.append(f"{distinfo}/RECORD,,")
    record = "\n".join(record_lines).encode("utf-8") + b"\n"
    entries.append((f"{distinfo}/RECORD", record))

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            # fixed metadata -> reproducible wheels (same inputs, same bytes)
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)

    print(f"  built {out.name}  ({out.stat().st_size:>9d} bytes, {len(entries)} files)")
    return out


def _audit_linux_wheel(wheel: Path) -> None:
    """Release gate: run auditwheel against the Linux wheel when it is
    installed. Advisory (the BRAW runtime intentionally links system
    libGL/libuuid, which auditwheel flags), but the report must be seen."""
    import shutil
    import subprocess
    if shutil.which("auditwheel") is None:
        print("  WARNING: auditwheel not installed - manylinux tag unverified")
        return
    res = subprocess.run(["auditwheel", "show", str(wheel)],
                         capture_output=True, text=True)
    print("  auditwheel show:")
    for line in (res.stdout + res.stderr).strip().splitlines():
        print(f"    {line}")


def main() -> int:
    version = project_version()
    print(f"Building {PROJECT_NAME} {version} wheels")
    # stale wheels from previous versions must not linger next to new ones
    if DIST.exists():
        for old in DIST.glob(f"{DIST_NAME}-*.whl"):
            old.unlink()
    for label, binname, runtime, plat_tag in PLATFORMS:
        wheel = build_wheel(version, label, binname, runtime, plat_tag)
        if "manylinux" in plat_tag:
            _audit_linux_wheel(wheel)
    print(f"\n{len(PLATFORMS)} wheels in {DIST.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
