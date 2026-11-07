#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
DIST_DIR="${WORKSPACE_ROOT}/dist"
mkdir -p "${DIST_DIR}"

download_verified() {
    local label="$1"
    local url="$2"
    local destination="$3"
    local expected_sha256="$4"
    local actual_sha256

    if [ ! -f "${destination}" ]; then
        echo "==> Downloading ${label}..."
        curl -fL --retry 3 "${url}" -o "${destination}.download"
        actual_sha256="$(shasum -a 256 "${destination}.download" | awk '{print $1}')"
        if [ "${actual_sha256}" != "${expected_sha256}" ]; then
            echo "${label} checksum mismatch" >&2
            rm -f -- "${destination}.download"
            exit 1
        fi
        mv "${destination}.download" "${destination}"
    fi

    actual_sha256="$(shasum -a 256 "${destination}" | awk '{print $1}')"
    if [ "${actual_sha256}" != "${expected_sha256}" ]; then
        echo "${label} checksum mismatch: ${destination}" >&2
        exit 1
    fi
}

fetch_runtime() {
    download_verified "Gcenx Wine ${WINE_VERSION} runtime" "${WINE_RUNTIME_URL}" \
        "${DIST_DIR}/${WINE_RUNTIME_ASSET}" "${WINE_RUNTIME_SHA256}"
}

fetch_wine_source() {
    download_verified "Wine ${WINE_VERSION} source" "${WINE_SOURCE_URL}" \
        "${DIST_DIR}/${WINE_SOURCE_ASSET}" "${WINE_SOURCE_SHA256}"
}

fetch_mono_patch() {
    # Source is distributed for license compliance, not built or patched locally.
    download_verified 'Shared Mono engine source' "${MONO_SOURCE_URL}" \
        "${DIST_DIR}/${MONO_SOURCE_ASSET}" "${MONO_SOURCE_SHA256}"
    local mono_dir="${DIST_DIR}/${MONO_PATCH_RELEASE}"
    mkdir -p "${mono_dir}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} x86 patch" "${MONO_PATCH_URL}" \
        "${mono_dir}/libmono-2.0-x86.dll" "${MONO_PATCH_SHA256}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} shared x64 engine" "${MONO_X64_URL}" \
        "${mono_dir}/libmono-2.0-x86_64.dll" "${MONO_X64_SHA256}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} registration mscorlib" "${MONO_MSCORLIB_URL}" \
        "${mono_dir}/mscorlib.dll" "${MONO_MSCORLIB_SHA256}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} x86 RegAsm" "${MONO_REGASM_X86_URL}" \
        "${mono_dir}/regasm-x86.exe" "${MONO_REGASM_X86_SHA256}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} x64 RegAsm" "${MONO_REGASM_X64_URL}" \
        "${mono_dir}/regasm-x86_64.exe" "${MONO_REGASM_X64_SHA256}"
}

# The clean-room stdole is in the repository (third_party/stdole-clean); nothing is downloaded.
fetch_stdole() {
    local actual_sha256
    actual_sha256="$(shasum -a 256 "${STDOLE_DLL_SOURCE}" | awk '{print $1}')"
    if [ "${actual_sha256}" != "${STDOLE_DLL_SHA256}" ]; then
        echo "stdole DLL checksum mismatch: ${STDOLE_DLL_SOURCE}" >&2
        exit 1
    fi
}

fetch_seven_zip() {
    local archive="${DIST_DIR}/${SEVEN_Z_ARCHIVE_ASSET}"
    download_verified "7-Zip ${SEVEN_Z_VERSION}" "${SEVEN_Z_URL}" \
        "${archive}" "${SEVEN_Z_SHA256}"
    if [ ! -x "${DIST_DIR}/7zz" ]; then
        tar -xJf "${archive}" -C "${DIST_DIR}" 7zz
        chmod +x "${DIST_DIR}/7zz"
    fi
}

# The source archives of the LGPL libraries in the Gcenx runtime and of 7-Zip, which
# SOURCE.txt names; scripts/stage_source_release.sh copies them next to the DMG.
fetch_lgpl_sources() {
    local key url sha256
    for key in ${MACSW_LGPL_SOURCES}; do
        eval "url=\${${key}_SOURCE_URL}; sha256=\${${key}_SOURCE_SHA256}"
        download_verified "${key} source" "${url}" "${DIST_DIR}/${url##*/}" "${sha256}"
    done
}

# Runs MacSW's own wine_runtime.py (install and Wine maintenance); always needed.
fetch_native_python() {
    download_verified "native macOS Python ${SWCLI_NATIVE_PYTHON_VERSION}" \
        "${SWCLI_NATIVE_PYTHON_ARCHIVE_URL}" \
        "${DIST_DIR}/${SWCLI_NATIVE_PYTHON_ARCHIVE_ASSET}" \
        "${SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256}"
}

fetch_swcli_runtime() {
    download_verified "Windows embeddable Python ${SWCLI_PYTHON_VERSION}" \
        "${SWCLI_PYTHON_ARCHIVE_URL}" \
        "${DIST_DIR}/${SWCLI_PYTHON_ARCHIVE_ASSET}" \
        "${SWCLI_PYTHON_ARCHIVE_SHA256}"
    download_verified "pywin32 ${SWCLI_PYWIN32_VERSION}" \
        "${SWCLI_PYWIN32_WHEEL_URL}" \
        "${DIST_DIR}/${SWCLI_PYWIN32_WHEEL_ASSET}" \
        "${SWCLI_PYWIN32_WHEEL_SHA256}"
    while read -r target asset checksum url; do
        [[ -z "${target}" || "${target}" == \#* ]] && continue
        download_verified "SWCLI ${target} dependency ${asset}" "${url}" \
            "${DIST_DIR}/${asset}" "${checksum}"
    done < "${SWCLI_WHEEL_MANIFEST}"
}

case "${1:-all}" in
    all)
        fetch_runtime
        fetch_wine_source
        fetch_mono_patch
        fetch_stdole
        fetch_seven_zip
        fetch_native_python
        if [ "${MACSW_SKIP_SWCLI}" != 1 ]; then
            fetch_swcli_runtime
        fi
        ;;
    runtime) fetch_runtime ;;
    wine-source) fetch_wine_source ;;
    mono) fetch_mono_patch ;;
    stdole) fetch_stdole ;;
    seven-zip) fetch_seven_zip ;;
    lgpl-sources) fetch_lgpl_sources ;;
    native-python) fetch_native_python ;;
    swcli-runtime) fetch_swcli_runtime ;;
    *)
        echo "Usage: $0 [all|runtime|wine-source|mono|stdole|seven-zip|lgpl-sources|native-python|swcli-runtime]" >&2
        exit 2
        ;;
esac
