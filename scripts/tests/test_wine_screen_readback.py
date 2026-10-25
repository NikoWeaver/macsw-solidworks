"""Offline integration checks; native probe checks actual compositor pixels."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = "0013-winemac-screen-readback.patch"


class ScreenReadbackTests(unittest.TestCase):
    def test_patch_is_built_cached_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH, script)
        self.assertIn('${SCREEN_READBACK_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${SCREEN_READBACK_PATCH}"', build)
        for script in (package, verify):
            self.assertIn('WineScreenReadbackPatchSHA256', script)
            self.assertIn('WineMacModuleSHA256', script)

    def test_only_desktop_readback_changes(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH).read_text()
        for text in ('NtUserWindowFromDC(dev->hdc) != NtUserGetDesktopWindow()',
                     'GET_NEXT_PHYSDEV(dev, pGetImage)', 'cgrect_mac_from_win',
                     'CGWindowListCreateImage', 'kCGColorSpaceSRGB',
                     'OnMainThread', '@autoreleasepool', 'CGRectIntegral',
                     'CGImageCreateWithImageInRect', 'kCGWindowImageBestResolution',
                     'kCGImageAlphaNoneSkipFirst', 'UINT_MAX / 4',
                     'src->x -= src->visrect.left', 'free_screen_bits'):
            self.assertIn(text, patch)
        for unrelated in ('swGestureTarget', 'sldworks', 'SetWindowRgn', 'WS_EX_LAYERED', 'SetLayeredWindowAttributes'):
            self.assertNotIn(unrelated, patch)

    def test_probe_is_optional_and_checks_background_pixels(self):
        self.assertIn('screen-readback-probe:', (PROJECT / 'Makefile').read_text())
        self.assertNotIn('wine_screen_readback_probe', (PROJECT / 'scripts/package_app.sh').read_text())
        probe = (PROJECT / 'native/wine_screen_readback_probe.c').read_text()
        for text in ('GetDC(NULL)', 'screen BitBlt', 'screen GetPixel',
                     'screen subrect', 'window pixel', '--unaware'):
            self.assertIn(text, probe)


if __name__ == '__main__':
    unittest.main()
