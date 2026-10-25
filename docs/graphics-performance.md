# Graphics performance: patch 0030 (opengl32 batches immediate-mode calls)

Date: 2026-10-24. Branch `gfx` (worktree `wt-gfx`): patch, build wiring and tests in commit 6cb8cb5 on top of
`integrate` c53bda3. Evidence: `build.nosync/gfx2/` (sessions, screenshots, diffs, probe output, tools). The
stopped first round is in `build.nosync/gfx/`; its summary is `docs/perf-round2-findings.md`.

## Summary

Patch 0030 makes the SOLIDWORKS 3D view 5-7 times faster, and in every scene tested it draws the same pixels.

| Question | Answer | Evidence |
|---|---|---|
| Speed (8 interleaved pairs, bottle-g1, WMI-fixed runtime) | full redraw 349 -> 49 ms (paired ratio 0.15), rotate step 586 -> 117 ms (0.20, about 1.7 -> 8.6 steps per second including 2 COM calls each), assembly open 15.2 -> 11.0 s (paired 0.85, noisy) | section 4 |
| Start time | no measurable change: 55.6 s without, 47.6 s with (paired ratio 1.07, range 0.72-1.44; load average 8-47) | section 4 |
| Correctness | every call that returns a value, reads state, can report an error, switches context or presents/reads pixels flushes first; a GL debug callback turns batching off; the probe gives identical results with and without batching | section 2 |
| Round-2 image difference (`diff-ab1-1*.png`) | not a rendering change: the round-2 screenshots were taken right after `bench-rotate` returned, while the slow unbatched arm still showed an intermediate frame. Taken at the same moment, every unbatched session reproduces the round-2 "ctl" image exactly (0 px) and every batched one the settled image; after an explicit redraw both are identical | section 3 |
| New screenshots (assembly before/after rotation, part shaded with edges, shaded, selection highlight, section view, drawing) | graphics area pixel-identical to the unbatched reference in 55 of 63 batched shots and 54 of 56 unbatched ones; the rest are 1 hover highlight under the mouse pointer, 2+3 scaled-down captures, and 4 shots of the one session whose assembly did not open (different window layout) | section 3 |
| Round-2 cold start that hit the 300 s timeout | harness and shared-bottle artefact, not the patch: the round-2 timeouts hit the unbatched and stock runtimes too; 9 of 9 cold starts with the patch in my own bottle reached the main window (38-96 s) | section 5 |
| Integration | branch `gfx` = `integrate` c53bda3 + commit 6cb8cb5; 0030 applies after 0001-0025 and 0028 on a pristine 11.16 tree; script tests 264/264 OK | section 6 |

## 1. Mechanism

SOLIDWORKS 2026 draws the model in OpenGL immediate mode. Per frame of the 9-plate test assembly it makes about
585,000 opengl32 calls, 99 % of them `glVertex3fv`, `glNormal3fv`, `glBegin` and `glEnd`
(`build.nosync/gfx/prof/glstats-ctl.txt`). In Wine 11 every call of the PE `opengl32.dll` is a unix call. On
macOS the dispatcher switches the gs base twice per call; under Rosetta 2 one `glVertex3fv` therefore costs about
0.44 us (`docs/performance-tuning.md` §3.1). That is about 250 ms per frame before the GPU does anything.

Patch 0030 changes only `dlls/opengl32`:

- The PE side records 19 entry points in a 64 KB buffer per thread (TEB `glReserved1[6]`): `glBegin`, `glEnd`,
  `glVertex2f/2fv/3f/3fv/3d/3dv`, `glNormal3f/3fv/3d/3dv`, `glColor3f/3fv/4f/4fv`, `glTexCoord2f/2fv/2d`.
  None of them returns a value or reads state. Pointer arguments are copied when the call is recorded.
- A new unix call, `macsw_gl_batch`, replays the buffer with the same driver functions (the `v` forms). It is
  appended to both call tables, so the indices of the generated calls stay the same.
- Every other unix call of opengl32 flushes the buffer first: `UNIX_CALL` (used by every generated thunk and by
  `wgl.c`) becomes `(gl_batch_flush(), WINE_UNIX_CALL(...))`. Thread detach also flushes.
- Installing a GL debug message callback (`glDebugMessageCallback`, `...ARB`, `...AMD`) turns batching off for
  the process.
- `MACSW_GL_BATCH=0` turns batching off. The variable is on the environment allowlist of `WineService` and
  `wine_runtime.py`, so it reaches SOLIDWORKS when it is set in MacSW's environment.
- Only the x86_64 opengl32 batches; the 32-bit one is the stock module.

Changes against the stopped round-2 version: the debug-callback rule, bounds checks in the unix replay, the
allowlist entry, and the build wiring after patch 0028 (the round-2 wiring was written against 0022).

## 2. Correctness review

Rule: a call that returns a value, reads state, can make an error visible, changes the current context, thread or
DC, or presents or reads pixels must see every earlier command. In this patch every such call is a unix call,
and every unix call flushes first. `scripts/tests/test_wine_opengl_batch.py` checks that the batch is the only
unix call that bypasses the flushing macro and that only the 19 `void` immediate-mode functions record.

| Call or situation | How it sees the recorded calls | Checked by |
|---|---|---|
| `glGet*`, `glIsEnabled`, `glIsList`, `glGetPointerv`, `glGetString(i)` | generated thunks or `wgl.c` wrappers, all through `UNIX_CALL`; the PE-only answers (`GL_VENDOR`, `GL_NUM_EXTENSIONS`, object-name mapping) come from PE bookkeeping that recorded calls do not change | probe: current color, normal, texcoord, `glIsEnabled`, `glIsList` |
| `glGetError` | `UNIX_CALL` flushes; the driver sets the error flags during the replay, in call order. The PE-side `set_gl_error` first calls `glGetError` (a flush); the unix-side one runs inside a unix call (after the flush). The error sequence is therefore the same. | probe: nested `glBegin`, `glEnd` without `glBegin`, invalid mode, `glGetError` between `glBegin` and `glEnd` |
| GL debug output (KHR/ARB/AMD) | a synchronous message would come from the flush instead of the call, so installing a callback turns batching off | code and test; not run (the macOS GL 2.1 context has no debug output) |
| `glReadPixels`, `glCopyPixels`, `glDrawPixels`, `glFinish`, `glFlush` | `UNIX_CALL` | probe: read-back hash |
| `SwapBuffers` (gdi32), `wglSwapBuffers`, `wglSwapLayerBuffers` | gdi32 `SwapBuffers` calls opengl32 `wglSwapBuffers` (`dlls/gdi32/opengl.c`); it and `wglSwapLayerBuffers` end in `UNIX_CALL( wglSwapBuffers )` | code |
| `wglMakeCurrent`, `wglMakeContextCurrentARB`, `wglDeleteContext`, `wglCopyContext` | all reach `UNIX_CALL( wglMakeContextCurrentARB )` or `UNIX_CALL( wglDeleteContext )`; the flush runs while the old context is still current, so the commands go to the context they were made in | probe: two contexts on one thread |
| `wglShareLists`, `wglGetCurrentContext/DC`, `wglGetProcAddress` | PE-only; they read no GL state that recorded calls change | code |
| Display lists (`glNewList`, `glEndList`, `glCallList(s)`) | unix calls; calls recorded between `glNewList` and `glEndList` are replayed before `glEndList`, so they are compiled into the list | probe: the list is drawn into the hashed frame |
| Selection and feedback (`glSelectBuffer`, `glFeedbackBuffer`, `glRenderMode`, `glInitNames`, `glPushName`, `glLoadName`) | unix calls; the buffers are defined only after `glRenderMode` returns, and it flushes first | probe: hit records and feedback values |
| Threads | one buffer per thread; the replay uses the calling thread's `glTable` (a context is current in one thread only); thread detach flushes and frees the buffer | probe: a second thread that only calls `wglMakeCurrent(NULL, NULL)` before it exits |
| No current context | the replay uses the null table and skips the calls, like the unbatched thunks (which return `STATUS_NOT_IMPLEMENTED`) | code |
| Truncated or corrupt buffer | the replay checks every record against the end and stops with an `ERR` | code and test |

Remaining differences (by design; not seen with SOLIDWORKS):

- Commands after the last GL call of a thread stay in its buffer until that thread makes another GL call. GL
  promises completion only after `glFlush`, `glFinish` or a buffer swap, and all of them flush. A program that
  draws into the front buffer and then waits without `glFlush` would show that drawing later. On macOS such
  drawing is not shown without `glFlush` either: win32u presents front-buffer rendering from its
  `glFlush`/`glFinish` wrappers.
- A window that is read back without GL (`BitBlt`/`PrintWindow` of an OpenGL window, patches 0011 and 0013) shows
  the latest commands only if the program flushed or swapped first, which GL already required.
- `TerminateThread` on a drawing thread, and process exit, drop the recorded calls, like unflushed commands.

### Probe under Wine (no SOLIDWORKS)

`scripts/diagnostics/check_opengl_batch.c`, run in a scratch prefix (`build.nosync/gfx2/micro/`): patched runtime
with `MACSW_GL_BATCH=0` and with batching (twice each), and the unpatched control build. All 16 `query` lines are
the same in the five runs (error codes `0x0502`, `0x0502`, `0x0500`, `0x0000`/`0x0502`, the current state,
`select_hits=2`, 6 feedback values, read-back hash `2f570d7c`, second context, second thread). The 600,000-call
frame takes 260-268 ms without batching and 11.6-16.4 ms with it (434 against 19-27 ns per call).

## 3. Images: before and after

### The round-2 difference

`build.nosync/gfx/perf/diff-ab1-1.png` shows 6,764 differing pixels (0.18 % of the window, max 177) at the hole
walls of all 9 plates between the unbatched ("ctl") and batched runs; `diff-ctl-ctl.png` is empty. The round-2
ctl and batch screenshots are each identical among themselves, so the difference was systematic, but:

- The unbatched control was code-identical in both rounds: the `.text` section of round 2's `dlls/ctl/opengl32.dll`
  equals mine (`ctl2`), and the `.so` files are byte-identical. Round 2's batched DLL equals a rebuild of its
  committed tree (9fffc3a).
- Round 2 took the screenshot right after `swapi bench-rotate`, which ends with `ShowNamedView2` +
  `ViewZoomtofit2` and returns before SOLIDWORKS has drawn the final frame. My sessions take the same shot at the
  same moment (`asm-norefresh.png`) and then one more after `GraphicsRedraw2` and 1 s (`asm-after.png`). Hole
  region (966 x 898 px) compared with round 2's images:

| Shot | Unbatched sessions (8) | Batched sessions (7) |
|---|---|---|
| right after `bench-rotate` vs round-2 "ctl" image | 0 px in all 8 | 6,764 px in all 7 |
| right after `bench-rotate` vs settled image | 6,764 px in all 8 | 0 px in all 7 |
| after redraw + 1 s vs settled image | 0 px in all 8 | 0 px in all 7 |

So the round-2 "ctl" image is an intermediate frame of the slow arm (about 0.4 s per redraw); the batched arm had
already drawn the final one. With the same settle time the two arms give the same pixels.

### New screenshots

Each session (`tools/session5.sh`) saves 7 window screenshots (2406 x 1558 px): the 9-plate assembly before any
rotation (`asm-static`) and after the rotate benchmark plus a redraw (`asm-after`); the 50-hole plate in "shaded
with edges" (`part-swe`) and "shaded" (`part-shaded`); the same plate with `Cut-Extrude1` selected (blue selection
highlight, `part-select`); a section view on the Right Plane (`part-section`); and a drawing with three views
(`drw`, `Block Test 1.SLDDRW`). Reference: the first unbatched session (`warm-ctl-171124`). Compared over the
graphics area (x 470-1730, y 240-1500 px) and over the whole window (`tools/imgcmp.py`; masks in
`build.nosync/gfx2/diffs/final/`, list in `diffs/final/imgcmp.txt`):

| Scene | Unbatched: identical / shots | Batched: identical / shots | Flush-each diagnostic build |
|---|---|---|---|
| assembly, before rotation | 8 / 8 | 8 / 9 | 1 / 1 |
| assembly, after rotation | 8 / 8 | 8 / 9 | 1 / 1 |
| part, shaded with edges | 8 / 8 | 8 / 9 | 1 / 1 |
| part, shaded | 8 / 8 | 8 / 9 | 1 / 1 |
| part, selection highlight | 8 / 8 | 8 / 9 | 1 / 1 |
| part, section view | 7 / 8 | 7 / 9 | 1 / 1 |
| drawing | 7 / 8 | 8 / 9 | 1 / 1 |

Every shot that is not identical is explained, and none by rendering:

- Session `ab1-batch`: the assembly open failed (section 4), the Design Library pane stayed collapsed, so its
  assembly, section and drawing shots have another window layout; its other 3 shots are scaled-down captures.
- 2 unbatched shots (`ab1-ctl`) and the 3 above are scaled-down captures (708 x 460 px and similar): macOS
  sometimes returned a reduced copy of the window. `session5.sh` now retries until the capture has full size.
- `ab2-batch` section view: orange outline of the face under the mouse pointer (SOLIDWORKS dynamic highlight).
- Outside the graphics area only: a toolbar button in hover state with its tooltip in the status bar (`ab6-batch`,
  part shots and drawing) and the title-bar tint of an inactive window (`ab8-batch` section view).

The flush-each diagnostic build (`rt-diag`: every recorded call is replayed at once, one unix call each) gives the
same pixels too, which also rules out the `v`-form replay as a source of differences.

## 4. Speed

Method:

- Bottle `bottle-g1`: APFS clone of `bottle-perf2` (SOLIDWORKS 2026 SP4.1, not activated; the activation wizard is
  answered "activate later" after `wtool` has checked the radio states). Test files copied to `C:\gfx`.
- Runtimes: APFS clones of the `integrate` ac96ef9 app runtime (`build.nosync/app-prev-ac96ef9`) with the WMI-fixed
  `wbemprox.dll` (x86_64 and i386, `build.nosync/wmi/dll`). `rt-ctl` has opengl32 built from the same Wine tree
  without 0030, `rt-batch` with the final 0030 (`build.nosync/gfx2/dlls/{ctl2,batch2}`). One warm-up session per
  runtime first (Rosetta translation of the copied runtime).
- Each session is a cold start (no process of the bottle running, wineserver gone) through
  `tools/sw_launch_g1.sh` (MacSW's launch environment), with a `sw_slot.sh` slot. Start = launch to the SOLIDWORKS
  main window, polled every 1 s with `wtool` (Win32 side) and every 2 s by the harness (macOS window of at least
  800 x 500 pt). At session age >= 75 s and >= 25 s after the main window: open the assembly (`OpenDoc6` only),
  iso view, redraw, then `swapi bench-rotate 36 2` (2 x 36 steps of `RotateAboutCenter` 10 degrees +
  `GraphicsRedraw2`, then 36 `GraphicsRedraw2`, then 36 pairs of trivial COM calls); open the part and the
  drawing; `ExitApp`.
- Order ctl, batch, ctl, batch ... (8 pairs, 17:39-19:14). The machine was very busy: up to 4 other agents'
  SOLIDWORKS sessions, the owner's SOLIDWORKS, Spotlight and a screen recorder; 1-minute load average 8-47. Only
  the relative numbers mean something; the "paired ratio" is batch/ctl within each pair.

| Metric (median, min-max, n) | Without 0030 | With 0030 | Ratio of medians | Paired ratio, median (range) |
|---|---|---|---|---|
| Full redraw (`GraphicsRedraw2`, incl. 1 COM call) | 348.7 ms (301.3-584.2, 8) | 48.6 ms (41.7-88.7, 7) | 0.14 | 0.15 (0.10-0.16) |
| Rotate step (2 COM calls) | 585.6 ms (496.8-803.9, 8) | 116.8 ms (101.4-174.5, 7) | 0.20 | 0.20 (0.18-0.23) |
| Rotate step, 90th percentile | 724.1 ms (618.8-1157.4, 8) | 136.8 ms (107.5-339.5, 7) | 0.19 | 0.18 (0.12-0.30) |
| COM pair (2 trivial calls) | 55.3 ms (44.0-114.8, 8) | 59.3 ms (41.3-92.2, 7) | 1.07 | 1.06 (0.86-1.35) |
| Assembly open (first document) | 15.2 s (10.9-20.4, 8) | 11.0 s (9.3-23.4, 7) | 0.72 | 0.85 (0.59-1.15) |
| Part open | 3.1 s (2.0-6.7, 8) | 2.5 s (2.2-18.1, 8) | 0.79 | 0.96 (0.68-2.72) |
| Drawing open | 10.1 s (5.9-22.0, 8) | 7.2 s (6.5-13.3, 8) | 0.71 | 0.90 (0.54-1.21) |
| Start to main window (`wtool`) | 55.6 s (35.1-83.1, 8) | 47.6 s (38.3-95.7, 8) | 0.86 | 1.07 (0.72-1.44) |
| Start to main window (harness) | 52.5 s (35-82, 8) | 48.0 s (38-94, 8) | 0.91 | 1.09 (0.74-1.59) |

- Without the COM overhead (half a COM pair per redraw, one pair per rotate step) the drawing itself takes about
  320 ms vs 24 ms per redraw and 530 ms vs 58 ms per rotate step: from about 2 to about 17 frames per second.
- Round 2 (3 runs each, `bottle-crashlab`) measured 306.5 -> 42.4 ms and 484.4 -> 96.3 ms: the same ratios
  (0.14, 0.20). The absolute numbers here are higher because of the load.
- Opening documents is probably faster too (they are drawn on open), but the spread is larger than the effect.
  Start time: no effect is measurable; the pairs scatter by +-40 %.
- One batched session (`ab1-batch`, load 20) could not open the assembly: `OpenDoc6` returned nothing with error 0,
  12 s after the main window; the part and the drawing opened later in the same session. It did not happen again
  in 7 batched sessions after the script waited at least 25 s after the main window (and would retry once; no
  retry was needed). Not seen in the unbatched arm, but with one case it cannot be attributed.

`build.nosync/gfx2/perf/sessions.tsv` has every session; `python3 -I build.nosync/gfx2/tools/summary.py
build.nosync/gfx2/perf/sessions.tsv ab` prints the table.

## 5. The round-2 cold start that timed out

`launch-gfx-ab1-batch-125400.json` (TIMEOUT, 300 s) is not a hang caused by batching:

- In that run `wtool` saw the main window after 49 s (`perf/ab1-batch-125400/launch.txt`), but macOS reported
  that window as 514 x 333 pt (the screenshots show the whole UI scaled down), and the harness only accepts a main
  window of at least 800 x 500 pt; it accepted it at +298 s. Three SLDWORKS.exe processes of `bottle-crashlab` had
  windows during that launch (pids 71132, 71364, 80095); round 2 shared that bottle with another agent's tests.
- Round 2 had more harness timeouts, also without batching: `launch-gfx-base2.json` (stock runtime),
  `launch-gfx-cnt-ctl2-154606.json` (unbatched, `wtool` main window at +58 s) and two batched instrumented runs
  (`cnt-batch-151828`, `cnt-batch-153912`, the latter with `wtool` main window at +46 s). Their dialog lists are
  empty: the harness only counts windows of processes whose environment `ps -E` can read, and SLDWORKS.exe's
  environment is not readable (Wine rewrites the process title), so it saw no window. `sw_launch_g1.sh` also
  accepts processes whose title is a unix path under the bottle's `drive_c`. The shared
  `tools/sw_launch_experiment.sh` has the same `bottle_procs`/`sw_pids` test (not changed here).
- The one round-2 crash (`cnt-batch-153725`, instrumented batch build) reported fault module
  `sldfileopen:0000cd0c`, with a SOLIDWORKS from the previous run still in the bottle.
- With the patch in my own bottle: 9 of 9 cold starts reached the main window (warm-up and `ab1`-`ab8`, 38-96 s),
  and every harness result was SUCCESS. The unbatched arm: 9 of 9 (one harness TIMEOUT with the old process test,
  main window by `wtool` at 63 s). One more batched session (`void-wtpipe-ab1`) stopped at the activation wizard
  because my own script blocked: its first `wtool` call started the wineserver, which inherited the pipe that the
  script read. The wizard was waiting for input, SOLIDWORKS waited for the wizard, both idle; `wtool` listed both
  windows. Fixed in `session3.sh` and later (output through a file, and the first poll waits for the wineserver).

## 6. Integration and build

- `git -C wt-gfx merge integrate` was a fast-forward to c53bda3; the patch, wiring and tests are commit 6cb8cb5.
  Patch 0030 applies after the 26 patches of `integrate` (0001-0025, 0028) on a pristine 11.16 tree (checked with
  `git apply --cached` into a scratch index); no other patch touches `dlls/opengl32`.
- `build_winemac.sh` applies 0030 last, builds `dlls/opengl32/x86_64-windows/opengl32.dll` and
  `dlls/opengl32/opengl32.so`, sets the install name, signs the `.so` with the other unix modules and adds the patch
  hash to the build key. `package_app.sh` installs both files, signs the `.so` and writes
  `WineOpenGLBatchPatchSHA256`, `WineOpenGL32ModuleSHA256` and `WineOpenGL32UnixModuleSHA256`. `verify_app.sh` and
  `wine_runtime.py` (`DECLARED_MODULES`) verify both modules.
- The new manifest keys change the runtime identity, so existing bottles get the usual runtime upgrade, as for any
  other Wine module change.
- Checked: `python3 -I -m unittest discover -s scripts/tests` (264 tests, OK); the Swift files parse
  (`swiftc -parse`). The opengl32 build steps ran in round 2's configured Wine tree with the same commands
  (`build.nosync/gfx2/tools/build_variant.sh`). Not run: a full `build_winemac.sh` + `package_app.sh` +
  `verify_app.sh`, and the Swift test suite.

## 7. Open points

- The debug-callback rule is untested at run time (no debug output in the macOS GL 2.1 context).
- The single failed assembly open in `ab1-batch` (section 4).
- Measured through the API only (`RotateAboutCenter` + `GraphicsRedraw2`); interactive mouse rotation, level of
  detail and dynamic highlight were not driven. SOLIDWORKS draws from one thread here (round-2 call counts).
- Re-measure on a quiet machine before quoting absolute numbers.

## Files

- Patch and wiring: `wt-gfx` commit 6cb8cb5 (`patches/wine-crossover/0030-opengl32-batch-immediate-mode-calls.patch`,
  `scripts/build_winemac.sh`, `scripts/package_app.sh`, `scripts/verify_app.sh`, `scripts/swcli/wine_runtime.py`,
  `macos/.../WineService.swift`, `scripts/tests/test_wine_opengl_batch.py`,
  `scripts/diagnostics/check_opengl_batch.c`).
- `build.nosync/gfx2/`: `dlls/` (ctl2, batch2, diag-flusheach, fork-9fffc3a builds), `rt-ctl`, `rt-batch`,
  `rt-diag`, `tools/` (session scripts, harness copy, `imgcmp.py`, `summary.py`), `perf/` (one directory per
  session, `sessions.tsv`), `crash/` (harness logs), `diffs/`, `micro/` (probe output), `fork-wip/` (round-2
  uncommitted files as found).

