#!/usr/bin/env bash
# Makes the tree for the public repository from a git ref of this repository: the files of the
# ref only, without history (sharing plan, section f, steps 2, 3 and 5).
# scripts/stage_source_release.sh uses it for the release source archive.
#
#   MACSW_SCAN_TERMS=<terms file> scripts/make_public_tree.sh <git ref> <output folder>
#
# 1. `git archive <ref>` into <output folder>. The folder must not exist, or be empty. The ref is
#    looked up in MACSW_SOURCE_TREE when it is set (a git checkout), else in this checkout.
# 2. Removes the paths in scripts/ci/public-tree-remove.txt (of this checkout) from it.
# 3. Runs scripts/ci/publication_scan.py of this checkout (not the copy in the new tree) on it,
#    with the private terms file that MACSW_SCAN_TERMS names (outside every repository; see the
#    scanner). Without that file the scan cannot check the owner's and the university's names,
#    so the script stops.
#
# Exit status: 0 when the scan finds nothing, 1 on any hit, 2 on a usage error.
set -euo pipefail

usage() {
    echo "usage: $0 <git ref> <output folder>" >&2
    exit 2
}
[ $# -eq 2 ] || usage
REF="$1"
OUT="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${MACSW_SOURCE_TREE:-${SCRIPT_DIR}}"
REPO="$(git -C "${REPO_DIR}" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "not in a git checkout: ${REPO_DIR}" >&2
    exit 2
}
SCANNER="${SCRIPT_DIR}/ci/publication_scan.py"
TERMS="${MACSW_SCAN_TERMS:-}"
if [ -z "${TERMS}" ] || [ ! -f "${TERMS}" ]; then
    echo "MACSW_SCAN_TERMS must name the private terms file (see scripts/ci/publication_scan.py)" >&2
    exit 2
fi

REMOVE_LIST="${SCRIPT_DIR}/ci/public-tree-remove.txt"
REMOVE=()
while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "${line}" in
        "") continue ;;
        /*|*..*) echo "not a path in the tree, in ${REMOVE_LIST}: ${line}" >&2; exit 2 ;;
    esac
    REMOVE+=("${line}")
done < "${REMOVE_LIST}"
if [ "${#REMOVE[@]}" -eq 0 ]; then
    echo "no paths in ${REMOVE_LIST}" >&2
    exit 2
fi

COMMIT="$(git -C "${REPO}" rev-parse --verify --quiet "${REF}^{commit}")" || {
    echo "not a commit in ${REPO}: ${REF}" >&2
    exit 2
}
if [ -e "${OUT}" ] && [ -n "$(ls -A "${OUT}")" ]; then
    echo "the output folder is not empty: ${OUT}" >&2
    exit 2
fi
mkdir -p "${OUT}"

git -C "${REPO}" archive --format=tar "${COMMIT}" | tar -x -C "${OUT}"
for path in "${REMOVE[@]}"; do
    if [ -e "${OUT}/${path}" ]; then
        rm -r "${OUT:?}/${path}"
    else
        echo "note: ${path} is not in ${REF}" >&2
    fi
done

echo "public tree: ${REF} (${COMMIT}), $(find "${OUT}" -type f | wc -l | tr -d ' ') files, in ${OUT}"
status=0
python3 -I -B "${SCANNER}" --terms-file "${TERMS}" "${OUT}" || status=$?
exit "${status}"
