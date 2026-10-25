"""glu32 NURBS (patch 0037): the patch, its wiring, and its evaluator against an independent reference.

The native tests extract dlls/glu32/nurbs.c from the patch, compile it as an arm64 program with
glu_nurbs/nurbs_stubs.h in place of the Wine headers (glu_nurbs/nurbs_harness.c records the GL calls
and callbacks), and compare the points with the Cox-de Boor recursion below.
"""
from pathlib import Path
import math
import platform
import random
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0037-glu32-nurbs.patch"
PATCH_KEY = "WineGluNurbsPatchSHA256"
MODULE_KEY = "WineGLU32ModuleSHA256"
HARNESS = Path(__file__).resolve().parent / "glu_nurbs"

GL_LINE_STRIP, GL_TRIANGLES, GL_QUAD_STRIP = 3, 4, 8


def patch_text():
    return (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()


def file_diff(path):
    for part in patch_text().split("diff --git ")[1:]:
        if part.startswith(f"a/{path} b/{path}"):
            return part
    raise AssertionError(path)


def new_file(path):
    """The full text of a file that the patch adds."""
    lines = file_diff(path).split("\n@@ ", 1)[1].splitlines()[1:]
    assert all(l.startswith("+") for l in lines if l), path
    return "\n".join(l[1:] for l in lines) + "\n"


def added(path):
    return [l[1:] for l in file_diff(path).splitlines() if l.startswith("+") and not l.startswith("+++")]


# ---------------------------------------------------------------- reference (Cox-de Boor recursion)

def last_span(knots, order, count):
    return max(i for i in range(order - 1, count) if knots[i] < knots[i + 1])


def basis(knots, i, degree, u, end_span):
    """N_{i,degree}(u); the end of the parameter range belongs to the last non-empty span."""
    if degree == 0:
        if u == knots[end_span + 1]:
            return 1.0 if i == end_span else 0.0
        return 1.0 if knots[i] <= u < knots[i + 1] else 0.0
    value = 0.0
    if knots[i + degree] != knots[i]:
        value += (u - knots[i]) / (knots[i + degree] - knots[i]) * basis(knots, i, degree - 1, u, end_span)
    if knots[i + degree + 1] != knots[i + 1]:
        value += (knots[i + degree + 1] - u) / (knots[i + degree + 1] - knots[i + 1]) * \
            basis(knots, i + 1, degree - 1, u, end_span)
    return value


def basis_derivative(knots, i, degree, u, end_span):
    if degree == 0:
        return 0.0
    value = 0.0
    if knots[i + degree] != knots[i]:
        value += degree / (knots[i + degree] - knots[i]) * basis(knots, i, degree - 1, u, end_span)
    if knots[i + degree + 1] != knots[i + 1]:
        value -= degree / (knots[i + degree + 1] - knots[i + 1]) * basis(knots, i + 1, degree - 1, u, end_span)
    return value


def ref_basis(knots, order, count, u):
    end = last_span(knots, order, count)
    lo, hi = knots[order - 1], knots[count]
    u = min(max(u, lo), hi)
    return ([basis(knots, i, order - 1, u, end) for i in range(count)],
            [basis_derivative(knots, i, order - 1, u, end) for i in range(count)])


def ref_curve(knots, order, points, u):
    """value and derivative (homogeneous for rational points)"""
    n, dn = ref_basis(knots, order, len(points), u)
    dim = len(points[0])
    return ([sum(n[i] * points[i][c] for i in range(len(points))) for c in range(dim)],
            [sum(dn[i] * points[i][c] for i in range(len(points))) for c in range(dim)])


def ref_surface(sknots, sorder, tknots, torder, grid, s, t):
    ns, nt, dim = len(grid), len(grid[0]), len(grid[0][0])
    n, dn = ref_basis(sknots, sorder, ns, s)
    m, dm = ref_basis(tknots, torder, nt, t)

    def combine(a, b):
        return [sum(a[i] * b[j] * grid[i][j][c] for i in range(ns) for j in range(nt)) for c in range(dim)]
    return combine(n, m), combine(dn, m), combine(n, dm)


def clamped_knots(rng, order, count, uniform=False):
    inner = count - order
    values = sorted(rng.uniform(0, 1) for _ in range(inner)) if not uniform else \
        [(i + 1) / (inner + 1) for i in range(inner)]
    start, end = rng.uniform(-2, 0), rng.uniform(1, 3)
    return [start] * order + [start + (end - start) * v for v in values] + [end] * order


def random_points(rng, count, dim):
    points = []
    for _ in range(count):
        p = [rng.uniform(-5, 5) for _ in range(3)]
        if dim == 4:
            w = rng.uniform(0.25, 4)
            p = [c * w for c in p] + [w]
        points.append(p)
    return points


SQRT_HALF = math.sqrt(0.5)
CIRCLE_KNOTS = [0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 4]
CIRCLE_XY = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0)]


def ellipse_points(a, b):
    points = []
    for i, (x, y) in enumerate(CIRCLE_XY):
        w = SQRT_HALF if i % 2 else 1.0
        points.append([x * a * w, y * b * w, 0.0, w])
    return points


# ---------------------------------------------------------------- patch and wiring

class GluNurbsPatchTests(unittest.TestCase):
    def test_patch_touches_only_glu32_and_its_header(self):
        files = [l.split(" b/", 1)[1] for l in patch_text().splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/glu32/Makefile.in", "dlls/glu32/glu.c", "dlls/glu32/nurbs.c",
                                 "dlls/glu32/tests/glu.c", "include/wine/glu.h"])
        self.assertIn("+\tnurbs.c \\", file_diff("dlls/glu32/Makefile.in"))

    def test_every_nurbs_entry_point_moves_to_nurbs_c(self):
        source = new_file("dlls/glu32/nurbs.c")
        glu_c = file_diff("dlls/glu32/glu.c")
        names = ["gluNewNurbsRenderer", "gluDeleteNurbsRenderer", "gluLoadSamplingMatrices", "gluNurbsProperty",
                 "gluGetNurbsProperty", "gluBeginCurve", "gluEndCurve", "gluNurbsCurve", "gluBeginSurface",
                 "gluEndSurface", "gluNurbsSurface", "gluBeginTrim", "gluEndTrim", "gluPwlCurve", "gluNurbsCallback"]
        for name in names:
            with self.subTest(name=name):
                # the spec maps gluX to wine_gluX; the old stub is removed from glu.c
                self.assertRegex(source, rf"\n\S.* WINAPI wine_{name}\(")
                self.assertIn(f"-void WINAPI wine_{name}(", glu_c.replace("-GLUnurbs * WINAPI", "-void WINAPI"))
        self.assertNotIn("assert", source)
        self.assertIn("-#include <assert.h>", glu_c)
        self.assertNotIn("+", "".join(l[0] for l in glu_c.splitlines()[4:] if l and l[0] in "+-"))

    def test_no_entry_point_dereferences_a_null_object(self):
        source = new_file("dlls/glu32/nurbs.c")
        for body in re.split(r"\n\S.* WINAPI wine_glu", source)[1:]:
            name = body.split("(", 1)[0]
            if name == "NewNurbsRenderer":
                continue
            code = body.split("\n{\n", 1)[1]
            with self.subTest(name=name):
                self.assertRegex(code.split("switch", 1)[0], r"if \(!nurbs(?: \|\| !value)?\) return;")

    def test_header_gets_the_glu_1_3_constants(self):
        header = "\n".join(added("include/wine/glu.h"))
        expected = {"GLU_NURBS_MODE": 100160, "GLU_NURBS_TESSELLATOR": 100161, "GLU_NURBS_RENDERER": 100162,
                    "GLU_OBJECT_PARAMETRIC_ERROR": 100208, "GLU_OBJECT_PATH_LENGTH": 100209,
                    "GLU_NURBS_ERROR": 100103, "GLU_NURBS_BEGIN": 100164, "GLU_NURBS_VERTEX": 100165,
                    "GLU_NURBS_NORMAL": 100166, "GLU_NURBS_COLOR": 100167, "GLU_NURBS_TEXTURE_COORD": 100168,
                    "GLU_NURBS_END": 100169, "GLU_NURBS_BEGIN_DATA": 100170, "GLU_NURBS_VERTEX_DATA": 100171,
                    "GLU_NURBS_NORMAL_DATA": 100172, "GLU_NURBS_COLOR_DATA": 100173,
                    "GLU_NURBS_TEXTURE_COORD_DATA": 100174, "GLU_NURBS_END_DATA": 100175}
        found = dict(re.findall(r"#define (\w+) (\d+)", header))
        self.assertEqual({k: int(v) for k, v in found.items()}, expected)
        # the native test stubs use the same numbers
        stubs = dict(re.findall(r"#define (GLU_\w+) (\d+)", (HARNESS / "nurbs_stubs.h").read_text()))
        for name, value in expected.items():
            self.assertEqual(int(stubs[name]), value, name)

    def test_defaults_and_limits(self):
        source = new_file("dlls/glu32/nurbs.c")
        create = source.split("wine_gluNewNurbsRenderer(void)", 1)[1].split("\n}\n", 1)[0]
        for line in ("nurbs->sampling_method = GLU_PATH_LENGTH;", "nurbs->sampling_tolerance = 50.0f;",
                     "nurbs->parametric_tolerance = 0.5f;", "nurbs->u_step = nurbs->v_step = 100.0f;",
                     "nurbs->display_mode = GLU_FILL;", "nurbs->culling = GL_FALSE;",
                     "nurbs->auto_load = GL_TRUE;", "nurbs->mode = GLU_NURBS_RENDERER;"):
            self.assertIn(line, create)
        for line in ("#define MAX_ORDER        24", "#define MAX_SPAN_STEPS   1024", "#define MAX_CURVE_STEPS  65536",
                     "#define MAX_GRID_STEPS   256",
                     "#define MAX_TRIM_STEPS   256", "WINE_DEFAULT_DEBUG_CHANNEL(glu);"):
            self.assertIn(line, source)
        # renderer mode uses immediate mode only (batched by patch 0030); no evaluators, no display lists
        self.assertNotRegex(source, r"\b(glMap[12][fd]|glEvalMesh[12]|glEvalCoord[12]\w*|glNewList|glCallList)\(")
        self.assertIn("glVertex3fv( pos );", source)

    def test_wine_tests_cover_the_tessellator(self):
        tests = "\n".join(added("dlls/glu32/tests/glu.c"))
        for text in ("GLU_NURBS_TESSELLATOR", "GLU_NURBS_VERTEX_DATA", "GL_QUAD_STRIP", "GLU_NURBS_ERROR1",
                     "win_skip", "glReadPixels", "test_nurbs_tessellator();", "test_nurbs_renderer(hdc);"):
            self.assertIn(text, tests)

    def test_description(self):
        header = " ".join(patch_text().split("diff --git ", 1)[0].split())
        for word in ("assert(0)", "gluNurbsCallbackData", "WINEDEBUG=+glu", "docs/glu-nurbs.md", "patch 0030",
                     "GLU_NURBS_ERROR1-37", "de Boor"):
            self.assertIn(word, header)

    def test_build_package_and_verify_wiring(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${GLU_NURBS_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${GLU_NURBS_PATCH}"', build)
        applies = re.findall(r'git -C "\$\{SOURCE_DIR\}" apply "\$\{(\w+)\}"', build)
        self.assertEqual(applies.count("GLU_NURBS_PATCH"), 1)
        # after 0033, before 0034; only 0036 (MPENGINE_PATCH) may also sit between them; 0034 and 0030 stay the last two
        tail = applies[applies.index("LOCAL_MODULE_READS_PATCH") + 1:]
        self.assertEqual(tail[-2:], ["SERVER_WINDOW_WALKS_PATCH", "OPENGL32_BATCH_PATCH"])
        self.assertIn("GLU_NURBS_PATCH", tail[:-2])
        self.assertLessEqual(set(tail[:-2]), {"MPENGINE_PATCH", "GLU_NURBS_PATCH"})
        self.assertIn("    dlls/glu32/x86_64-windows/glu32.dll \\", build)
        self.assertIn('[ -f "${GLU32_OUTPUT}" ]', build)
        self.assertIn('cp "${BUILD_DIR}/dlls/glu32/x86_64-windows/glu32.dll" "${GLU32_OUTPUT}.new"', build)
        self.assertIn('file "${GLU32_OUTPUT}.new" | grep -q \'PE32+ executable.*x86-64\'', build)
        self.assertIn('mv "${GLU32_OUTPUT}.new" "${GLU32_OUTPUT}"', build)
        self.assertNotIn("i386-windows/glu32.dll", build)   # SOLIDWORKS is 64-bit
        self.assertIn('GLU32_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/glu32.dll"', package)
        self.assertIn('cp "${GLU32_PATCH}" "${GLU32_TARGET}"', package)
        inputs = next(l for l in package.splitlines() if l.lstrip().startswith('"${WINEMAC_PATCH}"'))
        self.assertIn('"${GLU32_PATCH}"', inputs)
        for key in (PATCH_KEY, MODULE_KEY):
            self.assertIn(f"Add :{key} string", package)
            self.assertIn(f"Print :{key}", verify)
        table = verify.split('MANIFEST_MODULES="', 1)[1].split('"\n', 1)[0]
        self.assertIn(f"{MODULE_KEY}|${{GLU32_MODULE}}", table)
        # the packaged module is the dist module after package_app.sh's PE strip
        self.assertIn('cmp_pe_module glu32.dll ${GLU32_MODULE}', verify)

    def test_runtime_verification_declares_the_module(self):
        runtime = (PROJECT / "scripts/swcli/wine_runtime.py").read_text()
        declared = runtime.split("DECLARED_MODULES = {", 1)[1].split("}", 1)[0]
        self.assertIn(f'"{MODULE_KEY}": "lib/wine/x86_64-windows/glu32.dll"', declared)

    def test_pins_are_computed_from_the_files(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            for key in (PATCH_KEY, MODULE_KEY):
                line = next(l for l in text.splitlines() if key in l)
                self.assertNotRegex(line, r"[0-9a-f]{64}")


# ---------------------------------------------------------------- native evaluator and API

def native_skip_reason():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        return "native harness needs macOS on arm64"
    if not shutil.which("clang"):
        return "clang not found"
    return None


@unittest.skipIf(native_skip_reason(), native_skip_reason() or "")
class GluNurbsNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="glu-nurbs-")
        root = Path(cls.tmp.name)
        (root / "inc/wine").mkdir(parents=True)
        for header in ("windef.h", "winbase.h", "wine/wgl.h", "wine/glu.h", "wine/debug.h"):
            (root / "inc" / header).write_text('#include "nurbs_stubs.h"\n')
        (root / "src").mkdir()
        (root / "src/nurbs.c").write_text(new_file("dlls/glu32/nurbs.c"))
        cls.exe = root / "nurbs_harness"
        subprocess.run(["clang", "-arch", "arm64", "-std=c99", "-O1", "-g", "-Wall", "-Werror",
                        "-Wno-unused-function", "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", str(root / "inc"), "-I", str(HARNESS), "-I", str(root / "src"),
                        "-o", str(cls.exe), str(HARNESS / "nurbs_harness.c"), "-lm"],
                       check=True, capture_output=True, text=True, timeout=300)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_harness(self, *args, stdin=None):
        result = subprocess.run([str(self.exe), *args], input=stdin, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        return result.stdout.splitlines()

    def api(self, scenario):
        lines = self.run_harness("api", scenario)
        self.assertEqual(lines[-2:], ["heap 0", "attrib 0"])   # every block freed, every push popped
        return lines[:-2]

    # -- evaluation against the reference

    def evaluate(self, cases):
        text, expected = [], []
        for case in cases:
            if case[0] == "curve":
                _, knots, order, points, params = case
                text.append(f"curve {order} {len(points[0])} {len(knots)} " + " ".join(map(repr, knots)) + " " +
                            " ".join(repr(c) for p in points for c in p) + f" {len(params)} " +
                            " ".join(map(repr, params)))
                expected.append(("check", None))
                expected += [("p", ref_curve(knots, order, points, u)) for u in params]
            else:
                _, sknots, sorder, tknots, torder, grid, params = case
                flat = [c for row in grid for p in row for c in p]
                text.append(f"surface {sorder} {torder} {len(grid[0][0])} {len(sknots)} {len(tknots)} " +
                            " ".join(map(repr, sknots + tknots + flat)) + f" {len(params)} " +
                            " ".join(f"{s!r} {t!r}" for s, t in params))
                expected += [("p", ref_surface(sknots, sorder, tknots, torder, grid, s, t)) for s, t in params]
        lines = self.run_harness("eval", stdin="\n".join(text) + "\n")
        self.assertEqual(len(lines), len(expected))
        out = []
        for line, (kind, ref) in zip(lines, expected):
            fields = line.split()
            self.assertEqual(fields[0], kind, line)
            if kind == "check":
                self.assertEqual(fields[1], "0", line)
                continue
            got = [float(v) for v in fields[1:]]
            out.append((got, ref))
        return out

    def assert_close(self, results, scale_of):
        for got, ref in results:
            ref_flat = [c for part in ref for c in part]
            self.assertEqual(len(got), len(ref_flat))
            dim = len(ref[0])
            for k, (g, r) in enumerate(zip(got, ref_flat)):
                tol = scale_of(k // dim) * (1 + abs(r))
                self.assertLessEqual(abs(g - r), tol, (k, got, ref_flat))

    def test_curves_of_every_order_match_cox_de_boor(self):
        rng = random.Random(37)
        cases = []
        for order in range(1, 8):
            for dim in (3, 4):
                count = order + rng.randint(0, 4)
                knots = clamped_knots(rng, order, count)
                lo, hi = knots[order - 1], knots[count]
                params = [lo, hi] + [rng.uniform(lo, hi) for _ in range(20)] + knots[order:count]
                cases.append(("curve", knots, order, random_points(rng, count, dim), params))
        for order in (3, 4):   # unclamped uniform knots: the range is knots[order - 1] .. knots[count]
            count = order + 4
            knots = [float(i) for i in range(count + order)]
            params = [knots[order - 1], knots[count]] + [rng.uniform(knots[order - 1], knots[count]) for _ in range(20)]
            cases.append(("curve", knots, order, random_points(rng, count, 3), params))
        results = self.evaluate(cases)
        self.assertGreater(len(results), 300)
        # relative errors: points 2e-5, first derivatives 2e-4 (measured: 1e-6 and 2.3e-5)
        self.assert_close(results, lambda part: 2e-5 if part == 0 else 2e-4)

    def test_repeated_knots_and_rational_weights(self):
        rng = random.Random(3737)
        cases = []
        for order, mult in ((4, 2), (4, 3), (4, 4), (3, 3), (2, 2), (5, 2)):
            for dim in (3, 4):
                inner = sorted(rng.uniform(0.1, 0.9) for _ in range(2))
                knots = [0.0] * order + [inner[0]] + [0.5] * mult + [inner[1]] + [1.0] * order
                knots = sorted(knots)
                count = len(knots) - order
                params = [0.0, 1.0, 0.5, 0.5 - 1e-3, 0.5 + 1e-3] + [rng.random() for _ in range(25)]
                cases.append(("curve", knots, order, random_points(rng, count, dim), params))
        results = self.evaluate(cases)
        self.assert_close(results, lambda part: 2e-5 if part == 0 else 2e-4)

    def test_full_circle_and_ellipse(self):
        params = [i / 50 for i in range(201)]
        for a, b in ((1.0, 1.0), (3.0, 1.5), (0.02, 40.0)):
            with self.subTest(a=a, b=b):
                results = self.evaluate([("curve", CIRCLE_KNOTS, 3, ellipse_points(a, b), params)])
                self.assert_close(results, lambda part: 2e-6 * max(a, b) if part == 0 else 1e-4 * max(a, b))
                for got, _ in results:
                    x, y = got[0] / got[3], got[1] / got[3]
                    self.assertAlmostEqual((x / a) ** 2 + (y / b) ** 2, 1.0, delta=2e-6)

    def test_surfaces_match_the_tensor_product(self):
        rng = random.Random(1937)
        cases = []
        for sorder, torder, dim in ((2, 3, 3), (3, 3, 4), (4, 4, 3), (4, 2, 4), (1, 3, 3), (5, 4, 3)):
            ns, nt = sorder + rng.randint(0, 3), torder + rng.randint(0, 3)
            sknots, tknots = clamped_knots(rng, sorder, ns), clamped_knots(rng, torder, nt)
            grid = [random_points(rng, nt, dim) for _ in range(ns)]
            s0, s1, t0, t1 = sknots[sorder - 1], sknots[ns], tknots[torder - 1], tknots[nt]
            params = [(s0, t0), (s1, t1), (s0, t1), (s1, t0)] + \
                     [(rng.uniform(s0, s1), rng.uniform(t0, t1)) for _ in range(30)]
            cases.append(("surface", sknots, sorder, tknots, torder, grid, params))
        results = self.evaluate(cases)
        self.assert_close(results, lambda part: 2e-5 if part == 0 else 2e-4)

    # -- the public API

    @staticmethod
    def strips(lines, prefix=""):
        """[(mode, [vertex, ...]), ...] from begin/vertex/end events"""
        strips = []
        for line in lines:
            f = line.split()
            if f[0] in ("begin", "glBegin", "begin_data"):
                strips.append((int(f[1]), []))
            elif f[0] in ("vertex", "glVertex3fv"):
                strips[-1][1].append(tuple(float(v) for v in f[1:4]))
            elif f[0] == "vertex_data":
                strips[-1][1].append(tuple(float(v) for v in f[2:5]))
        return strips

    def test_properties(self):
        lines = self.api("props")
        defaults = {int(f[1]): float(f[2]) for f in (l.split() for l in lines) if f[0] == "default"}
        self.assertEqual(defaults, {100205: 100215, 100203: 50, 100202: 0.5, 100206: 100, 100207: 100,
                                    100204: 100012, 100201: 0, 100200: 1, 100160: 100162})
        sets = {int(f[1]): float(f[2]) for f in (l.split() for l in lines) if f[0] == "set"}
        self.assertEqual(sets, {100205: 100217, 100203: 7.5, 100202: 0.25, 100206: 12, 100207: 13,
                                100204: 100241, 100201: 1, 100200: 0, 100160: 100161})
        errors = lines[lines.index("invalid") + 1:]
        self.assertEqual(errors, ["error 100901"] * 6 + ["error 100900"] * 3 + ["kept 7.5"])

    def check_circle(self, scenario, radius=1.0):
        strips = self.strips(self.api(scenario))
        self.assertEqual(len(strips), 1)
        mode, points = strips[0]
        self.assertEqual(mode, GL_LINE_STRIP)
        for x, y, z in points:
            self.assertAlmostEqual(math.hypot(x, y), radius, delta=2e-6 * radius)
        self.assertAlmostEqual(points[0][0], radius, delta=1e-6)
        self.assertAlmostEqual(points[-1][0], radius, delta=1e-6)
        return points

    @staticmethod
    def edges(points, scale=1.0):
        return [math.dist(a[:2], b[:2]) * scale for a, b in zip(points, points[1:])]

    def test_path_length_keeps_every_edge_under_the_tolerance(self):
        points = self.check_circle("circle_path")   # radius 200 pixels, tolerance 10 pixels
        self.assertEqual(len(points), 161)
        self.assertLessEqual(max(self.edges(points, 200)), 10)
        points = self.check_circle("circle_object")   # object space, tolerance 0.05
        self.assertLessEqual(max(self.edges(points)), 0.05)

    def test_parametric_error_keeps_the_chords_close(self):
        for scenario, scale, tolerance in (("circle_parametric", 200, 0.5), ("circle_object_parametric", 1, 0.001)):
            with self.subTest(scenario=scenario):
                points = self.check_circle(scenario)
                sag = max(scale * (1 - math.hypot((a[0] + b[0]) / 2, (a[1] + b[1]) / 2))
                          for a, b in zip(points, points[1:]))
                self.assertLessEqual(sag, tolerance)
                self.assertLess(len(points), 4 * 64)

    def test_domain_distance_ellipse(self):
        strips = self.strips(self.api("ellipse_domain"))
        (mode, points), = strips
        self.assertEqual(len(points), 33)   # 8 steps on each of the 4 spans
        pts = ellipse_points(3, 1.5)
        for k, (x, y, z) in enumerate(points):
            ref, _ = ref_curve(CIRCLE_KNOTS, 3, pts, k / 8)
            self.assertAlmostEqual(x, ref[0] / ref[3], delta=1e-5)
            self.assertAlmostEqual(y, ref[1] / ref[3], delta=1e-5)
            self.assertAlmostEqual((x / 3) ** 2 + (y / 1.5) ** 2, 1, delta=1e-5)

    def test_renderer_mode_draws_with_immediate_mode(self):
        lines = self.api("render")
        zoom = lines.index("zoom")
        first, second = self.strips(lines[:zoom]), self.strips(lines[zoom:])
        self.assertEqual(lines[:3], ["glGetFloatv 0xba6", "glGetFloatv 0xba7", "glGetIntegerv 0xba2"])
        self.assertFalse([l for l in lines if l.startswith("vertex")])   # tessellator callbacks are not used
        self.assertEqual([m for m, _ in first + second], [GL_LINE_STRIP, GL_LINE_STRIP])
        for x, y, z in first[0][1] + second[0][1]:
            self.assertAlmostEqual(math.hypot(x, y), 0.5, delta=1e-6)
        self.assertLessEqual(max(self.edges(first[0][1], 200)), 25)
        ratio = len(second[0][1]) / len(first[0][1])
        self.assertTrue(3 < ratio < 5, ratio)

    def test_invalid_input_is_reported_and_not_drawn(self):
        lines = self.api("errors")
        cases, current = {}, None
        for line in lines:
            if line.startswith("case "):
                current = line[5:]
                cases[current] = []
            elif line.startswith("error "):
                cases[current].append(int(line[6:]))
        self.assertEqual(cases, {
            "order": [100251], "order25": [100251], "fewknots": [100252], "decreasing": [100254],
            "multiplicity": [100255], "emptyrange": [100253], "nullknots": [100282], "nullctl": [100286],
            "stride": [100284], "type": [100285], "endcurve": [100257], "endsurface": [100263],
            "begintrim": [100265], "endtrim": [100267], "pwl": [100269], "trimtype": [100272],
            "twice": [100256], "nosurface": [100256], "novertex": [100258], "surface": [],
            "trimtwice": [100266], "pwltype": [100264], "pwlcount": [100283], "curveintrim": [100264],
            "endsurfaceintrim": [100262, 100258], "recovered": []})
        strips = self.strips(lines)
        self.assertEqual(len(strips), 1)   # only the curve after the errors
        self.assertEqual(len(strips[0][1]), 3)

    def test_tiny_tolerances_and_bad_numbers_stay_bounded(self):
        lines = self.api("limits")
        parts, current = {}, None
        for line in lines:
            if line.startswith("case "):
                current = line[5:]
                parts[current] = []
            else:
                parts[current].append(line)
        for name in ("tiny", "parametric", "domain"):
            (mode, points), = self.strips(parts[name])
            self.assertEqual(len(points), 4 * 1024 + 1, name)   # MAX_SPAN_STEPS on each span
        self.assertEqual(parts["nanknot"], ["error 100254"])
        (mode, points), = self.strips(parts["nanpoint"])
        self.assertLessEqual(len(points), 4 * 1024 + 1)
        strips = self.strips(parts["surface"])
        self.assertEqual(len(strips), 256)   # MAX_GRID_STEPS along t ...
        self.assertTrue(all(len(p) == 2 * 257 for m, p in strips))   # ... and along s
        (mode, points), = self.strips(parts["manyspans"])
        self.assertTrue(200 < len(points) <= 65536 + 1, len(points))   # MAX_CURVE_STEPS for the whole curve
        self.assertEqual(points[-1], (1.0, 0.0, 0.0))

    def test_huge_sample_counts_give_out_of_memory(self):
        # very many knot spans, each with at least one step: the int counts in grid_params and
        # sample_trims passed INT_MAX and the buffers they sized overflowed (2^22 * 1024 grid steps,
        # 8,400,000 * 257 trim points). Now: GLU_OUT_OF_MEMORY, nothing drawn, every block freed.
        self.assertEqual(self.api("overflow"), ["case grid", "error 100902", "case gridcap", "error 100902",
                                                "case trim", "error 100902", "case pwl", "error 100902"])

    def test_surface_fill_with_computed_normals(self):
        lines = self.api("surface_fill")
        strips = self.strips(lines)
        self.assertEqual([(m, len(p)) for m, p in strips], [(GL_QUAD_STRIP, 10)] * 3)
        normals = [tuple(map(float, l.split()[1:])) for l in lines if l.startswith("normal")]
        self.assertEqual(len(normals), 30)
        knots = [0, 0, 0, 0, 1, 1, 1, 1]
        grid = [[[i / 3, j / 3, 0.5 if i in (1, 2) and j in (1, 2) else 0.0] for j in range(4)] for i in range(4)]
        k = 0
        for row in range(3):
            for col in range(5):
                for t in (row / 3, (row + 1) / 3):
                    value, ds, dt = ref_surface(knots, 4, knots, 4, grid, col / 4, t)
                    n = [ds[1] * dt[2] - ds[2] * dt[1], ds[2] * dt[0] - ds[0] * dt[2], ds[0] * dt[1] - ds[1] * dt[0]]
                    length = math.sqrt(sum(c * c for c in n))
                    for c in range(3):
                        self.assertAlmostEqual(strips[row][1][k % 10][c], value[c], delta=1e-5)
                        self.assertAlmostEqual(normals[k][c], n[c] / length, delta=1e-4)
                    k += 1

    def test_surface_outlines(self):
        strips = self.strips(self.api("surface_outline_polygon"))
        self.assertEqual(sorted(len(p) for m, p in strips), [4] * 5 + [5] * 4)
        self.assertTrue(all(m == GL_LINE_STRIP for m, p in strips))
        (mode, points), = self.strips(self.api("surface_outline_patch"))
        self.assertEqual(len(points), 2 * 4 + 2 * 3 + 1)
        self.assertEqual(points[0], points[-1])
        self.assertTrue(all(min(x, 1 - x, y, 1 - y) < 1e-6 for x, y, z in points))   # on the patch border

    def test_trimmed_surface_keeps_the_ring(self):
        strips = self.strips(self.api("surface_trim"))
        cell = 1 / 40
        area = 0.0
        for mode, points in strips:
            self.assertIn(mode, (GL_QUAD_STRIP, GL_TRIANGLES))
            for x, y, z in points:
                self.assertEqual(z, 0.0)
                self.assertLessEqual(math.hypot(x - 0.5, y - 0.5), 0.4 + 1.5 * cell)   # inside the circle
                self.assertFalse(0.4 + 1.5 * cell < x < 0.6 - 1.5 * cell and 0.4 + 1.5 * cell < y < 0.6 - 1.5 * cell)
            polys = [points[i:i + 3] for i in range(0, len(points), 3)] if mode == GL_TRIANGLES else \
                [(points[i], points[i + 1], points[i + 3], points[i + 2]) for i in range(0, len(points) - 2, 2)]
            for poly in polys:
                area += abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1]))) / 2
        # a cell is drawn when 3 or 4 corners are kept: the area is short by at most one cell along the border
        exact, border = math.pi * 0.4 ** 2 - 0.2 ** 2, 2 * math.pi * 0.4 + 4 * 0.2
        self.assertLess(area, exact)
        self.assertGreater(area, exact - border * cell)

    def test_trimmed_outline_follows_the_trimming_loops(self):
        strips = self.strips(self.api("surface_trim_outline"))
        self.assertEqual(len(strips), 2)
        circle = max(strips, key=lambda s: len(s[1]))[1]
        square = min(strips, key=lambda s: len(s[1]))[1]
        self.assertEqual(circle[0], circle[-1])
        for x, y, z in circle:
            self.assertAlmostEqual(math.hypot(x - 0.5, y - 0.5), 0.4, delta=1e-5)
        for x, y, z in square:
            self.assertLess(min(abs(x - 0.4), abs(x - 0.6), abs(y - 0.4), abs(y - 0.6)), 1e-6)

    def test_attributes_data_callbacks_discontinuities_and_culling(self):
        lines = self.api("attributes")
        cut = [lines.index(f"case {n}") for n in ("data", "discontinuous", "culling")]
        first = lines[:cut[0]]
        colors = [tuple(map(float, l.split()[1:])) for l in first if l.startswith("color")]
        texs = [tuple(map(float, l.split()[1:])) for l in first if l.startswith("texcoord")]
        (mode, points), = self.strips(first)
        self.assertEqual(len(points), 5)
        for (x, y, z), color, tex in zip(points, colors, texs):
            self.assertEqual(color, (1 - x / 2, 0, x / 2, 1))
            self.assertEqual(tex, (x / 2, x / 2))
        data = lines[cut[0] + 1:cut[1]]
        self.assertEqual(data[0], "begin_data 3 null")
        self.assertEqual(data[-1], "end_data null")
        self.assertTrue(all(l.startswith("vertex_data null") for l in data[1:-1]) and len(data) == 7)
        self.assertEqual(self.strips(lines[cut[1]:cut[2]]),
                         [(GL_LINE_STRIP, [(0, 0, 0), (1, 1, 0)]), (GL_LINE_STRIP, [(2, 0, 0), (3, 1, 0)])])
        self.assertEqual(self.strips(lines[cut[2]:]), [(GL_LINE_STRIP, [(-0.5, 0, 0), (0.5, 0, 0)])])

    def test_renderer_surface_keeps_the_current_attributes(self):
        lines = self.api("render_surface")
        body = [l for l in lines if not l.startswith("glGet")]
        self.assertEqual(body[0], "glPushAttrib 0x1")
        self.assertEqual(body[-1], "glPopAttrib")
        calls = [l.split()[0] for l in body[1:-1]]
        self.assertEqual(calls[0], "glBegin")
        self.assertEqual(calls[1:-1], ["glNormal3fv", "glVertex3fv"] * ((len(calls) - 2) // 2))


if __name__ == "__main__":
    unittest.main()
