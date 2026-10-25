"""Software renderer patch contracts and mocked CGL failures; never start Wine."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0009-winemac-software-renderer-fallback.patch"
PATCH = PROJECT / "patches/wine-crossover" / PATCH_NAME


def postimage():
    return "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                     if line.startswith(("+", " ")) and not line.startswith("+++"))


class SoftwareRendererTests(unittest.TestCase):
    def test_patch_is_built_cached_packaged_and_verified_after_bitmap_patch(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        self.assertIn(PATCH_NAME, build)
        key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${SOFTWARE_RENDERER_PATCH_SHA256}", key)
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${SOFTWARE_RENDERER_PATCH}"', build)
        self.assertLess(build.index('apply "${BITMAP_PATCH}"'),
                        build.index('apply "${SOFTWARE_RENDERER_PATCH}"'))
        for script in (package, verify):
            self.assertIn(PATCH_NAME, script)
            self.assertIn("WineMacSoftwareRendererPatchSHA256", script)
        self.assertIn("'patches/wine-crossover/**'", workflow)

    def test_fallback_enumeration_and_bitmap_acceleration_follow_native_context(self):
        patch = postimage()
        self.assertIn("!allow_software_rendering && !software_renderer", patch)
        self.assertIn("software_renderer = !accelerated", patch)
        self.assertIn("bitmap_accelerated = accelerated", patch)
        self.assertIn("bitmap.accelerated = bitmap_accelerated", patch)
        self.assertNotIn("bitmap.accelerated = bitmap.bitmap = 1", patch)
        self.assertNotIn("allow_software_rendering =", patch)
        self.assertIn("init_context(kCGLOGLPVersion_GL3_Core, NULL)", patch)
        self.assertIn("init_context(kCGLOGLPVersion_GL4_Core, NULL)", patch)
        # 0008's storage/capability gates and context sharing are not replaced.
        self.assertIn("GL_EXT_packed_depth_stencil", patch)
        self.assertIn("GL_MAX_RENDERBUFFER_SIZE_EXT", patch)

    def test_native_bitmap_gate_checks_acceleration_without_weakening_pixels(self):
        probe = (PROJECT / "scripts/diagnostics/check_bitmap_opengl.c").read_text()
        self.assertIn('wglGetProcAddress("wglGetPixelFormatAttribivARB")', probe)
        self.assertIn('!strcmp(renderer, "Apple Software Renderer")', probe)
        self.assertIn("!(actual.dwFlags & PFD_GENERIC_FORMAT)", probe)
        self.assertIn("acceleration != WGL_NO_ACCELERATION_ARB", probe)
        self.assertIn('glGetString(GL_VERSION)', probe)
        self.assertIn("red_pixels != (unsigned int)width * 8", probe)
        self.assertIn("depth < 24 || stencil < 8", probe)
        self.assertIn("for (int bpp = 24; bpp <= 32; bpp += 8)", probe)
        self.assertIn("for (int width = 7; width <= 8; ++width)", probe)
        self.assertIn("for (int top_down = 0; top_down <= 1; ++top_down)", probe)

    @unittest.skipUnless(shutil.which("cc"), "C compiler required for CGL mock")
    def test_actual_init_context_with_mocked_cgl(self):
        # Compile the patch's real postimage, not a separate Python model.
        function = re.search(r"static CGLContextObj init_context\([^\n]+\)\n\{.*?\n\}",
                             postimage(), re.S).group(0)
        selector = re.search(r"static BOOL select_renderer\([^\n]+\)\n\{.*?\n\}",
                             postimage(), re.S).group(0)
        prelude = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#define TRUE 1
#define FALSE 0
static int force_software_renderer;
typedef int BOOL;
typedef int CGLOpenGLProfile;
typedef int CGLPixelFormatAttribute;
typedef int GLint;
typedef int CGLError;
typedef struct { int accelerated; } *CGLPixelFormatObj;
typedef struct { int unused; } *CGLContextObj;
enum { kCGLOGLPVersion_Legacy = 0x1000, kCGLOGLPVersion_GL3_Core = 0x3200,
       kCGLOGLPVersion_GL4_Core = 0x4100, kCGLPFADisplayMask = 84,
       kCGLPFAAccelerated = 73, kCGLPFAOpenGLProfile = 99,
       kCGLPFARendererID = 70, kCGLRendererGenericFloatID = 0x20400,
       kCGLBadPixelFormat = 10002, kCGLBadAlloc = 10016 };
#define WARN(...) ((void)0)
#define TRACE(...) ((void)0)
static struct { int choose_error[2], no_pix[2], create_error, no_context,
                screen_error, describe_error, bind_error, reported_acceleration; } config;
static int chooses, creates, binds, releases_pix, releases_context;
static struct { int accelerated; } pix_storage;
static struct { int unused; } context_storage, previous_storage;
static CGLContextObj current;
static CGLOpenGLProfile requested_profile;
static unsigned int CGMainDisplayID(void) { return 42; }
static unsigned int CGDisplayIDToOpenGLDisplayMask(unsigned int display) {
    assert(display == 42); return 8;
}
static CGLContextObj CGLGetCurrentContext(void) { return current; }
static CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *attrs,
                                    CGLPixelFormatObj *pix, GLint *screens) {
    assert(chooses < 2);
    if (!chooses && !force_software_renderer) {
        assert(attrs[0] == kCGLPFADisplayMask && attrs[1] == 8);
        assert(attrs[2] == kCGLPFAAccelerated && attrs[3] == kCGLPFAOpenGLProfile);
        assert(attrs[4] == requested_profile && attrs[5] == 0);
    } else {
        assert(force_software_renderer || requested_profile == kCGLOGLPVersion_Legacy);
        assert(attrs[0] == kCGLPFARendererID && attrs[1] == kCGLRendererGenericFloatID);
        assert(attrs[2] == kCGLPFAOpenGLProfile && attrs[3] == requested_profile && attrs[4] == 0);
    }
    pix_storage.accelerated = config.reported_acceleration;
    *pix = config.no_pix[chooses] ? NULL : (CGLPixelFormatObj)&pix_storage;
    *screens = *pix ? 1 : 0;
    return config.choose_error[chooses++];
}
static CGLError CGLCreateContext(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *out) {
    assert(pix && !share); ++creates;
    *out = config.no_context ? NULL : (CGLContextObj)&context_storage;
    return config.create_error;
}
static CGLError CGLGetVirtualScreen(CGLContextObj context, GLint *screen) {
    assert(context == (CGLContextObj)&context_storage); *screen = 0;
    return config.screen_error;
}
static CGLError CGLDescribePixelFormat(CGLPixelFormatObj pix, GLint screen,
                                     CGLPixelFormatAttribute attr, GLint *value) {
    assert(pix && screen == 0 && attr == kCGLPFAAccelerated);
    *value = pix->accelerated; return config.describe_error;
}
static CGLError CGLReleasePixelFormat(CGLPixelFormatObj pix) {
    assert(pix); ++releases_pix; return 0;
}
static CGLError CGLReleaseContext(CGLContextObj context) {
    assert(context && context != (CGLContextObj)&previous_storage);
    ++releases_context; return 0;
}
static CGLError CGLSetCurrentContext(CGLContextObj context) {
    assert(context); ++binds;
    if (context == (CGLContextObj)&context_storage && config.bind_error) return config.bind_error;
    current = context; return 0;
}
'''
        cases = r'''
int main(int argc, char **argv) {
    assert(argc == 2);
    int test = atoi(argv[1]), success = 1, expected_chooses = 1, expected_releases = 1;
    config.reported_acceleration = 2; /* BOOL output must be normalized. */
    requested_profile = kCGLOGLPVersion_Legacy;
    current = (CGLContextObj)&previous_storage;
    assert(select_renderer(NULL) && !force_software_renderer);
    assert(select_renderer("auto") && !force_software_renderer);
    assert(!select_renderer("typo") && !force_software_renderer);
    switch (test) {
    case 0: break; /* hardware wins without consulting software */
    case 1: config.choose_error[0] = kCGLBadPixelFormat; config.no_pix[0] = 1;
            config.reported_acceleration = 0; expected_chooses = 2; break;
    case 2: config.no_pix[0] = 1; config.reported_acceleration = 0; expected_chooses = 2; break;
    case 3: config.choose_error[0] = kCGLBadAlloc; config.no_pix[0] = 1;
            success = 0; expected_releases = 0; break;
    case 4: requested_profile = kCGLOGLPVersion_GL3_Core;
            config.choose_error[0] = kCGLBadPixelFormat; config.no_pix[0] = 1;
            success = 0; expected_releases = 0; break;
    case 5: config.choose_error[0] = config.choose_error[1] = kCGLBadPixelFormat;
            config.no_pix[0] = config.no_pix[1] = 1;
            success = 0; expected_chooses = 2; expected_releases = 0; break;
    case 6: config.create_error = kCGLBadAlloc; success = 0; break;
    case 7: config.no_context = 1; success = 0; break;
    case 8: config.bind_error = kCGLBadAlloc; success = 0; break;
    case 9: config.screen_error = kCGLBadPixelFormat; success = 0; break;
    case 10: config.describe_error = kCGLBadPixelFormat; success = 0; break;
    case 11: config.choose_error[0] = kCGLBadPixelFormat;
             config.reported_acceleration = 0; expected_chooses = 2; expected_releases = 2; break;
    case 12: config.choose_error[0] = kCGLBadPixelFormat; config.no_pix[0] = 1;
             config.create_error = kCGLBadAlloc; expected_chooses = 2; success = 0; break;
    case 13: requested_profile = kCGLOGLPVersion_GL4_Core;
             config.choose_error[0] = kCGLBadPixelFormat; config.no_pix[0] = 1;
             success = 0; expected_releases = 0; break;
    case 14: requested_profile = kCGLOGLPVersion_GL3_Core; break;
    case 15: assert(select_renderer("software") && force_software_renderer);
             config.reported_acceleration = 0; break;
    case 16: assert(select_renderer("software")); requested_profile = kCGLOGLPVersion_GL3_Core;
             config.choose_error[0] = kCGLBadPixelFormat; config.no_pix[0] = 1;
             success = 0; expected_releases = 0; break;
    case 17: assert(select_renderer("software")); /* unexpected hardware must fail */
             success = 0; break;
    case 18: assert(select_renderer("software"));
             config.choose_error[0] = kCGLBadAlloc; config.no_pix[0] = 1;
             success = 0; expected_releases = 0; break;
    default: abort();
    }
    BOOL accelerated = -7;
    CGLContextObj context = init_context(requested_profile, test == 14 ? NULL : &accelerated);
    assert(chooses == expected_chooses && releases_pix == expected_releases);
    if (success) {
        assert(context == (CGLContextObj)&context_storage && current == context);
        assert(creates == 1 && binds == 1 && releases_context == 0);
        if (test != 14) assert(accelerated == !!config.reported_acceleration);
    } else {
        assert(!context && accelerated == -7 && current == (CGLContextObj)&previous_storage);
        assert(releases_context == (creates && !config.no_context));
        assert(binds == (config.bind_error ? 2 : 0)); /* never bind NULL after create failure */
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "init-context.c"
            source.write_text(prelude + selector + function + cases)
            executable = root / "init-context"
            subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror", str(source),
                            "-o", str(executable)], check=True, capture_output=True)
            for scenario in range(19):
                with self.subTest(scenario=scenario):
                    subprocess.run([str(executable), str(scenario)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
