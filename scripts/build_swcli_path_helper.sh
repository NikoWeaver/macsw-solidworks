#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${WORKSPACE_ROOT}/native/swcli_path.c"
OUTPUT_DIR="${WORKSPACE_ROOT}/build/native"
OUTPUT="${OUTPUT_DIR}/swcli_path.exe"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"

if ! command -v "${COMPILER}" >/dev/null 2>&1; then
    echo "Missing MinGW compiler: ${COMPILER}" >&2
    echo "Install it with: brew install mingw-w64" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
echo "==> Building SWCLI Wine path helper..."
"${COMPILER}" -Os -municode -Wall -Wextra -Werror \
    -o "${OUTPUT}.tmp" "${SOURCE}"
mv "${OUTPUT}.tmp" "${OUTPUT}"
echo "==> Built ${OUTPUT}"
