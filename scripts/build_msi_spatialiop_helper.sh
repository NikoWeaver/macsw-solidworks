#!/usr/bin/env bash
# Builds native/msi_spatialiop.c, the MSI edit that MacSW runs under Wine on its copy of the
# SOLIDWORKS core MSI (docs/spatialiop-fix.md). package_app.sh calls this script.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${WORKSPACE_ROOT}/native/msi_spatialiop.c"
OUTPUT_DIR="${WORKSPACE_ROOT}/build/native"
OUTPUT="${OUTPUT_DIR}/msi_spatialiop.exe"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"

if ! command -v "${COMPILER}" >/dev/null 2>&1; then
    echo "Missing MinGW compiler: ${COMPILER}" >&2
    echo "Install it with: brew install mingw-w64" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
echo "==> Building the SpatialIOP MSI helper..."
# -s: no symbols or build paths in the shipped file; no time stamp, so the same source gives the same file.
"${COMPILER}" -Os -s -municode -Wall -Wextra -Werror -Wl,--no-insert-timestamp \
    -o "${OUTPUT}.tmp" "${SOURCE}" -lmsi
mv "${OUTPUT}.tmp" "${OUTPUT}"
echo "==> Built ${OUTPUT}"
