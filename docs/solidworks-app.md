# SOLIDWORKS.app: start SOLIDWORKS like a normal Mac app

Status: works with notepad and probe stand-ins in a throwaway prefix, started from a shell (2026-10-24).
The owner has used it with SOLIDWORKS on the real bottle since 2026-10-24 22:42Z (`solidworks-app.log`).
The bug hunt of 2026-10-25 (`docs/bughunt-night.md` in the project folder) ran it with SOLIDWORKS in a
clone bottle, on the RC2.3 runtime, with the launcher in exec mode from a shell. It covered section 6:

- step 6 in part: a document hand-off through the helper (`--open-documents`). A part that was already
  open gave an error box (F3); a part that was not open opened after that box was closed.
- step 7, default quit mode: Quit with unsaved changes shows the save prompt; Cancel keeps SOLIDWORKS
  running; Don't Save quits and the bottle is empty after 10 s; the next start has no Document Recovery.
  The Quit was an Apple event to the host PID, not Command-Q or Dock > Quit.

It also found that three launches at the same time start three hosts in one bottle (F4). The other steps
of section 6, and a cold launch through LaunchServices as the real bundle, are not checked yet (see
sections 5 and 6). MacSW installs, updates and uninstalls it (section 4); that code is tested against
temporary folders, not yet in /Applications.

## 1. What the user gets

- An app named **SOLIDWORKS** with the SOLIDWORKS icon. It can live in /Applications, Launchpad, Spotlight
  and the Dock. MacSW.app stays the installer, settings and maintenance tool. MacSW.app carries
  SOLIDWORKS.app and installs it with one click (Settings → Maintenance → SOLIDWORKS App), and it updates the
  installed copy after a MacSW update (section 4).
- Click it: SOLIDWORKS starts. No MacSW window. The same preflight as MacSW runs first (Wine runtime state,
  Desktop/Documents/Downloads consent, font link, SWCLI sync, launch lock).
- While it runs there is **one** Dock tile, "SOLIDWORKS". The menu bar shows "SOLIDWORKS". Clicking the tile
  brings it to the front. A tile kept in the Dock starts it again later.
- Command-Q, the Dock's Quit and "Quit SOLIDWORKS" in the menu quit SOLIDWORKS without a force kill. Two
  modes (section 2, "Quit"); the default is Wine's end-of-session path.
- Double-clicking .sldprt/.sldasm/.slddrw (and the templates) opens them in SOLIDWORKS, on a cold start
  and in a running instance.

## 2. How it works

`SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS` is a universal binary:

| Slice | Content |
|---|---|
| arm64 | the launcher (`macos/Bootstrap/Sources/SolidWorksLauncher`, links MacSWCore) |
| x86_64 | MacSW.app's own Wine loader (`Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW`, same UUID) |

1. LaunchServices starts the arm64 slice (`LSRequiresNativeExecution`).
2. The launcher finds MacSW.app (`MACSW_HOST_APP`, Info.plist `MacSWHostApp`, next to SOLIDWORKS.app,
   /Applications, then the copies LaunchServices knows, for example in ~/Applications) and points MacSWCore
   at it (`MacSWBundle.url`). It reads MacSW's preferences domain.
3. It compares the LC_UUID of its own x86_64 slice with MacSW.app's loader. If they differ (MacSW.app was
   updated, SOLIDWORKS.app was not), it shows "SOLIDWORKS.app is out of date" and does not start Wine. The
   alert's "Open MacSW" button starts or activates MacSW, which then updates the copy (section 4).
4. It runs `RuntimeStore.launch()`, the code MacSW uses. Only two steps differ:
   - The font-link check (1-2 `wine reg query`, seconds each) runs once per bottle, prefix ID and runtime
     identity, not at every start. The stamp is `.solidworks-app-fontlink` in MacSW's data directory.
   - The last step: instead of a child process, `WineService.execSolidWorks` calls `posix_spawn` with
     `POSIX_SPAWN_SETEXEC` and binary preference x86_64 on its **own** executable, under the same launch
     lock and runtime check as MacSW. argv[0] is the runtime's loader path, so the loader loads the
     `ntdll.so` next to argv[0] (`loader/main.c`, `try_dlopen`). No symlink and no loader patch.
5. The process ID stays the same, so the Wine host **is** the app's process. It checks in with
   LaunchServices as this bundle (bundle ID, name, icon, Foreground). The launcher never checks in with
   AppKit before the exec. With a current stamp the exec comes about 0.6 s after the start (5-18 s
   without it), and the host checks in 2-4 s later (stand-in, warm wineserver).
6. One signature covers both slices, so macOS sees the launcher and the Wine host as the same app. Ad hoc
   (default): `designated => cdhash H"…" or cdhash H"…"`, which changes with every build. With
   `MACSW_SIGN_IDENTITY` (`scripts/lib/codesign.sh`): `identifier "com.yjbeetle.macsw.solidworks" and
   certificate leaf = H"…"`, which stays the same across rebuilds. The folder-consent preflight therefore also covers the
   Wine phase.

Processes that SOLIDWORKS or Wine start later (services, explorer, a second program) run the loader from
MacSW.app's runtime as before. They are not this bundle.

### Wine patch 0025 (`winemac: Act as the main process of an app bundle when asked to`)

`dlls/winemac.drv/cocoa_app.m`, `macdrv_cocoa.h` and `window.c` (all in winemac.so). The launcher sets
`MACSW_APP_BUNDLE` to its bundle path. winemac honours the variables below only in the process whose main
bundle is that path (`is_app_bundle_host`: realpath of both, read once). Wine processes that the host
starts inherit the variables, because Wine copies the Unix environment into the Windows one, but they run
MacSW.app's loader, whose main bundle is another directory. So for them nothing changes (checked: their
Quit item stays Command-Option-Q). MacSW.app's own launches also clear the variables
(`WineService.environment`).

| Variable | Effect in the host |
|---|---|
| `MACSW_APP_BUNDLE=<bundle path>` | The bundle is a regular app from launch (Dock tile while it starts). The one-time setup in `transformProcessToForeground` (menu, App Nap activity, icon) still runs once at the first window. The Quit item uses Command-Q instead of Command-Option-Q. |
| `MACSW_OPEN_DOCUMENTS_HELPER=<path>` | `application:openURLs:` (kAEOpenDocuments) starts `<path> --open-documents <file>…` (native slice preferred, only stdout/stderr inherited, default signals). Otherwise the delegate does not respond to that selector and AppKit behaves as before. |
| `MACSW_APP_QUIT=close` | Quit mode "close" (see below). Not set by default. |

The exec plan also passes `MACSW_APP_SUPPORT` and `MACSW_HOST_APP` to the host when they are set and not
empty (test instances). The helper inherits them, so a Finder open on a test instance stays in that
instance's bottle. Without them the helper uses `AppPaths.live()`. Other variables of the launcher's
environment (secrets, `DYLD_*`, `WINE*` overrides) stay out, as before.

The helper is the launcher itself. In `--open-documents` mode it calls `RuntimeStore.handOff(documents:)`:
it waits for the SOLIDWORKS main window (as MacSW does) and then runs `wine start /unix <file>`. It never
starts SLDWORKS.exe. Failures go to `solidworks-app.log`.

If SOLIDWORKS already runs but not as SOLIDWORKS.app (MacSW started it), the launcher becomes an accessory
app, receives the documents, hands them over, yields activation to SOLIDWORKS (macOS 14+), brings it
forward and quits (`forward` mode). The log says whether macOS allowed the activation.

### One start at a time (start lock)

MacSW and each SOLIDWORKS.app launch are separate processes. Without a lock, launches at the same moment
(for example MacSW's auto-launch at login and SOLIDWORKS.app in Login Items) all passed the "is SOLIDWORKS
running?" check, and one bottle got several `SLDWORKS.exe` (bughunt F4). Now `RuntimeStore.launch()`
takes an exclusive `flock` on the bottle's `start.lock` after the preflight, before its last process
check, and holds it through the start (`StartLock`):

- The file is `<data directory>/.bottle.wine-runtime/start.lock`, next to `launch.lock`. For an unmanaged
  bottle it is `.<bottle>.start.lock` next to the bottle (the `.wine-runtime` directory would make the
  bottle managed).
- The descriptor is `O_CLOEXEC`. In SOLIDWORKS.app the exec closes it, at the moment the host exists
  (its `ps` command already names `SLDWORKS.exe`). MacSW releases it after `Process.run()` returned.
- A start that waits 15 s for the lock, or that finds SOLIDWORKS running once it has the lock, does not
  start. SOLIDWORKS.app logs `forward:` and brings SOLIDWORKS forward; MacSW queues opened files for the
  running instance. `solidworks-app.log` shows the wait (`start lock: acquired after … s`).
- Lock order: `start.lock`, then `launch.lock`. A migration (`wine_runtime.py`) takes only `launch.lock`,
  and `withLaunchLock` never waits (`LOCK_NB`), so the two cannot deadlock.
- If the lock file cannot be opened, the start goes on without it, as before.
- Documents from a Finder open that loses the race are not forwarded: the launcher never checks in with
  AppKit before the exec, as before.

### Quit

| Mode | How to select | What Command-Q / Dock > Quit / the Quit item do |
|---|---|---|
| session end (default) | nothing | Wine's path: `WM_QUERYENDSESSION` to the host's top-level windows; if all agree, `WM_ENDSESSION(TRUE)`, then the process ends. A refusal keeps SOLIDWORKS running. No `WM_CLOSE`. |
| close | `defaults write com.yjbeetle.macsw MacSW.solidWorksAppQuitClosesWindows -bool true` (read at the next start) | `WM_CLOSE` to every top-level window of the host, like MacSW's "Quit SOLIDWORKS" (`taskkill` without `/f`). AppKit does not terminate; SOLIDWORKS asks to save and exits by itself, or stays. |

Log out, restart and shut down use the session-end path in both modes. Other Wine processes of the bottle
(for example `sldworks_fs.exe`) are not this process: neither mode stops them. MacSW's "Quit SOLIDWORKS"
also asks `sldworks_fs.exe` to close. Which mode SOLIDWORKS needs is part of the validation (section 6,
step 7).

With MacSW's Mac shortcuts on (`LeftCommandIsCtrl`), Command-Q used to reach SOLIDWORKS as Ctrl+Q (forced
rebuild), because the Quit item was Command-Option-Q. In SOLIDWORKS.app the Quit item takes Command-Q. Use
the Control key for Ctrl+Q there.

## 3. Document types (decision)

SOLIDWORKS.app declares the same `UTImportedTypeDeclarations` and document types as MacSW.app
(`scripts/solidworks_app_info.py`):

- SOLIDWORKS types (part, assembly, drawing and the three templates): rank **Owner**. MacSW.app declares them
  as Default, so Finder opens them with SOLIDWORKS.app when it is installed. MacSW's install also sets
  SOLIDWORKS.app as the default app for these types where MacSW (or no app) was the default, for example
  after "Change All" to MacSW; an uninstall gives them back to MacSW (section 4).
- STEP, IGES, Parasolid, DXF, DWG, STL: **Alternate**, the same rank as in MacSW.app. SOLIDWORKS is offered
  in "Open With" but does not take these formats from other CAD apps. Use Get Info > Open with > Change All
  to make it the default for one of them.
- MacSW.app's Info.plist is unchanged. Without SOLIDWORKS.app, MacSW.app handles every type as before. MacSW
  stays in "Open With" for the SOLIDWORKS types when SOLIDWORKS.app is installed.

## 4. Build, install and update

SOLIDWORKS.app is packaged **inside** MacSW.app. MacSW installs it into /Applications, updates it after
a MacSW update and removes it again. The user never builds or copies it by hand.

### Build

```
make app                                  # MacSW.app with SOLIDWORKS.app inside (build/app/)
MACSW_SKIP_SOLIDWORKS_APP=1 make app      # MacSW.app without it
make solidworks-app                       # an extra SOLIDWORKS.app next to build/app/MacSW.app (tests only)
```

`scripts/package_app.sh` runs `scripts/package_solidworks_app.sh --embed` before it seals MacSW.app. That
step combines `build/bootstrap/SOLIDWORKS` with the new MacSW.app's own loader, writes the Info.plist, takes
the icon from SLDWORKS.exe in the MacSW bottle (read only; or `MACSW_SOLIDWORKS_EXE`; `none` or no
SOLIDWORKS: MacSW's icon), signs the app (ad hoc, or `MACSW_SIGN_IDENTITY` and `MACSW_SIGN_KEYCHAIN`), checks
it with `verify_solidworks_app.sh` and stores it in MacSW.app:

| File in MacSW.app | Content |
|---|---|
| `Contents/Resources/SOLIDWORKS.app.zip` | the signed SOLIDWORKS.app (`ditto -c -k --sequesterRsrc --keepParent`) |
| `Contents/Resources/SOLIDWORKS.app.plist` | `CFBundleShortVersionString`, `CFBundleVersion`, `ExecutableSHA256` (SHA-256 of `Contents/MacOS/SOLIDWORKS`) |

Why a zip and not a bundle such as `Contents/Library/SOLIDWORKS.app`: LaunchServices registers app bundles
that it finds inside other bundles. The LaunchServices database of the development Mac has such records from
`Resources/` and `Frameworks/` of other apps, and one from a mounted disk image for a bundle without the
`.app` extension. A registered copy inside MacSW.app would be a second app with the bundle ID
`com.yjbeetle.macsw.solidworks` that owns the SOLIDWORKS types. Documents could then open from inside
MacSW.app, also before an install and after an uninstall. A zip is data, so the only registered
SOLIDWORKS.app is the installed one. `ditto -x -k --noqtn` restores the same files, so the installed copy has
the signature and the designated requirement of the build.

`scripts/verify_app.sh` (with `MACSW_SKIP_SOLIDWORKS_APP` unset) unpacks the zip as MacSW does and runs
`verify_solidworks_app.sh --embedded`: the zip holds `SOLIDWORKS.app` only, the plist matches the executable
and the build, and all checks of a separate SOLIDWORKS.app apply (Info.plist, both slices, x86_64 slice =
MacSW.app's loader, signature; with `MACSW_SIGN_IDENTITY` set, the certificate requirement).

`make archive` builds with `MACSW_SOLIDWORKS_EXE=none`, so the archive's SOLIDWORKS.app has MacSW's icon and
never artwork from a local SOLIDWORKS installation.

**Developer ID (CI).** The CI build (`build-app.yml`, "Build, verify and archive MacSW.app") sets
`MACSW_SKIP_SOLIDWORKS_APP=1`, so its archive, the input of the Developer ID and notarization workflow
(`sign-app.yml`), has no SOLIDWORKS.app inside. `scripts/sign_app.py` seals a zip in Resources as data and
would leave the SOLIDWORKS.app in it ad hoc and not notarized, so its inventory refuses a MacSW.app that has
`Contents/Resources/SOLIDWORKS.app.zip` ("Embedded app needs a signing policy"). A Developer ID MacSW therefore
does not offer "Install SOLIDWORKS App" yet. To add it, `sign_app.py` must unpack the zip, sign SOLIDWORKS.app
(Developer ID, timestamp, hardened runtime, one entitlement set for both slices: the Wine slice needs
`allow-unsigned-executable-memory`), zip it again, rewrite `ExecutableSHA256` in `SOLIDWORKS.app.plist`, and
then seal MacSW.app. `verify_solidworks_app.sh` (no hardened runtime) and `macsw_signature_kind` (ad hoc or
certificate leaf) must then accept that signature. Its requirement (`anchor apple generic … leaf[subject.OU]`)
differs from the local stable identity's, so MacSW asks before it replaces a copy that has the other one
(see "Privacy permissions").

Without SwiftPM, `tools/build_app_swiftc.sh --full` (outside the repository) runs the same `package_app.sh`
and `verify_app.sh`, so its MacSW.app also contains SOLIDWORKS.app. It still also builds the extra
SOLIDWORKS.app next to MacSW.app; that copy is not needed any more. `MACSW_SKIP_SOLIDWORKS_APP=1` skips both.

To move a built app as a file, use `ditto -c -k --sequesterRsrc --keepParent` and `ditto -x -k` (`unzip`
puts AppleDouble files into the bundle and breaks the signature).

### Install

Settings → Maintenance → **SOLIDWORKS App** shows the state and has **Install SOLIDWORKS App** (**Update** for
a stale copy, **Reinstall** for a current one), **Uninstall…** and **Show in Finder**. MacSW also suggests the
install:

- on the completion page after a SOLIDWORKS install (an **Install SOLIDWORKS App** button), and
- in the menu bar panel, once per SOLIDWORKS.app build, that is after a MacSW install or update, while
  SOLIDWORKS is installed in the bottle and SOLIDWORKS.app is not. The row stays until the app is installed or
  the × dismisses it (`MacSW.solidWorksAppSuggestionDismissed`).

The install (`SolidWorksAppInstaller.install`, called by `SolidWorksAppStore`):

1. **Target.** The installed copy (`/Applications/SOLIDWORKS.app`, then `~/Applications/SOLIDWORKS.app`),
   else `/Applications/SOLIDWORKS.app`. Another app with that name (another bundle ID) is never replaced or
   removed; Settings asks to move it away.
2. **Pairing.** Only the MacSW.app that a copy at the target would use installs or updates it. That is the
   launcher's own search (`AppBundleLaunch.locateMacSW`: next to the copy, `/Applications/MacSW.app`, then the
   copies that LaunchServices knows). A MacSW run from a build folder therefore does not change
   `/Applications/SOLIDWORKS.app` while `/Applications/MacSW.app` exists: that copy would carry a loader that
   `/Applications/MacSW.app` does not have, and the launcher would refuse to start. Settings names the MacSW
   that the copy would use.
3. **Not running.** No process may run whose executable is inside the target (`proc_pidpath`). This covers
   the launcher before its exec (it does not check in with LaunchServices), the Wine host after the exec and
   the open-documents helper. MacSW checks this before it unpacks and again right before the switch.
4. **Unpack and check.** `ditto -x -k --noqtn` into a hidden folder next to the target
   (`.SOLIDWORKS-install-<UUID>`, same volume). The copy must have the bundle ID, the executable SHA-256 from
   the plist and a valid signature (`SecStaticCodeCheckValidity`, strict, all architectures). Nothing is
   signed or changed. `--noqtn`: the copy never gets `com.apple.quarantine` from a downloaded MacSW.app
   (Gatekeeper would block an un-notarized copy, or App Translocation would run it from a random path).
   Quarantine is an extended attribute that the signature does not seal, so the requirement stays the same.
5. **Signature requirement.** If the installed copy's designated requirement names a certificate (stable
   identity or Developer ID) and the new copy's requirement is another one, the install stops here with
   "… is signed with another code signing identity …" unless the user confirmed the replacement (see
   "Privacy permissions"). A cdhash requirement (ad hoc) has no lasting permissions to keep: replaced
   without asking.
6. **Switch.** With an existing copy, `renamex_np(RENAME_SWAP)` exchanges both folders in one step (where the
   file system cannot do that: move aside, move in, move back on failure). A new copy is moved in with
   `RENAME_EXCL`. The superseded copy is MacSW's own and is removed (moved to the Trash if that fails). When
   its requirement differs from the new one, it is unregistered and moved to the Trash instead, so the user
   can put it back. If any step fails, the target is unchanged and the hidden folder is removed.
7. **Register.** `LSRegisterURL(target, true)`, the same as `lsregister -f`.
8. **Default app.** For the types that SOLIDWORKS.app owns (rank Owner: part, assembly, drawing and the three
   templates), `NSWorkspace.setDefaultApplication(at:toOpen:)` makes SOLIDWORKS.app the default where MacSW
   or no app is the default now. An app that the user chose for a type (Get Info > Open with) stays. MacSW.app
   stays in "Open With" for these types and keeps its own ranks (section 3).

`solidworks-app.log` gets one line per action (`MacSW install: …`, `MacSW uninstall: …`).

### Update after a MacSW update

An installed copy is **stale** when its executable is not the one in `SOLIDWORKS.app.plist`
(`ExecutableSHA256`). The executable holds both slices (launcher and Wine loader) and the code signature,
which seals the Info.plist and the resources, so the same bytes mean the same SOLIDWORKS.app build. MacSW
checks at start, on a Dock click (the launcher's "SOLIDWORKS.app is out of date" alert has an "Open MacSW"
button) and when SOLIDWORKS.app quits after a postponed update. When the pairing holds, it updates the copy
automatically with the install steps above, except when step 5 stops it: then MacSW does not retry, the
menu bar panel shows "Update SOLIDWORKS App in Settings…", and Settings asks before it replaces the copy.
Until then the stale copy may refuse to start ("SOLIDWORKS.app is out of date"); MacSW's own Launch
SOLIDWORKS still works. Each MacSW start and Dock click unpacks the payload again to check (2 MB, well under
a second). While SOLIDWORKS.app runs, the update waits until it quits; Settings says so. A certificate
signature carries its signing time, so with `MACSW_SIGN_IDENTITY` every new MacSW build updates the copy
once (2 MB, a fraction of a second).

### Privacy permissions

macOS stores privacy permissions (Desktop, Documents, Downloads, Full Disk Access) for the bundle ID and
the designated requirement. With `MACSW_SIGN_IDENTITY` the requirement of every build is
`identifier "com.yjbeetle.macsw.solidworks" and certificate leaf = H"…"`. MacSW never signs the copy, so an
update keeps that requirement and the permissions stay.

A MacSW.app built without `MACSW_SIGN_IDENTITY` (the default of `make app` and `tools/build_app_swiftc.sh`)
carries an ad hoc SOLIDWORKS.app. If such a MacSW finds a copy signed with the stable identity, it does
**not** replace it on its own (install step 5): the copy, its requirement and the permissions stay. Settings →
Maintenance → **Update SOLIDWORKS App** then asks "Replace SOLIDWORKS.app?" and says that macOS asks again for
Desktop, Documents and Downloads and that Full Disk Access must be given again. Only after **Replace** does
MacSW install the new copy; the signed copy goes to the Trash. The status line and `solidworks-app.log` say
so. The other way (ad hoc copy, signed new copy) is replaced without asking; the status line says that macOS
can ask again. Ad hoc builds have a cdhash requirement, which changes with every build.

### Uninstall

Settings → Maintenance → SOLIDWORKS App → **Uninstall…** is available only in the MacSW that the installed copy
uses (the pairing of install step 2; otherwise Settings names that MacSW, and the copy and its document
types stay as they are). It asks first, refuses while SOLIDWORKS.app runs, then
unregisters the copy (`lsregister -u`) and moves it to the Trash (`FileManager.trashItem`; it is not deleted).
The types whose default app was SOLIDWORKS.app go back to MacSW.app. SOLIDWORKS, the bottle and the user's
files do not change.

### Tests

`Tests/MacSWCoreTests/SolidWorksAppInstallerTests.swift` (temporary folders only; no /Applications, no
LaunchServices, no Trash): payload and staleness, install into an empty folder, atomic replacement of an
existing copy, the running guard before the unpack and before the switch, another app with the same name,
a damaged payload, no quarantine from a quarantined zip, a certificate-signed copy kept unless the change is
allowed (then the old copy goes to the stand-in Trash), uninstall to a stand-in Trash, the default-app rules,
the pairing, and the store (startup update, no automatic update that changes a certificate requirement, no
install or uninstall by another MacSW build, postponed update, uninstall, suggestion once per build).
With `MACSW_TEST_SIGNED_SOLIDWORKS_APP=<a signed SOLIDWORKS.app>`, a copy installed and then updated from a zip
keeps a valid signature and the same designated requirement. `scripts/tests/test_solidworks_app.py` checks
the packaging order and names, `--noqtn` and the CI archive without SOLIDWORKS.app;
`scripts/tests/test_sign_app.py` checks that `sign_app.py` refuses an embedded SOLIDWORKS.app.

## 5. Known limits

- **LaunchServices cold launch not validated for the real bundle.** All checks so far started the
  launcher from a shell (the rules of the test runs do not allow LaunchServices launches of new bundles
  from the work area), plus a C stub (`exp1`) that execs at once. Not shown: that LaunchServices keeps the
  launch's open-documents event and the bouncing Dock tile while the real launcher's preflight runs
  before the exec. With a current font-link stamp that phase is about 0.6 s plus the time a consent
  prompt waits for the user; the first start after a bottle or runtime change also runs the font-link
  check (5-18 s). Validation: section 6, step 2.
- Quitting (both modes) is checked with probe programs only, not with SOLIDWORKS (section 6, step 7).
- A second Windows GUI program (for example an error reporter, or a program a file association starts)
  still gets its own "MacSW" Dock tile, as today. It sees the inherited 0025 variables in its environment,
  but winemac ignores them there.
- Force Quit kills only the Wine host; other bottle processes stop when wineserver times out, as today.
- Quit MacSW leaves the bottle running while SOLIDWORKS.app's own SOLIDWORKS runs (the running
  SLDWORKS.exe has the bundle ID `com.yjbeetle.macsw.solidworks`). For a SOLIDWORKS that MacSW started it
  still offers "End Programs and Quit".
- `ProcessInventory` matches a process whose environment it cannot read by name. With several bottles
  running, the launcher can therefore take another bottle's SLDWORKS.exe for "already running".
- In forward mode, documents dropped while the launcher is already handing over are not picked up.
  Bringing SOLIDWORKS forward from forward mode is best effort (macOS can refuse; the log says so).
- The hand-off waits up to 240 s for the main window; after that the files are handed over even if
  SOLIDWORKS is not ready. Through the file association that could start a second SLDWORKS.exe.
- The font-link stamp trusts the registry while bottle and runtime are unchanged. If the font link is
  removed by hand, MacSW repairs it at its next start; `MACSW_LAUNCHER_FULL_PREFLIGHT=1` makes the launcher
  check every time.
- **Install, update and uninstall not yet run against /Applications** (the test rules do not allow it).
  Not shown on the real Mac: whether macOS asks MacSW for "App Management" permission before it replaces
  or moves an app bundle in /Applications. macOS protects notarized and App Store apps that way; MacSW's
  self-signed or ad hoc copy should not be affected. If macOS refuses, the step fails with the system's
  error in the status line, and the installed copy stays as it was (section 6, step 15).
- `NSWorkspace.setDefaultApplication` reports its result asynchronously; MacSW does not show it. Check the
  default app with Get Info (section 6, step 9).
- Only `/Applications/SOLIDWORKS.app` and `~/Applications/SOLIDWORKS.app` count as installed copies. A copy
  moved somewhere else is not updated; Install then puts a second one in /Applications.
- MacSW updates a stale copy without asking when SOLIDWORKS.app does not run and the designated requirement
  stays the same or the old copy is ad hoc. Then the superseded copy is removed, not moved to the Trash.
  A certificate-signed copy whose requirement would change is replaced only after the user's OK, and goes
  to the Trash.
- The Developer ID (CI) MacSW.app does not carry SOLIDWORKS.app yet: `sign_app.py` has no signing policy
  for it and refuses it (section 4, "Build").
- If MacSW is killed during an install, the hidden `.SOLIDWORKS-install-<UUID>` folder next to the target
  stays; a later install does not remove it. A symbolic link at `/Applications/SOLIDWORKS.app` is replaced by
  a real copy; the copy it pointed to is not updated.
- Test switches (launcher only): `MACSW_LAUNCHER_DELAY=<s>` waits before the preflight,
  `MACSW_LAUNCHER_FULL_PREFLIGHT=1` ignores the font-link stamp, `MACSW_SKIP_LOADER_CHECK=1` skips the
  loader comparison.

## 6. Validation with SOLIDWORKS (to do on the real bottle)

1. Build MacSW.app with 0025 (`make app` or `tools/build_app_swiftc.sh --full`) with `MACSW_SIGN_IDENTITY`,
   install it in /Applications, run the Wine maintenance "upgrade" (winemac.so changes the runtime
   identity), then Settings → Maintenance → SOLIDWORKS App → Install SOLIDWORKS App.
   `codesign -d -r- /Applications/SOLIDWORKS.app` names the certificate leaf.
2. LaunchServices cold launch, before any other step. Quit MacSW. Then:
   - `launchctl setenv MACSW_LAUNCHER_DELAY 60`, then `open -a /Applications/SOLIDWORKS.app part.sldprt`
     with SOLIDWORKS closed. During the 60 s and after the exec, `lsappinfo list` shows exactly one record
     with `com.yjbeetle.macsw.solidworks` (Foreground once checked in), the Dock shows one bouncing tile, and
     `solidworks-app.log` then shows `open-documents: 1` and the part opens. `launchctl unsetenv
     MACSW_LAUNCHER_DELAY` afterwards.
   - Once more with a fresh consent state (`tccutil reset SystemPolicyDesktopFolder
     com.yjbeetle.macsw.solidworks`), leaving the consent prompt open for about 60 s.
   - If the document or the tile is lost: keep the pre-exec phase short (the stamp does most of it) and
     record the limit here.
3. Open SOLIDWORKS.app from Finder, Launchpad and Spotlight: one Dock tile "SOLIDWORKS" with the SW icon;
   `lsappinfo` shows `com.yjbeetle.macsw.solidworks`, Foreground, x86_64; no "MacSW" tile; menu bar
   "SOLIDWORKS".
4. Consent: with a fresh TCC state the Desktop/Documents/Downloads prompts name "SOLIDWORKS" and appear
   before Wine starts; after Allow, no prompt in the Wine phase and no wineserver freeze.
5. Activation/licence: SOLIDWORKS starts licensed (same bottle, same Wine). Check `sw_launch.log`,
   `solidworks-app.log`.
6. Dock: keep in Dock, quit, click the tile: starts again. Click the tile while running: comes to the front.
   Documents: double-click a .sldprt while it runs (opens in the same instance; no second SLDWORKS.exe).
   Several files at once. Drop a file on the Dock tile.
7. Quit, default mode: open a part, change it, then Command-Q. Then the same with Dock > Quit. SOLIDWORKS
   asks to save; Cancel keeps it running; Don't Save quits. The next start has no Document Recovery and
   settings persist. Note whether `sldworks_fs.exe` keeps running. If any of this fails, repeat with the
   close mode (`defaults write com.yjbeetle.macsw MacSW.solidWorksAppQuitClosesWindows -bool true`, start
   again) and keep the mode that passes.
8. MacSW.app while SOLIDWORKS.app runs: its menu-bar panel shows the instance; "Quit SOLIDWORKS" and force
   stop still work; "Quit MacSW" quits MacSW only and SOLIDWORKS keeps running. Start SOLIDWORKS from MacSW,
   then click SOLIDWORKS.app: it is brought forward (forward mode), no second instance.
9. Default handler: Get Info on a .sldprt shows SOLIDWORKS. Settings → Maintenance → SOLIDWORKS App →
   Uninstall…: the copy is in the Trash, Get Info shows MacSW and a double-click opens it in MacSW's
   SOLIDWORKS. Install again for the next steps.
10. Performance: App Nap stays off for the host (0025 keeps the activity), view rotation as before.
    Start SOLIDWORKS.app and switch to another app at once: start-up time as with a MacSW launch.
11. File > Open in SOLIDWORKS browses Desktop/Documents without a new consent prompt (one identity for
    both slices).
12. Rosetta-cold first start with a document: the hand-off waits up to 240 s for the main window; check
    that no second SLDWORKS.exe appears if the start takes longer.
13. `defaults read com.yjbeetle.macsw MacSW.wineLocale` matches the language SOLIDWORKS uses (the launcher
    reads MacSW's preferences domain).
14. Stale loader: with SOLIDWORKS.app installed, replace /Applications/MacSW.app with a build that has another
    loader, and start SOLIDWORKS.app before MacSW: it shows "SOLIDWORKS.app is out of date" and Wine does
    not start. "Open MacSW": MacSW updates SOLIDWORKS.app (`MacSW install: … (replaced …)` in
    `solidworks-app.log`), and SOLIDWORKS.app starts. If the installed copy has the stable identity and the
    new MacSW build is ad hoc, MacSW does not replace it: the menu bar panel shows "Update SOLIDWORKS App in
    Settings…", and Settings asks before it replaces the copy (the old one goes to the Trash).
15. Update keeps the permissions: with the stable identity, grant Desktop/Documents/Downloads to
    SOLIDWORKS.app, then install a newer MacSW build in /Applications and start it. MacSW updates
    SOLIDWORKS.app at start (no App Management prompt expected; note it if one appears), the designated
    requirement is unchanged, and the next SOLIDWORKS.app start asks for no folder access. With
    SOLIDWORKS.app running, the update waits and happens when it quits.
