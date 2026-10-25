# Licences, notices and the source offer

Giving MacSW.app to team members is distribution. So every build carries the
licence notices of all bundled parts and says where to get the source of the
parts under the GNU LGPL. This page says what the build writes, how to keep it
correct, and what is still open.

## What the build writes

`scripts/package_app.sh` writes these files into MacSW.app:

| File in `Contents/Resources` | What it is |
|---|---|
| `SOURCE.txt` | The source offer: the MacSW source commit of this build and its source archive (for a build from a clone of this fork's repository, also that repository and the release tag), the Wine source archive and its SHA-256, the Gcenx runtime, Wine-Mono and 7-Zip. From `resources/licenses/Wine-SOURCE.txt.in`. |
| `licenses/Wine/SOURCE.txt` | The same file. `package_solidworks_app.sh` copies `licenses/Wine` into SOLIDWORKS.app. |
| `THIRD_PARTY_NOTICES.txt` | Every third-party part: version, licence, place in the bundle, source address, and each licence text once. From `config/third-party-notices.tsv`. |
| `licenses/Gecko/license.html` | Gecko's `about:license` page, taken from `omni.ja`. |

The DMG script copies `Contents/Resources/THIRD_PARTY_NOTICES.txt` and
`Contents/Resources/SOURCE.txt` into the DMG's `Licenses/` folder.
`scripts/verify_app.sh` checks both files: `SOURCE.txt` must name the
`GitCommit` of `BuildManifest.plist` and must not point at the upstream
repository.

`NOTICE` keeps upstream's text and adds one line: this copy is a modified
version of MacSW, based on YJBeetle/MacSW `69c5509`, and not an official
release. `CHANGES-FROM-UPSTREAM.md` lists the changed areas (Apache-2.0,
section 4(b)).

## The inventory

`scripts/third_party_notices.py` reads `config/third-party-notices.tsv`. It
stops the build when:

- a file or folder in `MacOS`, `Resources/managed`, `Resources/Wine/bin`,
  `Resources/Wine/lib`, `Resources/Wine/share/wine` or `Resources/SWCLI/runtime`
  is not in the table;
- a path in the table is not in the bundle;
- a licence text is missing, or a row has no text and no note.

So a new library in the Wine runtime fails the build until someone adds a row.
Licence texts come from three places: the pinned Wine source archive (Wine's
`LICENSE`, `COPYING.LIB`, `NOTICES.md` and the files of the libraries Wine
includes), files already in the bundle (MacSW, Mono, Python, Gecko), and
`resources/licenses/third-party/`.

Facts from the rc23 bundle (`build.nosync/rc23-out/app/MacSW.app`, read only):

- `Resources/Wine/lib` has 98 entries. All come unchanged from the Gcenx
  runtime tarball, which ships no licence files. `libinotify.0.dylib` is one of
  them, so libinotify-kqueue is a shipped binary, not only build-time headers.
- MoltenVK (`libMoltenVK.dylib`) and the Vulkan loader (`libvulkan.1.4.350`)
  are present. DXVK is not: `d3d10*.dll`, `d3d11.dll` and `dxgi.dll` in
  `lib/wine/x86_64-windows` are Wine's own modules.
- The PE modules include libraries that Wine builds in itself (vkd3d, ICU,
  libpng, zlib, libxml2, LibJPEG, LibTIFF and others). Wine's `NOTICES.md`
  covers them.
- No Dassault file or Dassault-derived list is in the bundle (E12).

## Where the vendored texts come from

| File | Origin |
|---|---|
| `7-Zip.txt` | `License.txt` of the pinned `7z2301-mac.tar.xz` (exact version) |
| `libinotify-kqueue.txt` | `third_party/libinotify-kqueue/LICENSE` |
| `brotli.txt`, `freetype.txt`, `p11-kit.txt`, `zstd.txt`, `xz-0BSD.txt`, `SDL2.txt`, `ICU.txt`, `libidn2-unicode.txt`, `LGPL-3.0.txt`, `GPL-3.0.txt` | The licence files of newer releases of the same projects (Homebrew packages on the build Mac). The terms are the same; the years can be newer. `SDL2.txt` is from sdl2-compat, same holder and the same zlib text. `ICU.txt` is from ICU 78, the same Unicode License V3 as ICU 76. |
| `libffi.txt` | libffi's `LICENSE`, as vendored by another package on the build Mac |
| `lz4.txt`, `bzip2.txt`, `libpcap.txt` | Written in the standard form of each licence, with the holder named by the project. Check them against the source archives before a public release. |

## For each release

Build each release from a clone of this fork's repository,
`https://github.com/NikoWeaver/macsw-solidworks`, not from the private MacSW
repository. Then the `GitCommit` of `BuildManifest.plist`, which `SOURCE.txt`
names, is a commit of the public repository. **Never push a tag or a branch
from the private MacSW repository.** Its history holds the upstream CI that
bypassed licensing and personal data, and git would upload all of it.

1. In the clone, commit the release, tag it with the `APP_RELEASE` label (for
   example `0.2.0-rc.1`) and push the commit and the tag.
2. Build the app and the DMG (`make dmg`). `verify_app.sh` runs as part of it.
   `SOURCE.txt` names the repository and the tag only when the build commit is
   on a branch of the clone's `origin` and `origin` is `MACSW_SOURCE_URL`
   (`scripts/lib/config.sh`). Otherwise it names only the commit and the
   source archive.
3. Make the source files that `SOURCE.txt` promises, from the same commit:

   ```sh
   MACSW_SCAN_TERMS=<terms file> scripts/stage_source_release.sh <out-dir> <commit>
   ```

   It writes `MacSW-<release>-source.tar.gz` (the `APP_RELEASE` label, as the DMG), copies `wine-11.16.tar.xz`, the
   Mono source and the source archives of the LGPL libraries and of 7-Zip from
   `dist/` (checksums checked; `make fetch-lgpl-sources` downloads the last
   ones) and writes `SHA256SUMS-source`.
   The source archive is the public tree of the commit, made by
   `scripts/make_public_tree.sh`: no history, without the paths in
   `scripts/ci/public-tree-remove.txt`, and only when the publication scan
   finds nothing. So it needs the private terms file (`MACSW_SCAN_TERMS`, see
   `scripts/ci/publication_scan.py`). On a scan hit it stops and writes no
   archive. It also stops when `MACSW_SOURCE_URL` is set and the commit is not
   on that repository.
4. Put these files next to the DMG in the team's `releases/` folder. For a
   public release, attach them to the GitHub Release.

A team release made before the fork's repository has the commit is built and
staged with `MACSW_SOURCE_URL=` (an empty value). Then `SOURCE.txt` names no
repository, and the source archive in the Box `releases/` folder is the way to
get the source.

## Open items

- **The fork's repository.** `https://github.com/NikoWeaver/macsw-solidworks`,
  private for now. `SOURCE.txt` names it and the release tag for a build from
  a clone of it (see above). A member who
  cannot open the repository uses the copy in the Box `releases/` folder, so
  that copy must be there for every release.
- **stdole.dll: the terms do not allow MacSW to ship it.** Every MacSW.app and
  DMG holds `Resources/managed/stdole.dll` from the NuGet package stdole
  7.0.3300 (Microsoft). The package gives only a licence address,
  `http://go.microsoft.com/fwlink/?LinkID=746386` (in `stdole.nuspec`).
  Read on 2026-10-25: that address leads to
  `https://visualstudio.microsoft.com/license-terms/mt591984/`, which shows the
  document `VS2017_PREVIEW_ENG_EULA.1033.docx` (SHA-256
  `b4371519045facdffd7d556fc7459c7a8b819ba593d9f346478d28cda3f373e7`): "Microsoft
  Pre-Release Software License Terms, Microsoft Visual Studio 2017 Family
  Pre-Release Software" (EULAID `VS2017_CTP_EVAL_VS_ENU.3`). These terms allow
  installation and use for evaluation only, allow no distribution of an
  application made with the software, and forbid sharing, publishing or
  transferring the software. They have no part for distributable code. So
  these terms give no right to give the file to team members or to publish
  it. Giving the app to team members is distribution (see the top of this
  page), so this blocks the Box team DMG as well as a DMG on a GitHub Release.
  The source tree is not affected: `make fetch-stdole` downloads the file at
  build time. The publication scan now fails a file list that holds
  `stdole.dll` (proprietary-file).
  Next step (a decision for the owner, then a licence test): stop putting the
  file in the bundle, and let MacSW get it on the member's Mac at install time.
  Either take it from the member's SOLIDWORKS media, if the media has it (this
  is not checked yet), or download the pinned NuGet package on the member's Mac
  and check both SHA-256 values. The second way is a change of rule: today an
  installed MacSW downloads nothing. Both ways change
  `PrerequisiteService.prepareManagedCOMDependencies` and `package_app.sh`, and
  need a test install.
- **Source of the LGPL libraries in `Resources/Wine/lib`.** The Gcenx runtime
  takes GnuTLS, Nettle, GMP, libtasn1, libunistring, libidn2, libiconv and
  gettext (libintl) from MacPorts, and its recipe does not pin their versions.
  The versions in `config/versions.env` were read from the libraries of the
  runtime: version strings (GnuTLS 3.8.7, GMP 6.3.0, libtasn1 4.20.0, libidn2
  2.3.7) and version numbers (Nettle 3.10, libunistring 1.3, libiconv 1.17,
  gettext 0.22.5; Nettle 3.10 is the only release with libnettle 8.9 and
  libhogweed 6.9). The checksums are those of the MacPorts Portfiles of these
  versions. `SOURCE.txt`, `THIRD_PARTY_NOTICES.txt` and the release files name
  and carry these archives, and the 7-Zip source (`7z2301-src.tar.xz`, the same
  source as `7z2301-src.7z`). Still open: `make fetch-lgpl-sources` has not been
  run yet, so the checksums have not been checked against a download; and
  MacPorts can apply its own patches to a library (for example
  `patch-lib-system-certs.c.diff` for GnuTLS). Those patches are not in the
  release files yet.
- **Texts not yet included verbatim:** the MacPorts legacy-support licence and
  FreeType's `docs/FTL.TXT` (the file has FreeType's own licence overview and
  the credit line that the FTL asks for).
- **The native Python** links libraries of its own (OpenSSL, SQLite, libffi, xz,
  zlib, bzip2 and others). Their notices are in `PYTHON.json` of the full
  python-build-standalone archive, not in the `install_only` one that MacSW uses.
