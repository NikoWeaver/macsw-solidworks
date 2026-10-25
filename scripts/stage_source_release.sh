#!/usr/bin/env bash
# Writes the source files that SOURCE.txt promises for a release (resources/licenses/Wine-SOURCE.txt.in):
#
#   MACSW_SCAN_TERMS=<terms file> scripts/stage_source_release.sh <out-dir> [<commit>]
#
#   MacSW-<APP_RELEASE>-source.tar.gz   the public tree of <commit> (default: HEAD), as
#                                       scripts/make_public_tree.sh makes it: the files of the
#                                       commit without history, without the paths in
#                                       scripts/ci/public-tree-remove.txt, and only when the
#                                       publication scan finds nothing; in the folder
#                                       MacSW-<APP_RELEASE>-source/
#   wine-<WINE_VERSION>.tar.xz          the pinned upstream Wine source (dist/, checksum checked)
#   mono-<commit>.tar.gz                the pinned Mono source (dist/, checksum checked)
#   gnutls-..., nettle-..., ...         the pinned source archives of the LGPL libraries in
#   7z2301-src.tar.xz                   Resources/Wine/lib and of 7-Zip (MACSW_LGPL_SOURCES in
#                                       scripts/lib/config.sh; dist/, checksums checked; make
#                                       fetch-lgpl-sources downloads them)
#   SHA256SUMS-source
#
# MACSW_SOURCE_TREE is the git checkout of <commit> (default: this checkout). MACSW_SCAN_TERMS
# names the private terms file of the scan (see scripts/ci/publication_scan.py).
# Put these files next to the DMG in the releases folder. Use the commit that BuildManifest.plist
# (GitCommit) and SOURCE.txt name. The script writes only into <out-dir> and never downloads.
# Exit status: 0 when done; 1 on a checksum mismatch, a scan hit or a commit that is not on
# MACSW_SOURCE_URL (see below); 2 on a usage error. On a failure it writes no source archive.
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"

OUT_DIR="${1:?usage: stage_source_release.sh <out-dir> [<commit>]}"
SOURCE_TREE="${MACSW_SOURCE_TREE:-${WORKSPACE_ROOT}}"
COMMIT="$(git -C "${SOURCE_TREE}" rev-parse --verify "${2:-HEAD}^{commit}")"
TREE_NAME="MacSW-${APP_RELEASE}-source"
ARCHIVE="${TREE_NAME}.tar.gz"

# A release for the public repository is built and staged from a clone of it, so that the commit
# in SOURCE.txt is public. MACSW_SOURCE_URL= (empty) stages a build that names no repository,
# for example a team release from the private repository.
if [ -n "${MACSW_SOURCE_URL:-}" ] && ! macsw_commit_is_published "${SOURCE_TREE}" "${COMMIT}"; then
    echo "Commit ${COMMIT} is not on ${MACSW_SOURCE_URL} (the origin of ${SOURCE_TREE}, as last fetched)." >&2
    echo "Stage a release from a clone of that repository after the push, or set MACSW_SOURCE_URL= for a" >&2
    echo "build that names no repository. Never push a branch or tag of the private MacSW repository." >&2
    exit 1
fi

check() {
    test "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" || { echo "Checksum mismatch: $1" >&2; exit 1; }
}

check "${WORKSPACE_ROOT}/dist/${WINE_SOURCE_ASSET}" "${WINE_SOURCE_SHA256}"
check "${WORKSPACE_ROOT}/dist/${MONO_SOURCE_ASSET}" "${MONO_SOURCE_SHA256}"
SOURCE_ASSETS=("${WINE_SOURCE_ASSET}" "${MONO_SOURCE_ASSET}")
for key in ${MACSW_LGPL_SOURCES}; do
    eval "url=\${${key}_SOURCE_URL}; sha256=\${${key}_SOURCE_SHA256}"
    if [ ! -f "${WORKSPACE_ROOT}/dist/${url##*/}" ]; then
        echo "Missing dist/${url##*/}. Run: make fetch-lgpl-sources" >&2
        exit 1
    fi
    check "${WORKSPACE_ROOT}/dist/${url##*/}" "${sha256}"
    SOURCE_ASSETS+=("${url##*/}")
done

# The public tree, scanned. make_public_tree.sh exits 1 on a scan hit and 2 on a usage error.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/macsw-source.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT
status=0
MACSW_SOURCE_TREE="${SOURCE_TREE}" bash "${WORKSPACE_ROOT}/scripts/make_public_tree.sh" \
    "${COMMIT}" "${STAGE}/${TREE_NAME}" || status=$?
if [ "${status}" -ne 0 ]; then
    echo "The public tree of ${COMMIT} did not pass; no source archive was written." >&2
    exit "${status}"
fi

mkdir -p "${OUT_DIR}"
# Owner 0:0 and no user or group names; no macOS metadata (._ files, extended attributes such as
# com.apple.provenance, ACLs, file flags).
(cd "${STAGE}" && COPYFILE_DISABLE=1 tar --numeric-owner --uid 0 --gid 0 --no-mac-metadata \
    --no-xattrs --no-acls --no-fflags -czf "${STAGE}/${ARCHIVE}" "${TREE_NAME}")
mv -f "${STAGE}/${ARCHIVE}" "${OUT_DIR}/${ARCHIVE}"
for asset in "${SOURCE_ASSETS[@]}"; do
    cp -p "${WORKSPACE_ROOT}/dist/${asset}" "${OUT_DIR}/"
done
(cd "${OUT_DIR}" && shasum -a 256 "${ARCHIVE}" "${SOURCE_ASSETS[@]}" > SHA256SUMS-source)
echo "==> Source files for MacSW ${APP_RELEASE} (commit ${COMMIT}) in ${OUT_DIR}"
