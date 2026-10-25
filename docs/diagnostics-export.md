# Export Diagnostics

When something breaks, a member clicks **Export Diagnostics…** and sends the zip
to the team admin. MacSW saves `~/Desktop/MacSW-diagnostics-<date>.zip`. Nothing
is uploaded.

## Where the button is

- the menu bar panel, below **Show Log**;
- Settings > Maintenance > Diagnostics;
- the install window, after an install failed or was stopped.

MacSW first shows the list of files, then saves. A second export on the same day
gets `-2`, `-3`, and so on; an existing zip is never replaced. If MacSW may not
write to the Desktop, it offers a save panel.

## What is in the zip

From a fixed list of names (`DiagnosticsExport.plan`), only the files that exist:

| In the zip | From |
|---|---|
| `logs/sw_launch.log`, `logs/folder-consent.log`, `logs/sw_open.log`, `logs/solidworks-app.log`, `logs/install_msi.log`, `logs/spatialiop.log` | `~/Library/Application Support/MacSW/logs` |
| The logs of the other install steps: `wineboot.log`, `mono-runtime.log`, `managed-com-registration.log`, `registry-write.log`, `vcredist-x64.log`, `vcredist-wine.log`, `login-manager-install.log`, `login-manager-wine.log`, `vba71-install.log`, `vba71_1033-install.log`, `vba-wine.log`, `winecfg.log`, `installer-wine.log`, `install_msi_errors.log`, `language-install.log`, `language-wine.log`, `prerequisites.log`, `toolbox-path.log`, `toolbox-install.log` | the same folder |
| `runtime/migration.log`, `runtime/receipt.json`, `runtime/last-upgrade.json` | `~/Library/Application Support/MacSW/.bottle.wine-runtime` |
| `BuildManifest.plist` | `MacSW.app/Contents/Resources` |
| `system.txt` | macOS version, Mac model, processor, memory, free disk, Rosetta (`arch -x86_64 /usr/bin/true`), bottle state |
| `folder-access.txt` | The bottle's links to protected folders, and whether macOS let MacSW open each one in this session. Read from the links; no folder is opened, so no prompt appears. |
| `processes.txt` | The names of the bottle's processes. No arguments, no environment. |
| `install-status.txt` | Only from the install window: the install state, its message, and each step with its status and detail |
| `README.txt` | What is in the zip and what was removed |

A log larger than 32 MB keeps its last 32 MB.

Only the core msiexec gets the serial (as an MSI property). MacSW removes it by
value from `install_msi.log` and `installer-wine.log` when msiexec ends or the
install is stopped. If MacSW is force-quit during the core install, msiexec can
finish these two logs alone, and only the pattern rules below protect them.

Never included: the bottle's registry (`*.reg`), `drive_c/ProgramData/FLEXnet`,
`INetCache`, `CXPA`, `SWActivateRequest*`, `.lic` and `.tsf` files, model files,
any file inside `drive_c`, and the environment of a process.
`DiagnosticsExport.refusal` rejects these paths, and one refused file stops the
whole export.

The export starts no Wine program. So it never turns on `+msxml` or `+wininet`
traces, which print request bodies with the serial in them.

## What is removed

MacSW does not keep the serial after the install, so `DiagnosticsScrubber` works
by pattern:

| What | Rule | Becomes |
|---|---|---|
| Installer property lines | a line with `SERIALNUMBER` or `SERVERLIST` | dropped |
| Cloud folder names | the folders in `~/Library/CloudStorage` and the keys of `drive-letters.json`, then any `CloudStorage/<provider>-<account>` | the provider |
| Licence servers | `port@host` | `<server>` |
| E-mail addresses | the usual pattern | `<email>` |
| Serial-shaped strings | six groups of four letters or digits, with an optional space or hyphen | `<serial>` |
| MAC addresses | six hex pairs; `02:00:00:00:00:00` stays | `<mac>` |
| Home folder | `/Users/<name>`, `C:\users\<name>`, `Z:\Users\<name>` | `~`, `<user>` |
| Host names | the Mac's host names, Wine's computer name for it (first label, upper case, 15 characters), `ComputerName = …` | `<host>` |
| The user's names | the account name and the full name as words, `USERNAME = …`, `LogonUser = …` | `<user>` |

GUIDs, SHA-256 values and git commits stay. A GUID (8-4-4-4-12 hex digits) is
found first and kept whole, so its last groups are never taken for a serial. A
group that is part of a longer run of letters and digits is not a serial. A
hyphen next to a serial does not protect it: `SN-<serial>` and `<serial>-1`.

Look at the zip before you send it. The rules cover the known cases; a serial
in a form that is not six groups of four would not be found.
