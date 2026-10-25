"""WMI IPEnabled needs a MAC address (patch 0028): build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0028-wbemprox-ipenabled-needs-mac-address.patch"
KEYS = ("WineWbemproxIPEnabledPatchSHA256", "WineWbemproxModuleSHA256", "WineWbemproxI386ModuleSHA256")


class WbemproxIPEnabledPatchTests(unittest.TestCase):
    def test_both_architectures_are_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
            self.assertIn("wbemprox", script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        # Apply order: 0001-0022, 0023, 0024, 0025, then 0028.
        self.assertIn("${APP_BUNDLE_HOST_PATCH_SHA256}:${WBEMPROX_IPENABLED_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${WBEMPROX_IPENABLED_PATCH}"', build)
        self.assertLess(build.index('apply "${MSXML_EMPTY_ELEMENT_PATCH}"'),
                        build.index('apply "${WBEMPROX_IPENABLED_PATCH}"'))
        self.assertLess(build.index('apply "${APP_BUNDLE_HOST_PATCH}"'),
                        build.index('apply "${WBEMPROX_IPENABLED_PATCH}"'))
        for target in ("dlls/wbemprox/x86_64-windows/wbemprox.dll", "dlls/wbemprox/i386-windows/wbemprox.dll"):
            self.assertIn(target, build)
        self.assertIn('[ -f "${WBEMPROX_OUTPUT}" ]', build)
        self.assertIn('[ -f "${WBEMPROX_I386_OUTPUT}" ]', build)
        self.assertIn('file "${WBEMPROX_I386_OUTPUT}.new" | grep -q \'PE32 executable.*Intel 80386\'', build)
        self.assertIn('${WBEMPROX_PATCH}" "${WBEMPROX_TARGET}"', package)
        self.assertIn('${WBEMPROX_I386_PATCH}" "${WBEMPROX_I386_TARGET}"', package)
        self.assertIn('wine/lib/wine/x86_64-windows/wbemprox.dll', package)
        self.assertIn('wine/lib/wine/i386-windows/wbemprox.dll', package)
        for key in KEYS:
            self.assertIn(key, package)
            self.assertIn(key, verify)
        self.assertIn('cmp_pe_module wbemprox.dll ', verify)
        self.assertIn('cmp_pe_module wbemprox-i386.dll ', verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if "WineWbemproxIPEnabledPatchSHA256" in l)
            self.assertIn(PATCH_NAME, text)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_only_derives_ipenabled_from_the_mac_address(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/wbemprox/builtin.c"])
        removals = [l[1:].strip() for l in patch.splitlines() if l.startswith("-") and not l.startswith("---")]
        additions = [l[1:].strip() for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++")]
        self.assertEqual(removals, ["rec->ipenabled            = -1;"])
        code = [l for l in additions if not l.startswith(("/*", "*"))]
        self.assertEqual(code, ["rec->ipenabled            = rec->mac_address ? -1 : 0;"])
        # The MAC address is computed before IPEnabled reads it, in the same record.
        context = [l[1:] for l in patch.splitlines() if l.startswith(" ")]
        self.assertTrue(any("rec->mac_address          = get_mac_address(" in l for l in context))
        text = patch.split("rec->mac_address          = get_mac_address(", 1)[1]
        self.assertIn("rec->ipenabled            = rec->mac_address ? -1 : 0;", text)


if __name__ == "__main__":
    unittest.main()
