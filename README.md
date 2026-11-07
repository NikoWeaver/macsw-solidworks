# macsw-solidworks

The Windows version of SOLIDWORKS 2026 on an Apple Silicon Mac. The app (`MacSW.app`) installs
SOLIDWORKS from your official media and runs it with a patched Wine 11.16 and Wine-Mono, under
Rosetta 2.

This repository is based on [MacSW](https://github.com/YJBeetle/MacSW) by YJBeetle, upstream commit
`69c5509` (Apache License 2.0). It is a modified version, not an official MacSW release.
[CHANGES-FROM-UPSTREAM.md](CHANGES-FROM-UPSTREAM.md) lists what changed.

You bring your own SOLIDWORKS licence and your own official installation media. This repository
contains no SOLIDWORKS files, no serial numbers and nothing that bypasses licensing. SOLIDWORKS
activates through Dassault's own Activation Wizard, or uses a real SolidNetWork licence server.

> SOLIDWORKS is a registered trademark of Dassault Systèmes SolidWorks Corporation. This project is
> not affiliated with, endorsed by or supported by Dassault Systèmes. Dassault supports SOLIDWORKS
> 2026 on Windows 11 only. Do not ask Dassault support for help with this setup.

## Status

- Release **0.2.0** for **SOLIDWORKS 2026 SP4.1** (34.4.1.1011). Other service packs
  may not install.
- Works: install, activation, parts, assemblies, drawings, STEP and STL export and import, equations
  and macros (with VBA 7.1), opening files from Finder, the Mac file panel for Open and Save.
- A complete first install from unmodified media on a new Mac has not been tested from start to end
  yet. Report what happens (see [Help](#help)).
- Limits: see [Known limits](#known-limits).

## What you need

- An **Apple Silicon** Mac (M1 or later). Intel Macs are not supported.
- **macOS 13 to 27.** Do not upgrade to **macOS 28**: Apple keeps only a part of Rosetta there.
- **Rosetta 2.** MacSW opens Apple's installer if it is missing.
- **16 GB of memory** or more. 8 GB is not enough for real work.
- **40 GB of free disk space**: a copy of the media (9 to 20 GB), the Windows environment ("bottle",
  about 10 GB) and the app (about 1 GB).
- **Your own SOLIDWORKS 2026 licence**: a serial number (for example a student, school, company or
  maker licence), or the address of your SolidNetWork licence server.
- **The official SOLIDWORKS 2026 SP4.1 installation media**, as a folder or an ISO. Get it from your
  SOLIDWORKS reseller, school or company, or from your SOLIDWORKS customer portal account. Use the
  files unchanged.
- An internet connection for the activation.

## Install

1. **Get the app.** Download `MacSW-<version>.dmg` from this repository's
   [Releases](../../releases) page. If there is no release yet, build it yourself (see
   [Build from source](#build-from-source)). Optional check: `shasum -a 256 -c SHA256SUMS` in the
   folder that holds the DMG and `SHA256SUMS`.
2. **Install it.** Open the DMG. Drag MacSW onto **Applications**.
3. **Open it.** The first time only, macOS blocks it, because the app is signed with a self-signed
   certificate, not with an Apple Developer ID. Click **Done** (not Move to Trash). Open **System
   Settings > Privacy & Security**, scroll down, click **Open Anyway**, enter your Mac password, then
   click **Open**. When MacSW asks about the download flag, click **Remove Download Flag**.
   Or, in Terminal: `bash "/Volumes/MacSW <version>/install-helper.sh"`. The script shows each step
   and asks first. It uses no `sudo`.
4. **Choose your media.** Click **Install Without Team Folder**. Drop your media folder or ISO into
   the install window. When macOS asks whether MacSW may open a folder, click **Allow**.
5. **Enter your serial number** (or your licence server). Click **Install**. Keep the Mac on charge.
   This takes about 30 to 90 minutes. Click **Allow** when macOS asks about Desktop, Documents and
   Downloads.
6. **Done.** On the last page, click **Install SOLIDWORKS App**, then **Done**.
7. **Activate.** Start SOLIDWORKS. In the Activation Wizard, click **Activate now** >
   **Automatically over the internet** > your e-mail > **Finish**. Activate once. If it says that no
   activations are left, stop and ask your licence provider: each try can use an activation.

MacSW does not save your serial number. Never post it in a chat, an issue or a screenshot. Before you
wipe or sell your Mac, deactivate: in SOLIDWORKS, **Help > Licenses > Deactivate**.

## Daily use

- Start **SOLIDWORKS** from Applications, Launchpad or the Dock, like any other app. The first start
  after an install or update is slow once. Later starts take about 30 seconds.
- MacSW itself lives in the menu bar (the cube icon). Its menu has **Launch SOLIDWORKS**,
  **Settings** and **Export Diagnostics**.
- Double-click a `.sldprt`, `.sldasm` or `.slddrw` file in Finder to open it.
- File > Open and Save As use the normal Mac file panel.
- Your Desktop, Documents and Downloads are the same folders inside SOLIDWORKS
  (`C:\users\<you>\Desktop` and so on). Your home folder is `H:`; Box Drive is `B:` and iCloud Drive
  is `I:` when you use them.
- **Updates:** quit SOLIDWORKS and MacSW, then install a newer DMG the same way as the first one. If
  SOLIDWORKS then does not start, open the MacSW menu > **Settings > Maintenance** and click **Back Up
  and Upgrade Bottle…**. MacSW keeps a backup, and **Roll Back Last Upgrade…** on the same page goes
  back. MacSW does not check for updates by itself.
- Do not run SOLIDWORKS's own updater.

## Using it in a team or class (optional)

One person can prepare a shared folder (for example on Box) with the DMG, the media and a small
`macsw-team.json`. MacSW then finds the media by itself, and each member only enters the serial
number. See [docs/team-admin.md](docs/team-admin.md) and
[team/macsw-team.example.json](team/macsw-team.example.json). Each Mac uses one activation of the
licence, so check how many activations the licence allows.

## Known limits

- **Graphics:** keep **Enhanced Graphics Performance** off (Tools > Options > System Options >
  Performance). Rotating larger assemblies is slow. Use **Shaded** instead of Shaded with Edges, and
  turn off RealView, shadows and ambient occlusion if it feels slow.
- **Memory:** some sessions grow slowly while idle. If the Mac starts to swap, save, quit SOLIDWORKS
  and start it again.
- **File panel:** the Mac panel does not show SOLIDWORKS's own options pane in File > Open (open mode,
  configuration, display state), and has no "Open Read-only". Folder pickers still use Wine's browser.
- **Web panels** (WebView2) may stay blank.
- **Simulation** is installed but off at start: Tools > Add-Ins > SOLIDWORKS Simulation. Running a
  study is not tested.
- **Do not enable CircuitWorks.** It crashes SOLIDWORKS under Wine.
- **API:** `EquationMgr.Add3` returns -1; use `Add2`.
- **macOS 28** will probably end Rosetta support for this app.
- **Security:** Wine is not a sandbox. Windows programs, add-ins and macros run with your rights. See
  [SECURITY.md](SECURITY.md).

## Help

- **MacSW menu > Export Diagnostics…** makes a zip on your Desktop. It removes serial numbers,
  e-mail addresses, MAC addresses, user names and host names. Look at it before you send it to
  anyone, and attach it to an issue in this repository.
- Never send your serial, licence files or activation request files.

## Build from source

You need Xcode (Swift 5.10 or later), Homebrew `bison` and `mingw-w64`, and several GB of disk for
the Wine build tree.

```sh
git clone https://github.com/NikoWeaver/macsw-solidworks.git
cd macsw-solidworks
brew install bison mingw-w64
make fetch      # pinned Wine, Mono, 7-Zip, Python; hashes in config/versions.env
make app        # build/app/MacSW.app, with SOLIDWORKS.app inside
make test
make dmg        # build/dmg/MacSW-<release>.dmg; needs MACSW_SIGN_IDENTITY
```

Set `MACSW_SIGN_IDENTITY` to sign with a stable certificate. Without it the app is signed ad hoc,
and macOS asks again for its folder permissions after each rebuild. See
[docs/development.md](docs/development.md) and [docs/packaging.md](docs/packaging.md).

## Credits and licences

- Based on [MacSW](https://github.com/YJBeetle/MacSW) by YJBeetle, Apache License 2.0. See
  [LICENSE](LICENSE), [NOTICE](NOTICE) and [CHANGES-FROM-UPSTREAM.md](CHANGES-FROM-UPSTREAM.md).
- [Wine](https://www.winehq.org/) 11.16, LGPL 2.1 or later, from the
  [Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds). The patches in
  `patches/wine-crossover/` are LGPL 2.1 or later. The msync patch (0017) is ported from Marc-Aurel
  Zent's work in `marzent/winecx`.
- [Wine-Mono](https://github.com/wine-mono/wine-mono) 11.3.0 with YJBeetle's patched runtime;
  Wine Gecko 2.47.4 (MPL 2.0).
- [7-Zip](https://www.7-zip.org/) (LGPL 2.1, BSD 3-clause, unRAR restriction),
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone) (PSF),
  MoltenVK (Apache 2.0), libinotify-kqueue (MIT), and the libraries listed in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Source code:** `SOURCE.txt` in the app and in the DMG's `Licenses` folder names the source
  commit, this repository and the release tag, and the exact Wine source archive.
- Not affiliated with Dassault Systèmes, Microsoft, Apple or CodeWeavers.
