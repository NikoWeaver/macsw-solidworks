#!/usr/bin/env bash
set -euo pipefail
WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${SCREEN_READBACK_PROBE_OUTPUT:-${WORKSPACE_ROOT}/build/native}"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
if ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo "Missing tool: $COMPILER (brew install mingw-w64)" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"
"$COMPILER" -Os -Wall -Wextra -Werror "$WORKSPACE_ROOT/native/wine_screen_readback_probe.c" \
    -o "$OUTPUT_DIR/wine_screen_readback_probe.exe.tmp" -luser32 -lgdi32
mv "$OUTPUT_DIR/wine_screen_readback_probe.exe.tmp" "$OUTPUT_DIR/wine_screen_readback_probe.exe"
echo "Built: $OUTPUT_DIR/wine_screen_readback_probe.exe"
