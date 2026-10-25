#!/usr/bin/env bash
# Local code signatures of the packaged apps (package_app.sh, package_solidworks_app.sh and
# their verify scripts). Developer ID signing for distribution is scripts/sign_app.py.
#
#   MACSW_SIGN_IDENTITY  unset or empty: ad hoc (codesign --sign -), as before.
#                        Set: a code-signing identity (name or SHA-1), for example the self-signed
#                        "MacSW Local Code Signing" certificate. The designated requirement then names
#                        that certificate instead of the cdhash, so macOS privacy consent (TCC) and
#                        LaunchServices records survive rebuilds.
#   MACSW_SIGN_KEYCHAIN  optional: the keychain that holds the identity (codesign --keychain). The
#                        caller unlocks it; these scripts never read or pass its password.
#
# No hardened runtime, no entitlements, no secure timestamp: local builds only.

# macsw_codesign <path>...: signs with MACSW_SIGN_IDENTITY, or ad hoc when it is unset.
macsw_codesign() {
    local arguments=(--force --sign -)
    if [ -n "${MACSW_SIGN_IDENTITY:-}" ]; then
        arguments=(--force --sign "${MACSW_SIGN_IDENTITY}")
        if [ -n "${MACSW_SIGN_KEYCHAIN:-}" ]; then arguments+=(--keychain "${MACSW_SIGN_KEYCHAIN}"); fi
    elif [ -n "${MACSW_SIGN_KEYCHAIN:-}" ]; then
        echo "MACSW_SIGN_KEYCHAIN is set without MACSW_SIGN_IDENTITY" >&2
        return 1
    fi
    codesign "${arguments[@]}" "$@"
}

# macsw_signature_kind <path>: prints "adhoc" or "certificate" (a designated requirement on a
# certificate leaf). Fails for anything else, and for an ad hoc signature while
# MACSW_SIGN_IDENTITY is set (the identity was asked for but not used).
macsw_signature_kind() {
    local details requirement
    details="$(codesign -dv "$1" 2>&1)" || { echo "$1: no code signature" >&2; return 1; }
    if grep -q 'Signature=adhoc' <<<"${details}"; then
        if [ -n "${MACSW_SIGN_IDENTITY:-}" ]; then
            echo "$1: signed ad hoc although MACSW_SIGN_IDENTITY is set" >&2
            return 1
        fi
        echo adhoc
        return 0
    fi
    requirement="$(codesign -d -r- "$1" 2>&1)" || { echo "$1: no designated requirement" >&2; return 1; }
    if grep -q 'certificate leaf' <<<"${requirement}"; then
        echo certificate
        return 0
    fi
    echo "$1: neither ad hoc nor a certificate requirement" >&2
    return 1
}
