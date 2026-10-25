# Release packaging: the DMG, the install helper and the download flag

This fork ships MacSW as a disk image. A member copies it from the team's Box folder, opens it and
drags MacSW onto Applications. The plan for this is section (d) and change C2 of the project's
sharing plan.

## Version numbers

`config/versions.env` has three release values:

| Key | Example | Used for |
|---|---|---|
| `APP_VERSION` | `0.2.0` | `CFBundleShortVersionString`. Numbers only. |
| `APP_BUILD` | `6` | `CFBundleVersion`. It only goes up, also between release candidates. |
| `APP_RELEASE` | `0.2.0-rc.2` | File names, git tags and `AppRelease` in `BuildManifest.plist`. |

`APP_RELEASE` is `APP_VERSION` for a release, or `APP_VERSION-rc.N` for a release candidate.
`scripts/lib/config.sh` refuses any other value. The three keys do not change the cache identity
(`scripts/ci/cache-identity.py`). A new SOLIDWORKS service pack is a new minor version (`0.3.0`).
The old labels "RC2", "rc23" and "RC3" belong to the `0.1.x` line.

`package_app.sh` writes `AppRelease` into `BuildManifest.plist`, and `verify_app.sh` checks it.
`make archive` writes `build/archive/MacSW-<release>-macOS.zip`.

## The disk image

```sh
make dmg                                      # build/app/MacSW.app -> build/dmg/
scripts/package_dmg.sh <MacSW.app> <folder>   # an app that is already built
```

`MACSW_SIGN_IDENTITY` must be set (and `MACSW_SIGN_KEYCHAIN` if the identity is in its own
keychain; unlock it first). The script makes:

```
<folder>/MacSW-<release>.dmg     UDZO, volume "MacSW <release>", signed
├── MacSW.app                    copied with ditto, not signed again
├── Applications -> /Applications
├── Read Me First.txt            from resources/dmg/ReadMeFirst.txt.in
├── install-helper.sh            resources/dmg/install-helper.sh
└── Licenses/                    the app's Resources/licenses and SWCLI/licenses
    ├── THIRD_PARTY_NOTICES.txt  the app's Resources/THIRD_PARTY_NOTICES.txt
    └── SOURCE.txt               the app's Resources/SOURCE.txt: where to get the exact sources
<folder>/SHA256SUMS              the SHA-256 of the signed image
```

`<release>` comes from the app's `BuildManifest.plist` (`AppRelease`, or `AppVersion` in older
builds). Thus the image always has the name of the build that is in it.

The script stops when:

- the app's signature is not valid (`codesign --verify --deep --strict`);
- the app is not signed with the certificate that `install-helper.sh` pins
  (`MACSW_CERTIFICATE_LEAF`, today `616428ae1195eb76e27758ae5b88122911551f7f`);
- the app has no `Resources/THIRD_PARTY_NOTICES.txt`. Builds from before the notices
  file need `MACSW_DMG_ALLOW_MISSING_NOTICES=1`. Never use that for a release;
- there is less free space than three times the size of the app.

After `hdiutil create` it signs the image, checks that the image is signed with the pinned
certificate, runs `hdiutil verify`, and then writes `SHA256SUMS`. Put the image and `SHA256SUMS`
in the Box folder `MacSW/releases`. The update feed `latest.json` is change C3; this script does
not write it.

## Before a DMG goes on a release

Scan the mounted image. Both scans must report 0 hits:

```sh
hdiutil attach -readonly -nobrowse -mountpoint <mount> <folder>/MacSW-<release>.dmg
python3 -I scripts/ci/publication_scan.py --list-volume <mount> > <list.txt>
MACSW_SCAN_TERMS=<terms file> python3 -I scripts/ci/publication_scan.py --file-list <list.txt>
python3 -I scripts/ci/publication_scan.py --home-paths <mount>
hdiutil detach <mount>
```

The file list has names only. `--home-paths` reads the bytes of every file and zip entry: a
module keeps the folder it was built in (debug information). `scripts/build_winemac.sh` maps
the checkout to `/macsw` (`-ffile-prefix-map`). The 0.2.0-rc.1 build was made before that
change: its 15 rebuilt Wine modules hold the build folder, so that image fails this check.
The file list scan fails while the app holds `Resources/managed/stdole.dll`: its licence
terms allow no distribution (`docs/licences-and-notices.md`, open items).

## The install helper

macOS blocks a downloaded `.command` file like the app. So the helper is a plain script that the
member runs with `bash`:

```sh
bash "/Volumes/MacSW <release>/install-helper.sh"
```

It prints each step before it runs it:

1. `codesign --verify --deep --strict` on `MacSW.app` next to the script, and a check that the
   signature satisfies `identifier "com.yjbeetle.macsw" and certificate leaf = H"616428ae…"`.
   The check tests the real certificate, not the text of the designated requirement.
2. It asks: "Copy MacSW to /Applications and remove the macOS download flag from MacSW only?
   [y/N]". Only `y` or `yes` is yes.
3. On yes: it stops if `/Applications/MacSW.app` exists and MacSW runs (a process named `MacSW`,
   or a process that runs from inside the installed bundle, such as its wineserver). Else it moves
   the old copy to `~/.Trash/MacSW <date time>.app`, then runs
   `ditto MacSW.app /Applications/MacSW.app`. `ditto` into an existing bundle would merge the
   files, so the old copy always goes first.
4. `xattr -dr com.apple.quarantine /Applications/MacSW.app`. Nothing else.
5. `open /Applications/MacSW.app`.

It uses no `sudo`, sets its own `PATH`, writes nowhere else and changes no setting. If the user
cannot write to `/Applications`, it says so and stops. The GUI path (Open Anyway) stays the
documented default in `Read Me First.txt`.

## The download flag at the first launch

Finder copies `com.apple.quarantine` from a downloaded image to every file of the app. "Open
Anyway" lets MacSW itself start, but the flag stays on the Wine loader, wineserver and 7zz, and
macOS can block those helpers. At launch, MacSW checks its own bundle folder for the flag
(`DownloadQuarantine` in MacSWCore). If the flag is there, MacSW asks:

> MacSW will remove the download flag from its own files so that macOS does not block its Wine
> helpers.

Buttons: **Remove Download Flag**, **Not Now**, and "Do not ask again"
(`MacSW.downloadFlagQuestionSuppressed`). On yes, MacSW removes the flag from every item in its
bundle and then from the bundle folder. Symbolic links are changed themselves and never followed,
so nothing outside the bundle changes. If an item cannot be changed, MacSW says so; the bundle
folder keeps its flag and the next launch asks again. The code signature does not cover extended
attributes, so it stays valid.

When macOS runs MacSW from a read-only random folder (App Translocation, for example when MacSW is
opened on the disk image), nothing can be removed. MacSW then tells the member to drag it onto
Applications and to open it from there.

The question comes before the first Wine process: the font check, the start of SOLIDWORKS and
documents opened from Finder wait for the answer.

## Tests

- `scripts/tests/test_dmg_packaging.py`: the helper (yes and no answers, signature failures, a
  running MacSW, the old copy in the Trash), the image layout, the order create, sign, verify,
  checksum, and the release label. All commands are fakes.
- `macos/Bootstrap/Tests/MacSWCoreTests/DownloadQuarantineTests.swift`: the decision, the removal
  in a temporary bundle with links that lead out of it, and a failed removal.

## Not done yet

- `Read Me First.txt` is plain text, so it has no pictures of the Open Anyway step.
- `Read Me First.txt` describes the 0.2.0-rc.1 build (rc3-team): no guided activation card, no
  time estimates and no update check yet. Change steps 4 to 7 and "After day one" when those
  features (sharing plan C0.7, C0.8, C3) are in the build.
