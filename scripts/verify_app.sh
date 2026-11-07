#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"
source "${WORKSPACE_ROOT}/scripts/lib/strip_pe.sh"
APP_DIR="${1:-${MACSW_APP_OUTPUT:-${WORKSPACE_ROOT}/build/app/MacSW.app}}"
CONTENTS_DIR="${APP_DIR}/Contents"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
RUNTIME_DIR="${CONTENTS_DIR}/Frameworks/wine"
RUNTIME_RESOURCE_DIR="${CONTENTS_DIR}/Resources/Wine"
MONO_DLL="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"
MONO_MSCORLIB="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/mono/4.5/mscorlib.dll"
MONO_REGASM_X86="${RUNTIME_DIR}/lib/wine/i386-windows/regasm.exe"
MONO_REGASM_X64="${RUNTIME_DIR}/lib/wine/x86_64-windows/regasm.exe"
MONO_CCW_DLL="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86_64.dll"
MONO_BTLS_DLL="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/x86_64/libmono-btls-shared.dll"
WINEMAC_DRIVER="${RUNTIME_DIR}/lib/wine/x86_64-unix/winemac.so"
WIN32U_DRIVER="${RUNTIME_DIR}/lib/wine/x86_64-unix/win32u.so"
COMBASE_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/combase.dll"
COMCTL32_V6_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/comctl32_v6.dll"
MSXML3_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/msxml3.dll"
MSXML3_I386_MODULE="${RUNTIME_DIR}/lib/wine/i386-windows/msxml3.dll"
WS2_32_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/ws2_32.dll"
WS2_32_I386_MODULE="${RUNTIME_DIR}/lib/wine/i386-windows/ws2_32.dll"
WINEMAC_DRV_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/winemac.drv"
WINEMAC_DRV_I386_MODULE="${RUNTIME_DIR}/lib/wine/i386-windows/winemac.drv"
COMDLG32_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/comdlg32.dll"
COMDLG32_I386_MODULE="${RUNTIME_DIR}/lib/wine/i386-windows/comdlg32.dll"
WBEMPROX_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/wbemprox.dll"
WBEMPROX_I386_MODULE="${RUNTIME_DIR}/lib/wine/i386-windows/wbemprox.dll"
WINDOWSCODECS_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/windowscodecs.dll"
KERNELBASE_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/kernelbase.dll"
OPENGL32_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/opengl32.dll"
OPENGL32_UNIX="${RUNTIME_DIR}/lib/wine/x86_64-unix/opengl32.so"
GLU32_MODULE="${RUNTIME_DIR}/lib/wine/x86_64-windows/glu32.dll"
NTDLL_UNIX="${RUNTIME_DIR}/lib/wine/x86_64-unix/ntdll.so"
BRANDED_WINE_LOADER="${RUNTIME_DIR}/lib/wine/x86_64-unix/MacSW"
WINE_LOADER_COMPAT="${RUNTIME_DIR}/lib/wine/x86_64-unix/wine"
STDOLE_DLL="${CONTENTS_DIR}/Resources/managed/stdole.dll"
BUILD_MANIFEST="${CONTENTS_DIR}/Resources/BuildManifest.plist"
# The packaged PE modules are the dist/ modules after package_app.sh's strip (scripts/lib/strip_pe.sh).
PE_STRIPPED_DECLARED="$(/usr/libexec/PlistBuddy -c 'Print :PEModulesStripped' "${BUILD_MANIFEST}" 2>/dev/null || echo missing)"
CMP_TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/macsw-verify.XXXXXX")"
trap 'rm -rf -- "${CMP_TMP}"' EXIT
cmp_pe_module() { # <module name in dist/winemac-*> <packaged file>: byte-identical, after the same strip when the build stripped
    local reference="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/$1"
    if [ "${PE_STRIPPED_DECLARED}" = true ]; then
        cp "${reference}" "${CMP_TMP}/reference"
        macsw_strip_pe "${CMP_TMP}/reference" > /dev/null
        cmp "${CMP_TMP}/reference" "$2"
    else
        cmp "${reference}" "$2"
    fi
}
SWCLI_DIR="${CONTENTS_DIR}/Resources/SWCLI"
SWCLI_LAUNCHER="${CONTENTS_DIR}/MacOS/sw-cli"
SWCLI_LAUNCHER_RESOURCE="${CONTENTS_DIR}/Resources/sw-cli"
SWCLI_PATH_HELPER="${SWCLI_DIR}/bin/swcli_path.exe"
SWCLI_NATIVE_PATH_HELPER="${SWCLI_DIR}/bin/swcli-path"
SWCLI_RUNTIME="${SWCLI_DIR}/runtime/Python311"
SWCLI_NATIVE_RUNTIME="${SWCLI_DIR}/runtime/PythonNative"
WINE_LICENSES_DIR="${CONTENTS_DIR}/Resources/licenses/Wine"
MACSW_LICENSES_DIR="${CONTENTS_DIR}/Resources/licenses/MacSW"

test -d "${APP_DIR}"
plutil -lint "${INFO_PLIST}" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")" = "${APP_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")" = "${APP_BUILD}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWWineVersion' "${INFO_PLIST}")" = "${WINE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoVersion' "${INFO_PLIST}")" = "${WINE_MONO_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoMscorlibSHA256' "${INFO_PLIST}")" = "${MONO_MSCORLIB_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoRegAsmX86SHA256' "${INFO_PLIST}")" = "${MONO_REGASM_X86_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoRegAsmX64SHA256' "${INFO_PLIST}")" = "${MONO_REGASM_X64_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWStdoleVersion' "${INFO_PLIST}")" = "${STDOLE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWStdoleSHA256' "${INFO_PLIST}")" = "${STDOLE_DLL_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")" = "${MACOS_DEPLOYMENT_TARGET}"

test -x "${CONTENTS_DIR}/MacOS/MacSW"
test -x "${CONTENTS_DIR}/MacOS/7zz"
test -L "${CONTENTS_DIR}/MacOS/7z"
# The SpatialIOP MSI edit (docs/spatialiop-fix.md).
file "${CONTENTS_DIR}/Resources/helpers/msi_spatialiop.exe" | grep -q 'PE32+ executable.*x86-64'
test -f "${CONTENTS_DIR}/Resources/AppIcon.icns"
test -f "${BUILD_MANIFEST}"
# The release label in file names and git tags (config/versions.env).
test "$(/usr/libexec/PlistBuddy -c 'Print :AppRelease' "${BUILD_MANIFEST}")" = "${APP_RELEASE}"
# MacSW's own bottle tooling (native Python + wine_runtime.py) ships in every build.
test -x "${SWCLI_NATIVE_RUNTIME}/bin/python3"
test -s "${SWCLI_DIR}/licenses/Python-Native-LICENSE.txt"
cmp "${WORKSPACE_ROOT}/scripts/swcli/wine_runtime.py" "${SWCLI_DIR}/bin/wine_runtime.py"
file "${SWCLI_NATIVE_RUNTIME}/bin/python3" | grep -q 'Mach-O 64-bit executable arm64'
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLINativePythonVersion' "${BUILD_MANIFEST}")" = "${SWCLI_NATIVE_PYTHON_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLINativePythonRelease' "${BUILD_MANIFEST}")" = "${SWCLI_NATIVE_PYTHON_RELEASE}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLINativePythonArchiveSHA256' "${BUILD_MANIFEST}")" = "${SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256}"
# SWCLI proper is optional; runtime-manifest.json is the App's runtime marker.
SWCLI_INCLUDED="$(/usr/libexec/PlistBuddy -c 'Print :SWCLIIncluded' "${BUILD_MANIFEST}")"
if [ "${SWCLI_INCLUDED}" = true ]; then
    test -x "${SWCLI_LAUNCHER}"
    test -L "${SWCLI_LAUNCHER}"
    test "$(readlink "${SWCLI_LAUNCHER}")" = "../Resources/sw-cli"
    test -f "${SWCLI_LAUNCHER_RESOURCE}"
    test ! -L "${SWCLI_LAUNCHER_RESOURCE}"
    cmp "${WORKSPACE_ROOT}/scripts/swcli/sw-cli" "${SWCLI_LAUNCHER_RESOURCE}"
    test -f "${SWCLI_RUNTIME}/python.exe"
    test -f "${SWCLI_RUNTIME}/pythonw.exe"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/pywin32_system32/pythoncom311.dll"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/win32com/client/__init__.py"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/swcli/__main__.py"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/swcli/schemas/v1/request.schema.json"
    test -f "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/__main__.py"
    test -f "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/schemas/v1/request.schema.json"
    test -s "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/skills/swcli/SKILL.md"
    test -s "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/skills/swcli/references/usage.md"
    cmp "${WORKSPACE_ROOT}/Dependencies/SWCLI/src/swcli/skills/swcli/SKILL.md" \
        "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/skills/swcli/SKILL.md"
    cmp "${WORKSPACE_ROOT}/Dependencies/SWCLI/src/swcli/skills/swcli/references/usage.md" \
        "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli/skills/swcli/references/usage.md"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/jsonschema/__init__.py"
    test -f "${SWCLI_RUNTIME}/Lib/site-packages/rpds/rpds.cp311-win_amd64.pyd"
    test "$(shasum -a 256 "${SWCLI_DIR}/wheels.tsv" | awk '{print $1}')" = "$(shasum -a 256 "${SWCLI_WHEEL_MANIFEST}" | awk '{print $1}')"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIWheelManifestSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${SWCLI_WHEEL_MANIFEST}" | awk '{print $1}')"
    PYTHONDONTWRITEBYTECODE=1 "${SWCLI_NATIVE_RUNTIME}/bin/python3" -c \
        'import attrs, jsonschema, referencing, rpds, typing_extensions; from swcli.operation_schemas import operation_schemas; [jsonschema.Draft202012Validator.check_schema(schema) for schema in operation_schemas().values()]'
    grep -Fxq 'Lib\site-packages' "${SWCLI_RUNTIME}/python311._pth"
    grep -Fxq 'import site' "${SWCLI_RUNTIME}/python311._pth"
    test -f "${SWCLI_DIR}/licenses/SWCLI-LICENSE"
    test -s "${SWCLI_DIR}/licenses/Python-LICENSE.txt"
    test -s "${SWCLI_DIR}/licenses/pywin32-LICENSE.txt"
    test -z "$(find "${SWCLI_RUNTIME}" -type d -name __pycache__ -print -quit)"
    test -z "$(find "${SWCLI_RUNTIME}" -type f -name '*.pyc' -print -quit)"
    test -f "${SWCLI_PATH_HELPER}"
    test -x "${SWCLI_NATIVE_PATH_HELPER}"
    cmp "${WORKSPACE_ROOT}/scripts/swcli/swcli_path.py" "${SWCLI_DIR}/bin/swcli_path.py"
    cmp "${WORKSPACE_ROOT}/scripts/swcli/swcli_runtime.py" "${SWCLI_DIR}/bin/swcli_runtime.py"
    "${SWCLI_NATIVE_RUNTIME}/bin/python3" -I "${SWCLI_DIR}/bin/swcli_runtime.py" \
        --contents "${CONTENTS_DIR}" --verify
    "${SWCLI_NATIVE_RUNTIME}/bin/python3" -I -c \
        'import json, sys; m=json.load(open(sys.argv[1])); assert m["version"] == sys.argv[2] and m["source_commit"] == sys.argv[3]' \
        "${SWCLI_DIR}/runtime-manifest.json" "${SWCLI_VERSION}" "${SWCLI_SOURCE_COMMIT}"
    (
        mapping_test="$(mktemp -d)"
        trap 'rm -rf -- "${mapping_test}"' EXIT
        mkdir -p "${mapping_test}/drive_c" "${mapping_test}/dosdevices"
        ln -s ../drive_c "${mapping_test}/dosdevices/c:"
        # Deliberately omit Z:; a configured C: must still translate correctly.
        test "$(WINEPREFIX="${mapping_test}" "${SWCLI_NATIVE_PATH_HELPER}" \
            "${mapping_test}/drive_c/models/example.SLDPRT")" = 'C:\models\example.SLDPRT'
    )
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIVersion' "${BUILD_MANIFEST}")" = "${SWCLI_VERSION}"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLISourceCommit' "${BUILD_MANIFEST}")" = "${SWCLI_SOURCE_COMMIT}"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPythonVersion' "${BUILD_MANIFEST}")" = "${SWCLI_PYTHON_VERSION}"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPythonArchiveSHA256' "${BUILD_MANIFEST}")" = "${SWCLI_PYTHON_ARCHIVE_SHA256}"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPyWin32Version' "${BUILD_MANIFEST}")" = "${SWCLI_PYWIN32_VERSION}"
    test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPyWin32WheelSHA256' "${BUILD_MANIFEST}")" = "${SWCLI_PYWIN32_WHEEL_SHA256}"
    file "${SWCLI_PATH_HELPER}" | grep -q 'PE32+ executable.*x86-64'
    file "${SWCLI_RUNTIME}/python.exe" | grep -q 'PE32+ executable.*x86-64'
    file "${SWCLI_RUNTIME}/pythonw.exe" | grep -Fq 'PE32+ executable (GUI) x86-64'
    "${SWCLI_LAUNCHER}" --help >/dev/null
    test "$("${SWCLI_LAUNCHER}" version --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["client_version"])')" = "${SWCLI_VERSION}"
else
    test "${SWCLI_INCLUDED}" = false
    test ! -L "${SWCLI_LAUNCHER}"
    test ! -e "${SWCLI_LAUNCHER}"
    test ! -e "${SWCLI_LAUNCHER_RESOURCE}"
    test ! -e "${SWCLI_RUNTIME}"
    test ! -e "${SWCLI_DIR}/runtime-manifest.json"
    test ! -e "${SWCLI_NATIVE_RUNTIME}/lib/python3.11/site-packages/swcli"
fi
test -s "${MACSW_LICENSES_DIR}/Apache-2.0.txt"
test -s "${MACSW_LICENSES_DIR}/NOTICE"
grep -Fq "Apache License" "${MACSW_LICENSES_DIR}/Apache-2.0.txt"
grep -Fq "Copyright 2026 YJBeetle" "${MACSW_LICENSES_DIR}/NOTICE"
test -s "${WINE_LICENSES_DIR}/LGPL-2.1.txt"
test -s "${WINE_LICENSES_DIR}/SOURCE.txt"
grep -Fq "GNU LESSER GENERAL PUBLIC LICENSE" "${WINE_LICENSES_DIR}/LGPL-2.1.txt"
grep -Fq "${WINE_SOURCE_URL}" "${WINE_LICENSES_DIR}/SOURCE.txt"
grep -Fq "${WINE_SOURCE_SHA256}" "${WINE_LICENSES_DIR}/SOURCE.txt"
# The source archives of the LGPL libraries in Resources/Wine/lib and of 7-Zip.
for LGPL_KEY in ${MACSW_LGPL_SOURCES}; do
    eval "LGPL_URL=\${${LGPL_KEY}_SOURCE_URL}; LGPL_SHA256=\${${LGPL_KEY}_SOURCE_SHA256}"
    grep -Fq "${LGPL_URL}" "${WINE_LICENSES_DIR}/SOURCE.txt"
    grep -Fq "${LGPL_SHA256}" "${WINE_LICENSES_DIR}/SOURCE.txt"
done
unset LGPL_KEY LGPL_URL LGPL_SHA256
# The source offer names this build's commit (as BuildManifest does), never upstream's repository,
# and the DMG script finds it and THIRD_PARTY_NOTICES.txt in Resources.
cmp "${WINE_LICENSES_DIR}/SOURCE.txt" "${CONTENTS_DIR}/Resources/SOURCE.txt"
grep -Fq "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "${BUILD_MANIFEST}")" "${WINE_LICENSES_DIR}/SOURCE.txt"
if grep -Fq "github.com/YJBeetle/MacSW" "${WINE_LICENSES_DIR}/SOURCE.txt"; then
    echo "SOURCE.txt points at the upstream repository, not at this build's source" >&2
    exit 1
fi
THIRD_PARTY_NOTICES="${CONTENTS_DIR}/Resources/THIRD_PARTY_NOTICES.txt"
test -s "${THIRD_PARTY_NOTICES}"
for NOTICE_PART in "Wine Gecko" "Wine Mono" "7-Zip" "stdole" "ICU" "MoltenVK" "libinotify-kqueue" \
    "GNU LESSER GENERAL PUBLIC LICENSE" "Mozilla Public License" "registered trademark of Dassault"; do
    grep -Fq "${NOTICE_PART}" "${THIRD_PARTY_NOTICES}"
done
unset NOTICE_PART
test "$(shasum -a 256 "${STDOLE_DLL}" | awk '{print $1}')" = "${STDOLE_DLL_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacBrandingPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0001-winemac-macsw-branding.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineInputPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WinePrintWindowPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0011-win32u-printwindow-surface.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineFontLinkPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0012-win32u-preserve-custom-font-links.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineScreenReadbackPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0013-winemac-screen-readback.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMSXMLSchemaPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0014-msxml-schema-cache-namespace.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WinePEMappingPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0015-ntdll-probe-executable-file-mappings.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMemResetPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0016-ntdll-macos-release-decommitted-memory.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMsyncPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0017-ntdll-server-msync.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineServerWindowWalksPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0034-server-unlinked-window-walks.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMPEnginePatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0036-winemac-multithreaded-gl-engine.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineCrossProcessSurfacesPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0018-win32u-cross-process-window-surfaces.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineHeaderLayoutPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0019-comctl32-header-layout-null.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineComputerNamePatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0020-ws2_32-resolve-own-computer-name.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWS2_32ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WS2_32_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWS2_32I386ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WS2_32_I386_MODULE}" | awk '{print $1}')"
cmp_pe_module ws2_32.dll ${WS2_32_MODULE}
cmp_pe_module ws2_32-i386.dll ${WS2_32_I386_MODULE}
file "${WS2_32_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${WS2_32_I386_MODULE}" | grep -q 'PE32 executable.*Intel 80386'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWICCachePatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0032-windowscodecs-cache-component-registry.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWindowsCodecsModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WINDOWSCODECS_MODULE}" | awk '{print $1}')"
cmp_pe_module windowscodecs.dll ${WINDOWSCODECS_MODULE}
file "${WINDOWSCODECS_MODULE}" | grep -q 'PE32+ executable.*x86-64'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineLocalModuleReadsPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0033-kernelbase-local-module-reads.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineKernelBaseModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${KERNELBASE_MODULE}" | awk '{print $1}')"
cmp_pe_module kernelbase.dll ${KERNELBASE_MODULE}
file "${KERNELBASE_MODULE}" | grep -q 'PE32+ executable.*x86-64'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMSXMLSendPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0021-msxml3-xmlhttp-send-domdocument.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMSXML3I386ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${MSXML3_I386_MODULE}" | awk '{print $1}')"
cmp_pe_module msxml3-i386.dll ${MSXML3_I386_MODULE}
file "${MSXML3_I386_MODULE}" | grep -q 'PE32 executable.*Intel 80386'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMSXMLEmptyElementPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0022-msxml3-expand-empty-elements.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacAppBundleHostPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0025-winemac-app-bundle-host.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacAppNapDefaultsPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0035-winemac-app-nap-defaults.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWbemproxIPEnabledPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0028-wbemprox-ipenabled-needs-mac-address.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWbemproxModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WBEMPROX_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineWbemproxI386ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WBEMPROX_I386_MODULE}" | awk '{print $1}')"
cmp_pe_module wbemprox.dll ${WBEMPROX_MODULE}
cmp_pe_module wbemprox-i386.dll ${WBEMPROX_I386_MODULE}
file "${WBEMPROX_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${WBEMPROX_I386_MODULE}" | grep -q 'PE32 executable.*Intel 80386'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineOpenGLBatchPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0030-opengl32-batch-immediate-mode-calls.patch" | awk '{print $1}')"
cmp_pe_module opengl32.dll ${OPENGL32_MODULE}
file "${OPENGL32_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${OPENGL32_UNIX}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
grep -aq 'invalid batch op' "${OPENGL32_UNIX}"
codesign --verify --verbose=2 "${OPENGL32_UNIX}"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineGluNurbsPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0037-glu32-nurbs.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineGLU32ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${GLU32_MODULE}" | awk '{print $1}')"
cmp_pe_module glu32.dll ${GLU32_MODULE}
file "${GLU32_MODULE}" | grep -q 'PE32+ executable.*x86-64'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMSXML3ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${MSXML3_MODULE}" | awk '{print $1}')"
cmp_pe_module msxml3.dll ${MSXML3_MODULE}
file "${MSXML3_MODULE}" | grep -q 'PE32+ executable.*x86-64'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineNativeFileDialogDriverPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0023-winemac-native-file-dialogs.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineNativeFileDialogPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0024-comdlg32-native-file-dialogs.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacDrvModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WINEMAC_DRV_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacDrvI386ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WINEMAC_DRV_I386_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineComdlg32ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${COMDLG32_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineComdlg32I386ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${COMDLG32_I386_MODULE}" | awk '{print $1}')"
cmp_pe_module winemac.drv ${WINEMAC_DRV_MODULE}
cmp_pe_module winemac-i386.drv ${WINEMAC_DRV_I386_MODULE}
cmp_pe_module comdlg32.dll ${COMDLG32_MODULE}
cmp_pe_module comdlg32-i386.dll ${COMDLG32_I386_MODULE}
file "${WINEMAC_DRV_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${WINEMAC_DRV_I386_MODULE}" | grep -q 'PE32 executable.*Intel 80386'
file "${COMDLG32_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${COMDLG32_I386_MODULE}" | grep -q 'PE32 executable.*Intel 80386'
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacOpenGLPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineChildTopmostPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0005-win32u-ignore-child-topmost.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacSpacePatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0006-winemac-preserve-solidworks-view-space.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineCOMActivationPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0007-combase-wait-solidworks-registration.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacBitmapPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0008-winemac-bitmap-framebuffer.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacSoftwareRendererPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0009-winemac-software-renderer-fallback.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WINEMAC_DRIVER}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineInputModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WIN32U_DRIVER}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineCOMBaseModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${COMBASE_MODULE}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineTreeViewPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0010-comctl32-treeview-image-spacing.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineComctl32V6ModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${COMCTL32_V6_MODULE}" | awk '{print $1}')"
cmp_pe_module comctl32_v6.dll ${COMCTL32_V6_MODULE}
file "${COMCTL32_V6_MODULE}" | grep -q 'PE32+ executable.*x86-64'
cmp_pe_module combase.dll ${COMBASE_MODULE}
test "$(/usr/libexec/PlistBuddy -c 'Print :WineNtdllModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${NTDLL_UNIX}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineLoaderSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${BRANDED_WINE_LOADER}" | awk '{print $1}')"
# Every module hash the manifest declares must match the packaged file, and every module this tree
# packages must be declared (security audit 2026-10-24, finding 10). A declared key without a
# file below fails, so a new module cannot be added to the manifest and skipped here.
MANIFEST_MODULES="
WineMacModuleSHA256|${WINEMAC_DRIVER}
WineInputModuleSHA256|${WIN32U_DRIVER}
WineNtdllModuleSHA256|${NTDLL_UNIX}
WineLoaderSHA256|${BRANDED_WINE_LOADER}
WineServerSHA256|${RUNTIME_DIR}/bin/wineserver
WineCOMBaseModuleSHA256|${COMBASE_MODULE}
WineComctl32V6ModuleSHA256|${COMCTL32_V6_MODULE}
WineMSXML3ModuleSHA256|${MSXML3_MODULE}
WineMSXML3I386ModuleSHA256|${MSXML3_I386_MODULE}
WineWS2_32ModuleSHA256|${WS2_32_MODULE}
WineWS2_32I386ModuleSHA256|${WS2_32_I386_MODULE}
WineMacDrvModuleSHA256|${WINEMAC_DRV_MODULE}
WineMacDrvI386ModuleSHA256|${WINEMAC_DRV_I386_MODULE}
WineComdlg32ModuleSHA256|${COMDLG32_MODULE}
WineComdlg32I386ModuleSHA256|${COMDLG32_I386_MODULE}
WineWbemproxModuleSHA256|${WBEMPROX_MODULE}
WineWbemproxI386ModuleSHA256|${WBEMPROX_I386_MODULE}
WineWindowsCodecsModuleSHA256|${WINDOWSCODECS_MODULE}
WineKernelBaseModuleSHA256|${KERNELBASE_MODULE}
WineOpenGL32ModuleSHA256|${OPENGL32_MODULE}
WineOpenGL32UnixModuleSHA256|${OPENGL32_UNIX}
WineGLU32ModuleSHA256|${GLU32_MODULE}
MonoCCWModuleSHA256|${MONO_CCW_DLL}
MonoBTLSModuleSHA256|${MONO_BTLS_DLL}
"
CHECKED_MODULES=0
while IFS='|' read -r MODULE_KEY MODULE_FILE; do
    [ -n "${MODULE_KEY}" ] || continue
    MODULE_HASH="$(/usr/libexec/PlistBuddy -c "Print :${MODULE_KEY}" "${BUILD_MANIFEST}" 2>/dev/null)" || {
        echo "verify_app: BuildManifest does not declare ${MODULE_KEY}" >&2; exit 1; }
    test -f "${MODULE_FILE}" || { echo "verify_app: ${MODULE_KEY}: missing ${MODULE_FILE}" >&2; exit 1; }
    test "${MODULE_HASH}" = "$(shasum -a 256 "${MODULE_FILE}" | awk '{print $1}')" || {
        echo "verify_app: ${MODULE_KEY} does not match ${MODULE_FILE}" >&2; exit 1; }
    CHECKED_MODULES=$((CHECKED_MODULES + 1))
done <<< "${MANIFEST_MODULES}"
# The 16 PE modules MacSW rebuilds ship without DWARF and COFF symbols (package_app.sh, scripts/lib/strip_pe.sh),
# with Wine's "builtin" mark intact, unless the build was made with MACSW_STRIP_PE=0 (the manifest says which).
case "$(/usr/libexec/PlistBuddy -c 'Print :PEModulesStripped' "${BUILD_MANIFEST}" 2>/dev/null || echo missing)" in
    true)
        for STRIPPED_MODULE in "${COMBASE_MODULE}" "${COMCTL32_V6_MODULE}" "${MSXML3_MODULE}" "${MSXML3_I386_MODULE}" \
            "${WS2_32_MODULE}" "${WS2_32_I386_MODULE}" "${WINEMAC_DRV_MODULE}" "${WINEMAC_DRV_I386_MODULE}" \
            "${COMDLG32_MODULE}" "${COMDLG32_I386_MODULE}" "${WBEMPROX_MODULE}" "${WBEMPROX_I386_MODULE}" \
            "${WINDOWSCODECS_MODULE}" "${KERNELBASE_MODULE}" "${OPENGL32_MODULE}" "${GLU32_MODULE}"; do
            macsw_pe_stripped "${STRIPPED_MODULE}" || {
                echo "verify_app: ${STRIPPED_MODULE} is not stripped (or lost its Wine builtin mark) but BuildManifest says PEModulesStripped" >&2; exit 1; }
        done
        unset STRIPPED_MODULE ;;
    false) echo "verify_app: note: PE modules were built with MACSW_STRIP_PE=0 (debug info kept, +60 MB)" ;;
    *) echo "verify_app: BuildManifest does not declare PEModulesStripped" >&2; exit 1 ;;
esac
for MODULE_KEY in $(plutil -p "${BUILD_MANIFEST}" | sed -nE 's/^ *"([A-Za-z0-9_]*(ModuleSHA256|LoaderSHA256|ServerSHA256))" => .*/\1/p'); do
    grep -q "^${MODULE_KEY}|" <<< "${MANIFEST_MODULES}" || {
        echo "verify_app: BuildManifest declares ${MODULE_KEY}, which verify_app.sh does not check" >&2; exit 1; }
done
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchRelease' "${BUILD_MANIFEST}")" = "${MONO_PATCH_RELEASE}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchSourceCommit' "${BUILD_MANIFEST}")" = "${MONO_PATCH_SOURCE_COMMIT}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchSHA256' "${BUILD_MANIFEST}")" = "${MONO_PATCH_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoMscorlibSHA256' "${BUILD_MANIFEST}")" = "${MONO_MSCORLIB_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoRegAsmX86SHA256' "${BUILD_MANIFEST}")" = "${MONO_REGASM_X86_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoRegAsmX64SHA256' "${BUILD_MANIFEST}")" = "${MONO_REGASM_X64_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoSourceCommit' "${BUILD_MANIFEST}")" = "${MONO_SOURCE_COMMIT}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoSourceSHA256' "${BUILD_MANIFEST}")" = "${MONO_SOURCE_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoCCWModuleSHA256' "${BUILD_MANIFEST}")" = "${MONO_X64_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoCCWModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${MONO_CCW_DLL}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoBTLSModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${MONO_BTLS_DLL}" | awk '{print $1}')"
cmp "${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/libmono-2.0-x86_64.dll" "${MONO_CCW_DLL}"
grep -Fq "${MONO_SOURCE_SHA256}" "${CONTENTS_DIR}/Resources/licenses/Mono/SOURCE.txt"
grep -Fq "${MONO_PATCH_SOURCE_COMMIT}" "${CONTENTS_DIR}/Resources/licenses/Mono/SOURCE.txt"
for license_file in LICENSE COPYING.LIB PATENTS.TXT; do
    test -s "${CONTENTS_DIR}/Resources/licenses/Mono/${license_file}"
done
file "${MONO_CCW_DLL}" | grep -q 'PE32+ executable.*x86-64'
test "$(/usr/libexec/PlistBuddy -c 'Print :StdoleVersion' "${BUILD_MANIFEST}")" = "${STDOLE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :StdoleDLLSHA256' "${BUILD_MANIFEST}")" = "${STDOLE_DLL_SHA256}"
test -L "${RUNTIME_DIR}"
test "$(readlink "${RUNTIME_DIR}")" = "../Resources/Wine"
test -d "${RUNTIME_RESOURCE_DIR}"
test ! -L "${RUNTIME_RESOURCE_DIR}"
test -x "${RUNTIME_DIR}/bin/wineloader"
test -x "${RUNTIME_DIR}/bin/wineserver"
# Patch 0017 bumps the server protocol, so the packaged server must be the one built with ntdll.so.
grep -aq 'msync: bootstrapped mach port' "${RUNTIME_DIR}/bin/wineserver"
grep -aq 'Server is running with WINEMSYNC' "${NTDLL_UNIX}"
test -x "${BRANDED_WINE_LOADER}"
test -L "${WINE_LOADER_COMPAT}"
test "$(readlink "${WINE_LOADER_COMPAT}")" = "MacSW"
test "$(shasum -a 256 "${MONO_DLL}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}"
test "$(shasum -a 256 "${MONO_MSCORLIB}" | awk '{print $1}')" = "${MONO_MSCORLIB_SHA256}"
test "$(shasum -a 256 "${MONO_REGASM_X86}" | awk '{print $1}')" = "${MONO_REGASM_X86_SHA256}"
test "$(shasum -a 256 "${MONO_REGASM_X64}" | awk '{print $1}')" = "${MONO_REGASM_X64_SHA256}"
file "${MONO_REGASM_X86}" | grep -q 'PE32 executable.*Intel 80386 Mono/.Net assembly'
file "${MONO_REGASM_X64}" | grep -q 'PE32+ executable.*x86-64 Mono/.Net assembly'
file "${COMBASE_MODULE}" | grep -q 'PE32+ executable.*x86-64'
file "${WINEMAC_DRIVER}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
file "${WIN32U_DRIVER}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
file "${NTDLL_UNIX}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
file "${BRANDED_WINE_LOADER}" | grep -q 'Mach-O 64-bit executable x86_64'
otool -l "${BRANDED_WINE_LOADER}" | grep -A2 '__info_plist' | grep -q '__TEXT'
strings "${BRANDED_WINE_LOADER}" | grep -q '<string>com.macsw.winehost</string>'
test "$(strings "${BRANDED_WINE_LOADER}" | grep -c '<string>MacSW</string>')" -ge 3
otool -l "${WIN32U_DRIVER}" | grep -A2 LC_RPATH | grep -q '@loader_path/../../'
codesign --verify --verbose=2 "${WINEMAC_DRIVER}"
codesign --verify --verbose=2 "${WIN32U_DRIVER}"
codesign --verify --verbose=2 "${NTDLL_UNIX}"
codesign --verify --verbose=2 "${BRANDED_WINE_LOADER}"
# The bundle signature is ad hoc or absent (linker-signed executable) by default; an app packaged
# with MACSW_SIGN_IDENTITY must carry that certificate (scripts/lib/codesign.sh).
if [ -n "${MACSW_SIGN_IDENTITY:-}" ]; then
    codesign --verify --strict --verbose=2 "${APP_DIR}"
    test "$(macsw_signature_kind "${APP_DIR}")" = certificate
fi

# SOLIDWORKS.app inside MacSW.app (package_solidworks_app.sh --embed), unpacked as MacSW does.
SOLIDWORKS_APP_SUMMARY="no SOLIDWORKS.app"
if [ "${MACSW_SKIP_SOLIDWORKS_APP:-0}" != 1 ]; then
    bash "${WORKSPACE_ROOT}/scripts/verify_solidworks_app.sh" --embedded "${APP_DIR}"
    SOLIDWORKS_APP_SUMMARY="SOLIDWORKS.app inside"
fi

ACTUAL_WINE_VERSION="$("${BRANDED_WINE_LOADER}" --version)"
test "${ACTUAL_WINE_VERSION}" = "wine-${WINE_VERSION}" || {
    echo "Packaged Wine version mismatch: ${ACTUAL_WINE_VERSION}" >&2
    exit 1
}

SWCLI_SUMMARY="SWCLI excluded"
if [ "${SWCLI_INCLUDED}" = true ]; then
    SWCLI_SUMMARY="SWCLI ${SWCLI_VERSION}"
fi
# Source traceability; apps packaged before these keys existed still verify.
GIT_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "${BUILD_MANIFEST}" 2>/dev/null || echo unknown)"
GIT_BRANCH="$(/usr/libexec/PlistBuddy -c 'Print :GitBranch' "${BUILD_MANIFEST}" 2>/dev/null || echo unknown)"
echo "==> Source: ${GIT_BRANCH} @ ${GIT_COMMIT}"
echo "==> Module hashes: ${CHECKED_MODULES} BuildManifest keys match the packaged files"
echo "==> Verified ${APP_DIR}: MacSW ${APP_RELEASE} (${APP_BUILD}), Wine ${WINE_VERSION}, Mono ${WINE_MONO_VERSION}, ${SWCLI_SUMMARY}, ${SOLIDWORKS_APP_SUMMARY}"
