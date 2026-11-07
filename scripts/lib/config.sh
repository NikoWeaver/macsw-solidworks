#!/usr/bin/env bash

if [ -n "${BASH_VERSION:-}" ]; then
    MACSW_CONFIG_SOURCE_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    MACSW_CONFIG_SOURCE_PATH="${(%):-%x}"
else
    echo "scripts/lib/config.sh requires Bash or zsh" >&2
    return 1 2>/dev/null || exit 1
fi

MACSW_CONFIG_ROOT="$(cd "$(dirname "${MACSW_CONFIG_SOURCE_PATH}")/../.." && pwd)"
MACSW_VERSIONS_FILE="${MACSW_CONFIG_ROOT}/config/versions.env"
SWCLI_WHEEL_MANIFEST="${MACSW_CONFIG_ROOT}/config/swcli-wheels.tsv"

if [ ! -f "${MACSW_VERSIONS_FILE}" ]; then
    echo "Missing build version configuration: ${MACSW_VERSIONS_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck source=../../config/versions.env
source "${MACSW_VERSIONS_FILE}"

MACSW_REQUIRED_VERSION_KEYS=(
    APP_VERSION APP_BUILD APP_RELEASE MACOS_DEPLOYMENT_TARGET
    WINE_VERSION WINE_RUNTIME_SHA256 WINE_SOURCE_SHA256 WINE_DRIVER_DEPLOYMENT_TARGET
    WINE_MONO_VERSION MONO_PATCH_RELEASE MONO_PATCH_SOURCE_COMMIT MONO_PATCH_SHA256
    MONO_MSCORLIB_SHA256 MONO_REGASM_X86_SHA256 MONO_REGASM_X64_SHA256
    MONO_X64_SHA256 MONO_SOURCE_COMMIT MONO_SOURCE_SHA256
    STDOLE_VERSION STDOLE_DLL_SHA256
    SEVEN_Z_VERSION SEVEN_Z_SHA256 SEVEN_Z_SOURCE_URL SEVEN_Z_SOURCE_SHA256
    GNUTLS_VERSION GNUTLS_SOURCE_URL GNUTLS_SOURCE_SHA256
    NETTLE_VERSION NETTLE_SOURCE_URL NETTLE_SOURCE_SHA256
    GMP_VERSION GMP_SOURCE_URL GMP_SOURCE_SHA256
    LIBTASN1_VERSION LIBTASN1_SOURCE_URL LIBTASN1_SOURCE_SHA256
    LIBUNISTRING_VERSION LIBUNISTRING_SOURCE_URL LIBUNISTRING_SOURCE_SHA256
    LIBIDN2_VERSION LIBIDN2_SOURCE_URL LIBIDN2_SOURCE_SHA256
    LIBICONV_VERSION LIBICONV_SOURCE_URL LIBICONV_SOURCE_SHA256
    GETTEXT_VERSION GETTEXT_SOURCE_URL GETTEXT_SOURCE_SHA256
    SWCLI_VERSION SWCLI_SOURCE_COMMIT
    SWCLI_PYTHON_VERSION SWCLI_PYTHON_ARCHIVE_SHA256
    SWCLI_PYWIN32_VERSION SWCLI_PYWIN32_WHEEL_SHA256
    SWCLI_NATIVE_PYTHON_VERSION SWCLI_NATIVE_PYTHON_RELEASE
    SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256
)

for MACSW_VERSION_KEY in "${MACSW_REQUIRED_VERSION_KEYS[@]}"; do
    eval "MACSW_VERSION_VALUE=\${${MACSW_VERSION_KEY}:-}"
    if [ -z "${MACSW_VERSION_VALUE}" ]; then
        echo "Missing required value in ${MACSW_VERSIONS_FILE}: ${MACSW_VERSION_KEY}" >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset MACSW_VERSION_KEY MACSW_VERSION_VALUE MACSW_REQUIRED_VERSION_KEYS

# APP_RELEASE is APP_VERSION, or APP_VERSION-rc.N for a release candidate.
case "${APP_RELEASE}" in
    "${APP_VERSION}") ;;
    "${APP_VERSION}"-rc.[1-9]|"${APP_VERSION}"-rc.[1-9][0-9]) ;;
    *)
        echo "APP_RELEASE must be APP_VERSION or APP_VERSION-rc.N in ${MACSW_VERSIONS_FILE}" >&2
        return 1 2>/dev/null || exit 1
        ;;
esac

WINE_SERIES="${WINE_VERSION%%.*}.x"
WINE_RUNTIME_ASSET="wine-devel-${WINE_VERSION}-osx64.tar.xz"
WINE_RUNTIME_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${WINE_VERSION}/${WINE_RUNTIME_ASSET}"
WINE_SOURCE_ASSET="wine-${WINE_VERSION}.tar.xz"
WINE_SOURCE_URL="https://dl.winehq.org/wine/source/${WINE_SERIES}/${WINE_SOURCE_ASSET}"
WINEMAC_OUTPUT_NAME="winemac-${WINE_VERSION}"
WINE_MONO_DIRECTORY="wine-mono-${WINE_MONO_VERSION}"
MONO_SOURCE_ASSET="mono-${MONO_SOURCE_COMMIT}.tar.gz"
MONO_SOURCE_URL="https://codeload.github.com/YJBeetle/mono/tar.gz/${MONO_SOURCE_COMMIT}"
MONO_PATCH_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll"
MONO_X64_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/libmono-2.0-x86_64.dll"
MONO_MSCORLIB_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/mscorlib.dll"
MONO_REGASM_X86_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/regasm-x86.exe"
MONO_REGASM_X64_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/regasm-x86_64.exe"
# The clean-room stdole (third_party/stdole-clean/README.md); it is in the repository, not downloaded.
STDOLE_DLL_SOURCE="${MACSW_CONFIG_ROOT}/third_party/stdole-clean/stdole.dll"
SEVEN_Z_ASSET_VERSION="${SEVEN_Z_VERSION//./}"
SEVEN_Z_ARCHIVE_ASSET="7z${SEVEN_Z_ASSET_VERSION}-mac.tar.xz"
SEVEN_Z_URL="https://www.7-zip.org/a/${SEVEN_Z_ARCHIVE_ASSET}"
SWCLI_PYTHON_ARCHIVE_ASSET="python-${SWCLI_PYTHON_VERSION}-embed-amd64.zip"
# The source archives that SOURCE.txt names for the LGPL libraries of the Gcenx runtime and for
# 7-Zip: <NAME>_SOURCE_URL and <NAME>_SOURCE_SHA256 in config/versions.env. The file in dist/
# and next to the DMG has the name of the last part of the URL.
MACSW_LGPL_SOURCES="GNUTLS NETTLE GMP LIBTASN1 LIBUNISTRING LIBIDN2 LIBICONV GETTEXT SEVEN_Z"
SWCLI_PYTHON_ARCHIVE_URL="https://www.python.org/ftp/python/${SWCLI_PYTHON_VERSION}/${SWCLI_PYTHON_ARCHIVE_ASSET}"
SWCLI_PYWIN32_WHEEL_ASSET="pywin32-${SWCLI_PYWIN32_VERSION}-cp311-cp311-win_amd64.whl"
SWCLI_PYWIN32_WHEEL_URL="https://files.pythonhosted.org/packages/35/c4/dcd2d62b5944b6d5db53413a5899016ccd57ffcb7278f3f81655d25d2027/${SWCLI_PYWIN32_WHEEL_ASSET}"
SWCLI_NATIVE_PYTHON_ARCHIVE_ASSET="cpython-${SWCLI_NATIVE_PYTHON_VERSION}+${SWCLI_NATIVE_PYTHON_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
SWCLI_NATIVE_PYTHON_ARCHIVE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${SWCLI_NATIVE_PYTHON_RELEASE}/cpython-${SWCLI_NATIVE_PYTHON_VERSION}%2B${SWCLI_NATIVE_PYTHON_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"

# Where this fork's source is published: this fork's repository. SOURCE.txt names it and the
# release tag (APP_RELEASE) next to the source commit. Set it to an empty value to name the
# release folder only (resources/licenses/Wine-SOURCE.txt.in).
MACSW_SOURCE_URL="${MACSW_SOURCE_URL-https://github.com/NikoWeaver/macsw-solidworks}"

# A repository address in one form: https, no ".git", no "/" at the end, lower case.
macsw_repo_address() {
    local address="${1%/}"
    address="${address%.git}"
    case "${address}" in
        *@github.com:*) address="https://github.com/${address#*@github.com:}" ;;
        ssh://*@github.com/*) address="https://github.com/${address#ssh://*@github.com/}" ;;
    esac
    printf '%s\n' "${address}" | tr '[:upper:]' '[:lower:]'
}

# True when commit $2 of the git checkout $1 is published in MACSW_SOURCE_URL: the checkout's
# origin is that repository and a branch of origin (as last fetched) holds the commit. Only then
# may SOURCE.txt say that the source of the commit is online. A commit of the private MacSW
# repository never is: the public repository starts with its own history-free import.
macsw_commit_is_published() {
    local origin
    [ -n "${MACSW_SOURCE_URL:-}" ] || return 1
    origin="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
    [ "$(macsw_repo_address "${origin}")" = "$(macsw_repo_address "${MACSW_SOURCE_URL}")" ] || return 1
    [ -n "$(git -C "$1" for-each-ref --count=1 --contains "$2" refs/remotes/origin/ 2>/dev/null)" ]
}

# This fork leaves SWCLI (daemon, CLI, Windows Python, pywin32, wheels) out by
# default. The native macOS Python and wine_runtime.py are always packaged:
# installation and Wine maintenance use them.
MACSW_SKIP_SWCLI="${MACSW_SKIP_SWCLI:-1}"

unset MACSW_CONFIG_SOURCE_PATH
