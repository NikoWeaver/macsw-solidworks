#!/bin/bash
# Makes media-manifest.sha256 in a SOLIDWORKS media folder (docs/team-admin.md). The team admin
# runs it once per media folder, after the VBA MSIs are in PreReqs/VBA and before the upload:
#
#   scripts/make_media_manifest.sh "$HOME/SW2026"
#
# The manifest lists every regular file below the folder (not hidden files or folders, not links,
# not the manifest itself), sorted by path, as `shasum -a 256` writes them. MacSW copies exactly
# these files and checks each one (MediaCopyService). The last line printed is the manifest's own
# SHA-256: put it into macsw-team.json as "manifestSHA256".
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <media folder>" >&2
    exit 2
fi
cd "$1"
name=media-manifest.sha256
partial=".$name.partial"

files() {
    find . -mindepth 1 -name '.*' -prune -o -type f ! -name "$name" -print0
}

# shasum escapes a name with \ or a line break, and MacSW refuses such lines: stop here instead.
odd=$(find . -mindepth 1 -name '.*' -prune -o -type f \( -name '*\\*' -o -name $'*\n*' \) -print | head -n 5)
if [ -n "$odd" ]; then
    echo "error: rename these files (no \\ or line break in a name):" >&2
    echo "$odd" >&2
    exit 1
fi
count=$(files | tr -cd '\0' | wc -c | tr -d ' ')
if [ "$count" -eq 0 ]; then
    echo "error: $(pwd) has no files" >&2
    exit 1
fi

echo "Hashing $count files in $(pwd) ..."
trap 'rm -f "$partial"' EXIT
files | LC_ALL=C sort -z | xargs -0 shasum -a 256 > "$partial"
mv "$partial" "$name"
trap - EXIT
echo "Wrote $(pwd)/$name"
echo "manifestSHA256 for macsw-team.json:"
shasum -a 256 "$name" | cut -d ' ' -f 1
