#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
# MACSW_SIGN_IDENTITY / MACSW_SIGN_KEYCHAIN: optional stable signing identity for the bundle.
source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"
source "${WORKSPACE_ROOT}/scripts/lib/strip_pe.sh"

APP_NAME="MacSW"
BUILD_ROOT="${WORKSPACE_ROOT}/build"
FINAL_APP_DIR="${MACSW_APP_OUTPUT:-${BUILD_ROOT}/app/${APP_NAME}.app}"
LAUNCHER_BIN="${BUILD_ROOT}/bootstrap/MacSW"
APP_ICON="${BUILD_ROOT}/resources/AppIcon.icns"
MACSW_LICENSE="${WORKSPACE_ROOT}/LICENSE"
MACSW_NOTICE="${WORKSPACE_ROOT}/NOTICE"
THIRD_PARTY_INVENTORY="${WORKSPACE_ROOT}/config/third-party-notices.tsv"
THIRD_PARTY_TEXTS="${WORKSPACE_ROOT}/resources/licenses/third-party"
WINE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_RUNTIME_ASSET}"
WINE_SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_SOURCE_ASSET}"
WINE_SOURCE_NOTICE_TEMPLATE="${WORKSPACE_ROOT}/resources/licenses/Wine-SOURCE.txt.in"
WINEMAC_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/winemac.so"
WIN32U_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/win32u.so"
NTDLL_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/ntdll.so"
COMBASE_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/combase.dll"
COMCTL32_V6_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/comctl32_v6.dll"
MSXML3_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/msxml3.dll"
MSXML3_I386_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/msxml3-i386.dll"
WS2_32_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/ws2_32.dll"
WS2_32_I386_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/ws2_32-i386.dll"
# Patches 0023/0024: native file dialogs (winemac.drv PE export + comdlg32), both architectures.
WINEMAC_DRV_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/winemac.drv"
WINEMAC_DRV_I386_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/winemac-i386.drv"
COMDLG32_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/comdlg32.dll"
COMDLG32_I386_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/comdlg32-i386.dll"
WBEMPROX_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/wbemprox.dll"
WBEMPROX_I386_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/wbemprox-i386.dll"
WINDOWSCODECS_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/windowscodecs.dll"
KERNELBASE_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/kernelbase.dll"
# Patch 0030: both halves of opengl32 (PE recorder and unix replay) come from the same build.
OPENGL32_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/opengl32.dll"
OPENGL32_UNIX_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/opengl32.so"
# Patch 0037: glu32 with GLU 1.3 NURBS (x86_64 only).
GLU32_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/glu32.dll"
WINE_LOADER_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/MacSW"
# Patch 0017 changes the server protocol: ntdll.so and wineserver must come from the same build.
WINESERVER_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/wineserver"
MONO_PATCH="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll"
MONO_MSCORLIB="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/mscorlib.dll"
MONO_REGASM_X86="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/regasm-x86.exe"
MONO_REGASM_X64="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/regasm-x86_64.exe"
MONO_CCW_DLL="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/libmono-2.0-x86_64.dll"
MONO_SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/${MONO_SOURCE_ASSET}"
STDOLE_DLL="${STDOLE_DLL_SOURCE}"
SEVEN_Z_BIN="${WORKSPACE_ROOT}/dist/7zz"
# The SpatialIOP MSI edit that MacSW runs under Wine (docs/spatialiop-fix.md).
MSI_SPATIALIOP_HELPER="${BUILD_ROOT}/native/msi_spatialiop.exe"
SWCLI_ROOT="${WORKSPACE_ROOT}/Dependencies/SWCLI"
SWCLI_SOURCE="${SWCLI_ROOT}/src/swcli"
SWCLI_LICENSE="${SWCLI_ROOT}/LICENSE"
SWCLI_LAUNCHER="${WORKSPACE_ROOT}/scripts/swcli/sw-cli"
SWCLI_NATIVE_PATH_HELPER="${WORKSPACE_ROOT}/scripts/swcli/swcli-path"
SWCLI_NATIVE_PATH_SCRIPT="${WORKSPACE_ROOT}/scripts/swcli/swcli_path.py"
SWCLI_RUNTIME_SYNC="${WORKSPACE_ROOT}/scripts/swcli/swcli_runtime.py"
SWCLI_PATH_HELPER="${BUILD_ROOT}/native/swcli_path.exe"
SWCLI_PYTHON_ARCHIVE="${WORKSPACE_ROOT}/dist/${SWCLI_PYTHON_ARCHIVE_ASSET}"
SWCLI_PYWIN32_WHEEL="${WORKSPACE_ROOT}/dist/${SWCLI_PYWIN32_WHEEL_ASSET}"
SWCLI_NATIVE_PYTHON_ARCHIVE="${WORKSPACE_ROOT}/dist/${SWCLI_NATIVE_PYTHON_ARCHIVE_ASSET}"

require_file() {
    if [ ! -f "$1" ]; then
        echo "Missing package input: $1" >&2
        exit 1
    fi
}

# Built from source on every run (one MinGW compile), so no old copy ships.
bash "${WORKSPACE_ROOT}/scripts/build_msi_spatialiop_helper.sh"

for PACKAGE_INPUT in "${LAUNCHER_BIN}" "${APP_ICON}" "${MACSW_LICENSE}" "${MACSW_NOTICE}" \
    "${WINE_ARCHIVE}" "${WINE_SOURCE_ARCHIVE}" "${WINE_SOURCE_NOTICE_TEMPLATE}" "${THIRD_PARTY_INVENTORY}" \
    "${WINEMAC_PATCH}" "${WIN32U_PATCH}" "${NTDLL_PATCH}" "${COMBASE_PATCH}" "${COMCTL32_V6_PATCH}" "${MSXML3_PATCH}" "${MSXML3_I386_PATCH}" "${WS2_32_PATCH}" "${WS2_32_I386_PATCH}" "${WINEMAC_DRV_PATCH}" "${WINEMAC_DRV_I386_PATCH}" "${COMDLG32_PATCH}" "${COMDLG32_I386_PATCH}" "${WBEMPROX_PATCH}" "${WBEMPROX_I386_PATCH}" "${WINDOWSCODECS_PATCH}" "${KERNELBASE_PATCH}" "${OPENGL32_PATCH}" "${OPENGL32_UNIX_PATCH}" "${GLU32_PATCH}" "${WINE_LOADER_PATCH}" "${WINESERVER_PATCH}" "${MONO_PATCH}" "${MONO_MSCORLIB}" \
    "${MONO_REGASM_X86}" "${MONO_REGASM_X64}" "${MONO_CCW_DLL}" "${MONO_SOURCE_ARCHIVE}" "${STDOLE_DLL}" "${SEVEN_Z_BIN}" \
    "${MSI_SPATIALIOP_HELPER}" "${SWCLI_NATIVE_PYTHON_ARCHIVE}"; do
    require_file "${PACKAGE_INPUT}"
done
if [ "${MACSW_SKIP_SWCLI}" != 1 ]; then
    for PACKAGE_INPUT in "${SWCLI_SOURCE}/__init__.py" "${SWCLI_LICENSE}" "${SWCLI_LAUNCHER}" \
        "${SWCLI_NATIVE_PATH_HELPER}" "${SWCLI_NATIVE_PATH_SCRIPT}" "${SWCLI_PATH_HELPER}" \
        "${SWCLI_PYTHON_ARCHIVE}" "${SWCLI_PYWIN32_WHEEL}" "${SWCLI_WHEEL_MANIFEST}"; do
        require_file "${PACKAGE_INPUT}"
    done
fi
unset PACKAGE_INPUT

test "$(shasum -a 256 "${WINE_ARCHIVE}" | awk '{print $1}')" = "${WINE_RUNTIME_SHA256}" || { echo "Wine runtime checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${WINE_SOURCE_ARCHIVE}" | awk '{print $1}')" = "${WINE_SOURCE_SHA256}" || { echo "Wine source checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_PATCH}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}" || { echo "Mono patch checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_CCW_DLL}" | awk '{print $1}')" = "${MONO_X64_SHA256}" || { echo "Shared Mono x64 checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_SOURCE_ARCHIVE}" | awk '{print $1}')" = "${MONO_SOURCE_SHA256}" || { echo "Shared Mono source checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_MSCORLIB}" | awk '{print $1}')" = "${MONO_MSCORLIB_SHA256}" || { echo "Mono mscorlib checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_REGASM_X86}" | awk '{print $1}')" = "${MONO_REGASM_X86_SHA256}" || { echo "x86 RegAsm checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_REGASM_X64}" | awk '{print $1}')" = "${MONO_REGASM_X64_SHA256}" || { echo "x64 RegAsm checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${STDOLE_DLL}" | awk '{print $1}')" = "${STDOLE_DLL_SHA256}" || { echo "stdole DLL checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${SWCLI_NATIVE_PYTHON_ARCHIVE}" | awk '{print $1}')" = "${SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256}" || { echo "native macOS Python archive checksum mismatch" >&2; exit 1; }
if [ "${MACSW_SKIP_SWCLI}" != 1 ]; then
    test "$(shasum -a 256 "${SWCLI_PYTHON_ARCHIVE}" | awk '{print $1}')" = "${SWCLI_PYTHON_ARCHIVE_SHA256}" || { echo "Windows Python archive checksum mismatch" >&2; exit 1; }
    test "$(shasum -a 256 "${SWCLI_PYWIN32_WHEEL}" | awk '{print $1}')" = "${SWCLI_PYWIN32_WHEEL_SHA256}" || { echo "pywin32 wheel checksum mismatch" >&2; exit 1; }
    ACTUAL_SWCLI_COMMIT="$(git -C "${SWCLI_ROOT}" rev-parse HEAD)"
    test "${ACTUAL_SWCLI_COMMIT}" = "${SWCLI_SOURCE_COMMIT}" || {
        echo "SWCLI submodule mismatch: expected ${SWCLI_SOURCE_COMMIT}, got ${ACTUAL_SWCLI_COMMIT}" >&2
        exit 1
    }
fi

mkdir -p "${BUILD_ROOT}/app"
STAGING_ROOT="$(mktemp -d "${BUILD_ROOT}/app/.package.XXXXXX")"
trap 'rm -rf -- "${STAGING_ROOT}"' EXIT
APP_DIR="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MAC_OS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

echo "==> Assembling ${APP_NAME}.app..."
mkdir -p "${MAC_OS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"
cp "${LAUNCHER_BIN}" "${MAC_OS_DIR}/MacSW"
cp "${WORKSPACE_ROOT}/resources/Info.plist.in" "${CONTENTS_DIR}/Info.plist"
cp "${APP_ICON}" "${RESOURCES_DIR}/AppIcon.icns"
mkdir -p "${RESOURCES_DIR}/managed"
cp -p "${STDOLE_DLL}" "${RESOURCES_DIR}/managed/stdole.dll"
cp -p "${SEVEN_Z_BIN}" "${MAC_OS_DIR}/7zz"
ln -sf 7zz "${MAC_OS_DIR}/7z"
mkdir -p "${RESOURCES_DIR}/helpers"
cp -p "${MSI_SPATIALIOP_HELPER}" "${RESOURCES_DIR}/helpers/msi_spatialiop.exe"
SWCLI_RUNTIME="${RESOURCES_DIR}/SWCLI/runtime/Python311"
SWCLI_SITE_PACKAGES="${SWCLI_RUNTIME}/Lib/site-packages"
SWCLI_NATIVE_RUNTIME="${RESOURCES_DIR}/SWCLI/runtime/PythonNative"
SWCLI_NATIVE_SITE_PACKAGES="${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages"
# MacSW's own bottle tooling (install and Wine maintenance) is always packaged:
# the native Python and wine_runtime.py. Keep the Resources/SWCLI paths.
mkdir -p "${RESOURCES_DIR}/SWCLI/bin" "${SWCLI_NATIVE_RUNTIME}" \
    "${RESOURCES_DIR}/SWCLI/licenses"
tar -xzf "${SWCLI_NATIVE_PYTHON_ARCHIVE}" -C "${SWCLI_NATIVE_RUNTIME}" \
    --strip-components=1
cp -p "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/LICENSE.txt" \
    "${RESOURCES_DIR}/SWCLI/licenses/Python-Native-LICENSE.txt"
cp -p "${WORKSPACE_ROOT}/scripts/swcli/wine_runtime.py" "${RESOURCES_DIR}/SWCLI/bin/wine_runtime.py"
# SWCLI itself. Without it there is no runtime-manifest.json, and the App
# skips backend deployment and hides the daemon UI.
if [ "${MACSW_SKIP_SWCLI}" != 1 ]; then
    # Non-Mach-O scripts belong in Resources, not a nested-code directory.
    # Keep the public CLI path; both entry locations are direct Contents children,
    # so the launcher's existing Contents-relative runtime lookup is unchanged.
    cp -p "${SWCLI_LAUNCHER}" "${RESOURCES_DIR}/sw-cli"
    chmod +x "${RESOURCES_DIR}/sw-cli"
    ln -s ../Resources/sw-cli "${MAC_OS_DIR}/sw-cli"
    mkdir -p "${SWCLI_SITE_PACKAGES}" "${SWCLI_NATIVE_SITE_PACKAGES}"
    unzip -q "${SWCLI_PYTHON_ARCHIVE}" -d "${SWCLI_RUNTIME}"
    unzip -q "${SWCLI_PYWIN32_WHEEL}" -d "${SWCLI_SITE_PACKAGES}"
    bash "${WORKSPACE_ROOT}/scripts/package_swcli_dependencies.sh" \
        "${SWCLI_SITE_PACKAGES}" "${SWCLI_NATIVE_SITE_PACKAGES}"
    cp -p "${SWCLI_WHEEL_MANIFEST}" "${RESOURCES_DIR}/SWCLI/wheels.tsv"
    tr -d '\r' < "${SWCLI_RUNTIME}/python311._pth" | awk '
        /^#import site$/ { print "Lib\\site-packages"; print "import site"; next }
        { print }
    ' > "${SWCLI_RUNTIME}/python311._pth.new"
    mv "${SWCLI_RUNTIME}/python311._pth.new" "${SWCLI_RUNTIME}/python311._pth"
    rsync -a --exclude='__pycache__' --exclude='*.pyc' \
        "${SWCLI_SOURCE}/" "${SWCLI_SITE_PACKAGES}/swcli/"
    rsync -a --exclude='__pycache__' --exclude='*.pyc' \
        "${SWCLI_SOURCE}/" "${SWCLI_NATIVE_SITE_PACKAGES}/swcli/"
    cp -p "${SWCLI_LICENSE}" "${RESOURCES_DIR}/SWCLI/licenses/SWCLI-LICENSE"
    unzip -p "${SWCLI_PYTHON_ARCHIVE}" LICENSE.txt \
        > "${RESOURCES_DIR}/SWCLI/licenses/Python-LICENSE.txt"
    unzip -p "${SWCLI_PYWIN32_WHEEL}" win32/License.txt \
        > "${RESOURCES_DIR}/SWCLI/licenses/pywin32-LICENSE.txt"
    cp -p "${SWCLI_PATH_HELPER}" "${RESOURCES_DIR}/SWCLI/bin/swcli_path.exe"
    cp -p "${SWCLI_NATIVE_PATH_HELPER}" "${RESOURCES_DIR}/SWCLI/bin/swcli-path"
    cp -p "${SWCLI_NATIVE_PATH_SCRIPT}" "${RESOURCES_DIR}/SWCLI/bin/swcli_path.py"
    cp -p "${SWCLI_RUNTIME_SYNC}" "${RESOURCES_DIR}/SWCLI/bin/swcli_runtime.py"
    chmod +x "${RESOURCES_DIR}/SWCLI/bin/swcli-path"
    "${SWCLI_NATIVE_RUNTIME}/bin/python3" -I "${SWCLI_RUNTIME_SYNC}" \
        --contents "${CONTENTS_DIR}" --build-manifest \
        --version "${SWCLI_VERSION}" --source-commit "${SWCLI_SOURCE_COMMIT}"
fi

MACSW_LICENSES_DIR="${RESOURCES_DIR}/licenses/MacSW"
mkdir -p "${MACSW_LICENSES_DIR}"
cp -p "${MACSW_LICENSE}" "${MACSW_LICENSES_DIR}/Apache-2.0.txt"
cp -p "${MACSW_NOTICE}" "${MACSW_LICENSES_DIR}/NOTICE"

SOURCE_TREE="${MACSW_SOURCE_TREE:-${WORKSPACE_ROOT}}"
GIT_COMMIT="$(git -C "${SOURCE_TREE}" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "${SOURCE_TREE}" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)"

# The source offer (LGPL): the same text in licenses/Wine (SOLIDWORKS.app copies that folder)
# and in Resources/SOURCE.txt, which the DMG script copies next to the app.
WINE_LICENSES_DIR="${RESOURCES_DIR}/licenses/Wine"
mkdir -p "${WINE_LICENSES_DIR}"
tar -xOf "${WINE_SOURCE_ARCHIVE}" "wine-${WINE_VERSION}/COPYING.LIB" \
    > "${WINE_LICENSES_DIR}/LGPL-2.1.txt"
MACSW_SOURCE_ONLINE=""
MACSW_SOURCE_TAG=""
# The @LGPL_SOURCES@ line of the template: the source archive of each LGPL library of the Gcenx
# runtime (MACSW_LGPL_SOURCES; 7-Zip has its own item) and its SHA-256.
lgpl_source_lines() {
    local line key url sha256
    while IFS= read -r line || [ -n "${line}" ]; do
        if [ "${line}" != "@LGPL_SOURCES@" ]; then
            printf '%s\n' "${line}"
            continue
        fi
        for key in ${MACSW_LGPL_SOURCES}; do
            [ "${key}" = SEVEN_Z ] && continue
            eval "url=\${${key}_SOURCE_URL}; sha256=\${${key}_SOURCE_SHA256}"
            printf '   %s\n     SHA-256: %s\n' "${url}" "${sha256}"
        done
    done
}
# The repository lines only for a commit that is in this fork's repository (a build from a clone
# of it). A build from the private MacSW repository names only the commit and the source archive.
if macsw_commit_is_published "${SOURCE_TREE}" "${GIT_COMMIT}"; then
    MACSW_SOURCE_ONLINE="   The source of that commit is also online: ${MACSW_SOURCE_URL}"
    MACSW_SOURCE_TAG="   Release tag ${APP_RELEASE}: ${MACSW_SOURCE_URL}/releases/tag/${APP_RELEASE}"
elif [ -n "${MACSW_SOURCE_URL:-}" ]; then
    echo "note: commit ${GIT_COMMIT} is not on ${MACSW_SOURCE_URL}; SOURCE.txt names no repository" >&2
fi
sed \
    -e "s|@APP_RELEASE@|${APP_RELEASE}|g" \
    -e "s|@APP_BUILD@|${APP_BUILD}|g" \
    -e "s|@GIT_COMMIT@|${GIT_COMMIT}|g" \
    -e "s|@MACSW_SOURCE_ONLINE@|${MACSW_SOURCE_ONLINE}|g" \
    -e "s|@MACSW_SOURCE_TAG@|${MACSW_SOURCE_TAG}|g" \
    -e "s|@WINE_VERSION@|${WINE_VERSION}|g" \
    -e "s|@WINE_SOURCE_URL@|${WINE_SOURCE_URL}|g" \
    -e "s|@WINE_SOURCE_SHA256@|${WINE_SOURCE_SHA256}|g" \
    -e "s|@WINE_RUNTIME_URL@|${WINE_RUNTIME_URL}|g" \
    -e "s|@WINE_RUNTIME_SHA256@|${WINE_RUNTIME_SHA256}|g" \
    -e "s|@SEVEN_Z_VERSION@|${SEVEN_Z_VERSION}|g" \
    -e "s|@SEVEN_Z_SOURCE_URL@|${SEVEN_Z_SOURCE_URL}|g" \
    -e "s|@SEVEN_Z_SOURCE_SHA256@|${SEVEN_Z_SOURCE_SHA256}|g" \
    "${WINE_SOURCE_NOTICE_TEMPLATE}" | lgpl_source_lines | cat -s > "${WINE_LICENSES_DIR}/SOURCE.txt"
cp -p "${WINE_LICENSES_DIR}/SOURCE.txt" "${RESOURCES_DIR}/SOURCE.txt"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWWineVersion ${WINE_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoVersion ${WINE_MONO_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoPatchSHA256 ${MONO_PATCH_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoMscorlibSHA256 ${MONO_MSCORLIB_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoRegAsmX86SHA256 ${MONO_REGASM_X86_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoRegAsmX64SHA256 ${MONO_REGASM_X64_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWStdoleVersion ${STDOLE_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWStdoleSHA256 ${STDOLE_DLL_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MACOS_DEPLOYMENT_TARGET}" "${CONTENTS_DIR}/Info.plist"

WINE_UNPACK="${STAGING_ROOT}/runtime"
mkdir -p "${WINE_UNPACK}"
tar -xf "${WINE_ARCHIVE}" -C "${WINE_UNPACK}"
# Wine is a mixed native/PE/data tree, not an Apple framework. Dotted data
# directories (icd.d, wine-mono-11.3.0, etc.) must not be parsed as nested
# code bundles. Keep the original public runtime path as a relative alias.
mv "${WINE_UNPACK}/Wine Devel.app/Contents/Resources/wine" "${RESOURCES_DIR}/Wine"
ln -s ../Resources/Wine "${FRAMEWORKS_DIR}/wine"
ln -sf wine "${FRAMEWORKS_DIR}/wine/bin/wineloader"

WINEMAC_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/winemac.so"
WIN32U_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/win32u.so"
COMBASE_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/combase.dll"
COMCTL32_V6_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/comctl32_v6.dll"
MSXML3_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/msxml3.dll"
MSXML3_I386_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/msxml3.dll"
WS2_32_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/ws2_32.dll"
WS2_32_I386_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/ws2_32.dll"
WINEMAC_DRV_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/winemac.drv"
WINEMAC_DRV_I386_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/winemac.drv"
COMDLG32_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/comdlg32.dll"
COMDLG32_I386_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/comdlg32.dll"
WBEMPROX_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/wbemprox.dll"
WBEMPROX_I386_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/wbemprox.dll"
WINDOWSCODECS_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/windowscodecs.dll"
KERNELBASE_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/kernelbase.dll"
OPENGL32_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/opengl32.dll"
OPENGL32_UNIX_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/opengl32.so"
GLU32_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/glu32.dll"
NTDLL_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/ntdll.so"
BRANDED_WINE_LOADER="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/MacSW"
WINE_LOADER_COMPAT="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/wine"
cp "${WINEMAC_PATCH}" "${WINEMAC_TARGET}"
cp "${WIN32U_PATCH}" "${WIN32U_TARGET}"
cp "${NTDLL_PATCH}" "${NTDLL_TARGET}"
cp "${COMBASE_PATCH}" "${COMBASE_TARGET}"
cp "${COMCTL32_V6_PATCH}" "${COMCTL32_V6_TARGET}"
cp "${MSXML3_PATCH}" "${MSXML3_TARGET}"
cp "${MSXML3_I386_PATCH}" "${MSXML3_I386_TARGET}"
cp "${WS2_32_PATCH}" "${WS2_32_TARGET}"
cp "${WS2_32_I386_PATCH}" "${WS2_32_I386_TARGET}"
cp "${WINEMAC_DRV_PATCH}" "${WINEMAC_DRV_TARGET}"
cp "${WINEMAC_DRV_I386_PATCH}" "${WINEMAC_DRV_I386_TARGET}"
cp "${COMDLG32_PATCH}" "${COMDLG32_TARGET}"
cp "${COMDLG32_I386_PATCH}" "${COMDLG32_I386_TARGET}"
cp "${WBEMPROX_PATCH}" "${WBEMPROX_TARGET}"
cp "${WBEMPROX_I386_PATCH}" "${WBEMPROX_I386_TARGET}"
cp "${WINDOWSCODECS_PATCH}" "${WINDOWSCODECS_TARGET}"
cp "${KERNELBASE_PATCH}" "${KERNELBASE_TARGET}"
cp "${OPENGL32_PATCH}" "${OPENGL32_TARGET}"
cp "${OPENGL32_UNIX_PATCH}" "${OPENGL32_UNIX_TARGET}"
cp "${GLU32_PATCH}" "${GLU32_TARGET}"
cp "${WINE_LOADER_PATCH}" "${BRANDED_WINE_LOADER}"
WINESERVER_TARGET="${FRAMEWORKS_DIR}/wine/bin/wineserver"
rm -f "${WINESERVER_TARGET}"
cp "${WINESERVER_PATCH}" "${WINESERVER_TARGET}"
ln -sf MacSW "${WINE_LOADER_COMPAT}"
# Strip the rebuilt PE modules (16 files; the first 15 are 72 MB with DWARF and the COFF symbol table,
# 12 MB without; see scripts/lib/strip_pe.sh). Done here, before the manifest hashes below, so BuildManifest.plist and
# verify_app.sh describe the shipped bytes, and dist/winemac-* keeps the symbols for debugging.
# MACSW_STRIP_PE=0 ships them unstripped (for a crash that needs symbols). The pinned Mono files
# (regasm.exe, libmono, mscorlib) are not touched here: their SHA-256 values are pins.
if [ "${MACSW_STRIP_PE:-1}" != 0 ]; then
    echo "==> Stripping the rebuilt PE modules..."
    macsw_strip_pe \
        "${COMBASE_TARGET}" "${COMCTL32_V6_TARGET}" "${MSXML3_TARGET}" "${MSXML3_I386_TARGET}" \
        "${WS2_32_TARGET}" "${WS2_32_I386_TARGET}" "${WINEMAC_DRV_TARGET}" "${WINEMAC_DRV_I386_TARGET}" \
        "${COMDLG32_TARGET}" "${COMDLG32_I386_TARGET}" "${WBEMPROX_TARGET}" "${WBEMPROX_I386_TARGET}" \
        "${WINDOWSCODECS_TARGET}" "${KERNELBASE_TARGET}" "${OPENGL32_TARGET}" "${GLU32_TARGET}"
fi
# Always ad hoc, also with MACSW_SIGN_IDENTITY: the SHA-256 of these files is the runtime identity
# in BuildManifest.plist (bottle receipts compare it). An ad hoc signature is reproducible; a
# certificate signature carries its signing time, so every rebuild would ask for a bottle migration.
codesign --force --sign - "${WINEMAC_TARGET}"
codesign --force --sign - "${WIN32U_TARGET}"
codesign --force --sign - "${NTDLL_TARGET}"
codesign --force --sign - "${OPENGL32_UNIX_TARGET}"
codesign --force --sign - "${BRANDED_WINE_LOADER}"
codesign --force --sign - "${WINESERVER_TARGET}"
cp "${MONO_PATCH}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"
MONO_CCW_TARGET="${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86_64.dll"
MONO_BTLS_TARGET="${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/x86_64/libmono-btls-shared.dll"
require_file "${MONO_BTLS_TARGET}"
cp "${MONO_CCW_DLL}" "${MONO_CCW_TARGET}"
cp "${MONO_MSCORLIB}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/mono/4.5/mscorlib.dll"
cp "${MONO_REGASM_X86}" "${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/regasm.exe"
cp "${MONO_REGASM_X64}" "${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/regasm.exe"

BUILD_MANIFEST="${RESOURCES_DIR}/BuildManifest.plist"
plutil -create xml1 "${BUILD_MANIFEST}"
WINEMAC_BRANDING_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0001-winemac-macsw-branding.patch" | awk '{print $1}')"
WINEMAC_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch" | awk '{print $1}')"
WIN32U_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch" | awk '{print $1}')"
WINEMAC_OPENGL_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch" | awk '{print $1}')"
WIN32U_TOPMOST_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0005-win32u-ignore-child-topmost.patch" | awk '{print $1}')"
WINEMAC_SPACE_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0006-winemac-preserve-solidworks-view-space.patch" | awk '{print $1}')"
COMBASE_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0007-combase-wait-solidworks-registration.patch" | awk '{print $1}')"
WINEMAC_BITMAP_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0008-winemac-bitmap-framebuffer.patch" | awk '{print $1}')"
WINEMAC_SOFTWARE_RENDERER_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0009-winemac-software-renderer-fallback.patch" | awk '{print $1}')"
TREEVIEW_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0010-comctl32-treeview-image-spacing.patch" | awk '{print $1}')"
PRINTWINDOW_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0011-win32u-printwindow-surface.patch" | awk '{print $1}')"
FONTLINK_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0012-win32u-preserve-custom-font-links.patch" | awk '{print $1}')"
SCREEN_READBACK_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0013-winemac-screen-readback.patch" | awk '{print $1}')"
MSXML_SCHEMA_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0014-msxml-schema-cache-namespace.patch" | awk '{print $1}')"
PE_MAPPING_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0015-ntdll-probe-executable-file-mappings.patch" | awk '{print $1}')"
MEM_RESET_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0016-ntdll-macos-release-decommitted-memory.patch" | awk '{print $1}')"
MSYNC_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0017-ntdll-server-msync.patch" | awk '{print $1}')"
CROSS_PROCESS_SURFACES_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0018-win32u-cross-process-window-surfaces.patch" | awk '{print $1}')"
HEADER_LAYOUT_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0019-comctl32-header-layout-null.patch" | awk '{print $1}')"
COMPUTER_NAME_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0020-ws2_32-resolve-own-computer-name.patch" | awk '{print $1}')"
MSXML_SEND_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0021-msxml3-xmlhttp-send-domdocument.patch" | awk '{print $1}')"
MSXML_EMPTY_ELEMENT_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0022-msxml3-expand-empty-elements.patch" | awk '{print $1}')"
NATIVE_FILE_DIALOG_DRIVER_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0023-winemac-native-file-dialogs.patch" | awk '{print $1}')"
NATIVE_FILE_DIALOG_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0024-comdlg32-native-file-dialogs.patch" | awk '{print $1}')"
APP_BUNDLE_HOST_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0025-winemac-app-bundle-host.patch" | awk '{print $1}')"
APP_NAP_DEFAULTS_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0035-winemac-app-nap-defaults.patch" | awk '{print $1}')"
WBEMPROX_IPENABLED_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0028-wbemprox-ipenabled-needs-mac-address.patch" | awk '{print $1}')"
WIC_CACHE_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0032-windowscodecs-cache-component-registry.patch" | awk '{print $1}')"
LOCAL_MODULE_READS_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0033-kernelbase-local-module-reads.patch" | awk '{print $1}')"
OPENGL32_BATCH_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0030-opengl32-batch-immediate-mode-calls.patch" | awk '{print $1}')"
SERVER_WINDOW_WALKS_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0034-server-unlinked-window-walks.patch" | awk '{print $1}')"
MPENGINE_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0036-winemac-multithreaded-gl-engine.patch" | awk '{print $1}')"
GLU_NURBS_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0037-glu32-nurbs.patch" | awk '{print $1}')"
WINEMAC_MODULE_SHA256="$(shasum -a 256 "${WINEMAC_TARGET}" | awk '{print $1}')"
WIN32U_MODULE_SHA256="$(shasum -a 256 "${WIN32U_TARGET}" | awk '{print $1}')"
COMBASE_MODULE_SHA256="$(shasum -a 256 "${COMBASE_TARGET}" | awk '{print $1}')"
COMCTL32_V6_MODULE_SHA256="$(shasum -a 256 "${COMCTL32_V6_TARGET}" | awk '{print $1}')"
MSXML3_MODULE_SHA256="$(shasum -a 256 "${MSXML3_TARGET}" | awk '{print $1}')"
MSXML3_I386_MODULE_SHA256="$(shasum -a 256 "${MSXML3_I386_TARGET}" | awk '{print $1}')"
WS2_32_MODULE_SHA256="$(shasum -a 256 "${WS2_32_TARGET}" | awk '{print $1}')"
WS2_32_I386_MODULE_SHA256="$(shasum -a 256 "${WS2_32_I386_TARGET}" | awk '{print $1}')"
WINEMAC_DRV_MODULE_SHA256="$(shasum -a 256 "${WINEMAC_DRV_TARGET}" | awk '{print $1}')"
WINEMAC_DRV_I386_MODULE_SHA256="$(shasum -a 256 "${WINEMAC_DRV_I386_TARGET}" | awk '{print $1}')"
COMDLG32_MODULE_SHA256="$(shasum -a 256 "${COMDLG32_TARGET}" | awk '{print $1}')"
COMDLG32_I386_MODULE_SHA256="$(shasum -a 256 "${COMDLG32_I386_TARGET}" | awk '{print $1}')"
WBEMPROX_MODULE_SHA256="$(shasum -a 256 "${WBEMPROX_TARGET}" | awk '{print $1}')"
WBEMPROX_I386_MODULE_SHA256="$(shasum -a 256 "${WBEMPROX_I386_TARGET}" | awk '{print $1}')"
WINDOWSCODECS_MODULE_SHA256="$(shasum -a 256 "${WINDOWSCODECS_TARGET}" | awk '{print $1}')"
KERNELBASE_MODULE_SHA256="$(shasum -a 256 "${KERNELBASE_TARGET}" | awk '{print $1}')"
OPENGL32_MODULE_SHA256="$(shasum -a 256 "${OPENGL32_TARGET}" | awk '{print $1}')"
OPENGL32_UNIX_MODULE_SHA256="$(shasum -a 256 "${OPENGL32_UNIX_TARGET}" | awk '{print $1}')"
GLU32_MODULE_SHA256="$(shasum -a 256 "${GLU32_TARGET}" | awk '{print $1}')"
NTDLL_MODULE_SHA256="$(shasum -a 256 "${NTDLL_TARGET}" | awk '{print $1}')"
WINE_LOADER_SHA256="$(shasum -a 256 "${BRANDED_WINE_LOADER}" | awk '{print $1}')"
# Patch 0017's wineserver (rebuilt, re-signed above): hashed like the loader.
WINESERVER_SHA256="$(shasum -a 256 "${WINESERVER_TARGET}" | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Add :AppVersion string ${APP_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :AppBuild string ${APP_BUILD}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :AppRelease string ${APP_RELEASE}" "${BUILD_MANIFEST}"
# Not part of the bottle identity (a bool, not a "Wine*" string): verify_app.sh checks the 16 rebuilt PE modules against it.
if [ "${MACSW_STRIP_PE:-1}" != 0 ]; then
    /usr/libexec/PlistBuddy -c "Add :PEModulesStripped bool true" "${BUILD_MANIFEST}"
else
    /usr/libexec/PlistBuddy -c "Add :PEModulesStripped bool false" "${BUILD_MANIFEST}"
fi
/usr/libexec/PlistBuddy -c "Add :GitCommit string ${GIT_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :GitBranch string ${GIT_BRANCH}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineVersion string ${WINE_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineRuntimeSHA256 string ${WINE_RUNTIME_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineSourceSHA256 string ${WINE_SOURCE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacBrandingPatchSHA256 string ${WINEMAC_BRANDING_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacPatchSHA256 string ${WINEMAC_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineInputPatchSHA256 string ${WIN32U_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WinePrintWindowPatchSHA256 string ${PRINTWINDOW_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineFontLinkPatchSHA256 string ${FONTLINK_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineScreenReadbackPatchSHA256 string ${SCREEN_READBACK_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMSXMLSchemaPatchSHA256 string ${MSXML_SCHEMA_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WinePEMappingPatchSHA256 string ${PE_MAPPING_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMemResetPatchSHA256 string ${MEM_RESET_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMsyncPatchSHA256 string ${MSYNC_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineServerWindowWalksPatchSHA256 string ${SERVER_WINDOW_WALKS_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMPEnginePatchSHA256 string ${MPENGINE_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineCrossProcessSurfacesPatchSHA256 string ${CROSS_PROCESS_SURFACES_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineHeaderLayoutPatchSHA256 string ${HEADER_LAYOUT_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineComputerNamePatchSHA256 string ${COMPUTER_NAME_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWS2_32ModuleSHA256 string ${WS2_32_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWS2_32I386ModuleSHA256 string ${WS2_32_I386_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMSXMLSendPatchSHA256 string ${MSXML_SEND_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMSXML3I386ModuleSHA256 string ${MSXML3_I386_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMSXMLEmptyElementPatchSHA256 string ${MSXML_EMPTY_ELEMENT_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacAppBundleHostPatchSHA256 string ${APP_BUNDLE_HOST_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacAppNapDefaultsPatchSHA256 string ${APP_NAP_DEFAULTS_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWbemproxIPEnabledPatchSHA256 string ${WBEMPROX_IPENABLED_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWbemproxModuleSHA256 string ${WBEMPROX_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWbemproxI386ModuleSHA256 string ${WBEMPROX_I386_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWICCachePatchSHA256 string ${WIC_CACHE_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineWindowsCodecsModuleSHA256 string ${WINDOWSCODECS_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineLocalModuleReadsPatchSHA256 string ${LOCAL_MODULE_READS_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineKernelBaseModuleSHA256 string ${KERNELBASE_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineOpenGLBatchPatchSHA256 string ${OPENGL32_BATCH_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineOpenGL32ModuleSHA256 string ${OPENGL32_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineOpenGL32UnixModuleSHA256 string ${OPENGL32_UNIX_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineGluNurbsPatchSHA256 string ${GLU_NURBS_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineGLU32ModuleSHA256 string ${GLU32_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMSXML3ModuleSHA256 string ${MSXML3_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineNativeFileDialogDriverPatchSHA256 string ${NATIVE_FILE_DIALOG_DRIVER_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineNativeFileDialogPatchSHA256 string ${NATIVE_FILE_DIALOG_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacDrvModuleSHA256 string ${WINEMAC_DRV_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacDrvI386ModuleSHA256 string ${WINEMAC_DRV_I386_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineComdlg32ModuleSHA256 string ${COMDLG32_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineComdlg32I386ModuleSHA256 string ${COMDLG32_I386_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacOpenGLPatchSHA256 string ${WINEMAC_OPENGL_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineChildTopmostPatchSHA256 string ${WIN32U_TOPMOST_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacSpacePatchSHA256 string ${WINEMAC_SPACE_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineCOMActivationPatchSHA256 string ${COMBASE_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacBitmapPatchSHA256 string ${WINEMAC_BITMAP_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacSoftwareRendererPatchSHA256 string ${WINEMAC_SOFTWARE_RENDERER_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineTreeViewPatchSHA256 string ${TREEVIEW_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacModuleSHA256 string ${WINEMAC_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineInputModuleSHA256 string ${WIN32U_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineCOMBaseModuleSHA256 string ${COMBASE_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineComctl32V6ModuleSHA256 string ${COMCTL32_V6_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineNtdllModuleSHA256 string ${NTDLL_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineLoaderSHA256 string ${WINE_LOADER_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineServerSHA256 string ${WINESERVER_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoVersion string ${WINE_MONO_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchRelease string ${MONO_PATCH_RELEASE}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSourceCommit string ${MONO_PATCH_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSHA256 string ${MONO_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoMscorlibSHA256 string ${MONO_MSCORLIB_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoRegAsmX86SHA256 string ${MONO_REGASM_X86_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoRegAsmX64SHA256 string ${MONO_REGASM_X64_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoSourceCommit string ${MONO_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoSourceSHA256 string ${MONO_SOURCE_SHA256}" "${BUILD_MANIFEST}"
# Retain this identity key so existing local-overlay containers upgrade safely.
/usr/libexec/PlistBuddy -c "Add :MonoCCWModuleSHA256 string ${MONO_X64_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoBTLSModuleSHA256 string $(shasum -a 256 "${MONO_BTLS_TARGET}" | awk '{print $1}')" "${BUILD_MANIFEST}"
MONO_LICENSES_DIR="${RESOURCES_DIR}/licenses/Mono"
mkdir -p "${MONO_LICENSES_DIR}"
for MONO_LICENSE_FILE in LICENSE COPYING.LIB PATENTS.TXT; do
    tar -xOf "${MONO_SOURCE_ARCHIVE}" "mono-${MONO_SOURCE_COMMIT}/${MONO_LICENSE_FILE}" > "${MONO_LICENSES_DIR}/${MONO_LICENSE_FILE}"
done
printf 'Mono engine source: %s\nSHA-256: %s\nShared build source: https://github.com/YJBeetle/wine-mono/tree/%s\nRelease: %s\nBTLS library remains from the pinned Wine runtime.\n' \
    "${MONO_SOURCE_URL}" "${MONO_SOURCE_SHA256}" "${MONO_PATCH_SOURCE_COMMIT}" "${MONO_PATCH_RELEASE}" > "${MONO_LICENSES_DIR}/SOURCE.txt"
/usr/libexec/PlistBuddy -c "Add :StdoleVersion string ${STDOLE_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :StdoleDLLSHA256 string ${STDOLE_DLL_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SevenZipVersion string ${SEVEN_Z_VERSION}" "${BUILD_MANIFEST}"
if [ "${MACSW_SKIP_SWCLI}" = 1 ]; then
    /usr/libexec/PlistBuddy -c "Add :SWCLIIncluded bool false" "${BUILD_MANIFEST}"
else
    /usr/libexec/PlistBuddy -c "Add :SWCLIIncluded bool true" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIVersion string ${SWCLI_VERSION}" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLISourceCommit string ${SWCLI_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIWheelManifestSHA256 string $(shasum -a 256 "${SWCLI_WHEEL_MANIFEST}" | awk '{print $1}')" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIPythonVersion string ${SWCLI_PYTHON_VERSION}" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIPythonArchiveSHA256 string ${SWCLI_PYTHON_ARCHIVE_SHA256}" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIPyWin32Version string ${SWCLI_PYWIN32_VERSION}" "${BUILD_MANIFEST}"
    /usr/libexec/PlistBuddy -c "Add :SWCLIPyWin32WheelSHA256 string ${SWCLI_PYWIN32_WHEEL_SHA256}" "${BUILD_MANIFEST}"
fi
# The native Python ships in both cases (wine_runtime.py runs on it).
/usr/libexec/PlistBuddy -c "Add :SWCLINativePythonVersion string ${SWCLI_NATIVE_PYTHON_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLINativePythonRelease string ${SWCLI_NATIVE_PYTHON_RELEASE}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLINativePythonArchiveSHA256 string ${SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256}" "${BUILD_MANIFEST}"

# SOLIDWORKS.app, the app users start, ships inside MacSW.app (Resources/SOLIDWORKS.app.zip) and
# MacSW's "Install SOLIDWORKS App" copies it to /Applications (docs/solidworks-app.md, section 4).
# It is built and signed here, before this bundle is sealed. MACSW_SKIP_SOLIDWORKS_APP=1 leaves it out.
if [ "${MACSW_SKIP_SOLIDWORKS_APP:-0}" != 1 ]; then
    MACSW_APP_OUTPUT="${APP_DIR}" bash "${WORKSPACE_ROOT}/scripts/package_solidworks_app.sh" --embed
fi

# THIRD_PARTY_NOTICES.txt, from config/third-party-notices.tsv, once every part is in place:
# the build stops when a part of the bundle is not in the table. The DMG script copies it.
GECKO_LICENSES_DIR="${RESOURCES_DIR}/licenses/Gecko"
mkdir -p "${GECKO_LICENSES_DIR}"
# Gecko's about:license page. omni.ja is an optimized jar: unzip reads it but warns and exits 2.
unzip -p "${FRAMEWORKS_DIR}/wine/share/wine/gecko/"wine-gecko-*-x86_64/omni.ja \
    chrome/toolkit/content/global/license.html > "${GECKO_LICENSES_DIR}/license.html" 2>/dev/null || true
grep -q '<title>about:license</title>' "${GECKO_LICENSES_DIR}/license.html"
NOTICE_VALUES=()
for NOTICE_KEY in APP_VERSION APP_BUILD WINE_VERSION WINE_SOURCE_URL WINE_SOURCE_SHA256 WINE_RUNTIME_URL \
    WINE_RUNTIME_SHA256 WINE_MONO_VERSION MONO_PATCH_RELEASE SEVEN_Z_VERSION SEVEN_Z_SOURCE_URL \
    STDOLE_VERSION STDOLE_DLL_SHA256 SWCLI_NATIVE_PYTHON_VERSION SWCLI_NATIVE_PYTHON_RELEASE SWCLI_VERSION \
    GNUTLS_VERSION GNUTLS_SOURCE_URL NETTLE_VERSION NETTLE_SOURCE_URL GMP_VERSION GMP_SOURCE_URL \
    LIBTASN1_VERSION LIBTASN1_SOURCE_URL LIBUNISTRING_VERSION LIBUNISTRING_SOURCE_URL \
    LIBIDN2_VERSION LIBIDN2_SOURCE_URL LIBICONV_VERSION LIBICONV_SOURCE_URL GETTEXT_VERSION GETTEXT_SOURCE_URL; do
    NOTICE_VALUES+=(--set "${NOTICE_KEY}=${!NOTICE_KEY}")
done
unset NOTICE_KEY
python3 -I "${WORKSPACE_ROOT}/scripts/third_party_notices.py" --inventory "${THIRD_PARTY_INVENTORY}" \
    --texts "${THIRD_PARTY_TEXTS}" --wine-source "${WINE_SOURCE_ARCHIVE}" --repo "${WORKSPACE_ROOT}" \
    --contents "${CONTENTS_DIR}" --output "${RESOURCES_DIR}/THIRD_PARTY_NOTICES.txt" "${NOTICE_VALUES[@]}"

# With MACSW_SIGN_IDENTITY, seal the bundle with it (nested code in Contents/MacOS first; the
# pinned 7zz has an unsigned x86_64 slice). Mach-O under Resources is sealed as data. Unset: the
# bundle keeps the linker's ad hoc signature on its executable, as before.
if [ -n "${MACSW_SIGN_IDENTITY:-}" ]; then
    for NESTED_CODE in "${APP_DIR}/Contents/MacOS/"*; do
        if [ ! -L "${NESTED_CODE}" ] && [ "${NESTED_CODE}" != "${APP_DIR}/Contents/MacOS/${APP_NAME}" ]; then
            macsw_codesign "${NESTED_CODE}"
        fi
    done
    unset NESTED_CODE
    macsw_codesign "${APP_DIR}"
    codesign --verify --strict --verbose=2 "${APP_DIR}"
    test "$(macsw_signature_kind "${APP_DIR}")" = certificate
fi

mkdir -p "$(dirname "${FINAL_APP_DIR}")"
if [ -d "${FINAL_APP_DIR}" ]; then
    rm -rf -- "${FINAL_APP_DIR}"
fi
mv "${APP_DIR}" "${FINAL_APP_DIR}"
echo "==> Packaged: ${FINAL_APP_DIR}"
