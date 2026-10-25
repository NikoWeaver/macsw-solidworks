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

- Release candidate **0.2.0-rc.2** for **SOLIDWORKS 2026 SP4.1** (34.4.1.1011). Other service packs
  may not install.
- The team install has not yet run from start to end on a member's Mac. Wait until your admin puts
  the build into the team's `releases` folder.
- Works: install, activation, parts, assemblies, drawings, STEP and STL export and import, equations
  and macros (with VBA 7.1), opening files from Finder, the Mac file panel for Open and Save.
- Limits: see [Known limits](#known-limits).

## What you need

- An **Apple Silicon** Mac (M1 or later). Intel Macs are not supported.
- **macOS 13 to 27.** Do not upgrade to **macOS 28**: Apple keeps only a part of Rosetta there, and
  the team setup refuses to install on it.
- **Rosetta 2.** MacSW opens Apple's installer if it is missing.
- **16 GB of memory** or more. 8 GB is not enough for real work.
- **40 GB of free disk space**: the media copy (9 to 20 GB), the Windows environment ("bottle",
  about 10 GB) and the app (about 1 GB).
- **The team's access key** (the SOLIDWORKS serial) from your team lead, or your own licence.
- An internet connection for the activation.

## Install (team members)

Your admin has a Box folder `MacSW` with the DMG in `releases/`, the media in `media/` and a small
`macsw-team.json`. `Read Me First.txt` on the DMG has the same steps with more detail.

1. **Get the app.** Copy `MacSW-0.2.0-rc.2.dmg` from `MacSW/releases` to Downloads. Optional check:
   `shasum -a 256 -c SHA256SUMS` in the folder that holds both files.
2. **Install it.** Open the DMG. Drag MacSW onto **Applications**.
3. **Open it.** The first time only, macOS blocks it, because the app is signed with the team's own
   certificate, not with an Apple Developer ID. Click **Done** (not Move to Trash). Open **System
   Settings > Privacy & Security**, scroll down, click **Open Anyway**, enter your Mac password, then
   click **Open**. When MacSW asks about the download flag, click **Remove Download Flag**.
   Or, in Terminal: `bash "/Volumes/MacSW 0.2.0-rc.2/install-helper.sh"`. The script shows each step
   and asks first. It uses no `sudo`.
4. **Confirm the media.** Click **Continue**. MacSW looks for the team folder in Downloads and in
   Box. When macOS asks whether MacSW may open these folders, click **Allow**.
5. **Enter the access key.** Type or paste it once. Click **Install**. Keep the Mac on charge. This
   takes about 30 to 90 minutes. Click **Allow** when macOS asks about Desktop, Documents and
   Downloads.
6. **Done.** On the last page, click **Install SOLIDWORKS App**, then **Done**.
7. **Activate.** Start SOLIDWORKS. In the Activation Wizard, click **Activate now** >
   **Automatically over the internet** > your e-mail > **Finish**. Activate once. If it says that no
   activations are left, stop and tell the admin: each try can use an activation.

MacSW does not save the access key. Never post it in a chat, an issue or a screenshot. Before you
wipe or sell your Mac, or leave the team, deactivate: in SOLIDWORKS, **Help > Licenses >
Deactivate**.

Without a team folder, click **Install Without Team Folder**. In the install window, drop your
media folder or ISO, type your serial and start the install.

## Daily use

- Start **SOLIDWORKS** from Applications, Launchpad or the Dock, or with **Launch SOLIDWORKS** in the
  MacSW menu. The first start is slow once. Later starts take about 30 seconds.
- Double-click a `.sldprt`, `.sldasm` or `.slddrw` file in Finder to open it.
- Your Desktop, Documents and Downloads are the same folders inside SOLIDWORKS
  (`C:\users\<you>\Desktop` and so on). Your home folder is `H:`, Box Drive is `B:`, iCloud Drive is
  `I:`.
- New builds: when the admin puts a new DMG in `releases/`, install it like the first one. MacSW
  does not check for updates by itself yet.
- Do not run SOLIDWORKS's own updater.

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
  e-mail addresses, MAC addresses, user names and host names. Look at it before you send it to the
  admin.
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

Set `MACSW_SIGN_IDENTITY` to sign with a stable certificate. See
[docs/development.md](docs/development.md) and [docs/packaging.md](docs/packaging.md). For the team
folder and `macsw-team.json`, see [docs/team-admin.md](docs/team-admin.md) and
[team/macsw-team.example.json](team/macsw-team.example.json).

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
  commit, this repository and the release tag, and the exact Wine source archive. For a team
  release, the source files are also in the team's Box folder `MacSW/releases`.
- Not affiliated with Dassault Systèmes, Microsoft, Apple or CodeWeavers.
