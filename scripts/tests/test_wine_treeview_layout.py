"""Offline build/patch contract. Native and Wine drawing use treeview-probe."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0010-comctl32-treeview-image-spacing.patch"


class TreeViewLayoutTests(unittest.TestCase):
    def test_v6_module_is_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        self.assertIn('${TREEVIEW_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${TREEVIEW_PATCH}"', build)
        self.assertIn('dlls/comctl32_v6/x86_64-windows/comctl32_v6.dll', build)
        self.assertIn('[ -f "${COMCTL32_V6_OUTPUT}" ]', build)
        self.assertIn('cp "${COMCTL32_V6_PATCH}" "${COMCTL32_V6_TARGET}"', package)
        for key in ("WineTreeViewPatchSHA256", "WineComctl32V6ModuleSHA256"):
            self.assertIn(key, package)
            self.assertIn(key, verify)
        self.assertIn('cmp_pe_module comctl32_v6.dll ', verify)
        self.assertIn("file \"${COMCTL32_V6_MODULE}\" | grep -q 'PE32+ executable.*x86-64'", verify)
        # Deliberately leave v5 and 32-bit modules at their pinned upstream versions.
        self.assertNotIn('dlls/comctl32/x86_64-windows/comctl32.dll', build)
        self.assertNotIn('dlls/comctl32_v6/i386-windows/comctl32_v6.dll', build)

    def test_spacing_changes_metrics_not_application_window_or_registry(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        additions = '\n'.join(line[1:] for line in patch.splitlines()
                              if line.startswith('+') and not line.startswith('+++'))
        self.assertIn('#define TREEVIEW_IMAGE_PADDING 3', additions)
        self.assertIn('#if __WINE_COMCTL32_VERSION == 6', additions)
        self.assertIn('item->stateOffset += TREEVIEW_IMAGE_PADDING', additions)
        self.assertIn('if (infoPtr->normalImageWidth) item->textOffset += TREEVIEW_IMAGE_PADDING', additions)
        self.assertIn('infoPtr->uIndent = infoPtr->normalImageWidth + TREEVIEW_IMAGE_PADDING', additions)
        for unrelated in ('SetWindowPos', 'RegSet', 'TVS_HASBUTTONS', 'SLDWORKS', 'WM_PAINT'):
            self.assertNotIn(unrelated, additions)

    def test_probe_explicitly_activates_v6_and_is_optional(self):
        manifest = (PROJECT / "native/wine_treeview_probe.manifest").read_text()
        self.assertIn('Microsoft.Windows.Common-Controls', manifest)
        self.assertIn('version="6.0.0.0"', manifest)
        self.assertIn('processorArchitecture="amd64"', manifest)
        self.assertIn('treeview-probe:', (PROJECT / "Makefile").read_text())
        self.assertNotIn('wine_treeview_probe', (PROJECT / "scripts/package_app.sh").read_text())

    def test_isolated_app_output_is_verified_instead_of_running_app(self):
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertIn('APP_DIR="${1:-${MACSW_APP_OUTPUT:-', verify)


if __name__ == '__main__':
    unittest.main()
