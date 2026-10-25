#!/usr/bin/env bash
set -euo pipefail
WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${PRINTWINDOW_PROBE_OUTPUT:-${WORKSPACE_ROOT}/build/native}"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
if ! command -v "$COMPILER" >/dev/null 2>&1; then
    echo "Missing tool: $COMPILER (brew install mingw-w64)" >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR"
"$COMPILER" -Os -Wall -Wextra -Werror "$WORKSPACE_ROOT/native/wine_printwindow_probe.c" \
    -o "$OUTPUT_DIR/wine_printwindow_probe.exe.tmp" -luser32 -lgdi32 -ldwmapi
mv "$OUTPUT_DIR/wine_printwindow_probe.exe.tmp" "$OUTPUT_DIR/wine_printwindow_probe.exe"
echo "Built: $OUTPUT_DIR/wine_printwindow_probe.exe"
