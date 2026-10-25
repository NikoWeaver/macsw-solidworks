"""Offline patch/build contract; live drawing is checked by the native probe."""

from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0008-winemac-bitmap-framebuffer.patch"


class BitmapFramebufferTests(unittest.TestCase):
    def test_patch_is_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertIn(PATCH_NAME, build)
        self.assertIn('${BITMAP_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${BITMAP_PATCH}"', build)
        self.assertIn(PATCH_NAME, package)
        self.assertIn(PATCH_NAME, verify)
        for script in (package, verify):
            self.assertIn("WineMacBitmapPatchSHA256", script)

    def test_only_new_bitmap_formats_use_framebuffers(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        additions = '\n'.join(line[1:] for line in patch.splitlines()
                              if line.startswith('+') and not line.startswith('+++'))
        self.assertIn("pixel_formats[nb_formats++] = bitmap", additions)
        self.assertIn("bitmap.accelerated = bitmap.bitmap = 1", additions)
        self.assertIn("bitmap.depth_bits = 24", additions)
        self.assertIn("bitmap.stencil_bits = 8", additions)
        self.assertIn("if (pixel_formats[format - 1].bitmap)", additions)
        self.assertIn("if (largest || texture_format || texture_target || max_level) return FALSE", additions)
        self.assertIn("delete_bitmap_buffers(gl)", additions)
        self.assertIn("CGLSetCurrentContext(previous)", additions)
        self.assertIn("GL_FRAMEBUFFER_COMPLETE_EXT", additions)
        self.assertIn("GL_EXT_packed_depth_stencil", additions)
        self.assertIn("CGLRetainPixelFormat(CGLGetPixelFormat(bitmap_context))", additions)
        self.assertNotIn("CGLCreatePBuffer", additions)
        self.assertNotIn("PFD_DOUBLEBUFFER", additions)

    def test_memory_dc_conversion_is_confined_to_framebuffer_targets(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        self.assertIn("+            if (context->draw->draw_fbo)", patch)
        self.assertIn("convert_bitmapinfo( info, bits, &src, &buffer_info, buffer )", patch)
        self.assertIn("convert_bitmapinfo( &buffer_info, buffer, &src, info, bits )", patch)
        self.assertIn("p_glPushClientAttrib( GL_CLIENT_PIXEL_STORE_BIT )", patch)
        self.assertIn("p_glPopClientAttrib()", patch)
        self.assertIn("free( buffer )", patch)


if __name__ == "__main__":
    unittest.main()
