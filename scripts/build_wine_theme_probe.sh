#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$WORKSPACE_ROOT/build/native"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
RESOURCE_COMPILER="${MINGW_WINDRES:-x86_64-w64-mingw32-windres}"
for TOOL in "$COMPILER" "$RESOURCE_COMPILER"; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        echo "Missing tool: $TOOL (brew install mingw-w64)" >&2
        exit 1
    fi
done
mkdir -p "$OUTPUT_DIR"
"$RESOURCE_COMPILER" -I "$WORKSPACE_ROOT/native" \
    "$WORKSPACE_ROOT/native/wine_theme_probe.rc" "$OUTPUT_DIR/wine_theme_probe.resources.o"
"$COMPILER" -Os -municode -Wall -Wextra -Werror \
    "$WORKSPACE_ROOT/native/wine_theme_probe.c" "$OUTPUT_DIR/wine_theme_probe.resources.o" \
    -o "$OUTPUT_DIR/wine_theme_probe.exe.tmp" -lcomctl32 -luxtheme -luser32 -lgdi32
mv "$OUTPUT_DIR/wine_theme_probe.exe.tmp" "$OUTPUT_DIR/wine_theme_probe.exe"
echo "Built: $OUTPUT_DIR/wine_theme_probe.exe"
