# Changes from upstream MacSW

This tree is a modified version of MacSW by YJBeetle
(<https://github.com/YJBeetle/MacSW>). It is based on upstream commit `69c5509`.
It is not an official MacSW release.

The Apache License 2.0 (section 4(b)) asks that changed files say that they were
changed. A copy of this tree without its git history does not show this per file,
so this list names the changed areas. `git diff 69c5509` gives the details.

## Removed

- The managed FlexNet licence code, the serial discovery and the CI that used
  them: `MacSWCI`, `MacSWCIRuntime`, `FlexNet*`, `SerialDiscoveryService`,
  `SerialNumber*` and their tests, and the runtime scripts in `scripts/ci`.
  MacSW uses only Dassault's own activation or a real licence server.
- The SWCLI submodule (`Dependencies/SWCLI`). The build leaves SWCLI out by
  default (`MACSW_SKIP_SWCLI=1`).

## Wine (`patches/wine-crossover`)

- Patches 0001-0015 are upstream's. This fork adds 0016-0025, 0028, 0030 and
  0032-0037: memory release on macOS, msync, cross-process window surfaces,
  comctl32 header layout, the ws2_32 computer name, msxml3 XMLHTTP bodies and
  empty elements, the macOS file dialogs (winemac.drv, comdlg32), the app-bundle
  host, wbemprox IPEnabled, opengl32 batching, two start-up caches, the
  wineserver window walks, no App Nap for Wine apps, Apple's multithreaded GL
  engine and GLU NURBS curves and surfaces in glu32.
- New in 0.2.0-rc.2 (the RC3 changes): 0023 matches the file filters of the
  Open panel without `fnmatch`, so a filter can no longer make the panel hang;
  0035 (App Nap), 0036 (multithreaded GL engine; `MACSW_GL_MPENGINE=0` turns it
  off) and 0037 (glu32 NURBS: a spline or an ellipse in a sketch no longer ends
  SOLIDWORKS with an assert) are new.
- `scripts/build_winemac.sh` builds the extra modules, both architectures, and
  wineserver. For 0037 it builds only the x86_64 `glu32.dll`.

The patches of this fork, by file name:

- `0016-ntdll-macos-release-decommitted-memory.patch`
- `0017-ntdll-server-msync.patch`
- `0018-win32u-cross-process-window-surfaces.patch`
- `0019-comctl32-header-layout-null.patch`
- `0020-ws2_32-resolve-own-computer-name.patch`
- `0021-msxml3-xmlhttp-send-domdocument.patch`
- `0022-msxml3-expand-empty-elements.patch`
- `0023-winemac-native-file-dialogs.patch`
- `0024-comdlg32-native-file-dialogs.patch`
- `0025-winemac-app-bundle-host.patch`
- `0028-wbemprox-ipenabled-needs-mac-address.patch`
- `0030-opengl32-batch-immediate-mode-calls.patch`
- `0032-windowscodecs-cache-component-registry.patch`
- `0033-kernelbase-local-module-reads.patch`
- `0034-server-unlinked-window-walks.patch`
- `0035-winemac-app-nap-defaults.patch`
- `0036-winemac-multithreaded-gl-engine.patch`
- `0037-glu32-nurbs.patch`

## The app (`macos/Bootstrap`)

- New: SOLIDWORKS.app (`Sources/SolidWorksLauncher`), shipped inside MacSW.app;
  folder consent before Wine starts; drive letters for the home and cloud
  folders; the bottle gate; the VBA 7.1 prerequisite; headless install; opening
  documents from Finder and the Dock; the diagnostics export.
- Changed: install, launch and maintenance code in `Sources/MacSWCore`; the
  menu bar panel, Settings and the install window in `Sources/MacSWApp`; the
  user-facing text is in English; logs are private (0700/0600) and have no serial.
- New for the team release (0.2.0-rc.1): the team setup window (the preflight,
  the team config `macsw-team.json`, the media search and the local media copy
  with its manifest check, the one-field access key, the VBA hash check); the
  SpatialIOP fix (MacSW's edited copy of the core MSI and the payload step,
  `CoreInstallRetry`); the download-flag question at the first start.
- New in 0.2.0-rc.2 (the RC3 changes): one SOLIDWORKS start at a time per
  bottle (a start lock that MacSW and SOLIDWORKS.app share,
  `Support/StartLock.swift`); SOLIDWORKS.app passes `MACSW_APP_SUPPORT` and
  `MACSW_HOST_APP` to the Wine host when they are set, so a Finder open on a
  test instance stays in its own bottle; MacSW passes `MACSW_GL_MPENGINE` to
  Wine.
- New in 0.2.0: an alert at launch and on a Dock click when the bottle's Wine
  record blocks SOLIDWORKS, with Back Up and Upgrade Bottle for a pending
  upgrade (`WineRuntimeLaunchPrompt`, `RuntimeStore.waitForWineMaintenance`).

## Build and packaging

- `scripts/package_app.sh`, `scripts/verify_app.sh`, `scripts/lib`: the stable
  signing identity, BuildManifest hashes for every replaced module and
  wineserver, the source commit, the source offer (`SOURCE.txt`) and
  `THIRD_PARTY_NOTICES.txt` (from `config/third-party-notices.tsv`).
- New: `scripts/package_solidworks_app.sh`, `scripts/verify_solidworks_app.sh`,
  `scripts/stage_source_release.sh`, `scripts/third_party_notices.py`,
  `scripts/diagnostics/`, `native/`, `third_party/libinotify-kqueue`.
- `resources/`: `Info.plist.in` changed; `SOLIDWORKS-Info.plist.in` and the
  third-party licence texts added.
- New for the team release: `scripts/package_dmg.sh` and `resources/dmg/` (the
  DMG, `Read Me First.txt`, `install-helper.sh`), `scripts/make_media_manifest.sh`,
  `scripts/build_msi_spatialiop_helper.sh` and `native/msi_spatialiop.c`; the
  release values `APP_VERSION`, `APP_BUILD` and `APP_RELEASE` in
  `config/versions.env`.
- New in 0.2.0-rc.2 (the RC3 changes): `scripts/lib/strip_pe.sh`.
  `package_app.sh` strips the 16 PE modules that MacSW rebuilds (about 60 MB
  less; `MACSW_STRIP_PE=0` keeps the symbols), and `verify_app.sh` checks them.
  `scripts/macho_func_cmp.py` compares the functions of two builds of a Mach-O
  module.
- New in 0.2.0: `third_party/stdole-clean`, a clean-room `stdole.dll`
  (LGPL-2.1-or-later, from Wine's `stdole2.idl`). It replaces Microsoft's file
  from the NuGet package stdole, which upstream downloads at build time and
  whose licence terms allow no distribution. `make fetch-stdole` now only checks
  the SHA-256 of the file in the tree.
- New for publication: `scripts/ci/publication_scan.py`,
  `scripts/make_public_tree.sh`, `scripts/ci/public-tree-remove.txt` and
  `.github/workflows/publication-scan.yml`.
- `.github/workflows/build-app.yml`: changed with the CI removal above. Both
  workflows and `scripts/ci/signing-input.py` name this fork's repository; the
  build job runs only when it is started by hand until it is tested. The
  workflows and `scripts/ci/signing-input.py` use the branch `main`, not
  upstream's `master`.

## Documents

- `README.md`, `README.cn.md`, `NOTICE` (one line about this fork) and several
  files in `docs/` changed; new files in `docs/` describe the fork's changes.
- `README.md` is rewritten for this fork. New: `SECURITY.md`,
  `THIRD_PARTY_NOTICES.md`, `team/macsw-team.example.json`.
- The public tree leaves out `docs/runtime-ci.md`, `docs/TODO.md`,
  `docs/superpowers/`, `.codex/`, `README.cn.md`, `docs/rc3-team.md` and
  `docs/rc3.md` (`scripts/make_public_tree.sh`).

## Changed files by area

From `git diff --name-status 69c5509` on the branch this tree was made from,
before the paths above were left out. Top-level files: `CHANGES-FROM-UPSTREAM.md`,
`SECURITY.md` and `THIRD_PARTY_NOTICES.md` are new; `Makefile`, `NOTICE`,
`README.md` and `README.cn.md` changed; `.gitmodules` is removed.

| Area | Added | Changed | Removed |
|---|---|---|---|
| `.github` | 1 | 2 | 0 |
| `Dependencies` | 0 | 0 | 1 |
| `config` | 1 | 1 | 0 |
| `docs` | 14 | 8 | 0 |
| macos/Bootstrap (other) | 0 | 2 | 0 |
| `macos/Bootstrap/Sources/MacSWApp` | 2 | 10 | 0 |
| `macos/Bootstrap/Sources/MacSWCI` | 0 | 0 | 1 |
| `macos/Bootstrap/Sources/MacSWCIRuntime` | 0 | 0 | 1 |
| `macos/Bootstrap/Sources/MacSWCore` | 26 | 29 | 7 |
| `macos/Bootstrap/Sources/SolidWorksLauncher` | 1 | 0 | 0 |
| `macos/Bootstrap/Tests/MacSWCoreTests` | 21 | 14 | 6 |
| `native` | 2 | 0 | 0 |
| `patches/wine-crossover` | 18 | 0 | 0 |
| resources (top level) | 1 | 1 | 0 |
| `resources/dmg` | 2 | 0 | 0 |
| `resources/licenses` | 16 | 1 | 0 |
| scripts (top level) | 12 | 9 | 0 |
| `scripts/ci` | 2 | 3 | 7 |
| `scripts/diagnostics` | 11 | 0 | 0 |
| `scripts/lib` | 2 | 1 | 0 |
| `scripts/swcli` | 0 | 3 | 0 |
| `scripts/tests` | 28 | 10 | 2 |
| `team` | 1 | 0 | 0 |
| `third_party` | 2 | 0 | 0 |
| top-level files | 3 | 4 | 1 |
