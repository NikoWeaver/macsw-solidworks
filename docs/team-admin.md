# Team setup: the team folder, the team config and the media copy

This page is for the team admin, and for the developers of the team first-run wizard. It covers
the parts that exist now: the team config `macsw-team.json`, the wizard window (the preflight, the
media search, the access key), the local media copy and the VBA check. The MSI fix comes later.

## The team folder

Make one folder in Box and share it with the team as **Viewer**. Give **Editor** to one or two
admins only. Do not make a public link.

```
MacSW/                                   the team folder
├── macsw-team.json                      the team config (below)
├── Start here.pdf                       the member steps
├── releases/                            MacSW-x.y.z.dmg, SHA256SUMS
└── media/
    └── SOLIDWORKS 2026 SP04.1/          the media, unchanged
        ├── setup.exe, swwi/, sldim/, PreReqs/, ...
        ├── PreReqs/VBA/vba71.msi, vba71_1033.msi   the two files of "The VBA MSIs"
        └── media-manifest.sha256        made with the command below
```

Never put a serial number in the team folder or in `macsw-team.json`. MacSW never reads one from
there. The member types the serial in MacSW (the "access key"), and MacSW does not keep it.

## The VBA MSIs

SOLIDWORKS needs Microsoft VBA 7.1 for equations and macros. Copy these two files into the
media's `PreReqs/VBA` folder before you make the manifest:

| File | SHA-256 |
|---|---|
| `vba71.msi` (6,266,880 bytes) | `08069ec9dfa56d1cdac335ec297451573e1ca8742ecbb358e20ae5be6e9feeee` |
| `vba71_1033.msi` (2,793,472 bytes) | `7029661494d24a8b0cba0a176ceab0c18fa02c004288672f21c1f0cfc7a07955` |

They are the Microsoft-signed VBA 7.1.11.28 MSIs that the owner uses (`docs/vba-equations.md`,
section 1, in the project repository). Check them with `shasum -a 256 vba71*.msi`.

The team install looks for them in the media copy's `PreReqs/VBA`, then in the folder of
`vba.path`, then in the folder saved in Settings. It installs them only when both match these
values: every editor of the team folder can change its files, so the values are in the app.
MacSW checks the copies in the bottle, the files that msiexec reads, before the first msiexec.
Another file gives a warning on the last page: SOLIDWORKS installs, but equations and macros do
not work. The install without a team config and Settings > Maintenance > Install VBA do not check
(official media can carry another VBA build, for example 7.1.11.35). To use another VBA build in
the team, add its values to `VBAPrerequisite.knownSHA256` and release a new MacSW.

## Make the manifest

Run this once for each media folder, on your own Mac, before you upload the folder. Add the VBA
MSIs first: files that you add after the manifest are not copied to the members' Macs.

```sh
scripts/make_media_manifest.sh "$HOME/SW2026"
```

The script writes `media-manifest.sha256` into the folder. It lists every regular file below the
folder with its SHA-256, sorted by path. It leaves out hidden files and folders (names that start
with a dot), links and the manifest itself. It stops if a file name has a `\` or a line break.
The last line it prints is the SHA-256 of the manifest. Put this value into `macsw-team.json` as
`media.manifestSHA256`.

Make the manifest again, and update the config, after every change to the media.

One ISO instead of a folder: put the ISO alone in a folder, run the script on that folder, and
name the folder in `media.path`.

## The team config: `macsw-team.json`

Start from `team/macsw-team.example.json`.

```json
{
  "schema": 1,
  "team": "Robotics team",
  "solidworks": { "release": "2026 SP4.1", "build": "34.4.1.1011" },
  "media": {
    "path": "media/SOLIDWORKS 2026 SP04.1",
    "manifestSHA256": "<the last line of make_media_manifest.sh>"
  },
  "vba": { "path": "media/SOLIDWORKS 2026 SP04.1/PreReqs/VBA" },
  "defaults": {
    "language": "en",
    "toolbox": false,
    "driveLetters": true,
    "macFileDialogs": "all",
    "launchSolidWorksAtStart": false
  },
  "install": { "showOtherKeys": false, "showLicenseServer": false },
  "updates": { "feed": "releases/latest.json" },
  "support": { "contact": "Ask in the team CAD channel", "guide": "Start here.pdf" }
}
```

| Key | Needed | Rule |
|---|---|---|
| `schema` | yes | `1`. A higher number tells the member to get a newer MacSW. |
| `team` | yes | Shown to the member. |
| `solidworks.release` | yes | Shown to the member, and the name of the local copy's folder. At most 64 characters, no `/`, `\` or `:`, not starting with a dot. |
| `solidworks.build` | no | For information. |
| `media.path` | yes | The media folder. |
| `media.manifestSHA256` | yes | 64 hex digits: the SHA-256 of the folder's `media-manifest.sha256`. |
| `vba.path` | no | The folder with `vba71.msi` and `vba71_1033.msi`, used when the media has no `PreReqs/VBA`. |
| `defaults.*` | no | `driveLetters`, `launchSolidWorksAtStart`: true or false. `macFileDialogs`: `"all"`, `"1"` or `"off"`. `language`: a language code such as `"en"`, `"de"` or `"zh-Hans"`, the SOLIDWORKS language of the team install (`"en"` adds no language pack; an unknown code keeps the Mac's own language). `toolbox` is read, but not used yet. |
| `install.showOtherKeys` | no | `true` shows the Simulation, Motion and MBD serial fields on the access key page. Default `false`. |
| `install.showLicenseServer` | no | `true` shows the licence server choice on the access key page. Default `false`: no licence server is written. |
| `updates.feed` | no | Not used yet. |
| `support.contact` | no | Shown under the access key field. |
| `support.guide` | no | Not used yet. |

Rules:

- **Paths are relative** to the folder that holds `macsw-team.json`. MacSW refuses absolute paths,
  paths with `~`, `\` or `..`, and links that lead out of the team folder.
- **Unknown keys are ignored.** A key with the wrong type, a missing key or a bad value stops the
  wizard with a message that names the key.
- **Defaults are defaults.** When MacSW imports the config, it writes a team default only into a
  setting that the member has not set. A member's own choice in Settings stays. A changed default
  in a later config does not change a setting that was already written.
- **The checks are in the app.** Every editor of the team folder can change the config, the media
  and the manifest. The manifest check finds a partial download, a Box placeholder that did not
  load, and media of another version than the config names. It does not prove who made the files.

### Where MacSW looks for it

In this order. The first valid config wins. If MacSW finds only invalid configs, it shows the
problem of the first one.

1. The imported copy, `~/Library/Application Support/MacSW/team.json`. Paths in it stay relative
   to the team folder that it came from (MacSW keeps that folder in the preference
   `MacSW.teamFolder`).
2. The folder that holds MacSW.app. If MacSW runs from a DMG: the folder of the DMG, and the folder
   above it (the DMG is in `releases/`).
3. `~/Downloads/macsw-team.json`.
4. `~/Library/CloudStorage/Box-*/MacSW/macsw-team.json` and
   `~/Library/CloudStorage/Box-*/<top-level folder>/MacSW/macsw-team.json`. MacSW looks at names
   only. It does not search deeper in Box.

If nothing is found, the member chooses the team folder (or the file) in a folder panel.

macOS asks the member before MacSW can read Downloads or Box. MacSW opens these folders from its
own code first (`FolderConsentService`), so the prompt appears while no Wine program waits.

## On the member's Mac

### The wizard

When SOLIDWORKS is not installed, MacSW opens the team setup. It has three pages:

1. **Check.** MacSW checks this Mac (below). Then a short text says that MacSW looks for the team
   folder in Downloads and in Box, and that macOS asks whether MacSW may open these folders. The
   member clicks **Continue**, then **Allow**. MacSW shows the team and the media it found, for
   example "Found SOLIDWORKS 2026 SP4.1 in your team folder, 9.2 GB". When the preflight passed and
   both were found, the next page opens by itself. If nothing is found, the member clicks
   **Choose Team Folder…**, or **Install Without Team Folder** for the install window as before.
   With a config imported earlier, MacSW searches at once (no new prompt).
2. **Access Key.** One field for the team's SOLIDWORKS serial, with **Paste**. The format check
   wants six groups of four letters or digits; spaces and hyphens between the groups are fine.
   The page says that the team lead gives the key and that MacSW does not save it. The other
   serial fields and the licence server choice appear only when the config shows them.
3. **Install.** MacSW keeps the team config (the import), copies the media when it is not on this
   Mac yet, then installs as before: silent, with the access key, VBA from the known MSIs, and the
   team language. If the copy stops, **Try Again** goes on where it stopped. If the install fails,
   **Adjust Options and Retry** returns to the access key page.

The access key stays in memory only. MacSW gives it to msiexec and removes it from the MSI log. It
does not write it to a file, a log, the preferences or the team config, and it forgets it when the
install has finished. After the install, the window opens as the install window (a reinstall from
Settings); **Team Setup…** returns to the team setup.

### Preflight

| Check | Blocks the install when |
|---|---|
| Apple silicon | the Mac has an Intel processor |
| macOS | the version is older than 13, or 28 or later (macOS 28 keeps only a part of Rosetta) |
| Rosetta | `arch -x86_64 /usr/bin/true` fails. MacSW opens Apple's Rosetta installer, and the member answers Apple's dialog. If it does not open, the member runs `softwareupdate --install-rosetta` in Terminal. MacSW never accepts Apple's licence for the member. |
| Free disk space | less than 40 GB is free. A media copy that is already on the Mac counts as free. |
| Memory | never; less than 16 GB gives a note |

### Finding the media

In this order: a finished local copy of the team's release; the team config's `media.path`;
`~/Downloads` and its first-level folders; the mounted volumes. Outside the team folder, only real
SOLIDWORKS media counts: a folder with `setup.exe` and `swwi/data/solidworks.msi`, or an ISO whose
name has "solidworks" or starts with "sw20" (for example `SW2026-SP04.1.iso`). The member can also
drop an ISO, `setup.exe` or a folder, as before. MacSW shows the size, for example
"Found SOLIDWORKS 2026 SP4.1 in your team folder, 9.2 GB".

### The media copy

With a team config, MacSW copies the media to
`~/Library/Application Support/MacSW/media/<release>/` and installs from that copy. It copies the
team folder's media, and also media found elsewhere when it has a `media-manifest.sha256`. Other
media is used where it is, as before.

- MacSW copies exactly the files that `media-manifest.sha256` lists, and checks the SHA-256 of
  each file while it copies. For the team folder's media, the manifest's own SHA-256 must match
  `media.manifestSHA256` first.
- A file is written as a hidden `.<name>.macsw-partial` and gets its real name only when its
  SHA-256 matches. If the copy stops (Cancel, a read error, Box offline, MacSW quit), the next start
  keeps the files that are in place and continues a partial file where it stopped.
- At the end MacSW writes the manifest and a receipt `.macsw-media-copy.json` into the copy. A
  later start with the same manifest uses the copy and does not need Box.
- Before it starts, MacSW checks that the copy fits and that 10 GB stay free for the bottle.
- MacSW keeps the copy: MSI repairs and add-ins read their source from it. **Remove installer
  copy** (in Settings, later) moves it to the Trash. Repairs then need the team folder again.

## For developers

`TeamSetupStore` (MacSWCore) drives the wizard, and `TeamSetupView` (MacSWApp) shows it inside
`BootstrapView`. The services are `PreflightService`, `TeamConfig` and `TeamConfigLocator`,
`InstallationMediaResolver.discover`, `MediaManifest`, `MediaCopyService`, `AccessKey` and
`VBAPrerequisite.checkKnownHashes`. The store's `page` is the page to show:

1. `.check`: `begin()` runs the preflight, and `search()` (Continue) the config and media search.
   With a config imported earlier, `begin()` searches by itself. `chooseTeamFolder(_:)`,
   `useDroppedMedia(_:)`, `findMedia()` and `runPreflight()` change the result; the page goes on
   to `.accessKey` when `isReady`. `useManualInstall(_:)` gives `.manual`, the old install window;
   `showTeamSetup()` comes back.
2. `.accessKey`: the field is `BootstrapStore.serialSolidWorks`, checked with `AccessKey.check`.
   Install is `install(into: bootstrapStore)`.
3. `.install`: `install(into:)` sets the team options on `BootstrapStore` (`silentInstall`,
   `requiresKnownVBA`, `teamVBAFolder`; it clears the hidden fields) and checks `startHint` before
   anything is copied. Then it imports the config, copies the media if `installMedia` is nil
   (`copyState`, `cancelCopy()`), calls `handOff(to:)` (the media and the language) and starts the
   install. `back()` returns to `.accessKey`. `finish(_:)`
   forgets the key when the install has finished.

Tests: `PreflightServiceTests`, `TeamConfigTests`, `InstallationMediaDiscoveryTests`,
`MediaCopyServiceTests`, `TeamSetupStoreTests`, `AccessKeyTests`, `VBAPrerequisiteTests`
(temporary folders only) and `scripts/tests/test_media_manifest.py`.

Not done yet: the team default for `toolbox`; a fresh import when the team folder has a newer
config than the imported copy; a local copy of an ISO stays an ISO (the MSI fix will need its
contents). The preflight counts the copies of every release in `media/` as free space; the copy's
own space check is the real gate.
