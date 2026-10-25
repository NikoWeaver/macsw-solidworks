#!/usr/bin/env bash
# Check a SOLIDWORKS.app built by package_solidworks_app.sh against the MacSW.app it pairs with.
#   verify_solidworks_app.sh [SOLIDWORKS.app] [MacSW.app]
#   verify_solidworks_app.sh --embedded MacSW.app    the copy inside MacSW.app (package --embed):
#       unpacks Contents/Resources/SOLIDWORKS.app.zip as MacSW does and checks it and its plist.
# Accepts an ad hoc signature or one from a stable identity (scripts/lib/codesign.sh); with
# MACSW_SIGN_IDENTITY set, only the latter.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"

fail() { echo "verify_solidworks_app: $*" >&2; exit 1; }
if [ "${1:-}" = --embedded ]; then
    MACSW_APP="${2:?usage: $0 --embedded MacSW.app}"
    PAYLOAD="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.zip"
    PAYLOAD_INFO="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.plist"
    [ -f "${PAYLOAD}" ] && [ -f "${PAYLOAD_INFO}" ] || fail "no SOLIDWORKS.app inside ${MACSW_APP}"
    UNPACKED="$(mktemp -d)"
    trap 'rm -rf -- "${UNPACKED}"' EXIT
    # As MacSW unpacks it: --noqtn, a quarantined MacSW.app does not quarantine the copy.
    ditto -x -k --noqtn "${PAYLOAD}" "${UNPACKED}"
    test "$(ls -A "${UNPACKED}")" = "SOLIDWORKS.app" || fail "the zip must hold SOLIDWORKS.app and nothing else"
    APP_DIR="${UNPACKED}/SOLIDWORKS.app"
    PI() { /usr/libexec/PlistBuddy -c "Print :$1" "${PAYLOAD_INFO}"; }
    test "$(PI CFBundleShortVersionString)" = "${APP_VERSION}"
    test "$(PI CFBundleVersion)" = "${APP_BUILD}"
    test "$(PI ExecutableSHA256)" = "$(shasum -a 256 "${APP_DIR}/Contents/MacOS/SOLIDWORKS" | awk '{print $1}')" \
        || fail "SOLIDWORKS.app.plist does not describe the zip's executable"
else
    MACSW_APP="${2:-${MACSW_APP_OUTPUT:-${WORKSPACE_ROOT}/build/app/MacSW.app}}"
    APP_DIR="${1:-${MACSW_SOLIDWORKS_APP_OUTPUT:-$(dirname "${MACSW_APP}")/SOLIDWORKS.app}}"
fi
INFO="${APP_DIR}/Contents/Info.plist"
BIN="${APP_DIR}/Contents/MacOS/SOLIDWORKS"
LOADER="${MACSW_APP}/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW"
PV() { /usr/libexec/PlistBuddy -c "Print :$1" "${INFO}"; }

plutil -lint "${INFO}" >/dev/null
test "$(PV CFBundleIdentifier)" = "com.yjbeetle.macsw.solidworks"
test "$(PV CFBundleExecutable)" = "SOLIDWORKS"
test "$(PV CFBundleName)" = "SOLIDWORKS"
test "$(PV CFBundleShortVersionString)" = "${APP_VERSION}"
test "$(PV CFBundleVersion)" = "${APP_BUILD}"
test "$(PV LSMinimumSystemVersion)" = "${MACOS_DEPLOYMENT_TARGET}"
test "$(PV NSPrincipalClass)" = "WineApplication"
test "$(PV LSRequiresNativeExecution)" = "true"
for KEY in LSUIElement NSHighResolutionCapable; do
    if PV "${KEY}" >/dev/null 2>&1; then fail "unexpected ${KEY}"; fi
done
test -s "${APP_DIR}/Contents/Resources/AppIcon.icns"
test -s "${APP_DIR}/Contents/Resources/licenses/MacSW/NOTICE"
test -s "${APP_DIR}/Contents/Resources/licenses/Wine/LGPL-2.1.txt"

# Same imported types as MacSW.app; SOLIDWORKS types owned here, other ranks as in MacSW.
python3 -I "${WORKSPACE_ROOT}/scripts/solidworks_app_info.py" check "${INFO}" "${MACSW_APP}/Contents/Info.plist"

# Universal: the arm64 launcher and exactly MacSW's Wine loader (same UUID) as x86_64.
test "$(lipo -archs "${BIN}" | tr ' ' '\n' | sort | xargs)" = "arm64 x86_64"
uuid() { otool -arch "$1" -l "$2" | awk '/LC_UUID/{f=1} f&&/uuid/{print $2; exit}'; }
test -n "$(uuid x86_64 "${LOADER}")"
test "$(uuid x86_64 "${BIN}")" = "$(uuid x86_64 "${LOADER}")"
otool -arch x86_64 -l "${BIN}" | grep -q '__info_plist'
MINOS="$(otool -arch arm64 -l "${BIN}" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
test "${MINOS}" = "${MACOS_DEPLOYMENT_TARGET}"

# No hardened runtime. Ad hoc: the designated requirement names both slices' cdhashes. Stable
# identity: it names the certificate, which one signature over both slices satisfies.
codesign --verify --strict --verbose=2 "${APP_DIR}"
SIG="$(codesign -dv "${APP_DIR}" 2>&1)"
if grep -q 'flags=.*runtime' <<<"${SIG}"; then fail "hardened runtime flag set"; fi
KIND="$(macsw_signature_kind "${APP_DIR}")" || fail "unexpected code signature"
if [ "${KIND}" = adhoc ]; then
    test "$(codesign -d -r- "${APP_DIR}" 2>&1 | grep -o 'cdhash H' | wc -l | tr -d ' ')" = 2
fi

if [ -n "${PAYLOAD:-}" ]; then
    echo "==> SOLIDWORKS.app inside MacSW.app verified (${KIND} signature, $(codesign -d -r- "${APP_DIR}" 2>&1 | sed -n 's/^#* *designated => //p')): ${PAYLOAD}"
else
    echo "==> SOLIDWORKS.app verified (${KIND} signature): ${APP_DIR}"
fi
