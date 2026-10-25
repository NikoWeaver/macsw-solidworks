"""Apple's multithreaded GL engine in winemac (patch 0036): patch invariants and build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0036-winemac-multithreaded-gl-engine.patch"
KEY = "WineMPEnginePatchSHA256"


def patch_text():
    return (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()


def added(text):
    return "\n".join(l[1:] for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))


def body():
    return patch_text().split("diff --git ", 1)[1]


class MPEnginePatchTests(unittest.TestCase):
    def test_patch_only_adds_lines_to_winemac_opengl_c(self):
        files = [l.split(" b/", 1)[1] for l in patch_text().splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/winemac.drv/opengl.c"])
        removed = [l for l in body().splitlines() if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])

    def test_engine_is_enabled_once_when_a_context_first_presents(self):
        code = added(patch_text())
        self.assertIn("CGLEnable(context->cglcontext, kCGLCEMPEngine)", code)
        self.assertIn("if (context->mp_engine_checked) return;", code)
        self.assertIn("BOOL                    mp_engine_checked;", code)
        # not at creation: only contexts that present to a window get the engine
        self.assertNotIn("macdrv_create_opengl_context", code)
        # both present paths: front-buffer flush (SOLIDWORKS) and SwapBuffers
        text = body()
        flush = text.split("if (flags & GL_FLUSH_PRESENT)", 1)[1].split("client_surface_present", 1)[0]
        self.assertIn("enable_mp_engine(context);", flush)
        swap = text.split("struct macdrv_client_surface *client = impl_from_client_surface(base->client);\n+        enable_mp_engine(context);", 1)
        self.assertEqual(len(swap), 2)
        # a failure only warns: the context is still used
        self.assertIn("continuing without it", code)

    def test_switch(self):
        code = added(patch_text())
        self.assertIn('getenv("MACSW_GL_MPENGINE")', code)
        self.assertIn("enabled = !(str && str[0] == '0');", code)

    def test_build_package_and_verify_wiring(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        self.assertIn(f'MPENGINE_PATCH="${{WORKSPACE_ROOT}}/patches/wine-crossover/{PATCH_NAME}"', build)
        self.assertIn(":${MPENGINE_PATCH_SHA256}:", build)
        # after every other winemac patch (0002-0025), before 0034 and 0030 (which stay last; other files)
        self.assertLess(build.index('apply "${APP_BUNDLE_HOST_PATCH}"'), build.index('apply --check "${MPENGINE_PATCH}"'))
        self.assertLess(build.index('apply --check "${MPENGINE_PATCH}"'), build.index('apply "${MPENGINE_PATCH}"'))
        self.assertLess(build.index('apply "${MPENGINE_PATCH}"'), build.index('apply --check "${SERVER_WINDOW_WALKS_PATCH}"'))
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            self.assertIn(KEY, text, name)
            self.assertIn(PATCH_NAME, text, name)

    def test_switch_survives_the_environment_allowlists(self):
        runtime = (PROJECT / "scripts/swcli/wine_runtime.py").read_text()
        inherited = runtime.split("INHERITED_ENVIRONMENT = frozenset((", 1)[1].split("))", 1)[0]
        self.assertIn('"MACSW_GL_MPENGINE"', inherited)
        swift = (PROJECT / "macos/Bootstrap/Sources/MacSWCore/Services/WineService.swift").read_text()
        keys = swift.split("static let inheritedEnvironmentKeys: Set<String> = [", 1)[1].split("]", 1)[0]
        self.assertIn('"MACSW_GL_MPENGINE"', keys)


if __name__ == "__main__":
    unittest.main()
