#!/usr/bin/env bash
# Optional regression probe for patch 0023 (native file dialogs); x86_64 and i386.
set -euo pipefail
WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${FILE_DIALOG_PROBE_OUTPUT:-${WORKSPACE_ROOT}/build/native}"
SOURCE="$WORKSPACE_ROOT/native/wine_file_dialog_probe.c"
mkdir -p "$OUTPUT_DIR"
for ARCH in x86_64 i686; do
    COMPILER="${ARCH}-w64-mingw32-gcc"
    if ! command -v "$COMPILER" >/dev/null 2>&1; then
        echo "Missing tool: $COMPILER (brew install mingw-w64)" >&2
        exit 1
    fi
    NAME="wine_file_dialog_probe-${ARCH/i686/i386}.exe"
    "$COMPILER" -O2 -municode -Wall -Wextra -Wno-unused-parameter -Werror "$SOURCE" \
        -o "$OUTPUT_DIR/$NAME.tmp" -lole32 -luuid -lshell32 -lshlwapi -lcomdlg32 -luser32
    mv "$OUTPUT_DIR/$NAME.tmp" "$OUTPUT_DIR/$NAME"
    echo "Built: $OUTPUT_DIR/$NAME"
done
