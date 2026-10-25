#!/usr/bin/env bash
# Assemble SOLIDWORKS.app next to a packaged MacSW.app, or (--embed) inside it.
#
#   package_solidworks_app.sh            SOLIDWORKS.app next to MacSW.app (make solidworks-app)
#   package_solidworks_app.sh --embed    SOLIDWORKS.app inside MacSW.app (package_app.sh): as
#                                        Contents/Resources/SOLIDWORKS.app.zip, plus SOLIDWORKS.app.plist
#                                        (versions and the SHA-256 of its executable). MacSW's
#                                        "Install SOLIDWORKS App" unpacks it into /Applications.
#                                        package_app.sh runs this before it seals MacSW.app.
#
# SOLIDWORKS.app is what the user starts from /Applications, Launchpad, Spotlight or the Dock.
# Its executable is universal: the arm64 slice is the launcher (macos/Bootstrap target
# SolidWorksLauncher, built by build_bootstrap.sh), the x86_64 slice is MacSW.app's own Wine
# loader. The launcher runs MacSW's preflight and then executes the loader slice, so the Wine
# host is this app's process (one Dock tile; Finder opens reach it; patch 0025).
# MacSW.app stays the installer and maintenance tool; the launcher uses its Wine runtime and
# finds it next to SOLIDWORKS.app or in /Applications.
#
# Inputs (environment):
#   MACSW_APP_OUTPUT             MacSW.app to pair with (default build/app/MacSW.app)
#   MACSW_SOLIDWORKS_APP_OUTPUT  result (default: next to MacSW.app)
#   MACSW_SOLIDWORKS_EXE         SLDWORKS.exe whose icon the app gets; read only. Default: the
#                                one in the MacSW bottle if it exists, else MacSW's icon.
#                                "none": MacSW's icon (make archive: no SOLIDWORKS artwork).
#   MACSW_SIGN_IDENTITY, MACSW_SIGN_KEYCHAIN
#                                optional stable signing identity (scripts/lib/codesign.sh);
#                                unset: ad hoc.
set -euo pipefail

EMBED=0
case "${1:-}" in
    "") ;;
    --embed) EMBED=1 ;;
    *) echo "usage: $0 [--embed]" >&2; exit 2 ;;
esac

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"

BUILD_ROOT="${WORKSPACE_ROOT}/build"
MACSW_APP="${MACSW_APP_OUTPUT:-${BUILD_ROOT}/app/MacSW.app}"
FINAL_APP_DIR="${MACSW_SOLIDWORKS_APP_OUTPUT:-$(dirname "${MACSW_APP}")/SOLIDWORKS.app}"
# The zip is not a bundle: LaunchServices never sees a second SOLIDWORKS.app inside MacSW.app.
PAYLOAD="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.zip"
PAYLOAD_INFO="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.plist"
LAUNCHER_BIN="${BUILD_ROOT}/bootstrap/SOLIDWORKS"
WINE_LOADER="${MACSW_APP}/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW"
MACSW_INFO="${WORKSPACE_ROOT}/resources/Info.plist.in"
INFO_TEMPLATE="${WORKSPACE_ROOT}/resources/SOLIDWORKS-Info.plist.in"
BOTTLE="${HOME}/Library/Application Support/MacSW/bottle"

for PACKAGE_INPUT in "${LAUNCHER_BIN}" "${WINE_LOADER}" "${MACSW_INFO}" "${INFO_TEMPLATE}" \
    "${MACSW_APP}/Contents/Resources/AppIcon.icns" "${MACSW_APP}/Contents/Resources/licenses/Wine/LGPL-2.1.txt"; do
    [ -f "${PACKAGE_INPUT}" ] || { echo "Missing package input: ${PACKAGE_INPUT}" >&2; exit 1; }
done
unset PACKAGE_INPUT
file "${LAUNCHER_BIN}" | grep -q 'Mach-O 64-bit executable arm64'
file "${WINE_LOADER}" | grep -q 'Mach-O 64-bit executable x86_64'

ICON_SOURCE="${MACSW_SOLIDWORKS_EXE:-}"
if [ "${ICON_SOURCE}" = none ]; then
    ICON_SOURCE=""
elif [ -z "${ICON_SOURCE}" ]; then
    for CANDIDATE in "${BOTTLE}/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe" \
        "${BOTTLE}/drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"; do
        if [ -f "${CANDIDATE}" ]; then ICON_SOURCE="${CANDIDATE}"; break; fi
    done
    unset CANDIDATE
fi

if [ "${EMBED}" = 1 ]; then
    STAGING_ROOT="$(mktemp -d "$(dirname "${MACSW_APP}")/.solidworks.XXXXXX")"
else
    mkdir -p "$(dirname "${FINAL_APP_DIR}")"
    STAGING_ROOT="$(mktemp -d "$(dirname "${FINAL_APP_DIR}")/.solidworks.XXXXXX")"
fi
trap 'rm -rf -- "${STAGING_ROOT}"' EXIT
APP_DIR="${STAGING_ROOT}/SOLIDWORKS.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
mkdir -p "${CONTENTS_DIR}/MacOS" "${RESOURCES_DIR}"

echo "==> Assembling SOLIDWORKS.app (arm64 launcher + MacSW's x86_64 Wine loader)..."
lipo -create "${LAUNCHER_BIN}" "${WINE_LOADER}" -output "${CONTENTS_DIR}/MacOS/SOLIDWORKS"

sed -e "s|@APP_VERSION@|${APP_VERSION}|g" \
    -e "s|@APP_BUILD@|${APP_BUILD}|g" \
    -e "s|@MACOS_DEPLOYMENT_TARGET@|${MACOS_DEPLOYMENT_TARGET}|g" \
    "${INFO_TEMPLATE}" > "${CONTENTS_DIR}/Info.plist"
# Same type declarations as MacSW.app; SOLIDWORKS types are owned here (see the script).
python3 -I "${WORKSPACE_ROOT}/scripts/solidworks_app_info.py" build "${MACSW_INFO}" "${CONTENTS_DIR}/Info.plist"
plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null

if [ -n "${ICON_SOURCE}" ] && [ -f "${ICON_SOURCE}" ]; then
    echo "==> Icon from ${ICON_SOURCE} (read only)"
    python3 -I "${WORKSPACE_ROOT}/scripts/extract_exe_icon.py" "${ICON_SOURCE}" "${RESOURCES_DIR}/AppIcon.icns"
else
    echo "==> No SLDWORKS.exe found; using MacSW's icon (set MACSW_SOLIDWORKS_EXE to change it)."
    cp "${MACSW_APP}/Contents/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# The launcher is MacSW code (Apache-2.0); the loader slice is Wine (LGPL-2.1).
mkdir -p "${RESOURCES_DIR}/licenses"
cp -pR "${MACSW_APP}/Contents/Resources/licenses/MacSW" "${RESOURCES_DIR}/licenses/MacSW"
cp -pR "${MACSW_APP}/Contents/Resources/licenses/Wine" "${RESOURCES_DIR}/licenses/Wine"

# Ad hoc (or MACSW_SIGN_IDENTITY), no hardened runtime, like MacSW.app. One signature covers both
# slices, so macOS treats the launcher and the Wine host as the same app (privacy consent,
# LaunchServices). With a stable identity that also holds across rebuilds.
macsw_codesign "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

if [ "${EMBED}" = 1 ]; then
    bash "${WORKSPACE_ROOT}/scripts/verify_solidworks_app.sh" "${APP_DIR}" "${MACSW_APP}"
    # ditto keeps the files as they are, so the copy that MacSW unpacks keeps this signature.
    rm -f -- "${PAYLOAD}" "${PAYLOAD_INFO}"
    ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${PAYLOAD}"
    plutil -create xml1 "${PAYLOAD_INFO}"
    plutil -insert CFBundleShortVersionString -string "${APP_VERSION}" "${PAYLOAD_INFO}"
    plutil -insert CFBundleVersion -string "${APP_BUILD}" "${PAYLOAD_INFO}"
    plutil -insert ExecutableSHA256 -string "$(shasum -a 256 "${CONTENTS_DIR}/MacOS/SOLIDWORKS" | awk '{print $1}')" \
        "${PAYLOAD_INFO}"
    echo "==> Embedded SOLIDWORKS.app in ${PAYLOAD}"
    exit 0
fi

rm -rf -- "${FINAL_APP_DIR}"
mv "${APP_DIR}" "${FINAL_APP_DIR}"
echo "==> Built ${FINAL_APP_DIR}"
