"""OpenGL immediate-mode batching (patch 0030): patch invariants and build, package and verify wiring."""
from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0030-opengl32-batch-immediate-mode-calls.patch"
KEYS = ("WineOpenGLBatchPatchSHA256", "WineOpenGL32ModuleSHA256", "WineOpenGL32UnixModuleSHA256")


def patch_text():
    return (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()


def added_lines(patch, path):
    """Added lines of one file of the patch."""
    out, current = [], None
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            current = line.split(" b/", 1)[1]
        elif current == path and line.startswith("+") and not line.startswith("+++"):
            out.append(line[1:])
    return "\n".join(out)


def function(code, signature):
    """Body of one added C function (up to the first closing brace in column 0)."""
    return code.split(signature, 1)[1].split("\n}\n", 1)[0]


class OpenGLBatchPatchTests(unittest.TestCase):
    def test_patch_only_touches_opengl32(self):
        files = [l.split(" b/", 1)[1] for l in patch_text().splitlines() if l.startswith("diff --git ")]
        self.assertTrue(files)
        for name in files:
            self.assertTrue(name.startswith("dlls/opengl32/"), name)

    def test_new_unix_call_is_appended_so_existing_indices_stay(self):
        patch = patch_text()
        unixlib = added_lines(patch, "dlls/opengl32/unixlib.h")
        self.assertIn("unix_macsw_gl_batch,", unixlib)
        # the enum entry is added directly before funcs_count, after the last generated entry
        self.assertRegex(patch, r"\s+unix_wglSwapIntervalEXT,\n\+    unix_macsw_gl_batch,\n     funcs_count")
        thunks = added_lines(patch, "dlls/opengl32/unix_thunks.c")
        self.assertIn("macsw_gl_batch,", thunks)          # 64-bit table
        self.assertIn("wow64_macsw_gl_batch,", thunks)    # wow64 table (32-bit PE never batches)

    def test_every_pe_unix_call_flushes_first(self):
        private = added_lines(patch_text(), "dlls/opengl32/private.h")
        self.assertIn("#undef UNIX_CALL", private)
        self.assertRegex(private, r"#define UNIX_CALL\( func, params \) \(gl_batch_flush\(\), WINE_UNIX_CALL\(")
        self.assertIn("#ifdef _WIN64", private)
        wgl = added_lines(patch_text(), "dlls/opengl32/wgl.c")
        self.assertIn('L"MACSW_GL_BATCH"', wgl)           # opt-out switch
        self.assertIn("gl_batch_flush();", wgl)           # thread detach flushes pending calls
        # the only direct unix call that bypasses the flushing macro is the batch itself
        direct = re.findall(r"WINE_UNIX_CALL\( (\w+)", wgl + added_lines(patch_text(), "dlls/opengl32/thunks.c"))
        self.assertEqual(direct, ["unix_macsw_gl_batch"])

    def test_only_void_immediate_mode_calls_are_recorded(self):
        # every thunks.c hunk that records a call names its function in the hunk header
        thunks = patch_text().split("diff --git a/dlls/opengl32/thunks.c", 1)[1].split("diff --git ", 1)[0]
        recorders = []
        for hunk in thunks.split("\n@@ ")[1:]:
            if "gl_batch_put(" in hunk:
                recorders.append(re.match(r"[^@]*@@ (.*)", hunk).group(1))
        # one recording call per hunk, so every recording function is checked (19 of them)
        self.assertEqual(len(recorders), added_lines(patch_text(), "dlls/opengl32/thunks.c").count("gl_batch_put("))
        self.assertGreaterEqual(len(recorders), 19)
        for signature in recorders:
            # no return value, no state read: glGet*, glIsEnabled, glReadPixels, glFinish... never batch
            self.assertRegex(signature, r"^void WINAPI gl(Begin|End|Vertex[23][fd]v?|Normal3[fd]v?|Color[34]fv?|TexCoord2[fd]v?)\(")

    def test_debug_callback_turns_batching_off(self):
        thunks = added_lines(patch_text(), "dlls/opengl32/thunks.c")
        self.assertEqual(thunks.count("if (callback) gl_batch_disable();"), 3)   # core, ARB, AMD
        private = added_lines(patch_text(), "dlls/opengl32/private.h")
        put = function(private, "static inline BOOL gl_batch_put(")
        self.assertIn("if (!gl_batch_enabled) return FALSE;", put)
        self.assertLess(put.index("if (!gl_batch_enabled) return FALSE;"), put.index("memcpy"))
        wgl = added_lines(patch_text(), "dlls/opengl32/wgl.c")
        self.assertIn("InterlockedExchange( &gl_batch_enabled, 0 );", function(wgl, "void gl_batch_disable(void)"))

    def test_replay_checks_bounds_and_ops(self):
        replay = function(added_lines(patch_text(), "dlls/opengl32/unix_wgl.c"), "NTSTATUS macsw_gl_batch( void *args )")
        self.assertIn("if (end - ptr < sizeof(v)) goto truncated;", replay)
        self.assertIn("if (end - ptr < sizeof(mode)) goto truncated;", replay)
        self.assertIn('ERR( "invalid batch op %u\\n", op );', replay)
        self.assertIn("if (ptr == end) return STATUS_SUCCESS;", replay)

    def test_every_recorded_op_is_replayed(self):
        patch = patch_text()
        recorded = set(re.findall(r"GL_BATCH_[A-Z0-9]+", added_lines(patch, "dlls/opengl32/thunks.c")))
        replayed = set(re.findall(r"case (GL_BATCH_[A-Z0-9]+):", added_lines(patch, "dlls/opengl32/unix_wgl.c")))
        self.assertTrue(recorded)
        self.assertEqual(recorded, replayed)
        for op in ("GL_BATCH_BEGIN", "GL_BATCH_END", "GL_BATCH_VERTEX3F", "GL_BATCH_NORMAL3F"):
            self.assertIn(op, recorded)

    def test_build_package_and_verify_wiring(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${OPENGL32_BATCH_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${OPENGL32_BATCH_PATCH}"', build)
        # applied after every other patch (it is independent of them; 0028, 0032 and 0033 come right before it)
        applies = re.findall(r'git -C "\$\{SOURCE_DIR\}" apply "\$\{(\w+)\}"', build)
        self.assertEqual(applies[-1], "OPENGL32_BATCH_PATCH")
        self.assertIn("WBEMPROX_IPENABLED_PATCH", applies)
        for target in ("dlls/opengl32/x86_64-windows/opengl32.dll", "dlls/opengl32/opengl32.so"):
            self.assertIn(target, build)
        self.assertIn('[ -f "${OPENGL32_OUTPUT}" ]', build)
        self.assertIn('[ -f "${OPENGL32_UNIX_OUTPUT}" ]', build)
        self.assertIn('install_name_tool -id opengl32.so "${OPENGL32_UNIX_OUTPUT}.new"', build)
        sign_loop = next(l for l in build.splitlines() if l.startswith("for MODULE in "))
        self.assertIn('"${OPENGL32_UNIX_OUTPUT}.new"', sign_loop)   # codesigned and verified with the other .so files
        self.assertIn("wine/lib/wine/x86_64-windows/opengl32.dll", package)
        self.assertIn("wine/lib/wine/x86_64-unix/opengl32.so", package)
        self.assertIn('codesign --force --sign - "${OPENGL32_UNIX_TARGET}"', package)
        for key in KEYS:
            self.assertIn(key, package)
            self.assertIn(key, verify)
        table = verify.split('MANIFEST_MODULES="', 1)[1].split('"\n', 1)[0]
        self.assertIn("WineOpenGL32ModuleSHA256|${OPENGL32_MODULE}", table)
        self.assertIn("WineOpenGL32UnixModuleSHA256|${OPENGL32_UNIX}", table)
        self.assertIn('cmp_pe_module opengl32.dll ', verify)
        self.assertIn('codesign --verify --verbose=2 "${OPENGL32_UNIX}"', verify)

    def test_runtime_verification_and_switch_reach_wine(self):
        runtime = (PROJECT / "scripts/swcli/wine_runtime.py").read_text()
        declared = runtime.split("DECLARED_MODULES = {", 1)[1].split("}", 1)[0]
        self.assertIn('"WineOpenGL32ModuleSHA256": "lib/wine/x86_64-windows/opengl32.dll"', declared)
        self.assertIn('"WineOpenGL32UnixModuleSHA256": "lib/wine/x86_64-unix/opengl32.so"', declared)
        # MACSW_GL_BATCH=0 must survive the environment allowlist of the app and of wine_runtime.py
        inherited = runtime.split("INHERITED_ENVIRONMENT = frozenset((", 1)[1].split("))", 1)[0]
        self.assertIn('"MACSW_GL_BATCH"', inherited)
        swift = (PROJECT / "macos/Bootstrap/Sources/MacSWCore/Services/WineService.swift").read_text()
        keys = swift.split("static let inheritedEnvironmentKeys: Set<String> = [", 1)[1].split("]", 1)[0]
        self.assertIn('"MACSW_GL_BATCH"', keys)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if "WineOpenGLBatchPatchSHA256" in l)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_description_points_to_the_measurements(self):
        header = " ".join(patch_text().split("diff --git ", 1)[0].split())
        self.assertIn("docs/graphics-performance.md", header)
        self.assertIn("MACSW_GL_BATCH=0", header)
        self.assertIn("debug message callback", header)


if __name__ == "__main__":
    unittest.main()
