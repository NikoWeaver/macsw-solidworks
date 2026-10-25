#!/usr/bin/env bash
# The disk image of a MacSW release (docs/packaging.md):
#
#   scripts/package_dmg.sh [MacSW.app] [output directory]
#
# Defaults: build/app/MacSW.app (MACSW_APP_OUTPUT) and build/dmg. The output directory gets
#
#   MacSW-<release>.dmg         UDZO, volume "MacSW <release>", signed
#   ├── MacSW.app               copied with ditto, never re-signed
#   ├── Applications -> /Applications
#   ├── Read Me First.txt       resources/dmg/ReadMeFirst.txt.in
#   ├── install-helper.sh       resources/dmg/install-helper.sh
#   └── Licenses/               the app's Resources/licenses (and SWCLI/licenses) as the build made
#                               them, with the app's Resources/THIRD_PARTY_NOTICES.txt and
#                               Resources/SOURCE.txt at the top
#   SHA256SUMS                  the SHA-256 of the signed image
#
# <release> comes from the app's BuildManifest.plist (AppRelease; AppVersion in builds before it),
# not from config/versions.env, so an image is always named after the build inside it.
#
# The app must be signed with the certificate that install-helper.sh pins, or the helper would
# refuse it. The image is signed with MACSW_SIGN_IDENTITY (MACSW_SIGN_KEYCHAIN optional, unlocked
# by the caller; scripts/lib/codesign.sh), which must be that same certificate.
# MACSW_DMG_ALLOW_MISSING_NOTICES=1 accepts an app without Resources/THIRD_PARTY_NOTICES.txt
# (builds from before the notices file). Never use it for a release.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"
APP="${1:-${MACSW_APP_OUTPUT:-${WORKSPACE_ROOT}/build/app/MacSW.app}}"
OUTPUT_DIR="${2:-${WORKSPACE_ROOT}/build/dmg}"
HELPER="${WORKSPACE_ROOT}/resources/dmg/install-helper.sh"
README_TEMPLATE="${WORKSPACE_ROOT}/resources/dmg/ReadMeFirst.txt.in"
LICENSES="${APP}/Contents/Resources/licenses"
SWCLI_LICENSES="${APP}/Contents/Resources/SWCLI/licenses"
BUILD_MANIFEST="${APP}/Contents/Resources/BuildManifest.plist"

die() { echo "package_dmg: $*" >&2; exit 1; }

test -d "${APP}" || die "no app at ${APP}"
test -f "${BUILD_MANIFEST}" || die "${APP} has no BuildManifest.plist"
test -f "${HELPER}" && test -f "${README_TEMPLATE}" || die "missing resources/dmg inputs"
[ -n "${MACSW_SIGN_IDENTITY:-}" ] || die "set MACSW_SIGN_IDENTITY: the image is signed with the app's certificate"

RELEASE="$(/usr/libexec/PlistBuddy -c 'Print :AppRelease' "${BUILD_MANIFEST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :AppVersion' "${BUILD_MANIFEST}")"
[[ "${RELEASE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$ ]] || die "unexpected release label: ${RELEASE}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")"
VOLUME="MacSW ${RELEASE}"
DMG_NAME="MacSW-${RELEASE}.dmg"
DMG="${OUTPUT_DIR}/${DMG_NAME}"

# One pin for the helper and this script: the helper's MACSW_CERTIFICATE_LEAF.
LEAF="$(sed -n 's/^MACSW_CERTIFICATE_LEAF="\([0-9a-f]\{40\}\)"$/\1/p' "${HELPER}")"
[ -n "${LEAF}" ] || die "no MACSW_CERTIFICATE_LEAF in ${HELPER}"
APP_REQUIREMENT="=identifier \"com.yjbeetle.macsw\" and certificate leaf = H\"${LEAF}\""
# codesign would take the identifier from the file name ("MacSW-0" for MacSW-0.2.0.dmg).
DMG_IDENTIFIER="com.yjbeetle.macsw.dmg"
DMG_REQUIREMENT="=identifier \"${DMG_IDENTIFIER}\" and certificate leaf = H\"${LEAF}\""

echo "==> MacSW ${RELEASE} (${BUILD}) from ${APP}"
codesign --verify --deep --strict "${APP}" || die "the app's signature is not valid"
codesign --verify -R "${APP_REQUIREMENT}" "${APP}" || die "the app is not signed with certificate leaf ${LEAF}"

# package_app.sh writes both files to Contents/Resources (docs/licences-and-notices.md).
NOTICES="${APP}/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [ ! -f "${NOTICES}" ]; then
    [ "${MACSW_DMG_ALLOW_MISSING_NOTICES:-0}" = 1 ] || die "the app has no ${NOTICES#"${APP}/"}"
    echo "WARNING: the app has no THIRD_PARTY_NOTICES.txt; the image has none either (not for a release)" >&2
fi
SOURCE_NOTICE="${APP}/Contents/Resources/SOURCE.txt"
[ -f "${SOURCE_NOTICE}" ] || SOURCE_NOTICE="${LICENSES}/Wine/SOURCE.txt"
test -f "${SOURCE_NOTICE}" || die "the app has no Resources/SOURCE.txt or licenses/Wine/SOURCE.txt"

mkdir -p "${OUTPUT_DIR}"
# The staged copy, hdiutil's temporary image and the image: about three times the app.
APP_KB="$(du -sk "${APP}" | awk '{print $1}')"
FREE_KB="$(df -Pk "${OUTPUT_DIR}" | awk 'NR == 2 {print $4}')"
[ "${FREE_KB}" -gt $((APP_KB * 3)) ] || die "not enough free space in ${OUTPUT_DIR}: need $((APP_KB * 3 / 1024)) MB"

STAGE="$(mktemp -d "${OUTPUT_DIR}/.dmg-staging.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
echo "==> Staging ${VOLUME}"
ditto "${APP}" "${STAGE}/MacSW.app"
ln -s /Applications "${STAGE}/Applications"
sed -e "s|@RELEASE@|${RELEASE}|g" -e "s|@VOLUME@|${VOLUME}|g" -e "s|@DMG@|${DMG_NAME}|g" \
    "${README_TEMPLATE}" > "${STAGE}/Read Me First.txt"
! grep -q '@[A-Z]*@' "${STAGE}/Read Me First.txt" || die "Read Me First.txt has an unreplaced placeholder"
cp "${HELPER}" "${STAGE}/install-helper.sh"
chmod 0644 "${STAGE}/Read Me First.txt"
chmod 0755 "${STAGE}/install-helper.sh"
ditto "${LICENSES}" "${STAGE}/Licenses"
if [ -d "${SWCLI_LICENSES}" ]; then ditto "${SWCLI_LICENSES}" "${STAGE}/Licenses/SWCLI"; fi
cp "${SOURCE_NOTICE}" "${STAGE}/Licenses/SOURCE.txt"
if [ -f "${NOTICES}" ]; then cp "${NOTICES}" "${STAGE}/Licenses/THIRD_PARTY_NOTICES.txt"; fi
codesign --verify --deep --strict "${STAGE}/MacSW.app" || die "the staged copy of the app does not verify"

echo "==> Creating ${DMG}"
hdiutil create -volname "${VOLUME}" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov "${DMG}"
macsw_codesign --identifier "${DMG_IDENTIFIER}" "${DMG}"
codesign --verify -R "${DMG_REQUIREMENT}" "${DMG}" || die "the image is not signed with certificate leaf ${LEAF}"
hdiutil verify "${DMG}"
(cd "${OUTPUT_DIR}" && shasum -a 256 "${DMG_NAME}" > SHA256SUMS)

echo "==> ${DMG}: $(stat -f '%z' "${DMG}") bytes"
cat "${OUTPUT_DIR}/SHA256SUMS"
