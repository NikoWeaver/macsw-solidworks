#!/usr/bin/env bash
# Isolated Wine 11.16 diagnostics. Does not use the production launcher.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/lib/config.sh"
RUNTIME="$ROOT/dist/wine-devel-${WINE_VERSION}/Wine Devel.app/Contents/Resources/wine"
export WINELOADER="$RUNTIME/bin/wineloader"
export WINESERVER="$RUNTIME/bin/wineserver"
unset WINEDLLPATH CX_ROOT DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
export WINEDEBUG="${WINEDEBUG:-+timestamp,+pid,+tid,+seh,+loaddll}"
# Match the existing Swift launcher for the installed Microsoft VC++ runtime.
# Keep Wine 11's own mscoree and graphics implementation for this isolated test.
export WINEDLLOVERRIDES="${PROBE_DLL_OVERRIDES:-atiadlxx=d;concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b}"
export WINEPREFIX="$ROOT/prefixes/sw-wine11-baseline"
case "${1:-}" in
  init) exec "$WINELOADER" cmd /c ver ;;
  launch)
    cd "$WINEPREFIX/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
    exec "$WINELOADER" sldworks.exe ;;
  launch-official)
    export WINEPREFIX="$ROOT/prefixes/sw-wine11-official"
    cd "$WINEPREFIX/drive_c/Program Files/SOLIDWORKS"
    exec "$WINELOADER" SLDWORKS.exe ;;
  installer)
    export WINEPREFIX="$ROOT/prefixes/sw-wine11-official"
    media="${2:-/Volumes/Solidworks1}"
    test -f "$media/swwi/data/solidworks.msi"
    mkdir -p "$ROOT/scratch/wine-baseline"
    # The official installer wizard asks for the serial number itself; nothing
    # is pre-written to the registry. Preserve deployed files if a late
    # Wine-incompatible custom action fails.
    exec "$WINELOADER" msiexec /i "$media/swwi/data/solidworks.msi" DISABLEROLLBACK=1 \
      /l*v "$ROOT/scratch/wine-baseline/official-msi.log" ;;
  *) echo "Usage: bash scripts/wine11_probe.sh {init|launch|launch-official|installer media-directory}" >&2; exit 2 ;;
esac
