#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 WINDOWS_SITE_PACKAGES NATIVE_SITE_PACKAGES" >&2
    exit 2
fi

# Never resolve dependencies while packaging. Copy exact, verified wheels,
# including their .dist-info metadata and third-party license files.
while read -r target asset checksum url; do
    [[ -z "${target}" || "${target}" == \#* ]] && continue
    case "${target}" in
        common) destinations=("$1" "$2") ;;
        windows) destinations=("$1") ;;
        native) destinations=("$2") ;;
        *) echo "Unknown SWCLI wheel target: ${target}" >&2; exit 1 ;;
    esac
    wheel="${WORKSPACE_ROOT}/dist/${asset}"
    test "$(shasum -a 256 "${wheel}" | awk '{print $1}')" = "${checksum}" || {
        echo "SWCLI wheel missing or checksum mismatch: ${wheel}" >&2
        exit 1
    }
    for destination in "${destinations[@]}"; do
        mkdir -p "${destination}"
        unzip -q "${wheel}" -d "${destination}"
    done
done < "${SWCLI_WHEEL_MANIFEST}"
