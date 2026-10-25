# Compatibility reports

MacSW 的应用版本与 SOLIDWORKS 版本相互独立。构建所使用的 Wine、Wine-Mono 和补丁产物由
[`config/versions.env`](../config/versions.env) 固定；SOLIDWORKS 版本只记录为验证结果，不参与
Builder 的版本选择。

## Maintainer-verified baseline

| SOLIDWORKS | MacSW | Wine / Mono | Host | Result | Remaining coverage |
| --- | --- | --- | --- | --- | --- |
| 2025 SP5.0 | `e7c705a`, `0.1.0` (1) | Wine 11.16 / Wine-Mono 11.3.0 | Apple Silicon, macOS 15.6 | Clean install through the App completed; automatic Login Manager/COM registration removed the startup error; main window and Part document verified; FeatureManager clipping, CommandManager expand/collapse, Task Pane redraw, composite context-menu commands, mouse gestures, and PropertyManager confirmation verified; the same-binary AppCompat A/B isolated and fixed Wine's same-window capture resend; the patched Wine driver preserved the model across blank-canvas clicks and focus loss and kept edge preselection visible | Save/reopen after a fresh launch, Toolbox, display hot-plug, and mouse-gesture transparency |

This table records observed behavior, not a promise that every component or workflow is supported.

## SWCLI development snapshot (2026-10-08)

The configured baseline is now SWCLI `0.1.0a6.dev0` at `fb147c1`; this is a
development snapshot, not a published a6 release. With the bitmap-only FBO
Wine patch, the existing local main bottle passed the unchanged shared
modeling → driving-dimensions sequence in both visible and hidden owned
hosts. Each mode completed 85 modeling events and 242 dimension events with
zero cleanup errors, without restarting between gates. The eight-case native
DIB/WGL pixel probe also passed; real BMP content is verified separately from
file existence and API return values.

The rebuilt App passed manifest/module/signature verification. The current
offline baseline is 66 MacSW Python tests (1 expected skip), 141 Swift tests,
and 621 SWCLI tests (8 expected macOS skips). These are local results, not
hosted runtime approval: the latest completed hosted run `37746169893` still
failed at native `CloseDoc / 0x800703e6` before driving/hidden gates. See the
[native investigation](native-modeling-investigation.md) for the bitmap proof,
earlier failures, and the separate remaining hosted-CI issue.

### Earlier same-day a5 investigation (historical)

The earlier baseline pinned SWCLI `0.1.0a5.dev0` at `b1c78d3`. This was a development
snapshot, not a published a5 release. Native macOS clients and Wine Windows
workers both include checksum-locked JSON Schema dependencies; the `rpds-py`
extension is packaged separately for ARM64 macOS and AMD64 Windows Python 3.11.

Verified locally:

- 133 Swift tests, 547 SWCLI tests (8 expected macOS skips), and 5 offline
  dependency-packaging tests passed.
- A complete fresh App was built and passed `verify_app.sh`; the deployed App
  was then verified against the same source and dependency manifest.
- Both the native client and the installed Wine Python imported the complete
  dependency set successfully. The foreground `daemon serve` launcher also
  has a regression test for its Windows Python path.

At that stage the real modeling sequence was **not yet verified on this Mac**. Before the
complete App replacement, the long-running main bottle acquired SOLIDWORKS
2025 SP5.0 in hidden mode, but the generic gate's first `document create` did
not return within its 600-second outer deadline. It never reached the driving
dimension gate or the later `InsertSketch` operation that failed on Linux
Wine. Subsequent visible COM activation failed even though `doctor` still
found the registered local server and its executable. This is diagnostic
evidence, not proof of the same Linux exception or its cause.

After full App replacement and a confirmed cold restart, an owned **visible**
host successfully created parts and ran the generic gate's three-plane
rectangle/circle extrusions, forward/reverse cuts, native save/read-only reopen,
and intentional nonintersecting-cut rejection/cleanup checks. It then failed
at the installed `Paper Airplane.SLDPRT` open, before driving dimensions ran.
This was an internal SOLIDWORKS error, **not** an outer deadline termination.
The failed open left an inactive native document; attempting to close that
partial document timed out and the owned worker/host were terminated. Preserve
this failed run rather than reporting it as a passing generic gate.

A separate fresh-host path comparison isolated a MacSW translation problem:
the sample opened and closed successfully through `C:\\...`, while its
`Z:\\...bottle\\drive_c\\...` alias returned the internal error and left a
partially opened document. The sample's SHA256 matched the Linux control, so
this was not evidence of a different/corrupt sample. MacSW `c83ace3` now reads
the active prefix's actual `dosdevices` mappings without starting Wine, chooses
the most specific matching drive root, and refuses unmapped local paths.
It neither assumes Z exists nor changes the user's drive configuration.

The deployed corrected App passed full packaging verification, including a
fixture deliberately **without Z**. Eleven path tests and five dependency
packaging tests passed; the earlier full test run also passed 133 Swift and
547 SWCLI tests (8 expected skips). Using the original Unix sample path through
the installed `sw-cli` now reports native `C:\\...`, `api_errors=0` and
`api_warnings=0`; normal close followed by `document list` confirms **count 0**.
This establishes the path fix, not the full generic -> driving sequence or the
root cause of Linux's separate unsaved-part `InsertSketch / 0x800703E6` failure.

Keep these experiments separate from the graphics/manual baseline above.
The required follow-up was to start from a confirmed healthy host, run generic
modeling followed by driving dimensions in **one unchanged COM session**, and
retain all failures. Passing driving dimensions alone or restarting between
the two gates does not establish that sequence's correctness.

## Community reports

Compatibility reports are welcome as pull requests. Add one row below and include enough evidence to distinguish
an application regression from a Wine, installer, licensing, graphics, or host-specific issue.

| SOLIDWORKS | MacSW commit/release | Wine / Mono | macOS and hardware | Install | Launch | Modeling depth | Known issues | Evidence / PR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| _Example: 2025 SP5.0_ | _commit SHA or release_ | _from BuildManifest.plist_ | _macOS version, Mac model/chip, displays_ | _pass/fail_ | _pass/fail_ | _new part / sketch / feature / save-reopen_ | _short summary_ | _log, screenshot, or PR link_ |

Please redact serial numbers, license files, user names, and local paths before attaching logs. A useful report should
also state whether the bottle was clean or reused and whether the failure is reproducible after restarting MacSW.
