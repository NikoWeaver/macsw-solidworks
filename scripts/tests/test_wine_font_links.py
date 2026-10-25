"""Offline patch/build wiring. Disposable-prefix fontlink-probe tests behavior."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = "0012-win32u-preserve-custom-font-links.patch"


class FontLinkPatchTests(unittest.TestCase):
    def test_patch_is_built_cached_and_verified(self):
        build = (PROJECT / 'scripts/build_winemac.sh').read_text()
        package = (PROJECT / 'scripts/package_app.sh').read_text()
        verify = (PROJECT / 'scripts/verify_app.sh').read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH, script)
        self.assertIn('${FONTLINK_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${FONTLINK_PATCH}"', build)
        for script in (package, verify):
            self.assertIn('WineFontLinkPatchSHA256', script)
            self.assertIn('WineInputModuleSHA256', script)

    def test_only_missing_or_known_default_values_are_replaced(self):
        patch = (PROJECT / 'patches/wine-crossover' / PATCH).read_text()
        self.assertIn('STATUS_OBJECT_NAME_NOT_FOUND) return FALSE', patch)
        self.assertIn('if (!(info = malloc( size ))) return TRUE', patch)
        self.assertIn('info->Type != REG_MULTI_SZ', patch)
        self.assertIn('info->DataLength != len * sizeof(WCHAR)', patch)
        self.assertIn('if (preserve_custom_font_link( hkey, link_reg )) continue', patch)
        for locale in ('non_cjk', 'sc', 'tc', 'jp', 'kr'):
            self.assertIn(f'link->link_{locale}, link->link_{locale}_len', patch)
        for unrelated in ('PingFang', 'Tahoma', 'sldworks', 'update_codepage(', 'FontSubstitutes', 'REG_DWORD'):
            self.assertNotIn(unrelated, patch)
        self.assertNotIn('\n-', patch.split('+++', 1)[1])

    def test_probe_is_optional_and_warns_about_registry_fixtures(self):
        probe = (PROJECT / 'native/wine_fontlink_probe.c').read_text()
        self.assertIn('disposable', probe)
        for fixture in ('setup-custom', 'verify-custom', 'setup-default', 'verify-default', 'memcmp', 'large_entry'):
            self.assertIn(fixture, probe)
        self.assertIn('fontlink-probe:', (PROJECT / 'Makefile').read_text())
        self.assertNotIn('wine_fontlink_probe', (PROJECT / 'scripts/package_app.sh').read_text())


if __name__ == '__main__':
    unittest.main()
