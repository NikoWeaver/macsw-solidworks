# macOS file dialogs for Windows programs (patches 0023 + 0024)

MacSW can show the Apple file browser (NSOpenPanel / NSSavePanel) where a
Windows program asks for a file dialog. The switch is the environment variable
`MACSW_NATIVE_FILE_DIALOGS`:

| Value | Behaviour |
|---|---|
| unset, `0`, anything but `1` or `all` | Wine's Windows-style dialogs, unchanged |
| `1` | NSOpenPanel / NSSavePanel where it is safe (rules below), Wine's dialog otherwise |
| `all` | as `1`, but also for IFileDialogs whose program asks for the dialog window (rule 5); what the program puts into the dialog window is built in the hidden dialog window and is not seen |

The app sets `MACSW_NATIVE_FILE_DIALOGS` only in the SOLIDWORKS environment
(`WineService.environment(..., solidWorks: true)`: SOLIDWORKS launches from
MacSW and from SOLIDWORKS.app, document hand-off, and the SWCLI runtime sync
helper, which shows no dialogs), behind "Use macOS file dialogs" in
Settings > General > Personalization (`MacSW.useMacFileDialogs`, **default
on**). On, the value is `all`; the hidden preference
`MacSW.macFileDialogsEverywhere` (default on) set to NO makes it `1`:
`defaults write com.yjbeetle.macsw MacSW.macFileDialogsEverywhere -bool NO`
(`defaults delete com.yjbeetle.macsw MacSW.macFileDialogsEverywhere` to go
back). Both take effect the next time SOLIDWORKS starts; SOLIDWORKS.app reads
them from MacSW's preferences domain. A value that is set explicitly (for
example `MacSW.useMacFileDialogs` = NO from an earlier build, where the
default was off) stays; `defaults delete` gives the default again.

| "Use macOS file dialogs" (`MacSW.useMacFileDialogs`) | `MacSW.macFileDialogsEverywhere` (hidden) | Value |
|---|---|---|
| off | (ignored) | unset: Wine's Windows-style dialogs |
| on (default) | off | `1`: rule 5 keeps the Windows-style dialog where SOLIDWORKS asks for the dialog window while the dialog opens (File > Open, Save As, Insert Component); SOLIDWORKS's pane is not visible in that dialog either (see below) |
| on (default) | on (default) | `all`: the Apple file browser everywhere, SOLIDWORKS File > Open included; SOLIDWORKS's own options pane there (open mode, configuration, display state, quick filter) is not shown (it is built in the hidden dialog window, so SOLIDWORKS uses its defaults), and neither is the Open button's drop-down ("Open" / "Open Read-only", see Open issues) |

**On by default (`all`) since RC2 (branch `filedlg-shadow`), off in RC1.**
With the first version of these
patches SOLIDWORKS 2026 SP4.1 File > Open crashed in both modes, `1` and
`all` (access violation reading `0xc8` at `mfc140u.dll+0x2b7467`, called
from `sldfileopen.dll+0xcd0c`: `GetDlgItem(cmb1)` on a NULL dialog window;
evidence in the project's `build.nosync/filedlg-crash/`, outside this
repository). That made the setting off by default (commit 857266f); the
short-lived default `all` with the "Keep the Windows dialog where SOLIDWORKS
adds its options" switch (`MacSW.keepWindowsDialogForSolidWorksOptions`,
commit e381ca9) went with it, and that preference is no longer read. The
hidden dialog window (below, branch `filedlg-shadow`) fixes the crash in
both modes. RC2 turns the setting on again, with `all` (both defaults
true): `all` gives the Apple file browser for File > Open too, and the
wineserver hang seen with `1` (Open issues) was not seen with `all`.

Installers and Wine tools that MacSW starts itself keep the Wine dialogs;
processes that SOLIDWORKS starts inherit the variable and get the panels too.
SOLIDWORKS sessions that `scripts/swcli/sw-cli` starts do not get the
variable (Wine dialogs).

## What SOLIDWORKS 2026 SP4.1 uses (static evidence)

Read-only scan of the 3,396 PE files under `Program Files/SOLIDWORKS` (import
tables, delay imports, and the binary GUIDs of the Common Item Dialog
interfaces), plus disassembly of the `GetOpenFileName`/`GetSaveFileName` call
sites in the main UI modules. No SOLIDWORKS process was started.

- `SLDWORKS.exe` imports no dialog API. The UI is in DLLs.
- **Common Item Dialog (IFileDialog)**: 31 modules contain `CLSID_FileOpenDialog`
  or `CLSID_FileSaveDialog`, 27 contain `IID_IFileDialogCustomize`.
  - `sldfileopen.dll` is SOLIDWORKS's own file dialog: COM class `CSwxFileDialog`
    (`filedialog.SwxFileDialog`), export `CoCreateVistaFileDialog` (looked up by
    `sldmfcu.dll`). It holds `CLSID_FileOpenDialog`, `CLSID_FileSaveDialog`,
    `IFileOpenDialog`, `IFileSaveDialog`, `IFileDialogCustomize`,
    `IFileDialogEvents` and `IFileDialogControlEvents`. This is the path of
    File > Open / Save As / Insert Component / export.
  - It also imports `SetWindowsHookExW`, `EnumThreadWindows`, `FindWindowExW`,
    `GetClassNameW`, `CreateWindowExW`, `MoveWindow`, and carries the strings
    `DirectUIHWND`, `DUIViewWndClassName`, `swFOPanel`, `ToolbarWindow32`,
    `PNG_MODE_ASSY_LW/LDR/RESOLVED…`, `PNG_DOCSEL_PART/ASSEM/DRAW…`,
    `ShowHideCordinateSystemOptions`, `SetOKButtonText`,
    `SetFileNameEditBoxText`; `sldutu.dll` exports `ut_EnableFOCustomPanel`.
    SOLIDWORKS therefore embeds its own options pane (mode buttons, quick
    filter, configuration/display state) into the dialog window.
  - How it gets the window (disassembly of `sldfileopen.dll`): its
    `IFileDialogEvents` sink (`utCommonFileDialogEventHandler_c`, vtable at
    RVA 0x2e9d8) does the work in **OnFolderChange** (0x18001a250). For an
    open dialog (it skips the block when `QueryInterface(IID_IFileSaveDialog)`
    succeeds), when `ut_EnableFOCustomPanel()` (sldutu) or another option is
    true, 0x18001d380 calls `QueryInterface(IID_IOleWindow)` +
    `GetWindow`, checks only the HRESULT, hooks `WH_CALLWNDPROCRET` for the
    auto-suggest list, walks the child windows for `DUIViewWndClassName` /
    `DirectUIHWND`, subclasses the dialog window (`SetWindowSubclass`), and
    builds the pane in 0x180014240, which starts with `IsWindow(hwnd)` and
    `GetDlgItem(hwnd, 0x470)`. 0x470 is `cmb1`, the file-type combo box; Wine's
    item dialog has it (`IDC_FILETYPE` = `cmb1`). For save dialogs, 0x18001d840
    also calls `GetWindow` in OnFolderChange when another option is true,
    and subclasses the dialog window.
  - A second path in the same handler (0x180014900 at 0x1800149dd) calls
    `GetWindow` again and does **not** check the result: on failure it uses
    `CWnd::FromHandle(NULL)` as the parent of the pane and calls
    `GetDlgItem(0x470)` on that NULL `CWnd*`. That was the File > Open crash
    with the first version of these patches in modes `1` and `all`
    (access violation reading 0xc8 in `mfc140u.dll`, called from
    `sldfileopen.dll+0xcd0c`): there was no dialog window during a native
    `Show()`, and the crash happened inside the first `OnFolderChange`,
    before rule 5 could choose the Wine dialog. The hidden dialog window
    (below) fixes it in both modes.
  - Under Wine's dialog the pane is built but not visible: its layout
    (0x18001b230) needs the `DUIViewWndClassName` / `DirectUIHWND` children
    of the Windows dialog, which Wine's dialog does not have. Seen in a
    clone-bottle screenshot of File > Open in mode `0` (2026-10-24): no
    pane, no mode or configuration choice, and a file-type box emptied by
    the pane's code. Under a native panel the pane is built in the hidden
    dialog window.
  - `mfc140u.dll` (MFC `CFileDialog`, Vista style) also uses IFileDialog,
    IFileDialogCustomize and the event interfaces; `sldmfcu.dll` wraps it
    (`CMFCFileDialogInterface_i`, used by sldappu, sldasmu, sldprtu, slduiu,
    sldpatternu, sldmatu, sldfuiu, sldutu).
- **GetOpenFileName / GetSaveFileName**: 25 modules. Flags at the call sites:
  - `sldappu.dll` (W): a CFileDialog-style `DoModal` that copies `m_ofn`,
    calls `AfxHookWindowCreate` or sets `m_pAlternateWndInit` depending on
    `OFN_EXPLORER`, then calls `GetOpenFileNameW`/`GetSaveFileNameW` and checks
    `FNERR_BUFFERTOOSMALL`. MFC always sets `OFN_ENABLEHOOK` there, so this
    path **keeps the Wine dialog**.
  - `sldappu.dll` and `sldutu.dll` (A): `Flags = 0x200C`
    (`OFN_CREATEPROMPT | OFN_NOCHANGEDIR | OFN_HIDEREADONLY`), no hook: **keeps
    the Wine dialog** (create-prompt rule).
  - `sldfuncfeat.dll`: open `Flags = 0x81800` (`OFN_EXPLORER | OFN_FILEMUSTEXIST |
    OFN_PATHMUSTEXIST`), save `0x83A02` (with `OFN_OVERWRITEPROMPT`): no hook,
    **native**.
  - Others: `rtFunction.dll` (flags computed at run time), FloXpress
    `ngp_ui.dll`/`fwpost_fxp.dll`, Simulation translators `cos2*.exe`,
    `gabiswengine.exe`, `sldsetdocprop.exe`, `sldBenchmark.exe`,
    `sldProcMon.exe`, activation wizards (`swactwiz*.exe`, i386 helper).
- **SHBrowseForFolder**: 25 modules (Toolbox `ConfigureU.dll`,
  `sldxtoolkitu.dll`, `sldanimateu.dll`, `sldShellUtilsUIu.dll`, FloXpress,
  MFC). Not covered by these patches (Wine's folder browser stays).
- Print/page setup (`PrintDlgW`, `PageSetupDlgW`) are not file dialogs and are
  untouched.

## Design

```
comdlg32 (PE, macdlg.c)                winemac.drv (PE)        winemac.so (unix)        Cocoa main thread
IFileDialog::Show / GetOpenFileName -> macsw_file_dialog() -> unix_file_dialog --------> NSOpenPanel/NSSavePanel
  disable owner                        (GetProcAddress)        begin: OnMainThreadAsync   sheet on owner window
  loop: MsgWaitForMultipleObjectsEx(50 ms) + Peek/Dispatch                               delegate + accessory
        poll  <------------------------------------------- queued lines (folder, selection, type, check, item,
        fire IFileDialogEvents / ControlEvents                button, edit, path..., result)
        update -> controls changed by the app's handlers
  re-enable + activate owner
```

- The unix call never waits for the user, so the Windows GUI thread keeps
  pumping its messages (SOLIDWORKS keeps repainting). `WM_QUIT` ends the panel
  and is re-posted; a destroyed owner cancels the panel.
- The panel sends a `started` line once it is on screen. If it ends without
  one (an AppKit exception while it is set up; `-show` and `-applyUpdate:`
  catch exceptions) or no `started` comes within 10 s, comdlg32 cancels it
  and shows the Wine dialog instead. The IFileDialog opening events have
  then fired twice (once before the panel, once in the Wine dialog).
- The panel is a sheet on the owner's Cocoa window when that window is on
  screen, otherwise a centred panel at the owner's window level (at least
  the normal level), so a Win32 dialog that an accessory button opens comes
  up in front of it. While such a button's handler runs, comdlg32 sends
  `{"busy":true}` and the panel ignores the mouse until the handler returns.
  The app asks to be activated (`tryToActivateIgnoringOtherApps:`).
- After the panel, activation goes back to the owner if comdlg32 disabled
  it (as when a modal dialog ends), otherwise to the window that was active
  before (for example an outer modal dialog that had disabled the owner);
  the keyboard focus goes back to the control that had it.
- Request: JSON (title, prompt, folder as unix path, file name, filters,
  filter index, default extension, multi-select, hidden files, controls).
  Results come back as unix paths and are converted with
  `wine_get_dos_file_name`.
- `IFileDialogCustomize` state stays in the hidden control windows that Wine's
  dialog uses, so every getter works unchanged. Rendered in the accessory
  view: check buttons, combo boxes, radio button lists, text, edit boxes,
  separators, push buttons, menus, visual groups (label + row). The Windows
  filters appear as a "Format" popup.
- While the panel is up, comdlg32 compares the controls with what the panel
  shows on every loop round (at most every 50 ms) and sends changes, so
  changes made from timers or posted messages arrive too, not only those
  made in event handlers. `SetFileTypeIndex`, `SetFolder` and `SetFileName`
  are sent as well; `SetFolder` navigates the panel and fires
  `OnFolderChange`, as on Windows.

## The hidden dialog window (IFileDialog)

During a native `Show()` the window of Wine's item dialog exists too, hidden.
`native_shadow_create` makes it from the same template (`NEWFILEOPENV3ORD`,
copied without `WS_VISIBLE`) with `CreateDialogIndirectParamW`, after the
owner is disabled and before the first event, so `IOleWindow::GetWindow`
returns it (`S_OK`) from the first event to the end of `Show()`, `OnFileOk`
included. It has the controls and ids of the Wine dialog (`cmb1`, `edt1`,
`IDOK`, `IDCANCEL`, the custom controls), so programs that subclass it or
put their own windows into it (SOLIDWORKS's open options pane) work as with
the Wine dialog, unseen. Differences from the Wine dialog:

- no shell browser (no folder listing, no navigation or selection events of
  its own); the panel drives the events, as before;
- never visible and never active: `WM_WINDOWPOSCHANGING` removes
  `SWP_SHOWWINDOW` and adds `SWP_NOACTIVATE`, `WM_STYLECHANGING` removes
  `WS_VISIBLE`, and the panel loop hides it again if a
  `SetWindowPos(SWP_NOSENDCHANGING)` showed it; no focus at creation;
- comdlg32 keeps its file name box and type box in step with the panel
  (`GetFileName` and `edt1` give the panel's name in `OnFileOk`);
- `IDOK` sent to it does nothing (the panel accepts); `IDCANCEL` sent to it,
  and `IFileDialog::Close`, end the panel. It is never ended with
  `EndDialog` (which would enable the owner while the panel is up);
- it is destroyed after `OnFileOk` (or cancel), before the owner is enabled
  and activated again. When a Wine dialog replaces the panel (rule 5, or a
  panel that did not start), it stays, hidden and inert, until `Show()`
  returns: the program can keep state in it, and SOLIDWORKS does (it does
  not build its pane again in the Wine dialog).

MFC `CFileDialog` (Vista style; about 66 SOLIDWORKS modules call it
directly) hooks window creation (`AfxHookWindowCreate`, `WH_CBT`) while
`Show()` runs and attaches itself to the first window created on the
thread. That is now the hidden window, as the visible dialog is on Windows;
before, no window was created during a native `Show()` and
`CFileDialog::m_hWnd` stayed NULL. This follows from the MFC source and was
not tested. OPENFILENAME dialogs (GetOpenFileName / GetSaveFileName) have no
hidden window: with a hook or a template they keep the Wine dialog (rule 3),
because `CDN_*`/`CDM_*` need the shell browser state of a real Explorer
dialog.

## Rules

Native panel when all of these hold, otherwise Wine's dialog:

1. `MACSW_NATIVE_FILE_DIALOGS=1` or `all` in the process environment.
2. `winemac.drv` is loaded and exports `macsw_file_dialog` (the process has
   used the Mac driver, which every GUI program has); the panel started.
3. `OPENFILENAME`: no hook (`OFN_ENABLEHOOK` with `lpfnHook`) and no custom
   template (`OFN_ENABLETEMPLATE`, `OFN_ENABLETEMPLATEHANDLE`). Hook procedures
   get `CDN_*` notifications and send `CDM_*` messages to a real dialog window,
   and templates add child controls to it. Old-style MFC `CFileDialog` always
   installs a hook, so it keeps the Wine dialog. Win 3.1-style dialogs
   (`is_win16_looks`) never reach this code.
4. Open dialogs with `OFN_CREATEPROMPT` / `FOS_CREATEPROMPT` keep the Wine
   dialog: they must accept the name of a file that does not exist yet, and
   NSOpenPanel only returns existing items.
5. `IFileDialog`: if the program calls `IOleWindow::GetWindow` in one of the
   events fired while the dialog opens (`OnFolderChanging`, `OnFolderChange`,
   `OnTypeChange`, before the panel starts), it has put or is about to put
   its own windows into the dialog, so `Show()` uses the Wine dialog, where
   they can be seen. Its handlers run again there, with that window. This is
   the IFileDialog counterpart of rule 3. In those first events
   `GetWindow` already returns the hidden dialog window, so the rule only
   chooses the visible dialog; it does not prevent a crash. For SOLIDWORKS
   it gives the Windows-style dialog for File > Open, Save As and Insert
   Component, but not a visible options pane: SOLIDWORKS built it in the
   hidden window, which stays behind the Wine dialog, and does not build it
   again (in mode `0` it could not be placed either, see above). The
   Settings switch passes `all` by default, which turns this rule off; the
   hidden preference set to NO passes `1`, which keeps it. A `GetWindow`
   call later, while the panel is
   up, returns the hidden window and does not change the dialog.

SOLIDWORKS correctness comes first: when in doubt, the Wine dialog.

## Behaviour notes

- Overwrite: NSSavePanel asks before replacing an existing file and that is
  the only prompt. `IFileDialogEvents::OnOverwrite` is still called
  (`FDEOR_REFUSE` shows the panel again). Only when comdlg32 must add the
  extension itself (name without extension, no concrete filter extension in
  the panel) does Wine's own prompt run for the final name. NSSavePanel also
  asks when `OFN_OVERWRITEPROMPT`/`FOS_OVERWRITEPROMPT` is not set (it cannot be
  turned off).
- Extensions: save panels get the selected format's extensions as
  `allowedFileTypes`, so NSSavePanel appends the first one and checks
  overwrite on the final name; a different extension the user confirms is
  kept. comdlg32 then adds the Windows default extension only to a name that
  has none (IFileDialog: filter's first extension, else `SetDefaultExtension`;
  OPENFILENAME: only with `lpstrDefExt`, like `FILEDLG95_OnOpen`). Changing
  the format in a save panel changes the extension in the name field.
- `OnFileOk` returning `S_FALSE` shows the panel again in the same folder with
  the same name. `IFileDialog::Close` ends the panel with its HRESULT.
- Events: `OnFolderChanging`/`OnFolderChange`/`OnTypeChange` at start (as Wine's
  dialog), then on folder, selection and format changes; control events from
  the accessory view. Changes the application makes in its handlers (enable,
  hide, select, check, label, `SetFileName`) are sent back to the panel.
- `IOleWindow::GetWindow` returns the hidden dialog window (`S_OK`) from the
  first event of a native `Show()` to its end (see "The hidden dialog
  window"). Earlier versions returned `S_OK` with a NULL window, then
  `E_FAIL`; SOLIDWORKS's File > Open crashed with both.
- `Show()` on a dialog whose panel is up returns `E_UNEXPECTED` (it used to
  open a second, Wine, dialog on the same object). `Close(S_FALSE)` from
  `OnFileOk` ends `Show()` with `S_FALSE` and does not show the panel again.
- OPENFILENAME multi-select lists hold one folder: the items in the first
  item's folder. Items the panel found elsewhere (search results, Recents)
  are left out, as the Windows dialog cannot select them together. Items at
  a drive root work (`"Z:\\\0a.txt\0b.txt\0\0"`).
- Names that Windows programs cannot use (`\ / * ? " < > |`, control
  characters, a trailing dot or space): a picked file with such a name
  comes back as the 8.3 name Wine lists for it (`q?x.txt` ->
  `Q_X~~UQW.TXT`), which Windows programs can open; save panels refuse such
  names with a message. Open panels still list these files (Wine's dialog
  does too). `:` is allowed (Wine opens such names).
- Not rendered: the Open button drop-down (`EnableOpenDropDown`); its first
  enabled item is the result, as in Wine. `AddPlace`, `SetFilter`
  (IShellItemFilter), `SetClientGuid` persistence, OPENFILENAME custom filters
  and `OFN_SHAREAWARE` are not used by the panel.
- Open panels cannot take a typed name of a file that does not exist (rule 4
  covers the explicit case).
- "Format:" and "Open as read-only" are English labels.

## Test hook (automation only)

Read by comdlg32 for every native panel; never set by the app (the app also
strips them from the launch environment):

| Variable | Effect |
|---|---|
| `MACSW_NATIVE_FILE_DIALOG_TEST` | `cancel`, or newline separated unix paths: after the delay the real panel ends with this answer (a save name the panel refuses ends it with cancel). Before an answer with paths the panel sends a `folder` line for the first path's folder and, in open panels, a `selection` line with the paths (so `OnFolderChange` and `OnSelectionChange` run, as when a user goes to the file and clicks it), then answers 500 ms later |
| `MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS` | keep the real panel up that long first (for a screenshot) |
| `MACSW_NATIVE_FILE_DIALOG_TEST_TYPE` | 1-based "Format" entry to pick, as a user would |
| `MACSW_NATIVE_FILE_DIALOG_TEST_CONTROLS` | `<control id>=<value>;...`: check box 0/1, combo/radio/menu item id, edit text, push button (any value) |

The hook answers in place of the user, so NSSavePanel's own naming (adding
the Format's extension, its overwrite question, the "Use .step?" question)
is not covered by it. A hook that types a name and reads `[panel URL]` does
not work on macOS 27: the panel runs out of process, and during the panel
`[panel URL]` stayed at the start name (`.../Untitled`, without extension)
after `setNameFieldStringValue:` (measured, 200 ms and 1.7 s later). These
behaviours are in the SOLIDWORKS validation plan.

Side effects of probe runs (and of any native panel):

- The panel state (`NSOSPLastRootDirectory`, `NSNavPanelExpandedSize*`) is
  written to `~/Library/Preferences/com.macsw.winehost.plist`, because the
  Wine loader's embedded Info.plist uses that bundle id. Real SOLIDWORKS
  uses the same file: a probe run changes where the next panel opens when
  no folder is given.
- A process that shows a panel becomes the active app, also when it was
  started in the background. Probe runs therefore take the focus: run them
  only when no one, and no other automation, is using the screen.

## Tests

- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
  (`test_wine_native_file_dialogs.py`: wiring, pins, patch scope, gate, op table).
- Swift: `AppPreferencesTests.testMacFileDialogsDefaultOnAndExplicitChoiceIsHonoured`,
  `AppPreferencesTests.testMacFileDialogsEverywhereIsOnByDefault`,
  `RuntimeTests.testMacFileDialogsSettingSetsTheNativeFileDialogGateForSolidWorksOnly`
  (`all` by default, `1` with the hidden switch off, unset with the setting off).
- Runtime probe (`scripts/build_wine_file_dialog_probe.sh`, x86_64 and i386),
  run in a throwaway prefix with the rebuilt modules:

  ```sh
  export WINEPREFIX=<throwaway prefix>   # with the patched runtime
  # Keep the browsed folder outside ~/Desktop, ~/Documents, ~/Downloads:
  export FILE_DIALOG_PROBE_DIR='Z:\private\tmp\filedlg-files'
  MACSW_NATIVE_FILE_DIALOGS=1 wine wine_file_dialog_probe-x86_64.exe native   # 118 checks
  MACSW_NATIVE_FILE_DIALOGS=1 wine wine_file_dialog_probe-x86_64.exe shadow   # hidden window checks only (28)
  wine wine_file_dialog_probe-x86_64.exe wine                                  # gate unset: Wine dialogs
  MACSW_NATIVE_FILE_DIALOGS=1 wine wine_file_dialog_probe-x86_64.exe show 60000  # real panel for 60 s
  ```

  `native` covers IFileOpenDialog (filters + Format change, custom controls
  and their events, GetFileName/GetFileTypeIndex in OnFileOk, owner disabled
  while up), multi-select, pick folders, IFileSaveDialog (default extension,
  format extension, overwrite event without a second prompt), OnFileOk
  `S_FALSE`, cancel, GetOpenFileNameW (offsets, filter index, file title,
  read-only box), multi-select double-NUL list, GetSaveFileNameW (default and
  format extension, `OFN_EXTENSIONDIFFERENT`, `FNERR_BUFFERTOOSMALL`),
  GetOpenFileNameA, the Wine-dialog fallbacks (hook, create prompt), and:
  a push button whose handler runs a modal dialog while the panel is up,
  rule 5 (GetWindow in OnFolderChange/OnTypeChange gives a window, then the
  Wine dialog, whose GetWindow returns its own window; the first, hidden,
  window lives until `Show()` returns; with `all` the panel appears and
  every GetWindow call gives the hidden window), the hidden window (class
  `#32770`, `cmb1`/`edt1`/`IDOK`/`IDCANCEL`, owned by the owner, a child
  window can be put into it, `ShowWindow`/`SetWindowPos`/`SetWindowLong`
  and `SWP_NOSENDCHANGING` do not show it, never active or focused, same
  window and file name box in both `OnFileOk` calls of an `S_FALSE` round,
  the test hook's `folder` and `selection` lines give `OnFolderChange` in
  the file's folder and `OnSelectionChange` with the file, where `GetWindow`
  gives the hidden window with its file name box,
  destroyed with `WM_NCDESTROY` when `Show()` returns, owner active and
  focus back, save dialogs too, `IDCANCEL` sent to it cancels the panel, 10
  cancelled panels leave no window), `Show()` re-entry (`E_UNEXPECTED`, no second
  dialog), `SetFileTypeIndex`/`SetFolder` from a timer, `Close(S_FALSE)` in
  OnFileOk, activation and focus after the panel (owner and outer-modal
  cases), a `*.a/b` filter with a Format change, multi-select across
  folders, and names with `? | "` or a trailing `. ` (created through
  `\\?\unix\`). `wine` mode also checks that GetWindow returns the Wine
  dialog's window with the gate unset.
  Result on 2026-10-24 (macOS 27, Rosetta): `native` 94/94 on x86_64 and
  on i386; `wine` 4/4 on both, also with `MACSW_NATIVE_FILE_DIALOGS=yes`.
  With the hidden dialog window (branch `filedlg-shadow`): `native`
  116/116 on x86_64, `shadow` 26/26 on x86_64 and i386, `wine` 4/4 on
  both. With the test hook's `folder` and `selection` lines: `native`
  118/118 on x86_64 (not run on i386), `shadow` 28/28 on x86_64 and
  i386, `wine` 4/4 on both (`shadow` and `wine` also with the merged
  runtime, integrate cebbaa2 + this branch). The probe's watchdog is
  300 s for `native`; the run now takes about 180 s (the hook waits
  500 ms before each answer).
- SOLIDWORKS 2026 SP4.1 in a clone bottle (2026-10-24, `tools/swdialogs`,
  test hook, comdlg32 of this branch in the RC1 runtime): with `all`,
  File > Open of a part with configurations and of an assembly, and Save As
  of a part, through the panel: no crash, the files open or are written,
  the hidden window is never shown. With `1`: File > Open shows the Wine
  dialog (rule 5), the hidden window stays behind it until `Show()`
  returns, the part opens, no crash.
- Again on 2026-10-24 (evening), with the merged runtime (integrate
  cebbaa2 + this branch: the Wine modules of this branch's
  `build_winemac.sh` output put into a runtime) and the test hook that
  sends `folder` and `selection` lines, clone bottle, evidence in the
  project's `build.nosync/picker-fix/runs/`:
  - `all`: File > Open of the part with configurations with a Format
    change (`OnTypeChange`, `OnFolderChange`, `OnSelectionChange`; in
    `OnSelectionChange` SOLIDWORKS calls `GetCurrentSelection`,
    `GetFileName` and `GetWindow`, which gives the hidden window): opens,
    no crash. File > Open of the same part while it is open: activates
    it, no message. Insert Component of that part into an assembly: the
    part is taken (it hangs on the cursor), placed with one click. Save As
    to PDF with a Format change (`folder` line in a save panel): the PDF
    is written. In every case the hidden window was never visible and the
    SOLIDWORKS window had the focus again afterwards.
  - `1`: File > Open (and Cancel), Save As of a part, Save As to STEP and
    Insert Component all show the Wine dialog (rule 5; the hidden window
    is parked, then destroyed when `Show()` returns) and work.
  - In 2 of 16 Save As to STEP runs with `1`, the bottle's wineserver
    hung after the STEP file was written (see Open issues); 0 of 9 with
    the setting off. (The first hang was in the RC1 runtime with this
    branch's comdlg32 and Mac driver; its wineserver, win32u and comdlg32
    code are the same as in the merged runtime.)

## SOLIDWORKS validation plan

Status 2026-10-24: with the first version of the patches step 1 failed in
both modes (`1` and `all`): SOLIDWORKS crashed in File > Open (see the top
of this page). With the hidden dialog window the crash is gone in the
automated clone-bottle runs (see Tests); the plan itself, done by a person
who clicks in the panel, has not run yet. Run it only in a clone bottle,
never in the bottle someone is working in.

Use the app after the integration build, Settings > "Use macOS file dialogs"
on (the default, value `all`), SOLIDWORKS restarted; for the `1` cases
also `MacSW.macFileDialogsEverywhere` NO. For each step note: native panel
or Wine dialog, panel in front of SOLIDWORKS, SOLIDWORKS responsive
afterwards.

1. **File > Open** (Ctrl+O). With `1`, rule 5 keeps the Wine dialog here;
   it shows no SOLIDWORKS options pane, as with the setting off (seen in a
   clone bottle on 2026-10-24). With `all` (the default) expect a sheet on
   the SOLIDWORKS window, in SOLIDWORKS's last folder, with "Format" listing
   the SOLIDWORKS filters, and no SOLIDWORKS options pane.
   Change Format to "Assembly (*.asm;*.sldasm)": parts grey out. Open an
   assembly: it opens; the window is enabled and focused again. Repeat with
   Cancel: nothing opens, no error. Right after the dialog closes, press a
   keyboard shortcut (for example Ctrl+S or a view shortcut) without
   clicking: SOLIDWORKS must react.
2. **Gate: open with mode and configuration choice.** Open a part with
   several configurations and an assembly, three times each:
   a. setting off (Wine dialog);
   b. setting on and `MacSW.macFileDialogsEverywhere` NO (`1`, rule 5);
   c. setting on, the default (`all`: native panel for File > Open too).
   Record in each case whether the mode (Resolved/Lightweight/Large Design
   Review), configuration and display state choices are offered, and
   whether the chosen ones are applied (ConfigurationManager, Lightweight
   feather icons). No stray floating pane and no crash in any case.
   Finding (clone bottle, 2026-10-24): a and b show no pane either (a:
   Wine's dialog lacks the DirectUI windows the pane is placed against; b:
   the pane stays in the hidden window), so no case offers the choices;
   SOLIDWORKS uses its defaults. The owner's earlier choice of `all` as the
   default (e381ca9) was withdrawn with 857266f because of the crash.
3. **File > Save As** with a format change: open a part, Save As, change
   Format to "STEP AP214 (*.step;*.stp)". The name field extension becomes
   `.STEP`/`.step`; Save. Expect SOLIDWORKS's STEP export options/progress and
   a `.step` file in the chosen folder. Save As again onto the same name:
   exactly one "replace?" question (from macOS). Save As with Format "Part"
   and a name without extension: file gets `.SLDPRT`. Type `Part1.step`
   with Format "Part": macOS asks which extension to use; both answers give
   a file that SOLIDWORKS writes. Note whether this is the native panel or
   the Wine dialog (rule 5).
   - **Save As > STEP > Options…** (if the panel shows an Options button):
     the STEP options dialog comes up in front of the panel, the panel
     ignores clicks while it is open, and after OK/Cancel the panel works
     again and Save still saves.
   - In the name field: paste a name with Cmd-V, select all with Cmd-A,
     copy with Cmd-C. If these do not work (Wine has no Edit menu), record
     it; the fix is an Edit menu whose items are disabled while a Wine
     window is key.
   - Type a name with `?` or `|`: the panel refuses it with a message.
4. **Insert Component** (Assembly > Insert Components > Browse...): the
   dialog opens from the PropertyManager (Wine dialog under rule 5 when
   SOLIDWORKS adds its pane, else the panel); pick a part; the component
   follows the cursor for placement. Try multi-select if the dialog allows
   it. If the open dialog shows a **References…** button, click it: its
   dialog comes up in front, and the open dialog works again afterwards.
5. **Export STEP** via File > Save As (STEP) and, if present, File > Export
   / "Publish" commands: same expectations as step 3; check the written file
   opens again with File > Open (Format "STEP").
6. Dialogs expected to stay Wine (by the rules): anything using old-style
   MFC `CFileDialog` (hooked), `GetOpenFileNameA` with create prompt
   (sldappu/sldutu), and the sldfileopen dialogs that ask for their window
   (rule 5). Note which commands show them.
7. Set `MacSW.macFileDialogsEverywhere` to NO (value `1`), restart
   SOLIDWORKS: File > Open shows Wine's dialog (without a visible pane, see
   step 2), dialogs that do not ask for the dialog window stay native. Turn
   "Use macOS file dialogs" off, restart SOLIDWORKS: every dialog is Wine's
   again (no other change).

If anything misbehaves, the setting turns it off without a rebuild.

## Open issues

- **wineserver hang with `1` (2 of 16 STEP exports, 0 of 9 with the
  setting off).** After Save As to STEP through the Wine dialog (rule 5,
  hidden window parked, then destroyed), the STEP file was written and
  then the bottle's wineserver used a full core inside
  `req_get_class_windows` (macOS `sample`: every sample in its loop over
  the top-level windows), so the desktop's top-level window list had most
  likely become a loop; every process of the bottle waited for the server
  (in the second hang SOLIDWORKS's main thread was in `destroy_window`).
  `1` is the value with the hidden switch off (the default is `all`). The list walk came from the test
  sampler's `FindWindowExW` loop; any enumeration of the top-level windows
  would hang the same way. The cause is not known, and two hangs are too
  few to show that the parked window causes it. Evidence: the
  project's `build.nosync/picker-fix/runs/g1-03-export-step/hang/` and
  `runs/r1-03-export-step-2/hang/`.
- The setting was off by default in RC1 (857266f) because of the File >
  Open crash. The hidden dialog window fixes it, and RC2 turns the setting
  on with `all`. The validation plan above, done by a person who clicks in
  the panel, has not run yet; the setting turns the panels off without a
  rebuild.
- SOLIDWORKS's own options pane (`swFOPanel`) is built into the dialog
  window by `sldfileopen.dll` (see above). It is not visible in any mode:
  with a native panel and with rule 5 it is in the hidden dialog window,
  and in Wine's dialog (mode `0`) it cannot be placed. So open mode (Resolved / Lightweight / Large
  Design Review), configuration and display state cannot be chosen when a
  file is opened; SOLIDWORKS uses its defaults.
- `SHBrowseForFolder` (Toolbox setup, Toolkit, animation, FloXpress) still
  uses Wine's folder browser.
- The Open button drop-down (`EnableOpenDropDown`) is not rendered.
  SOLIDWORKS File > Open adds one with "Open" and "Open Read-only"; Wine's
  dialog (mode `0`, and `1` through rule 5) shows it, the panel does not,
  so with `all` File > Open cannot open a file read-only.
- Wine has no Edit menu, so Cmd-C/V/X/A in the panel's name and search
  fields may not work (not verified; validation step 3).
- NSSavePanel's own naming is not covered by automated tests (see the test
  hook section).
