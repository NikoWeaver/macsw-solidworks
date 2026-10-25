"""Header-control NULL guard (patch 0019): build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0019-comctl32-header-layout-null.patch"
KEY = "WineHeaderLayoutPatchSHA256"


class HeaderLayoutPatchTests(unittest.TestCase):
    def test_patch_is_applied_after_0018_cached_pinned_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${CROSS_PROCESS_SURFACES_PATCH_SHA256}:${HEADER_LAYOUT_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${HEADER_LAYOUT_PATCH}"', build)
        self.assertLess(build.index('apply "${CROSS_PROCESS_SURFACES_PATCH}"'),
                        build.index('apply "${HEADER_LAYOUT_PATCH}"'))
        # The fix lives in header.c, which the already shipped comctl32_v6 module builds.
        self.assertIn("dlls/comctl32_v6/x86_64-windows/comctl32_v6.dll", build)
        for script in (package, verify):
            self.assertIn(KEY, script)
        self.assertIn("WineComctl32V6ModuleSHA256", package)
        self.assertIn("WineComctl32V6ModuleSHA256", verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if KEY in l)
            self.assertIn("0019-comctl32-header-layout-null.patch", text)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_only_guards_header_layout(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/comctl32/header.c"])
        additions = "\n".join(l[1:] for l in patch.splitlines()
                              if l.startswith("+") and not l.startswith("+++"))
        self.assertIn("HEADER_Layout", patch)
        self.assertIn("if (!lpLayout", additions)
        self.assertIn("return FALSE;", additions)
        self.assertNotIn("SendMessage", additions)


if __name__ == "__main__":
    unittest.main()
