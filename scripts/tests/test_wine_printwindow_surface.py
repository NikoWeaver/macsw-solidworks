"""Offline wiring checks; printwindow-probe provides pixel/message evidence."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = "0011-win32u-printwindow-surface.patch"


class PrintWindowSurfaceTests(unittest.TestCase):
    def test_patch_is_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH, script)
        self.assertIn('${PRINTWINDOW_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${PRINTWINDOW_PATCH}"', build)
        for script in (package, verify):
            self.assertIn('WinePrintWindowPatchSHA256', script)
            self.assertIn('WineInputModuleSHA256', script)

    def test_capture_is_opt_in_and_does_not_hide_scrollbars(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH).read_text()
        additions = '\n'.join(line[1:] for line in patch.splitlines()
                              if line.startswith('+') and not line.startswith('+++'))
        self.assertIn('if (compat_printwindow_surface)', additions)
        self.assertIn('WINE_PRINTWINDOW_SURFACE', additions)
        self.assertIn('flags & PW_CLIENTONLY', additions)
        self.assertIn('NtGdiBitBlt', additions)
        self.assertIn('NtUserReleaseDC', additions)
        for unrelated in ('ShowScrollBar', 'SetScrollInfo', 'SetWindowPos', 'NtUserMessageCall'):
            self.assertNotIn(unrelated, additions)
        registry = (PROJECT / 'macos/Bootstrap/Sources/MacSWCore/Services/RegistryService.swift').read_text()
        self.assertIn('WINE_NOCAPTURERESEND WINE_PRINTWINDOW_SURFACE', registry)

    def test_diagnostic_is_optional_and_checks_pixels(self):
        self.assertIn('printwindow-probe:', (PROJECT / 'Makefile').read_text())
        self.assertNotIn('wine_printwindow_probe', (PROJECT / 'scripts/package_app.sh').read_text())
        probe = (PROJECT / 'native/wine_printwindow_probe.c').read_text()
        for feature in ('--legacy', '--unaware', 'occluded', 'GetPixel', 'WM_PRINTCLIENT', 'WS_VSCROLL'):
            self.assertIn(feature, probe)


if __name__ == '__main__':
    unittest.main()
