#!/usr/bin/env bash
# Build the C++ oracle tools against the extracted SDK (third_party/).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="$REPO/third_party/braw/sdk/Linux"
[ -d "$SDK/Include" ] || { echo "run tools/extract-sdk.sh first" >&2; exit 1; }
mkdir -p "$REPO/test/oracle/bin"
CXX="${CXX:-g++}"
"$CXX" -O2 -std=c++11 -I"$SDK/Include" \
    "$REPO/test/oracle/dump_frame.cpp" "$SDK/Include/BlackmagicRawAPIDispatch.cpp" \
    -o "$REPO/test/oracle/bin/dump_frame" -ldl -lpthread
echo "built test/oracle/bin/dump_frame"
