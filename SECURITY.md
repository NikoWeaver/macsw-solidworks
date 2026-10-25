# Security

This page says whom you trust when you use this fork, what MacSW reads and keeps, and how to report
a problem. MacSW here means the app of this repository (`MacSW.app`), a modified version of MacSW,
not an official MacSW release.

## Trust model

- **The builds.** The maintainer signs each build with a self-signed certificate, not with an Apple
  Developer ID. Apple does not check these builds. Use only a DMG from the team's Box folder
  `MacSW/releases`, and check it with `shasum -a 256 -c SHA256SUMS`. `install-helper.sh` and
  `scripts/package_dmg.sh` check that MacSW.app is signed with the pinned certificate (leaf
  `616428ae1195eb76e27758ae5b88122911551f7f`).
- **Wine is not a sandbox.** SOLIDWORKS, its add-ins and macros run with your user rights. They can
  read every file that your account can read, except the folders that macOS protects and that you
  did not allow. Install only add-ins and macros that you would run on Windows.
- **The team folder.** Every editor of the team folder can change `macsw-team.json`, the media and
  `media-manifest.sha256`. MacSW checks the manifest and the SHA-256 of the two VBA MSIs. These
  checks find a partial download or the wrong files. They do not prove who made the files. Give
  Editor rights to one or two admins. Members get Viewer.
- **Full Disk Access.** MacSW does not need it. Do not grant it unless your Box or iCloud folder
  stays unreadable after you click Allow: every Windows program in the bottle inherits that access.
- **SOLIDWORKS files.** MacSW does not change SOLIDWORKS program files and does not bypass
  licensing. It changes one thing of Dassault's: MacSW's local copy of the core installer database
  (`solidworks.msi`) gets the condition "never" for the three SpatialIOP actions, and MacSW then
  unpacks that payload itself (`docs/spatialiop-fix.md`). The media in the team folder stays
  unchanged.

## What MacSW reads

- The SOLIDWORKS media that you choose or that the team config names: a folder or an ISO.
- The team folder: `macsw-team.json`, `media-manifest.sha256` and `PreReqs/VBA`. To find the team
  config and the media, MacSW looks at the folder of the app or the DMG, `~/Downloads` and its
  first-level folders, the mounted volumes, and the names of the folders in
  `~/Library/CloudStorage/Box-*` (`docs/team-admin.md`).
- Desktop, Documents and Downloads, and Box, iCloud Drive or another cloud folder if you allow it.
  MacSW links them into the bottle, so that SOLIDWORKS can open your files. macOS asks you first.
- Its own folder `~/Library/Application Support/MacSW` (the bottle, the logs, the team config copy,
  the media copy, `drive-letters.json`) and its preferences (`com.yjbeetle.macsw`).
- The serial (the "access key") that you type.

## What MacSW never reads or keeps

- MacSW does not read serial numbers or licence files from next to the media or from the team
  folder.
- The serial stays in memory. MacSW gives it to msiexec once, as an MSI property, and removes it
  from `install_msi.log` and `installer-wine.log`. It does not write it to a file, a log, the
  preferences or the team config.
- MacSW never installs, starts or edits a FlexNet licence server or any licence file. It uses
  Dassault's own activation, or the address of a real SolidNetWork licence server that you enter.
- MacSW itself opens no network connection. SOLIDWORKS connects to Dassault for the activation and,
  unless you turn it off, for its Customer Experience Improvement Program (Tools > Options).
- **Export Diagnostics** makes a zip on your Desktop and uploads nothing. It never takes the
  bottle's registry, FLEXnet data, `INetCache`, crash dumps, `SWActivateRequest*`, `.lic` and `.tsf`
  files, model files, any file inside `drive_c`, or the environment of a process. It removes
  serial-shaped strings, e-mail addresses, MAC addresses, licence server addresses, user names and
  host names (`docs/diagnostics-export.md`). Look at the zip before you send it.

## Report a problem

- **A security problem**, for example a serial in a log or a diagnostics zip, or a build that does
  not pass the signature check: tell the team admin directly. Do not post it in a team chat or an
  issue.
- **Other problems:** open an issue in this repository, with a diagnostics zip that you have read.
- Never attach the serial, licence files, activation request files, a bottle or full MSI logs.
