#!/usr/bin/env bash
# Build and package batteries-included release zips: plugin + Blackmagic RAW
# runtime in the per-OS deps folder next to it — ready to drop into a plugin
# directory. Requires tools/extract-sdk.sh to have run (runtime libraries).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$REPO/third_party/braw/runtime"
OUT="$REPO/zig-out/release-zips"
VER=$(grep -m1 '\.version' "$REPO/build.zig.zon" | sed 's/.*"\(.*\)".*/\1/')

for d in linux-x86_64 windows-x86_64 macos-universal; do
    [ -e "$RUNTIME/$d" ] || { echo "error: $RUNTIME/$d missing - run tools/extract-sdk.sh first" >&2; exit 1; }
done
command -v 7z >/dev/null || { echo "error: 7z is required" >&2; exit 1; }

echo "== building release artifacts ($VER) =="
(cd "$REPO" && zig build release)

rm -rf "$OUT"
mkdir -p "$OUT"

write_notice() {
    cat > "$1/NOTICE.txt" <<'NOTE'
This folder contains the Blackmagic RAW API Libraries,
Copyright Blackmagic Design Pty. Ltd.
Redistributed together with the brawsource plugin under the
Blackmagic RAW SDK Developer License, clause 1.1(d)
(https://www.blackmagicdesign.com/developer).
NOTE
}

package() { # <label> <deps-dir-name> <runtime-src...>
    local label="$1" deps="$2"
    shift 2
    local stage="$OUT/stage/$label"
    mkdir -p "$stage/$deps"
    find "$REPO/zig-out/release/$label" -type f ! -name "*.pdb" -exec cp {} "$stage/" \;
    local src
    for src in "$@"; do
        cp -r "$src" "$stage/$deps/"
    done
    write_notice "$stage/$deps"
    cp "$REPO/README.md" "$REPO/LICENSE" "$stage/"
    (cd "$stage" && 7z a -tzip -mx=9 "$OUT/brawsource-$VER-$label.zip" ./* >/dev/null)
    echo "packaged brawsource-$VER-$label.zip"
}

package vapoursynth-linux-x86_64 blackmagic_linux_deps "$RUNTIME/linux-x86_64/."
package vapoursynth-windows-x86_64 blackmagic_win_deps "$RUNTIME/windows-x86_64/."
package vapoursynth-macos-x86_64 blackmagic_mac_deps "$RUNTIME/macos-universal/BlackmagicRawAPI.framework"
package vapoursynth-macos-arm64 blackmagic_mac_deps "$RUNTIME/macos-universal/BlackmagicRawAPI.framework"
package avisynth-windows-x86_64 blackmagic_win_deps "$RUNTIME/windows-x86_64/."

(cd "$OUT" && sha256sum brawsource-*.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "release zips in $OUT"
