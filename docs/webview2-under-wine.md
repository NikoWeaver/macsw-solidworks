# Microsoft Edge WebView2 under the MacSW Wine 11.16 runtime

Status: **PASS** (2026-10-23). A minimal WebView2 host creates the environment and the controller, navigates, and
the page pixels reach the host window. This needs two things together:

1. Wine patch **0018** (`win32u` cross-process window surfaces), enabled with `MACSW_CROSS_PROCESS_SURFACES=1`.
2. Windows version **win7** for `msedgewebview2.exe` only (`HKCU\Software\Wine\AppDefaults\msedgewebview2.exe`,
   `Version=win7`).

No `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` are necessary.

Host: Apple M2 Pro, macOS 27.0, Rosetta. Runtime: `runtime/wine-11.16-macsw` + patched `win32u.so` (private copy).
WebView2 runtime: Evergreen standalone 156.0.4314.42 (Chromium 156.0.8078.48). SolidWorks 2026 uses WebView2 only
for web task panes and web content, so this is a nice-to-have.

## 1. Winning configuration

| Item | Value |
|---|---|
| Wine | MacSW Wine 11.16 with patches 0001-0018 (0018 only changes `win32u.so`) |
| Environment | `MACSW_CROSS_PROCESS_SURFACES=1` (Unix environment of the Wine process; child processes inherit it) |
| Registry | `[HKCU\Software\Wine\AppDefaults\msedgewebview2.exe]` `"Version"="win7"` |
| Browser arguments | none |
| Result | Environment + controller OK; `data:` page (magenta) 81/81 sampled host pixels correct; https://example.com rendered (background `#eeeeee`); `CapturePreview` and DevTools `Page.captureScreenshot` OK |

With win7, Chromium uses software compositing (`--disable-gpu-compositing --use-gl=disabled` in the GPU process)
and does not need DirectComposition.

Note: on a cold start the first frame appears about 9-10 s after `NavigationCompleted` (Chromium start-up under
Rosetta). Later navigations show within 4 s. The page is correct after that delay; it is not a hang.

## 2. Test matrix (test host `wv2test.exe`, one change at a time)

| Run | Windows version | Patch 0018 + env | Browser arguments | Result |
|---|---|---|---|---|
| a | win10 (default) | no | none | GPU process crashes (`0x80000003`); `fixme:dcomp:DCompositionCreateDevice` (WineHQ bug 58921); no frames |
| b | win7 | no | none | Navigation and `CapturePreview` OK, **host window black** (frames not presented) |
| c8 (control) | win7 | built, env **not** set | none | Host window black for 30 s: **FAIL** |
| c6/c7/e | win7 | yes | none | **PASS**: host pixels magenta, then example.com |
| d | win10 | yes | none | Browser process crash `0x80000003`, black: FAIL |
| d | win10 | yes | `--disable-gpu` | FAIL (same crash) |
| d | win10 | yes | `--disable-gpu --disable-gpu-compositing` | FAIL (`CapturePreview` 0x8007139f, black) |
| d | win10 | yes | `--in-process-gpu` | FAIL (same) |
| d | win10 | yes | `--no-sandbox` | FAIL (same) |
| c5 | win7 | yes | `--disable-features=CalculateNativeWinOcclusion` | No change (first frame still late); not needed |
| f | win10 | yes | `--single-process` | FAIL (`CapturePreview` 0x8007139f, black) |
| f | win7 | yes | `--single-process` | PASS as well; not needed and not recommended (Chromium marks it unsupported) |

## 3. Cause and patch 0018

Window tree in the host process: `Chrome_WidgetWin_0` (host process) -> `Chrome_WidgetWin_1` (browser process)
-> `Chrome_RenderWidgetHostHWND` (browser process). In `dlls/win32u/dce.c` `update_visible_region()`, a DC gets a
window surface only if its top-level window belongs to the current process. Chromium draws from the browser
process, so with winemac every frame was lost. winex11 avoids this with `X11DRV_GetDC`; winemac cannot (WineHQ bug
35456). This is a clear Wine limitation, so a patch was written.

Patch: `MacSW/patches/wine-crossover/0018-win32u-cross-process-window-surfaces.patch`, branch `webview2`
(worktree `wt-webview2`), commit `a8ef971`. It applies on top of 0001-0017.

* Drawing process: when the top-level window of a client-area DC belongs to another process and
  `MACSW_CROSS_PROCESS_SURFACES=1` is set, draw into a DIB in the named section
  `\Sessions\<n>\BaseNamedObjects\__wine_foreign_surface_<pid>_<hwnd>_<id>`. On flush (after `ReleaseDC` and
  on idle) post the internal message `WM_WINE_FOREIGN_SURFACE` to the top-level window (coalesced; resent after
  500 ms without answer).
* Owner process: the thread of the top-level window maps the section and copies it with `SetDIBitsToDevice`
  into its own window surface through `GetDCEx(child, DCX_CACHE | DCX_USESTYLE)`, so normal clipping applies.
  The shared header is untrusted (any process of the prefix can write the section or post the message): the
  receiver reads magic, width and height once into locals, accepts at most 16384 x 16384 (the sender's limit)
  and checks `width * height * 4` against the mapped view without an overflowing multiplication (hardening
  after the security audit of 2026-10-24, finding 8).
* Without the variable, the code path is never entered on either side: the drawing process uses no shared
  surface and the owner ignores `WM_WINE_FOREIGN_SURFACE`. SOLIDWORKS itself does not draw across processes.
* Debug channel: `WINEDEBUG=+xsurface`.
* Known limits: a full-size copy per flush (fine for task panes, not for video); shared surfaces of a destroyed
  window are freed only on resize or process exit; no alpha/layered-window support (not needed here).

## 4. Reproduce

Files (outside the repo, `build.nosync/webview2-wine/`):

* `source/` patched Wine 11.16 tree (git: commit `base` = 0001-0017, working tree = 0018); `build/` configured
  build; `work/build.sh` (configure + make; use `make -C build -j4 dlls/win32u/win32u.so` to rebuild only win32u).
* `work/install-runtime.sh`: clones `runtime/wine-11.16-macsw` to `build.nosync/webview2-runtime` (APFS clone)
  and installs the patched, ad-hoc signed `win32u.so`. The original runtime is not changed.
* `work/src/wv2test.c`, `work/bin/{wv2test.exe,WebView2Loader.dll}`: test host. Build:
  `x86_64-w64-mingw32-gcc -O1 -o wv2test.exe wv2test.c -I../sdk/include -lole32 -lshlwapi -luuid -lgdi32 -luser32`
  (WebView2 SDK 1.0.4314.35 headers). It samples 81 points of the host client area every 2 s until they match.
* `work/run.sh <log> [url1 [url2]]` with `ENVFILE=work/env-patched.sh MACSW_CROSS_PROCESS_SURFACES=1`. It stops
  only its own prefix (`wineserver -k`) and `wv2test.exe`.
* Prefix: `build.nosync/prefix-webview2` (WebView2 runtime installed with the standalone installer, `Version=win7`
  for `msedgewebview2.exe` set). Logs: `work/logs/` (`e-final-win7.log` is the passing run).

## 5. Apply to the SolidWorks bottle (wired in MacSW: steps 1-3 are automatic for new installs)

Do this only when no installation is running in the bottle.

1. Ship patch 0018 in the runtime: add it to `scripts/build_winemac.sh` like 0015 (path variable, SHA-256 in
   `BUILD_KEY`, `git apply --check` + `git apply`) and add a test like `scripts/tests/test_wine_pe_mapping.py`.
   Rebuild the runtime and the app. Only `win32u.so` changes; the code is inactive without the variable.
2. Set `MACSW_CROSS_PROCESS_SURFACES=1` in the environment the launcher gives to Wine for SOLIDWORKS (the
   variable must be in the environment of both `SLDWORKS.exe` and `msedgewebview2.exe`; children inherit it).
3. In the bottle (as the bottle user, with the bottle's Wine):
   `wine reg add "HKCU\Software\Wine\AppDefaults\msedgewebview2.exe" /v Version /t REG_SZ /d win7 /f`
   This applies only to `msedgewebview2.exe`; SOLIDWORKS keeps its own Windows version.
4. The WebView2 runtime must be installed in the bottle (the SOLIDWORKS installer normally installs it; otherwise
   use `MicrosoftEdgeWebView2RuntimeInstallerX64.exe /silent /install`).
5. Check: open a SOLIDWORKS web task pane (for example "SOLIDWORKS Resources" / 3DEXPERIENCE panes). Expect the
   first page to take about 10 s on a cold start.

## 6. Downloads (all from Microsoft domains)

| File | Source | SHA-256 |
|---|---|---|
| `MicrosoftEdgeWebView2RuntimeInstallerX64.exe` (214,823,632 B, runtime 156.0.4314.42) | `go.microsoft.com/fwlink/?linkid=2124701` → `msedge.sf.dl.delivery.mp.microsoft.com` | `9b0142e22e8daa92855d746ae4d1e9eeef561ccaf67d1dd452165c4af3df3191` |
| `MicrosoftEdgeWebview2Setup.exe` (bootstrapper, 1,876,736 B) | `go.microsoft.com/fwlink/p/?LinkId=2124703` → `msedge.sf.dl.delivery.mp.microsoft.com` | `f414de01c4680f0bb0694d1ea7803c6968f3a81bf6bad01b89bfc65dce14c2a2` |
| `microsoft.web.webview2.1.0.4314.35.nupkg` | `api.nuget.org` | `90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4` |

Both .exe files carry an Authenticode signature from "Microsoft Corporation" (issuer Microsoft Code Signing PCA
2024); the nupkg has the Microsoft author signature and the NuGet.org repository signature.
