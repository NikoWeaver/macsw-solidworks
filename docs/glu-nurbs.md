# glu32 NURBS (patch 0037)

Branch `glu-nurbs` (from `rc23` 3873d67). Patch `patches/wine-crossover/0037-glu32-nurbs.patch`.

## Bug

SOLIDWORKS ends the first time it redraws a sketch that contains a spline or an ellipse. A
"Wine C++ Runtime Library" box shows "Assertion failed ... dlls/glu32/glu.c, line 155", and SOLIDWORKS
closes. Making the entity works; the crash comes at the next redraw. Users who draw a spline by hand
get the same crash. `tools/swcad` refuses `spline` and `ellipse` unless `unsafe=true`.

## Cause

SOLIDWORKS draws spline and ellipse sketch entities with the GLU NURBS API. In Wine 11.16:

- `gluNewNurbsRenderer` returns NULL (with `ERR: Nurbs renderer is not supported`).
- Every other NURBS function is `assert(0)`.

SOLIDWORKS does not check the NULL. Its next call, `gluNurbsProperty`, hits `assert(0)` (line 155 of
`glu.c`).

## What patch 0037 does

New file `dlls/glu32/nurbs.c` (plain C, about 1,480 lines). The NURBS stubs in `glu.c` are removed.
The export names in `glu32.spec` do not change.

- `gluNewNurbsRenderer` / `gluDeleteNurbsRenderer`.
- `gluNurbsProperty` / `gluGetNurbsProperty` with the GLU 1.3 defaults:

  | property | default |
  |---|---|
  | `GLU_SAMPLING_METHOD` | `GLU_PATH_LENGTH` |
  | `GLU_SAMPLING_TOLERANCE` | 50 (pixels) |
  | `GLU_PARAMETRIC_TOLERANCE` | 0.5 |
  | `GLU_U_STEP`, `GLU_V_STEP` | 100 |
  | `GLU_DISPLAY_MODE` | `GLU_FILL` |
  | `GLU_CULLING` | `GL_FALSE` |
  | `GLU_AUTO_LOAD_MATRIX` | `GL_TRUE` |
  | `GLU_NURBS_MODE` | `GLU_NURBS_RENDERER` |

  An unknown property gives `GLU_INVALID_ENUM`. A bad value (for example a tolerance of 0 or less)
  gives `GLU_INVALID_VALUE` and the old value stays.
- `gluLoadSamplingMatrices` (used when `GLU_AUTO_LOAD_MATRIX` is false).
- `gluNurbsCallback`: `GLU_NURBS_ERROR` and the tessellator callbacks `GLU_NURBS_BEGIN`, `_VERTEX`,
  `_NORMAL`, `_COLOR`, `_TEXTURE_COORD`, `_END` and their `_DATA` forms. When both forms are set, the
  `_DATA` form is called. glu32 does not export `gluNurbsCallbackData`, so the user data pointer is
  always NULL.
- Curves: `gluBeginCurve`, `gluNurbsCurve`, `gluEndCurve`. Types `GL_MAP1_VERTEX_3`,
  `GL_MAP1_VERTEX_4` (rational), `GL_MAP1_NORMAL`, `GL_MAP1_COLOR_4`, `GL_MAP1_INDEX` and
  `GL_MAP1_TEXTURE_COORD_1` to `_4`. A `gluNurbsCurve` outside a begin/end pair is drawn at once.
- Surfaces: `gluBeginSurface`, `gluNurbsSurface`, `gluEndSurface`, with the same `GL_MAP2_` types.
  Display modes `GLU_FILL` (quad strips, like `glEvalMesh2`), `GLU_OUTLINE_POLYGON` (grid lines) and
  `GLU_OUTLINE_PATCH` (the border, or the trimming loops).
- Normals of a surface without a `GL_MAP2_NORMAL` map are computed from the two partial derivatives
  (rational surfaces too). In renderer mode this happens only when `GL_AUTO_NORMAL` is enabled, as with
  GL evaluators. In tessellator mode it happens when a normal callback is set.
- Trimming: `gluBeginTrim`, `gluPwlCurve`, `gluNurbsCurve` with `GLU_MAP1_TRIM_2` / `_3`,
  `gluEndTrim`. See "Limits".

How it works:

- Points come from de Boor's algorithm on each knot span. A surface uses de Boor along t for each
  row, then along s. The first derivative comes from the last step of the same algorithm.
- The number of steps for each knot span comes from the sampling method:
  - `GLU_PATH_LENGTH`: length of the span's control polygon in window pixels (through the sampling
    matrices) / `GLU_SAMPLING_TOLERANCE`.
  - `GLU_PARAMETRIC_ERROR`: sqrt(d (d - 1) |second difference| / (8 tolerance)), in pixels, so the
    distance between a chord and the curve stays under `GLU_PARAMETRIC_TOLERANCE`.
  - `GLU_OBJECT_PATH_LENGTH`, `GLU_OBJECT_PARAMETRIC_ERROR`: the same in object coordinates.
  - `GLU_DOMAIN_DISTANCE`: span length * `GLU_U_STEP` (`GLU_V_STEP` along t).
- Limits on the work: at most 1,024 steps per knot span of a curve and 65,536 per curve (steps are scaled
  down, but each span keeps at least one), at most 256 grid steps along each
  direction of a surface (but at least one per knot span), at most 256 steps per span of a trimming
  curve. A span with a control point behind the eye gets 64 steps. A NaN gives 1 step. So a tiny
  tolerance, a huge zoom or bad numbers cannot make a huge loop on one knot span.
- Each knot span keeps at least one step, so the work also grows with the number of spans. Two limits
  stop this for surfaces: a surface grid larger than 256 MB, and trimming loops with more than 2^25
  points (256 MB) in all, give `GLU_OUT_OF_MEMORY`. The counts are checked on each span, before they
  can pass `INT_MAX` and before memory is allocated for them. (Before this check, a surface with 2^22
  knot spans, or a trimming curve with 8.4 million spans, made an `int` count wrap, and the buffer
  that it sized overflowed. A review found this.) A curve needs no buffer for its points, and its
  step count is a `double`.
- Renderer mode draws with `glBegin` / `glColor4fv` / `glNormal3fv` / `glTexCoord*fv` /
  `glVertex3fv` / `glEnd`. Rational points are divided by w before `glVertex3fv` (only a point with
  w = 0 uses `glVertex4fv`). So the calls go through the immediate-mode batching of patch 0030. When it
  puts out colors, normals or texture coordinates, it saves and restores the current ones
  (`glPushAttrib(GL_CURRENT_BIT)`), because GL evaluators do not change them either.
- A curve can jump at a knot of full multiplicity (multiplicity = order). There, a new line strip
  starts.
- `GLU_CULLING`: a curve or surface whose control points are all outside one clip plane is not drawn.
- Errors: invalid input goes to the `GLU_NURBS_ERROR` callback and is not drawn. Codes:
  `GLU_NURBS_ERROR1` order < 1 or > 24, `2` too few knots, `3` empty knot range, `4` decreasing knots
  (also a NaN), `5` multiplicity > order, `6`/`7` curve begin/end order, `8` missing or extra data
  (for example `gluEndCurve` without a vertex curve), `12`/`13`/`15`/`16`/`17`/`19`/`27` surface and
  trim begin/end order, `14`/`22` wrong use of trim types, `32` NULL or infinite knots, `33` negative
  count, `34` negative stride, `35` unknown type, `36` NULL control points, and `GLU_OUT_OF_MEMORY`.
  Without an error callback, errors are ignored silently (as in the SGI sample implementation).
- Every entry point ignores a NULL object. Nothing asserts.
- `TRACE` on every entry point, plus the number of segments of each curve and the grid of each surface.
  Use `WINEDEBUG=+glu` (the channel is `glu`, not `glu32`).

`include/wine/glu.h` gets the GLU 1.3 constants that it did not have: `GLU_NURBS_MODE`,
`GLU_NURBS_TESSELLATOR`, `GLU_NURBS_RENDERER`, `GLU_OBJECT_PARAMETRIC_ERROR`, `GLU_OBJECT_PATH_LENGTH`,
`GLU_NURBS_ERROR` and `GLU_NURBS_BEGIN` ... `GLU_NURBS_END_DATA` (100160-100175, 100208, 100209, 100103).

## Limits

- Trimming is approximate. The trimming loops are sampled in the (s, t) domain. A grid vertex is kept
  when its winding number is positive: a counterclockwise loop keeps its inside, a clockwise loop cuts a
  hole. When no loop is counterclockwise, the whole domain is the outer boundary. A grid cell is drawn
  when 3 or 4 of its corners are kept (4: in the quad strip, 3: as a triangle). So a trimmed edge is
  accurate to about one grid cell, and the drawn area is a little smaller than the exact area (test:
  0.419 for an exact 0.463, with 1/40 grid cells). Open loops are closed with a straight line.
  Intersecting loops are not reported (no `GLU_NURBS_ERROR28`/`29`).
- No `gluNurbsCallbackData` / `gluNurbsCallbackDataEXT` (glu32 does not export them).
- Surfaces do not start new strips at a knot of full multiplicity (curves do).
- The renderer does not use GL evaluators, so `glPushAttrib(GL_EVAL_BIT)` state and evaluator maps
  are not changed.
- The `GL_MAP1_INDEX` value is passed to the color callback as the first of four floats.
- Only the x86_64 glu32.dll ships (SOLIDWORKS is 64-bit). The i386 glu32 stays the stock one.

## What SOLIDWORKS calls

From the `WINEDEBUG=+glu` trace of the SOLIDWORKS session (section 3 below). Each time SOLIDWORKS draws
a spline or an ellipse of a sketch, it makes a new NURBS object, draws one curve and deletes the object:

```
gluNewNurbsRenderer()
gluNurbsProperty(nurbs, GLU_SAMPLING_TOLERANCE, 5.0)      100203, 5 pixels
gluBeginCurve(nurbs)
gluNurbsCurve(nurbs, 11 knots, ..., stride 3, ..., order 4, GL_MAP1_VERTEX_3)
gluEndCurve(nurbs)                                        drawn here
gluDeleteNurbsRenderer(nurbs)
```

- 238 curve draws in the session (the redraws of the spline and the ellipse, in the sketch, after the
  sketch was closed, after the extrude and after the reopen). All were cubic (order 4), not rational,
  with 7 control points. No other curve shape appears, so the ellipse is also sent as a cubic B-spline
  (an inference from the trace: the trace does not show the knot and point values).
- Once, SOLIDWORKS also sent a `GL_MAP1_TEXTURE_COORD_1` curve (stride 1, order 4, 11 knots) in the same
  begin/end pair as the vertex curve, probably for a line pattern. It was drawn (330 segments).
- SOLIDWORKS keeps the other defaults: `GLU_PATH_LENGTH`, `GLU_AUTO_LOAD_MATRIX` on (so every curve reads
  the modelview and projection matrices and the viewport with `glGet*`), renderer mode, no culling. It
  sets no callback, not even `GLU_NURBS_ERROR`, and it uses no surfaces and no trims.
- With the 5 pixel tolerance, a curve got 181 to 566 segments (median 416) in an 800 x 600 view.
- No call gave an error (no `warn:glu:` line).

Each curve costs three `glGet*` calls, and each one flushes the immediate-mode batch of patch 0030. A
real GLU does the same. With Apple's multithreaded GL engine (patch 0036), a `glGet` can wait for the GL
thread; a sketch with very many splines could show this. It was not measured.

## Test evidence

### 1. Native arm64 unit test (`scripts/tests/test_wine_glu_nurbs.py`)

The test takes `dlls/glu32/nurbs.c` out of the patch and compiles it with `clang -arch arm64
-fsanitize=address,undefined`. `scripts/tests/glu_nurbs/nurbs_stubs.h` stands in for the Wine and GL
headers, and `nurbs_harness.c` records the GL calls and callbacks. The reference is an independent
Cox-de Boor recursion in Python (basis functions and their derivatives).

- Curves of order 1 to 7, polynomial and rational, clamped and unclamped knots: 371 points.
- Repeated knots (multiplicity 2, 3 and full multiplicity), rational weights 0.25 to 4: 360 points.
- Full circle as a rational quadratic (9 points, 4 spans) and ellipses with a/b = 2 and 1/2,000:
  (x/a)^2 + (y/b)^2 = 1 within 2e-6.
- Surfaces of orders (2,3), (3,3) rational, (4,4), (4,2) rational, (1,3), (5,4): value and both partial
  derivatives at 204 points.
- Worst relative error against the reference: points 4e-6, derivatives 2.3e-5 (the test allows 2e-5
  and 2e-4).
- Through the public API: property defaults and errors; path length (no edge longer than the 10 pixel
  tolerance), parametric error (no chord more than 0.5 pixel off the circle), object-space methods,
  domain distance (exactly 33 points for 4 spans * 8 steps); renderer mode (`glGet*` of the matrices,
  then `glBegin(GL_LINE_STRIP)` / `glVertex3fv`; a 4x zoom gives about 4x the points); every error code
  of the list above, then a normal curve again; tiny tolerance, huge zoom and huge `GLU_U_STEP` stop at
  4 * 1,024 + 1 points; a 200-span curve with a tiny tolerance stops at 65,536 segments; NaN knots give `GLU_NURBS_ERROR4`; NaN points do not hang; a surface with a tiny
  tolerance stops at 256 x 256 cells; computed surface normals against the reference cross product;
  outline modes; a trimmed surface (outer circle as a rational NURBS trim, square hole as two
  `gluPwlCurve` pieces); color and texture maps; `_DATA` callbacks get NULL; a knot of full
  multiplicity gives two strips; culling. After each scenario every heap block is freed and every
  `glPushAttrib` has its `glPopAttrib`.
- Huge sample counts (scenario `overflow`): a surface with 2^22 knot spans and 1,024 domain-distance
  steps per span; a surface with 4,500,000 spans; a trimming curve with 8,400,000 spans of 257 points;
  a trimming loop with 130,000 such spans and then a 200,000-point `gluPwlCurve`. Each one gives
  `GLU_OUT_OF_MEMORY`, draws nothing and frees every block (0.8 s). With the code before the fix, the
  harness stops with a UBSan trap: signed integer overflow at `nurbs.c:684` (grid) and `nurbs.c:750`
  (trim). The other 16 scenarios give byte-identical output before and after the fix, and so do the
  reviewer's adversarial scenarios (`build.nosync/glu/review/adv.c`). Logs: `build.nosync/glu/evidence/overflow/`.
- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`: 339 tests, OK.

### 2. Wine conformance test (`dlls/glu32/tests/glu.c`, in the patch)

New tests: `test_nurbs_properties` (defaults, invalid value, invalid property),
`test_nurbs_tessellator` (circle in tessellator mode with domain distance and with path length,
begin/vertex/end counts, `GL_LINE_STRIP`, all points on the circle; errors 1, 2, 7, 8, 19; the
`_DATA` vertex callback with a NULL user pointer; a bicubic surface: 3 `GL_QUAD_STRIP`s of 10 vertices
with unit normals) and `test_nurbs_renderer` (renderer mode in a real GL context: a white circle on black,
read back with `glReadPixels`; lit pixels on the circle, none inside it). On Windows the tessellator part
is skipped when `GLU_NURBS_MODE` is not supported (Windows glu32 is GLU 1.2).

Run tonight with MinGW (the configured tree has `--disable-tests`), in the clone bottle `bottle-glu`:

| runtime | result |
|---|---|
| stock RC2.3 (`rt-stock`) | `glu.c:182: Test failed: gluNewNurbsRenderer failed`, 16 tests, 1 failure |
| RC2.3 + 0037 glu32.dll (`rt-glu`) | 55 tests, 0 failures; renderer test: 408 lit pixels in a 192x166 viewport, 0 inside the circle |
| RC2.3 + 0037 glu32.dll with the overflow fix (`rt-glu`, sha256 `dc9150a4`) | 55 tests, 0 failures; 408 lit pixels |

The new module is the one that Wine loaded. With `WINEDEBUG=+module`, Wine maps `GLU32.dll` with a
`.buildid` section and the `.text` size of the file in `rt-glu`: 0x24210 for the first test build
(06:51), 0x24450 for the build with the overflow fix. The stock file has `.text` 0x20db6 and no
`.buildid`; the bottle's `system32` copy still has the stock hash `fac66046`. The `rt-glu` module
from 07:07 (`dfac3766`, used by the SOLIDWORKS sessions) has `.text` 0x24310.
Logs: `build.nosync/glu/evidence/winetest-*.txt` (rerun: `winetest-rt-glu-fix*.txt`).

### 3. SOLIDWORKS

Clone bottle `bottle-glu` (APFS clone of `bottle-perf2` when it had no Wine processes, part templates
copied from `bottle-t1`), slot `glu`, launched with `tools/swdialogs/swd.sh launch`, driven with
`tools/swcad` (`session start --bottle bottle-glu`, `graphics on`). Two sessions after the night gate
(07:50, one other agent SOLIDWORKS running), `nice` 0, quit with `swcad session stop --exit` (close all,
ExitApp, slot released, no SOLIDWORKS left in the bottle). Script: `build.nosync/glu/sw_session.sh`.

| session | runtime | what | result |
|---|---|---|---|
| B (07:50) | `rt-glu` (RC2.3 + 0037 glu32.dll), `WINEDEBUG=+glu` | plain sketch; sketch with `spline` (5 points, `unsafe=true`), three lines and an `ellipse` (a 15, b 6, `unsafe=true`); renders in the sketch and after `exit-sketch`; `extrude` 10 mm; iso render; view rotated (`RotateAboutCenter` 0.6, 0.4) and rendered; 4-view sheet; `save` `glu-curves.SLDPRT`, `close`, `open`, iso render, `edit-sketch Curves`, render, `sketch-info`, `tree` | every step OK; no crash, no assert box (`swd.sh crashed` after each step, `swd.sh dialogs` showed only the main window, no "assert" in `wine.log`, no crash reporter); 1,667 `trace:glu:` lines, 0 `warn:glu:` |
| A (07:53) | stock RC2.3 (`rt-stock`) | the same plain sketch | every step OK; 0 `trace:glu:` lines (stock glu32 has no NURBS traces) |

What the pictures show (looked at, `build.nosync/glu/evidence/session-B/`):

- `curves-sketch.png` (in the sketch): the spline is a smooth wave through its 5 points, the ellipse is
  smooth, both in the sketch colour with the region shaded.
- `curves-exited.png` (sketch closed): the same curves in grey.
- `extrude-iso.png`, `extrude-rotated.png`, `extrude-sheet.png`: a 10 mm plate with the wave on top and an
  elliptical hole; the rotated view and the four standard views are correct.
- `reopen-iso.png`, `reopen-sketch.png`: after save, close and open, the same body, and in the sketch the
  same spline and ellipse. `sketch-info` after the reopen lists `Ellipse1` (79.33 mm) and `Spline1`
  (101.48 mm), the same lengths as before the save.

Nothing else changed: the plain sketch (rectangle, circle, line; no spline) rendered in the sketch and
after `exit-sketch` gives byte-identical PNGs in session A (stock) and session B (0037): 800 x 600,
0 differing pixels, same SHA-256 (`build.nosync/glu/evidence/pixdiff.txt`).

Evidence: `build.nosync/glu/evidence/session-{A,B}/` (steps, PNGs, `env.txt`, launch result),
`session-B/glu-trace.txt` (all `glu` lines), `session-B/glu-trace-summary.txt`; harness logs in
`build.nosync/crash/swd-bottle-glu-20261025-075021` (B) and `-075332` (A).

Not tested in SOLIDWORKS: the stock-runtime crash itself (it is described in `tools/swcad/README.md`;
the Wine test shows the NULL from stock `gluNewNurbsRenderer`), and sketches with very many splines.

Not run again after the overflow fix. The sessions used module `dfac3766`. The fix changes only
`grid_params` and `sample_trims` (surfaces and trims); `draw_curve` did not change. SOLIDWORKS calls only
the curve functions (`glu-trace-summary.txt`: no `gluNurbsSurface`, `gluBeginTrim` or `gluPwlCurve`), so
the fix cannot change what it draws.

## How the test module was built tonight

The official build is `scripts/build_winemac.sh` (make with winegcc and winebuild). It could not run
tonight: new x86_64 programs hang in Rosetta. In the clone of the configured tree, `make -n` ran
`config.status`, and its `tools/makedep` stopped in state U (pid 73017, it cannot be killed). After that,
no Wine build tool was started again.

The test glu32.dll (`build.nosync/glu/build_glu32.sh`) uses only arm64 programs:

1. `x86_64-w64-mingw32-gcc` compiles each glu32 source with the exact flags of the configured tree.
2. The MinGW linker links against the tree's own Wine import libraries and `libwinecrt0.a`; the exports
   come from `glu32.spec` through a `.def` file; a small object gives the `.CRT$X??` start and end
   markers that winebuild's spec object gives.
3. A Python step writes the "Wine builtin DLL" signature at offset 0x40 and sets the prefer-native bit
   (0x0010) in DllCharacteristics, as `winebuild --builtin` and `-Wb,--prefer-native` do.

This module is for tests only. **Open issue:** the winegcc build of 0037 through `build_winemac.sh`
was not run tonight. It must build `dlls/glu32/x86_64-windows/glu32.dll` without warnings in the
morning build. The patch applies in the build order (0001 ... 0033, 0037, 0034, 0030) on a clean
`wine-11.16.tar.xz` (checked with `git apply`), and nurbs.c compiles with the tree's `-Wall` flags
and MinGW without warnings. After the overflow fix: on a clone of that tree (`build.nosync/glu/applycheck`),
the old 0037 was reverse-applied and the new 0037 applied cleanly; `build_glu32.sh` ran again with the fixed nurbs.c (0 warnings), result
sha256 `dc9150a4e4051444e843f073544d521c29e22f299092527411033ff8eada1e2a`, copied to `rt-glu`. The
fixed nurbs.c also compiles for i386 (`i686-w64-mingw32-gcc`, the same flags) without warnings.

## Wiring

- `scripts/build_winemac.sh`: `GLU_NURBS_PATCH`, its SHA in `BUILD_KEY`, `apply --check` + `apply`
  after 0033 and before 0034 (0034 and 0030 stay the last two), make target
  `dlls/glu32/x86_64-windows/glu32.dll`, output `dist/<winemac>/glu32.dll` (PE32+ check).
- `scripts/package_app.sh`: copies it to `Contents/Frameworks/wine/lib/wine/x86_64-windows/glu32.dll`;
  BuildManifest keys `WineGluNurbsPatchSHA256` and `WineGLU32ModuleSHA256`.
- `scripts/verify_app.sh`: checks both keys, `cmp` with the dist file, PE32+, and the module table.
- `scripts/swcli/wine_runtime.py`: `WineGLU32ModuleSHA256` in `DECLARED_MODULES`.

## Notes for the integrator

- The new module changes the runtime identity, so bottles migrate once (RC3 migrates anyway).
- `storage-strip` strips a fixed list of rebuilt PE modules in `package_app.sh`: add `glu32.dll`.
- `rc3-team` also changes `package_app.sh` and `verify_app.sh`: expect mechanical conflicts.
- After 0037 is in a release, `tools/swcad` can stop refusing `spline` and `ellipse`.
