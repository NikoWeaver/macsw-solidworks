# The SpatialIOP fix

Date: 2026-10-25. Branch `team-c1`, based on `rc23` (`3873d67`). This is change C1 of the sharing
plan (`solidworks-mac/docs/sharing-plan.md`). It lets MacSW install SOLIDWORKS 2026 from unmodified
media. Before this change, the core MSI ended with exit code 67 on unmodified media.

## 1. The problem

- The SOLIDWORKS 2026 core MSI (`swwi/data/solidworks.msi`) runs the custom action
  `InstallSpatialIOP`. It unzips `swwi/data/spatialiop.zip` (the Spatial InterOp CAD import
  libraries) into `[SPIOP]files`, that is `<INSTALLDIR>\spiop\files`.
- The action uses the Windows shell's zip folder. Wine has no zip folder (WineHQ bug 17368). The
  action fails, and msiexec returns 1603. `Process.terminationStatus` keeps only the low 8 bits, so
  MacSW sees 67.
- Three actions belong together in `InstallExecuteSequence`:

  | Action | Sequence | Condition | Custom action (type, source, target) |
  |---|---|---|---|
  | `CopySpatialIOP` | 6543 | `NOT REMOVE~="ALL"` | 1, `SwInst`, `WIDll_CopySpatialIOP` |
  | `set_InstallSpatialIOP` | 6544 | `NOT REMOVE~="ALL"` | 51, `InstallSpatialIOP`, `[SpatialIOPTempFile];$[SPIOP]files` |
  | `InstallSpatialIOP` | 6545 | `NOT REMOVE~="ALL"` | 3073 (deferred, no impersonation), `SwInst`, `WIDll_InstallSpatialIOP` |

- The owner's earlier fix was manual: a media copy (`~/SW2026-mac`) whose MSI has the condition `0`
  for the three actions, and `tools/install_spatialiop.sh` after the install.

## 2. No command-line property can switch the actions off

Sharing plan C1, item 3, asked for this check first. The answer is no.

- All three conditions are `NOT REMOVE~="ALL"`. The only property in them is `REMOVE`. The only
  value that makes the condition false is `REMOVE=ALL`, and that uninstalls the product.
- `set_InstallSpatialIOP` is a type 51 action. It sets the `InstallSpatialIOP` property (the
  deferred action's data) at run time. A value given on the command line is overwritten.
- So MacSW must change the table. This is item 1 of the plan.

Evidence (all reads were read-only, with `tools/msi_inspect.sh` in a scratch Wine prefix):

- Unmodified media: `~/SW2026/swwi/data/solidworks.msi`, 63,878,144 bytes, SHA-256 `6efa9d2f…`.
- Hand-patched copy: `~/SW2026-mac/swwi/data/solidworks.msi`, 66,315,776 bytes, SHA-256 `9092f7ca…`.
- The two differ in exactly three cells: the `Condition` of the three actions above (`0` in the
  copy). The `CustomAction` and `Property` tables are the same.
- The MSI writes `Setup\SolidWorks Folder` as `[INSTALLDIR]` (Registry table). The Directory table
  has `SPIOP = INSTALLDIR\spiop` and `IOPFILES = SPIOP\files`. The only component in `SPIOP` is
  `sldimport.exe`; nothing is installed in `spiop\files`, so that folder holds only the zip's files.

## 3. What MacSW does now

### 3.1 Before the core MSI: MacSW's own copy of the MSI

`SpatialIOPService.prepareCorePackage` (step "Silently deploy the SOLIDWORKS core"):

1. It makes a stage in the bottle: `drive_c/MacSW/InstallMedia`. The stage mirrors the media root
   with symbolic links: every top-level entry, every entry of `swwi`, every entry of `swwi/data`.
   It holds one real file: a copy of `swwi/data/solidworks.msi`, mode 0644 (ISO media gives
   read-only copies). The cabinets stay on the media. The copy costs one file of 64 MB, and all
   paths from the MSI back into the media still resolve.
2. It runs `Resources/helpers/msi_spatialiop.exe C:\MacSW\InstallMedia\swwi\data\solidworks.msi`
   under Wine in the bottle. The output goes to `logs/spatialiop.log`.
3. msiexec installs the copy, in silent mode and in wizard mode. The media is only read.
4. The stage stays in the bottle. Windows Installer records it as the source for repairs. It goes
   to the Trash or away with the bottle.

The stage is rebuilt for every install. Removing it removes the links and never follows them (unit
test). When the media copy of the sharing plan (C0.4) exists, the links point into that copy.
Nothing else changes.

### 3.2 The helper `msi_spatialiop.exe`

Source `native/msi_spatialiop.c`, built by `scripts/build_msi_spatialiop_helper.sh` with MinGW
(`-lmsi`, stripped, no time stamp, so the same source gives the same file). `package_app.sh` builds
it on every run and copies it to `Contents/Resources/helpers/`. `verify_app.sh` checks it.

It opens the copy with `MsiOpenDatabaseW` in transact mode and finds the three actions by name. It
changes only what it knows:

- a condition must be `NOT REMOVE~="ALL"` (it becomes `0`) or `0` (left alone);
- each `CustomAction` row must have the type, source and target in section 1.

Then it runs one `UPDATE … SET Condition='0'` per action, calls `MsiDatabaseCommit`, opens the file
again read-only and checks that all three are `0`. It prints one line per action, for example
`InstallSpatialIOP: condition 'NOT REMOVE~="ALL"' -> '0'`. `--check` only reports.

| Exit code | Meaning | What MacSW does |
|---|---|---|
| 0 | All three are off (now or already before) | Installs the copy, then extracts the payload |
| 3 | The MSI has none of the three actions | Installs the media's own MSI unchanged; the SpatialIOP step is "Skipped" |
| 4 | Some of the three are missing | Stops before msiexec: "MacSW does not know this SOLIDWORKS installer" |
| 5 | A condition is not one of the two known values | Same |
| 6 | A custom action row is not the known one | Same |
| 7 | The database could not be opened, changed or committed | Stops before msiexec, with the exit code |
| 8 | `--check` only: the actions are still on | — |

Exit code 3 keeps other media working: an MSI without these actions does not have the problem.
Codes 4 to 6 commit nothing (the fixture tests check that the file stays byte-identical).

### 3.3 After the core MSI: the payload

New install step "Add the SpatialIOP files (CAD import)", right after the core MSI.
`SpatialIOPService.installPayload` replaces `tools/install_spatialiop.sh`:

1. The bundled `Contents/MacOS/7zz` lists the media's `spatialiop.zip` (`l -slt -ba`). The listing
   is the reference. There are no fixed counts in the code.
2. Members with an absolute path, a `..` part, a backslash or a link type are refused.
3. The destination is `<SolidWorks Folder>\spiop\files`. `SolidWorks Folder` is read from
   `system.reg`, only from the section `Software\[Wow6432Node\]SolidWorks\SOLIDWORKS <year>\Setup`
   (the newest year, the 64-bit key first). Lines of all other keys, the `Licenses` key among them,
   are skipped and never parsed or kept. Only `C:` paths without `.` or `..` parts are accepted.
4. When every folder and every file of the listing is already there with the right size, nothing is
   extracted. Otherwise MacSW checks the free space and runs `7zz x -aoa -y` into the destination.
5. Then it checks every folder, every file and every size against the listing again. A difference
   stops the install with the first difference named; the first 20 go to `spatialiop.log`.

### 3.4 The retry rule

Windows Installer caches the package it installs (`drive_c/windows/Installer/<hex>.msi`). For the
same ProductCode it uses that cached copy again, even when MacSW points at a newly edited MSI. So a
failed core install fails again in the same bottle. The rule (plan C1, item 4): a failed core install
in a bottle that was never activated is retried in a fresh bottle, and the old bottle goes to the
Trash.

MacSW must not read licence or activation files. So "never activated" becomes "SOLIDWORKS never
started in this bottle". Activation happens in SOLIDWORKS or in the wizard that SOLIDWORKS starts.
`CoreInstallRetry` keeps two files in the bottle root (like `.macsw-held`):

- `.macsw-solidworks-never-started`: written when the installer makes a new bottle. It is removed
  before anything starts in the bottle that is SOLIDWORKS or can start it: MacSW's launch,
  SOLIDWORKS.app's launch, a document hand-off, the SWCLI daemon, the Wine tools and CMD.
- `.macsw-core-install-incomplete`: written just before the core msiexec starts. It is removed only
  when that msiexec succeeds. A failure, a cancel or a crash leaves it.

At the next start, MacSW uses a fresh bottle only when both files exist and there is no
installation receipt (`installation-complete.json`). It stops the bottle's Wine processes and moves
the bottle to the Trash with `FileManager.trashItem`. Nothing is deleted. The Wine upgrade check
does not block this: a failed core install never reaches the baseline record, so
`WineRuntimeService.status` reports `baseline`, not `upgrade`, also after a MacSW update.

Each condition fails safe:

- A bottle made before this change has no never-started file. The rule never replaces it, also
  after a failed core install. Use Clean install for such a bottle, after a deactivation if it was
  activated.
- A bottle in which SOLIDWORKS started is kept, even if the core install failed later.
- A bottle with a receipt is kept.

What the user sees:

- Before Start, the install window shows: "The last SOLIDWORKS install in this bottle failed.
  Windows Installer keeps the failed package in the bottle and would use it again, so MacSW moves
  this bottle to the Trash and installs into a fresh bottle. SOLIDWORKS never started in this
  bottle, so it was never activated." `--headless-install` prints the same line.
- A core failure message ends with "Start the install again: MacSW then moves this bottle to the
  Trash …" when the rule applies to the next start.
- The environment step says "the bottle of the failed install is in the Trash".

## 4. How it was tested

Unit tests (all pass on this branch):

- Swift (XCTest shim, all files except `BootstrapStoreLifecycleTests`): 353 tests, 0 failed. New:
  `SpatialIOPTests` (stage layout, link removal never touches the media, media spelling, `C:`
  paths, helper exit codes, zip listing, unsafe members, the check against the listing, the Setup
  key only, the destination, the step order) and `CoreInstallRetryTests` (the decision table, the
  markers, the window note). `AppBundleLaunchTests` checks that SOLIDWORKS.app's start ends the
  never-started state.
- Python (`python3 -m unittest discover -s scripts/tests`): 319 tests, 6 skipped. The 6 skipped are
  the helper fixture tests in `test_msi_spatialiop.py`. They need Wine. Run them with:

  ```sh
  MACSW_TEST_WINE_RUNTIME=<project>/runtime/wine-11.16-macsw \
    python3 -m unittest scripts.tests.test_msi_spatialiop -v
  ```

  They build the helper with MinGW, make small MSIs with Wine's `msidb`, and check: the edit and a
  second run, a partly edited MSI, an MSI without the actions (exit 3), a missing action (4), an
  unknown condition (5) and an unknown custom action (6). Refused files stay byte-identical. All 8
  passed: 29 s with the command above (a temporary prefix), 78 s with `MACSW_TEST_WINE_PREFIX` set
  to an existing scratch prefix.

Checks on the real media (scratch prefix and a scratch bottle under `build.nosync/team-c1`, never
the real bottle):

- `SpatialIOPService.prepareCorePackage` on `~/SW2026`: the stage mirrors all 160 entries of
  `swwi/data`; the helper changed 3 of 3 actions; 2.2 s. The media MSI kept its SHA-256.
- The staged copy and the hand-patched `~/SW2026-mac` MSI are equal in all 63 non-empty tables (70
  tables), the 52 stream names and the summary information (the PackageCode did not change).
  Against the unmodified MSI, only `InstallExecuteSequence` differs.
- `SpatialIOPService.installPayload` with a `system.reg` that has only a Setup and a Licenses
  section: 11,547 members, 11,476 files and 71 folders, 2,048,172,990 bytes, in 13 to 15 s. These
  are the shell script's fixed counts, found from the listing. A second run extracted nothing
  (1.3 s). After one file was cut to 0 bytes and one deleted, the next run extracted again and the
  check passed.

Not tested yet: a full install from the unmodified media in a fresh bottle (see section 5).

## 5. The end-to-end test that is still to do

Conditions: a fresh macOS user (or a Mac without a MacSW bottle), at least 25 GB free, the
unmodified media. Never activate: at the first start answer "activate later". Never type the
serial into a log or a chat.

`MacSW --headless-install` uses `~/Library/Application Support/MacSW`, the bottle of the user who
runs it. Run it only as a test user:

```sh
chmod 600 ~/sw-serial     # the serial file, mode 0600, owned by the test user
/Applications/MacSW.app/Contents/MacOS/MacSW --headless-install \
  --media "<unmodified media folder>" --serial-file ~/sw-serial --windows-version win11
```

Pass: exit 0; step 7 "Add the SpatialIOP files" completed; `logs/spatialiop.log` shows
`changed 3 of 3` and `payload extracted and checked`; `spiop/files` is in the SOLIDWORKS folder;
SOLIDWORKS starts; Simulation loads. To test the retry rule, stop the install during the core MSI,
start again, and check that the old bottle is in the Trash.

## 6. Limits

- Until C0.4 exists, msiexec reads the cabinets from the media through the links, as before this
  change. Media on Box is read in place.
- Only MacSW's own start paths remove the never-started file. A Windows program started in another
  way (for example `wine` in a terminal, or a SOLIDWORKS.app from a build before this change) does
  not. Update SOLIDWORKS.app together with MacSW.
- A new SOLIDWORKS release or service pack can change these actions. The helper then refuses
  (codes 4 to 6), and the table in section 1 must be checked again.
