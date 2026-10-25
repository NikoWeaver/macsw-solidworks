#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_SOURCE_ASSET}"
# wineserver links libinotify (directory change notifications) like the stock
# Gcenx server; the library comes from the pinned runtime archive.
RUNTIME_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_RUNTIME_ASSET}"
INOTIFY_INCLUDE="${WORKSPACE_ROOT}/third_party/libinotify-kqueue"
BRANDING_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0001-winemac-macsw-branding.patch"
DRIVER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch"
INPUT_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch"
OPENGL_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch"
TOPMOST_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0005-win32u-ignore-child-topmost.patch"
SPACE_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0006-winemac-preserve-solidworks-view-space.patch"
COM_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0007-combase-wait-solidworks-registration.patch"
BITMAP_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0008-winemac-bitmap-framebuffer.patch"
SOFTWARE_RENDERER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0009-winemac-software-renderer-fallback.patch"
TREEVIEW_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0010-comctl32-treeview-image-spacing.patch"
PRINTWINDOW_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0011-win32u-printwindow-surface.patch"
FONTLINK_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0012-win32u-preserve-custom-font-links.patch"
SCREEN_READBACK_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0013-winemac-screen-readback.patch"
MSXML_SCHEMA_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0014-msxml-schema-cache-namespace.patch"
PE_MAPPING_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0015-ntdll-probe-executable-file-mappings.patch"
MEM_RESET_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0016-ntdll-macos-release-decommitted-memory.patch"
MSYNC_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0017-ntdll-server-msync.patch"
CROSS_PROCESS_SURFACES_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0018-win32u-cross-process-window-surfaces.patch"
HEADER_LAYOUT_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0019-comctl32-header-layout-null.patch"
COMPUTER_NAME_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0020-ws2_32-resolve-own-computer-name.patch"
MSXML_SEND_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0021-msxml3-xmlhttp-send-domdocument.patch"
MSXML_EMPTY_ELEMENT_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0022-msxml3-expand-empty-elements.patch"
NATIVE_FILE_DIALOG_DRIVER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0023-winemac-native-file-dialogs.patch"
NATIVE_FILE_DIALOG_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0024-comdlg32-native-file-dialogs.patch"
APP_BUNDLE_HOST_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0025-winemac-app-bundle-host.patch"
# winemac: NSAppSleepDisabled before NSApp exists, so macOS 27 does not clamp a background Wine app to utility QoS.
APP_NAP_DEFAULTS_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0035-winemac-app-nap-defaults.patch"
WBEMPROX_IPENABLED_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0028-wbemprox-ipenabled-needs-mac-address.patch"
# Start-up patches (docs/startup-performance.md); both act only with their MACSW_* variable set.
WIC_CACHE_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0032-windowscodecs-cache-component-registry.patch"
LOCAL_MODULE_READS_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0033-kernelbase-local-module-reads.patch"
OPENGL32_BATCH_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0030-opengl32-batch-immediate-mode-calls.patch"
# wineserver: never walk a parent's unlinked window list as its Z-order list (FindWindowEx racing DestroyWindow froze the bottle).
SERVER_WINDOW_WALKS_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0034-server-unlinked-window-walks.patch"
# winemac: Apple's multithreaded GL engine on contexts that present (GL driver work on a worker thread; MACSW_GL_MPENGINE=0 turns it off).
MPENGINE_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0036-winemac-multithreaded-gl-engine.patch"
# glu32: GLU 1.3 NURBS curves and surfaces (a spline or an ellipse in a sketch ended SOLIDWORKS with an assert).
GLU_NURBS_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0037-glu32-nurbs.patch"
OUTPUT_DIR="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}"
WINEMAC_OUTPUT="${OUTPUT_DIR}/winemac.so"
WIN32U_OUTPUT="${OUTPUT_DIR}/win32u.so"
NTDLL_OUTPUT="${OUTPUT_DIR}/ntdll.so"
WINE_LOADER_OUTPUT="${OUTPUT_DIR}/MacSW"
COMBASE_OUTPUT="${OUTPUT_DIR}/combase.dll"
COMCTL32_V6_OUTPUT="${OUTPUT_DIR}/comctl32_v6.dll"
MSXML3_OUTPUT="${OUTPUT_DIR}/msxml3.dll"
# Patch 0021 is also needed by 32-bit processes (the Activation Wizard is i386).
MSXML3_I386_OUTPUT="${OUTPUT_DIR}/msxml3-i386.dll"
# Patch 0020 is also needed by 32-bit processes, so ws2_32 ships for both architectures.
WS2_32_OUTPUT="${OUTPUT_DIR}/ws2_32.dll"
WS2_32_I386_OUTPUT="${OUTPUT_DIR}/ws2_32-i386.dll"
# Patches 0023/0024 (native file dialogs) add a PE export to winemac.drv and change
# comdlg32; both PE modules ship for both architectures next to winemac.so.
WINEMAC_DRV_OUTPUT="${OUTPUT_DIR}/winemac.drv"
WINEMAC_DRV_I386_OUTPUT="${OUTPUT_DIR}/winemac-i386.drv"
COMDLG32_OUTPUT="${OUTPUT_DIR}/comdlg32.dll"
COMDLG32_I386_OUTPUT="${OUTPUT_DIR}/comdlg32-i386.dll"
# Patch 0028 (WMI IPEnabled) ships for both architectures like ws2_32.
WBEMPROX_OUTPUT="${OUTPUT_DIR}/wbemprox.dll"
WBEMPROX_I386_OUTPUT="${OUTPUT_DIR}/wbemprox-i386.dll"
# Patches 0032/0033 are only enabled for SOLIDWORKS (64-bit), so they ship for x86_64 only.
WINDOWSCODECS_OUTPUT="${OUTPUT_DIR}/windowscodecs.dll"
KERNELBASE_OUTPUT="${OUTPUT_DIR}/kernelbase.dll"
# Patch 0030 (OpenGL immediate-mode batching) changes both halves of opengl32; they ship together.
# The 32-bit opengl32 does not batch and stays the stock one.
OPENGL32_OUTPUT="${OUTPUT_DIR}/opengl32.dll"
OPENGL32_UNIX_OUTPUT="${OUTPUT_DIR}/opengl32.so"
WINESERVER_OUTPUT="${OUTPUT_DIR}/wineserver"
# Patch 0037 (glu32 NURBS) is for SOLIDWORKS (64-bit), so glu32 ships for x86_64 only.
GLU32_OUTPUT="${OUTPUT_DIR}/glu32.dll"
STAMP_FILE="${OUTPUT_DIR}/build-key"

if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
    BISON_BIN=/opt/homebrew/opt/bison/bin/bison
elif [ -x /usr/local/opt/bison/bin/bison ]; then
    BISON_BIN=/usr/local/opt/bison/bin/bison
else
    echo "GNU Bison is required. Install it with: brew install bison" >&2
    exit 1
fi

if [ -f /opt/homebrew/opt/freetype/include/freetype2/ft2build.h ]; then
    FREETYPE_INCLUDE=/opt/homebrew/opt/freetype/include/freetype2
elif [ -f /usr/local/opt/freetype/include/freetype2/ft2build.h ]; then
    FREETYPE_INCLUDE=/usr/local/opt/freetype/include/freetype2
else
    echo "FreeType headers are required to build win32u.so. Install them with: brew install freetype" >&2
    exit 1
fi

mkdir -p "${WORKSPACE_ROOT}/dist" "${WORKSPACE_ROOT}/build"

if [ ! -f "${SOURCE_ARCHIVE}" ]; then
    echo "Missing Wine source archive. Run: make fetch-wine-source" >&2
    exit 1
fi

if [ ! -f "${RUNTIME_ARCHIVE}" ]; then
    echo "Missing Wine runtime archive (needed for libinotify). Run: make fetch-runtime" >&2
    exit 1
fi

ACTUAL_SOURCE_SHA256="$(shasum -a 256 "${SOURCE_ARCHIVE}" | awk '{print $1}')"
if [ "${ACTUAL_SOURCE_SHA256}" != "${WINE_SOURCE_SHA256}" ]; then
    echo "Wine source archive SHA-256 mismatch; refusing to build." >&2
    exit 1
fi
if [ "$(shasum -a 256 "${RUNTIME_ARCHIVE}" | awk '{print $1}')" != "${WINE_RUNTIME_SHA256}" ]; then
    echo "Wine runtime archive SHA-256 mismatch; refusing to build." >&2
    exit 1
fi

BRANDING_PATCH_SHA256="$(shasum -a 256 "${BRANDING_PATCH}" | awk '{print $1}')"
DRIVER_PATCH_SHA256="$(shasum -a 256 "${DRIVER_PATCH}" | awk '{print $1}')"
INPUT_PATCH_SHA256="$(shasum -a 256 "${INPUT_PATCH}" | awk '{print $1}')"
OPENGL_PATCH_SHA256="$(shasum -a 256 "${OPENGL_PATCH}" | awk '{print $1}')"
TOPMOST_PATCH_SHA256="$(shasum -a 256 "${TOPMOST_PATCH}" | awk '{print $1}')"
SPACE_PATCH_SHA256="$(shasum -a 256 "${SPACE_PATCH}" | awk '{print $1}')"
COM_PATCH_SHA256="$(shasum -a 256 "${COM_PATCH}" | awk '{print $1}')"
BITMAP_PATCH_SHA256="$(shasum -a 256 "${BITMAP_PATCH}" | awk '{print $1}')"
SOFTWARE_RENDERER_PATCH_SHA256="$(shasum -a 256 "${SOFTWARE_RENDERER_PATCH}" | awk '{print $1}')"
TREEVIEW_PATCH_SHA256="$(shasum -a 256 "${TREEVIEW_PATCH}" | awk '{print $1}')"
PRINTWINDOW_PATCH_SHA256="$(shasum -a 256 "${PRINTWINDOW_PATCH}" | awk '{print $1}')"
FONTLINK_PATCH_SHA256="$(shasum -a 256 "${FONTLINK_PATCH}" | awk '{print $1}')"
SCREEN_READBACK_PATCH_SHA256="$(shasum -a 256 "${SCREEN_READBACK_PATCH}" | awk '{print $1}')"
MSXML_SCHEMA_PATCH_SHA256="$(shasum -a 256 "${MSXML_SCHEMA_PATCH}" | awk '{print $1}')"
PE_MAPPING_PATCH_SHA256="$(shasum -a 256 "${PE_MAPPING_PATCH}" | awk '{print $1}')"
MEM_RESET_PATCH_SHA256="$(shasum -a 256 "${MEM_RESET_PATCH}" | awk '{print $1}')"
MSYNC_PATCH_SHA256="$(shasum -a 256 "${MSYNC_PATCH}" | awk '{print $1}')"
CROSS_PROCESS_SURFACES_PATCH_SHA256="$(shasum -a 256 "${CROSS_PROCESS_SURFACES_PATCH}" | awk '{print $1}')"
HEADER_LAYOUT_PATCH_SHA256="$(shasum -a 256 "${HEADER_LAYOUT_PATCH}" | awk '{print $1}')"
COMPUTER_NAME_PATCH_SHA256="$(shasum -a 256 "${COMPUTER_NAME_PATCH}" | awk '{print $1}')"
MSXML_SEND_PATCH_SHA256="$(shasum -a 256 "${MSXML_SEND_PATCH}" | awk '{print $1}')"
MSXML_EMPTY_ELEMENT_PATCH_SHA256="$(shasum -a 256 "${MSXML_EMPTY_ELEMENT_PATCH}" | awk '{print $1}')"
NATIVE_FILE_DIALOG_DRIVER_PATCH_SHA256="$(shasum -a 256 "${NATIVE_FILE_DIALOG_DRIVER_PATCH}" | awk '{print $1}')"
NATIVE_FILE_DIALOG_PATCH_SHA256="$(shasum -a 256 "${NATIVE_FILE_DIALOG_PATCH}" | awk '{print $1}')"
APP_BUNDLE_HOST_PATCH_SHA256="$(shasum -a 256 "${APP_BUNDLE_HOST_PATCH}" | awk '{print $1}')"
APP_NAP_DEFAULTS_PATCH_SHA256="$(shasum -a 256 "${APP_NAP_DEFAULTS_PATCH}" | awk '{print $1}')"
WBEMPROX_IPENABLED_PATCH_SHA256="$(shasum -a 256 "${WBEMPROX_IPENABLED_PATCH}" | awk '{print $1}')"
WIC_CACHE_PATCH_SHA256="$(shasum -a 256 "${WIC_CACHE_PATCH}" | awk '{print $1}')"
LOCAL_MODULE_READS_PATCH_SHA256="$(shasum -a 256 "${LOCAL_MODULE_READS_PATCH}" | awk '{print $1}')"
OPENGL32_BATCH_PATCH_SHA256="$(shasum -a 256 "${OPENGL32_BATCH_PATCH}" | awk '{print $1}')"
SERVER_WINDOW_WALKS_PATCH_SHA256="$(shasum -a 256 "${SERVER_WINDOW_WALKS_PATCH}" | awk '{print $1}')"
MPENGINE_PATCH_SHA256="$(shasum -a 256 "${MPENGINE_PATCH}" | awk '{print $1}')"
GLU_NURBS_PATCH_SHA256="$(shasum -a 256 "${GLU_NURBS_PATCH}" | awk '{print $1}')"
INOTIFY_HEADER_SHA256="$(shasum -a 256 "${INOTIFY_INCLUDE}/sys/inotify.h" | awk '{print $1}')"
SCRIPT_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
BUILD_KEY="${WINE_VERSION}:${WINE_SOURCE_SHA256}:${WINE_DRIVER_DEPLOYMENT_TARGET}:${BRANDING_PATCH_SHA256}:${DRIVER_PATCH_SHA256}:${INPUT_PATCH_SHA256}:${OPENGL_PATCH_SHA256}:${TOPMOST_PATCH_SHA256}:${SPACE_PATCH_SHA256}:${BITMAP_PATCH_SHA256}:${SOFTWARE_RENDERER_PATCH_SHA256}:${TREEVIEW_PATCH_SHA256}:${PRINTWINDOW_PATCH_SHA256}:${FONTLINK_PATCH_SHA256}:${SCREEN_READBACK_PATCH_SHA256}:${MSXML_SCHEMA_PATCH_SHA256}:${PE_MAPPING_PATCH_SHA256}:${MEM_RESET_PATCH_SHA256}:${MSYNC_PATCH_SHA256}:${CROSS_PROCESS_SURFACES_PATCH_SHA256}:${HEADER_LAYOUT_PATCH_SHA256}:${COMPUTER_NAME_PATCH_SHA256}:${MSXML_SEND_PATCH_SHA256}:${MSXML_EMPTY_ELEMENT_PATCH_SHA256}:${NATIVE_FILE_DIALOG_DRIVER_PATCH_SHA256}:${NATIVE_FILE_DIALOG_PATCH_SHA256}:${APP_BUNDLE_HOST_PATCH_SHA256}:${WBEMPROX_IPENABLED_PATCH_SHA256}:${WIC_CACHE_PATCH_SHA256}:${LOCAL_MODULE_READS_PATCH_SHA256}:${OPENGL32_BATCH_PATCH_SHA256}:${SERVER_WINDOW_WALKS_PATCH_SHA256}:${APP_NAP_DEFAULTS_PATCH_SHA256}:${MPENGINE_PATCH_SHA256}:${GLU_NURBS_PATCH_SHA256}:${INOTIFY_HEADER_SHA256}:${WINE_RUNTIME_SHA256}:${COM_PATCH_SHA256}:${SCRIPT_SHA256}"
if [ -f "${WINEMAC_OUTPUT}" ] && [ -f "${WIN32U_OUTPUT}" ] && [ -f "${NTDLL_OUTPUT}" ] && [ -f "${WINE_LOADER_OUTPUT}" ] && [ -f "${COMBASE_OUTPUT}" ] && [ -f "${COMCTL32_V6_OUTPUT}" ] && [ -f "${MSXML3_OUTPUT}" ] && [ -f "${MSXML3_I386_OUTPUT}" ] && [ -f "${WS2_32_OUTPUT}" ] && [ -f "${WS2_32_I386_OUTPUT}" ] && [ -f "${WINEMAC_DRV_OUTPUT}" ] && [ -f "${WINEMAC_DRV_I386_OUTPUT}" ] && [ -f "${COMDLG32_OUTPUT}" ] && [ -f "${COMDLG32_I386_OUTPUT}" ] && [ -f "${WBEMPROX_OUTPUT}" ] && [ -f "${WBEMPROX_I386_OUTPUT}" ] && [ -f "${WINDOWSCODECS_OUTPUT}" ] && [ -f "${KERNELBASE_OUTPUT}" ] && [ -f "${OPENGL32_OUTPUT}" ] && [ -f "${OPENGL32_UNIX_OUTPUT}" ] && [ -f "${WINESERVER_OUTPUT}" ] && [ -f "${GLU32_OUTPUT}" ] && [ -f "${STAMP_FILE}" ] &&
   [ "$(<"${STAMP_FILE}")" = "${BUILD_KEY}" ]; then
    echo "==> Patched Wine modules are up to date."
    exit 0
fi

STAGING_ROOT="$(mktemp -d "${WORKSPACE_ROOT}/build/.winemac.XXXXXX")"
trap 'rm -rf -- "${STAGING_ROOT}"' EXIT
SOURCE_DIR="${STAGING_ROOT}/source"
BUILD_DIR="${STAGING_ROOT}/build"
mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}"
tar -xf "${SOURCE_ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1

git -C "${SOURCE_DIR}" init -q
git -C "${SOURCE_DIR}" apply --check "${BRANDING_PATCH}"
git -C "${SOURCE_DIR}" apply "${BRANDING_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${DRIVER_PATCH}"
git -C "${SOURCE_DIR}" apply "${DRIVER_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${INPUT_PATCH}"
git -C "${SOURCE_DIR}" apply "${INPUT_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${OPENGL_PATCH}"
git -C "${SOURCE_DIR}" apply "${OPENGL_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${TOPMOST_PATCH}"
git -C "${SOURCE_DIR}" apply "${TOPMOST_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${SPACE_PATCH}"
git -C "${SOURCE_DIR}" apply "${SPACE_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${COM_PATCH}"
git -C "${SOURCE_DIR}" apply "${COM_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${BITMAP_PATCH}"
git -C "${SOURCE_DIR}" apply "${BITMAP_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${SOFTWARE_RENDERER_PATCH}"
git -C "${SOURCE_DIR}" apply "${SOFTWARE_RENDERER_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${TREEVIEW_PATCH}"
git -C "${SOURCE_DIR}" apply "${TREEVIEW_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${PRINTWINDOW_PATCH}"
git -C "${SOURCE_DIR}" apply "${PRINTWINDOW_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${FONTLINK_PATCH}"
git -C "${SOURCE_DIR}" apply "${FONTLINK_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${SCREEN_READBACK_PATCH}"
git -C "${SOURCE_DIR}" apply "${SCREEN_READBACK_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MSXML_SCHEMA_PATCH}"
git -C "${SOURCE_DIR}" apply "${MSXML_SCHEMA_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${PE_MAPPING_PATCH}"
git -C "${SOURCE_DIR}" apply "${PE_MAPPING_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MEM_RESET_PATCH}"
git -C "${SOURCE_DIR}" apply "${MEM_RESET_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MSYNC_PATCH}"
git -C "${SOURCE_DIR}" apply "${MSYNC_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${CROSS_PROCESS_SURFACES_PATCH}"
git -C "${SOURCE_DIR}" apply "${CROSS_PROCESS_SURFACES_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${HEADER_LAYOUT_PATCH}"
git -C "${SOURCE_DIR}" apply "${HEADER_LAYOUT_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${COMPUTER_NAME_PATCH}"
git -C "${SOURCE_DIR}" apply "${COMPUTER_NAME_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MSXML_SEND_PATCH}"
git -C "${SOURCE_DIR}" apply "${MSXML_SEND_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MSXML_EMPTY_ELEMENT_PATCH}"
git -C "${SOURCE_DIR}" apply "${MSXML_EMPTY_ELEMENT_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${NATIVE_FILE_DIALOG_DRIVER_PATCH}"
git -C "${SOURCE_DIR}" apply "${NATIVE_FILE_DIALOG_DRIVER_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${NATIVE_FILE_DIALOG_PATCH}"
git -C "${SOURCE_DIR}" apply "${NATIVE_FILE_DIALOG_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${APP_BUNDLE_HOST_PATCH}"
git -C "${SOURCE_DIR}" apply "${APP_BUNDLE_HOST_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${APP_NAP_DEFAULTS_PATCH}"
git -C "${SOURCE_DIR}" apply "${APP_NAP_DEFAULTS_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${WBEMPROX_IPENABLED_PATCH}"
git -C "${SOURCE_DIR}" apply "${WBEMPROX_IPENABLED_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${WIC_CACHE_PATCH}"
git -C "${SOURCE_DIR}" apply "${WIC_CACHE_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${LOCAL_MODULE_READS_PATCH}"
git -C "${SOURCE_DIR}" apply "${LOCAL_MODULE_READS_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${MPENGINE_PATCH}"
git -C "${SOURCE_DIR}" apply "${MPENGINE_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${GLU_NURBS_PATCH}"
git -C "${SOURCE_DIR}" apply "${GLU_NURBS_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${SERVER_WINDOW_WALKS_PATCH}"
git -C "${SOURCE_DIR}" apply "${SERVER_WINDOW_WALKS_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${OPENGL32_BATCH_PATCH}"
git -C "${SOURCE_DIR}" apply "${OPENGL32_BATCH_PATCH}"

INOTIFY_LIB_DIR="${STAGING_ROOT}/inotify"
mkdir -p "${INOTIFY_LIB_DIR}"
tar -xOf "${RUNTIME_ARCHIVE}" "Wine Devel.app/Contents/Resources/wine/lib/libinotify.0.dylib" \
    > "${INOTIFY_LIB_DIR}/libinotify.0.dylib"

# A compiled module keeps the folder it was built in (debug information, __FILE__). Map this
# checkout, which holds the staging folder and third_party, to /macsw, so that no home folder is
# in a shipped module. DWARF takes the physical path of the build folder, so map that one too.
PREFIX_MAP="-ffile-prefix-map=${WORKSPACE_ROOT}=/macsw"
WORKSPACE_PHYSICAL="$(cd "${WORKSPACE_ROOT}" && pwd -P)"
if [ "${WORKSPACE_PHYSICAL}" != "${WORKSPACE_ROOT}" ]; then
    PREFIX_MAP="${PREFIX_MAP} -ffile-prefix-map=${WORKSPACE_PHYSICAL}=/macsw"
fi

export MACOSX_DEPLOYMENT_TARGET="${WINE_DRIVER_DEPLOYMENT_TARGET}"
pushd "${BUILD_DIR}" >/dev/null
FREETYPE_CFLAGS="-I${FREETYPE_INCLUDE}" \
FREETYPE_LIBS=" " \
ac_cv_lib_soname_freetype=libfreetype.6.dylib \
INOTIFY_CFLAGS="-I${INOTIFY_INCLUDE}" \
INOTIFY_LIBS="${INOTIFY_LIB_DIR}/libinotify.0.dylib" \
"${SOURCE_DIR}/configure" \
    --build=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 \
    --disable-tests \
    --disable-winebth_sys \
    --without-alsa \
    --without-capi \
    --with-coreaudio \
    --without-cups \
    --without-dbus \
    --without-ffmpeg \
    --without-fontconfig \
    --with-freetype \
    --without-gettext \
    --without-gettextpo \
    --without-gphoto \
    --without-gnutls \
    --without-gssapi \
    --without-gstreamer \
    --with-inotify \
    --without-krb5 \
    --without-netapi \
    --without-opencl \
    --without-opengl \
    --without-oss \
    --without-pcap \
    --without-pcsclite \
    --with-pthread \
    --without-pulse \
    --without-sane \
    --without-sdl \
    --without-udev \
    --without-usb \
    --without-v4l2 \
    --with-vulkan \
    --without-wayland \
    --without-x \
    CC="/usr/bin/clang -arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET}" \
    CXX="/usr/bin/clang++ -arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET}" \
    CFLAGS="-O2 ${PREFIX_MAP}" \
    CROSSCFLAGS="-g -O2 ${PREFIX_MAP}" \
    LDFLAGS="-arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET} -Wl,-rpath,@loader_path" \
    BISON="${BISON_BIN}" \
    ac_cv_lib_soname_vulkan=libvulkan.1.dylib
popd >/dev/null

MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')}"
make -C "${BUILD_DIR}" -j"${MAKE_JOBS}" \
    dlls/winemac.drv/winemac.so \
    dlls/win32u/win32u.so \
    dlls/ntdll/ntdll.so \
    dlls/combase/x86_64-windows/combase.dll \
    dlls/comctl32_v6/x86_64-windows/comctl32_v6.dll \
    dlls/msxml3/x86_64-windows/msxml3.dll \
    dlls/msxml3/i386-windows/msxml3.dll \
    dlls/ws2_32/x86_64-windows/ws2_32.dll \
    dlls/ws2_32/i386-windows/ws2_32.dll \
    dlls/winemac.drv/x86_64-windows/winemac.drv \
    dlls/winemac.drv/i386-windows/winemac.drv \
    dlls/comdlg32/x86_64-windows/comdlg32.dll \
    dlls/comdlg32/i386-windows/comdlg32.dll \
    dlls/wbemprox/x86_64-windows/wbemprox.dll \
    dlls/wbemprox/i386-windows/wbemprox.dll \
    dlls/windowscodecs/x86_64-windows/windowscodecs.dll \
    dlls/kernelbase/x86_64-windows/kernelbase.dll \
    dlls/opengl32/x86_64-windows/opengl32.dll \
    dlls/opengl32/opengl32.so \
    dlls/glu32/x86_64-windows/glu32.dll \
    loader/wine \
    server/wineserver

mkdir -p "${OUTPUT_DIR}"
cp "${BUILD_DIR}/dlls/winemac.drv/winemac.so" "${WINEMAC_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/win32u/win32u.so" "${WIN32U_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/ntdll/ntdll.so" "${NTDLL_OUTPUT}.new"
cp "${BUILD_DIR}/loader/wine" "${WINE_LOADER_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/combase/x86_64-windows/combase.dll" "${COMBASE_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/comctl32_v6/x86_64-windows/comctl32_v6.dll" "${COMCTL32_V6_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/msxml3/x86_64-windows/msxml3.dll" "${MSXML3_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/msxml3/i386-windows/msxml3.dll" "${MSXML3_I386_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/ws2_32/x86_64-windows/ws2_32.dll" "${WS2_32_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/ws2_32/i386-windows/ws2_32.dll" "${WS2_32_I386_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/winemac.drv/x86_64-windows/winemac.drv" "${WINEMAC_DRV_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/winemac.drv/i386-windows/winemac.drv" "${WINEMAC_DRV_I386_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/comdlg32/x86_64-windows/comdlg32.dll" "${COMDLG32_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/comdlg32/i386-windows/comdlg32.dll" "${COMDLG32_I386_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/wbemprox/x86_64-windows/wbemprox.dll" "${WBEMPROX_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/wbemprox/i386-windows/wbemprox.dll" "${WBEMPROX_I386_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/windowscodecs/x86_64-windows/windowscodecs.dll" "${WINDOWSCODECS_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/kernelbase/x86_64-windows/kernelbase.dll" "${KERNELBASE_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/opengl32/x86_64-windows/opengl32.dll" "${OPENGL32_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/opengl32/opengl32.so" "${OPENGL32_UNIX_OUTPUT}.new"
cp "${BUILD_DIR}/server/wineserver" "${WINESERVER_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/glu32/x86_64-windows/glu32.dll" "${GLU32_OUTPUT}.new"
# This is a Wine PE module, not Mach-O: verify architecture, do not codesign it.
file "${COMBASE_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${COMCTL32_V6_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${MSXML3_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${MSXML3_I386_OUTPUT}.new" | grep -q 'PE32 executable.*Intel 80386'
file "${WS2_32_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${WS2_32_I386_OUTPUT}.new" | grep -q 'PE32 executable.*Intel 80386'
file "${WINEMAC_DRV_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${WINEMAC_DRV_I386_OUTPUT}.new" | grep -q 'PE32 executable.*Intel 80386'
file "${COMDLG32_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${COMDLG32_I386_OUTPUT}.new" | grep -q 'PE32 executable.*Intel 80386'
file "${WBEMPROX_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${WBEMPROX_I386_OUTPUT}.new" | grep -q 'PE32 executable.*Intel 80386'
file "${WINDOWSCODECS_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${KERNELBASE_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${OPENGL32_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
file "${GLU32_OUTPUT}.new" | grep -q 'PE32+ executable.*x86-64'
install_name_tool -id winemac.so "${WINEMAC_OUTPUT}.new"
install_name_tool -id win32u.so "${WIN32U_OUTPUT}.new"
install_name_tool -id ntdll.so "${NTDLL_OUTPUT}.new"
install_name_tool -id opengl32.so "${OPENGL32_UNIX_OUTPUT}.new"
install_name_tool -add_rpath '@loader_path/../../' "${WIN32U_OUTPUT}.new"
# Match the stock Gcenx wineserver: bin/wineserver finds lib/libinotify.0.dylib via @rpath.
install_name_tool -change libinotify.dylib @rpath/libinotify.0.dylib "${WINESERVER_OUTPUT}.new"
install_name_tool -add_rpath '@loader_path/../lib' "${WINESERVER_OUTPUT}.new"
otool -L "${WINESERVER_OUTPUT}.new" | grep -q '@rpath/libinotify.0.dylib'
for MODULE in "${WINEMAC_OUTPUT}.new" "${WIN32U_OUTPUT}.new" "${NTDLL_OUTPUT}.new" "${OPENGL32_UNIX_OUTPUT}.new" "${WINE_LOADER_OUTPUT}.new" "${WINESERVER_OUTPUT}.new"; do
    codesign --force --sign - "${MODULE}"
    file "${MODULE}" | grep -q 'x86_64'
    codesign --verify --verbose=2 "${MODULE}"
done
unset MODULE
mv "${WINEMAC_OUTPUT}.new" "${WINEMAC_OUTPUT}"
mv "${WIN32U_OUTPUT}.new" "${WIN32U_OUTPUT}"
mv "${NTDLL_OUTPUT}.new" "${NTDLL_OUTPUT}"
mv "${WINE_LOADER_OUTPUT}.new" "${WINE_LOADER_OUTPUT}"
mv "${COMBASE_OUTPUT}.new" "${COMBASE_OUTPUT}"
mv "${COMCTL32_V6_OUTPUT}.new" "${COMCTL32_V6_OUTPUT}"
mv "${MSXML3_OUTPUT}.new" "${MSXML3_OUTPUT}"
mv "${MSXML3_I386_OUTPUT}.new" "${MSXML3_I386_OUTPUT}"
mv "${WS2_32_OUTPUT}.new" "${WS2_32_OUTPUT}"
mv "${WS2_32_I386_OUTPUT}.new" "${WS2_32_I386_OUTPUT}"
mv "${WINEMAC_DRV_OUTPUT}.new" "${WINEMAC_DRV_OUTPUT}"
mv "${WINEMAC_DRV_I386_OUTPUT}.new" "${WINEMAC_DRV_I386_OUTPUT}"
mv "${COMDLG32_OUTPUT}.new" "${COMDLG32_OUTPUT}"
mv "${COMDLG32_I386_OUTPUT}.new" "${COMDLG32_I386_OUTPUT}"
mv "${WBEMPROX_OUTPUT}.new" "${WBEMPROX_OUTPUT}"
mv "${WBEMPROX_I386_OUTPUT}.new" "${WBEMPROX_I386_OUTPUT}"
mv "${WINDOWSCODECS_OUTPUT}.new" "${WINDOWSCODECS_OUTPUT}"
mv "${KERNELBASE_OUTPUT}.new" "${KERNELBASE_OUTPUT}"
mv "${OPENGL32_OUTPUT}.new" "${OPENGL32_OUTPUT}"
mv "${OPENGL32_UNIX_OUTPUT}.new" "${OPENGL32_UNIX_OUTPUT}"
mv "${WINESERVER_OUTPUT}.new" "${WINESERVER_OUTPUT}"
mv "${GLU32_OUTPUT}.new" "${GLU32_OUTPUT}"
printf '%s' "${BUILD_KEY}" > "${STAMP_FILE}"

echo "==> Patched Wine components built: ${WINEMAC_OUTPUT}, ${WIN32U_OUTPUT}, ${NTDLL_OUTPUT}, ${WINE_LOADER_OUTPUT}, ${COMBASE_OUTPUT}, ${COMCTL32_V6_OUTPUT}, ${MSXML3_OUTPUT}, ${MSXML3_I386_OUTPUT}, ${WS2_32_OUTPUT}, ${WS2_32_I386_OUTPUT}, ${WINEMAC_DRV_OUTPUT}, ${WINEMAC_DRV_I386_OUTPUT}, ${COMDLG32_OUTPUT}, ${COMDLG32_I386_OUTPUT}, ${WBEMPROX_OUTPUT}, ${WBEMPROX_I386_OUTPUT}, ${WINDOWSCODECS_OUTPUT}, ${KERNELBASE_OUTPUT}, ${OPENGL32_OUTPUT}, ${OPENGL32_UNIX_OUTPUT}, ${WINESERVER_OUTPUT}, ${GLU32_OUTPUT}"
