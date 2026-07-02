#!/usr/bin/env bash
# Extract the Blackmagic RAW SDK and runtime libraries from the vendor
# downloads in SDK-Sources/ into third_party/ (gitignored).
#
# The developer SDK (headers, samples, docs, sample.braw) ships inside the
# *Mac* download: DMG -> Install pkg -> BlackmagicRawSDK.pkg -> cpio payload.
# The Linux runtime libraries ship inside the Linux desktop-software tar.
#
# Usage: tools/extract-sdk.sh [--force] [--samples]
#   --force    re-extract even if third_party/braw already exists
#   --samples  also unzip Video_samples/*.zip into third_party/samples/

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/SDK-Sources"
OUT="$REPO/third_party"
TMP="$OUT/.tmp"

FORCE=0
SAMPLES=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --samples) SAMPLES=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

for tool in 7z cpio tar; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' is required" >&2; exit 1; }
done

MAC_ZIP="$SRC/Blackmagic_RAW_Macintosh_5.1.zip"
LINUX_TAR="$SRC/Blackmagic_RAW_Linux_5.1.tar.tar"
WIN_ZIP="$SRC/Blackmagic_RAW_Windows_5.1.zip"
[ -f "$MAC_ZIP" ] || { echo "error: $MAC_ZIP not found" >&2; exit 1; }
[ -f "$LINUX_TAR" ] || { echo "error: $LINUX_TAR not found" >&2; exit 1; }
[ -f "$WIN_ZIP" ] || { echo "error: $WIN_ZIP not found" >&2; exit 1; }

# The SDK archive contains directories with mode 0444; make a tree
# traversable/writable so it can be copied and deleted.
fix_perms() {
    [ -e "$1" ] || return 0
    find "$1" -type d -exec chmod u+rwx {} \; 2>/dev/null || true
    chmod -R u+w "$1" 2>/dev/null || true
}

if [ -d "$OUT/braw" ] && [ "$FORCE" -eq 0 ]; then
    echo "third_party/braw already exists (use --force to re-extract)"
else
    fix_perms "$OUT/braw"; fix_perms "$TMP"
    rm -rf "$OUT/braw" "$TMP"
    mkdir -p "$TMP"

    echo "== extracting developer SDK (from Mac package) =="
    (
        cd "$TMP"
        7z x -y "$MAC_ZIP" "Blackmagic_RAW_5.1.dmg" >/dev/null
        7z x -y "Blackmagic_RAW_5.1.dmg" "Blackmagic RAW/Install Blackmagic RAW 5.1.pkg" >/dev/null
        mkdir -p pkg && cd pkg
        7z x -y "../Blackmagic RAW/Install Blackmagic RAW 5.1.pkg" "BlackmagicRawSDK.pkg" >/dev/null
        mkdir -p payload && cd payload
        # Some directories in the archive are mode 0555; bsdtar defers
        # permissions until after extraction, GNU cpio does not.
        if command -v bsdtar >/dev/null; then
            bsdtar -xf "../BlackmagicRawSDK.pkg/Payload"
        else
            # A few sample dirs are mode 0444 and their contents fail to
            # extract with GNU cpio; none of them are needed by this project.
            cpio -idmu --quiet < "../BlackmagicRawSDK.pkg/Payload" || true
        fi
    )
    fix_perms "$TMP/pkg/payload"
    mkdir -p "$OUT/braw"
    cp -r "$TMP/pkg/payload/Applications/Blackmagic RAW/Blackmagic RAW SDK" "$OUT/braw/sdk"

    echo "== extracting Linux runtime libraries =="
    (
        cd "$TMP"
        mkdir -p linux && cd linux
        tar xf "$LINUX_TAR"
        tar xf "Blackmagic RAW/BlackmagicRAW_5.1.tar.gz"
    )
    mkdir -p "$OUT/braw/runtime"
    cp -r "$TMP/linux/BlackmagicRAW/BlackmagicRawAPI" "$OUT/braw/runtime/linux-x86_64"

    echo "== extracting Windows runtime libraries (from MSI) =="
    # The MSI stores files under their File-table keys; the runtime DLLs of
    # the BlackmagicRawAPI component carry this stable key -> name mapping.
    (
        cd "$TMP"
        mkdir -p win && cd win
        7z x -y "$WIN_ZIP" >/dev/null
        mkdir -p ext && cd ext
        7z x -y "../Install Blackmagic RAW 5.1.msi" >/dev/null 2>&1 || true
    )
    WIN_OUT="$OUT/braw/runtime/windows-x86_64"
    mkdir -p "$WIN_OUT"
    win_component="119C6D62_D037_40CB_9C18_B55829655B28"
    declare -A win_dlls=(
        [BlackmagicRawApiDll]="BlackmagicRawAPI.dll"
        [DecoderCudaDll]="DecoderCUDA.dll"
        [DecoderOpenClDll]="DecoderOpenCL.dll"
        [InstructionSetServicesAVXDll]="InstructionSetServicesAVX.dll"
        [InstructionSetServicesAVX2Dll]="InstructionSetServicesAVX2.dll"
    )
    for key in "${!win_dlls[@]}"; do
        src_file="$TMP/win/ext/$key.$win_component"
        dst_file="$WIN_OUT/${win_dlls[$key]}"
        [ -f "$src_file" ] || { echo "error: MSI stream $key.$win_component not found" >&2; exit 1; }
        # sanity: must be a PE binary
        [ "$(head -c2 "$src_file")" = "MZ" ] || { echo "error: $key is not a PE file" >&2; exit 1; }
        cp "$src_file" "$dst_file"
    done

    echo "== staging macOS runtime framework (universal x86_64+arm64) =="
    rm -rf "$OUT/braw/runtime/macos-universal"
    mkdir -p "$OUT/braw/runtime/macos-universal"
    cp -r "$OUT/braw/sdk/Mac/Libraries/BlackmagicRawAPI.framework" "$OUT/braw/runtime/macos-universal/"

    rm -rf "$TMP"
    echo "SDK:     $OUT/braw/sdk"
    echo "Runtime: $OUT/braw/runtime/{linux-x86_64,windows-x86_64,macos-universal}"
    echo "Sample:  $OUT/braw/sdk/Media/sample.braw"
fi

if [ "$SAMPLES" -eq 1 ]; then
    mkdir -p "$OUT/samples"
    for z in "$REPO/Video_samples"/*.zip; do
        echo "== unzipping $(basename "$z") =="
        7z x -y -o"$OUT/samples" "$z" >/dev/null
    done
    find "$OUT/samples" -name "*.braw" -o -name "*.sidecar" | sort
fi
