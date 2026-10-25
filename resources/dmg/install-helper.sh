#!/bin/bash
# MacSW install helper: the optional fast path of "Read Me First.txt" on the MacSW disk image.
# macOS blocks a downloaded .command file the same way as the app, so run this file with bash:
#
#   bash "/Volumes/MacSW <release>/install-helper.sh"
#
# It prints each step before it runs it and asks before it changes anything. It uses no sudo,
# writes only /Applications/MacSW.app (an old copy goes to your Trash) and changes no setting.
# The GUI path (Open Anyway in System Settings) stays the documented default.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# The certificate that signs every MacSW build ("MacSW Local Code Signing", self-signed).
MACSW_CERTIFICATE_LEAF="616428ae1195eb76e27758ae5b88122911551f7f"
MACSW_REQUIREMENT="=identifier \"com.yjbeetle.macsw\" and certificate leaf = H\"${MACSW_CERTIFICATE_LEAF}\""
SOURCE_APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/MacSW.app"
TARGET_APP="/Applications/MacSW.app"
QUESTION="Copy MacSW to /Applications and remove the macOS download flag from MacSW only? [y/N] "

step() { printf '\n==> %s\n' "$*"; }
stop() { printf 'Stopped: %s\n' "$*" >&2; exit 1; }

# Only an explicit "y" or "yes" is yes. Return alone, "n" and anything else are no.
is_yes() { [[ "$1" =~ ^[[:space:]]*([yY]|[yY][eE][sS])[[:space:]]*$ ]]; }

# A name in the Trash that is not in use: "MacSW <stamp>.app", then "MacSW <stamp> 2.app", ...
trash_destination() {
    local trash="$1" stamp="$2" number=1
    local candidate="${trash}/MacSW ${stamp}.app"
    while [ -e "${candidate}" ] || [ -L "${candidate}" ]; do
        number=$((number + 1))
        candidate="${trash}/MacSW ${stamp} ${number}.app"
    done
    printf '%s\n' "${candidate}"
}

# MacSW runs, or a Wine process of the installed copy does (its wineserver runs from the bundle).
macsw_running() {
    pgrep -x MacSW >/dev/null 2>&1 || pgrep -f "^${TARGET_APP//./\\.}/" >/dev/null 2>&1
}

main() {
    step "1/5 Check ${SOURCE_APP}"
    echo "    codesign --verify --deep --strict, certificate leaf ${MACSW_CERTIFICATE_LEAF}"
    [ -d "${SOURCE_APP}" ] || stop "MacSW.app is not next to this script."
    codesign --verify --deep --strict "${SOURCE_APP}" \
        || stop "the signature of MacSW.app is not valid. Do not install this copy."
    codesign --verify -R "${MACSW_REQUIREMENT}" "${SOURCE_APP}" \
        || stop "MacSW.app is not signed with the MacSW certificate. Do not install this copy."
    echo "    The signature is valid."

    step "2/5 Ask"
    local reply=""
    # Printed with printf: read -p shows its prompt only when stdin is a terminal.
    printf '%s' "${QUESTION}"
    read -r reply || true
    if ! is_yes "${reply}"; then
        echo "Nothing was changed."
        exit 0
    fi

    step "3/5 Copy MacSW to ${TARGET_APP}"
    [ -w "$(dirname "${TARGET_APP}")" ] \
        || stop "you cannot write to $(dirname "${TARGET_APP}"). Drag MacSW onto Applications in Finder instead."
    if [ -e "${TARGET_APP}" ] || [ -L "${TARGET_APP}" ]; then
        if macsw_running; then
            stop "MacSW or SOLIDWORKS is running. Quit SOLIDWORKS, then quit MacSW (menu bar icon > Quit MacSW), and run this again."
        fi
        local old
        old="$(trash_destination "${HOME}/.Trash" "$(date '+%Y-%m-%d %H.%M.%S')")"
        echo "    mv ${TARGET_APP} \"${old}\"   (the old copy goes to the Trash)"
        mv "${TARGET_APP}" "${old}" || stop "could not move the old copy to the Trash."
    fi
    echo "    ditto ${SOURCE_APP} ${TARGET_APP}"
    ditto "${SOURCE_APP}" "${TARGET_APP}" || stop "the copy failed."

    step "4/5 Remove the macOS download flag from ${TARGET_APP} only"
    echo "    xattr -dr com.apple.quarantine ${TARGET_APP}"
    xattr -dr com.apple.quarantine "${TARGET_APP}"

    step "5/5 Open MacSW"
    echo "    open ${TARGET_APP}"
    open "${TARGET_APP}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
