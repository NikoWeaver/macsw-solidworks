"""Own-computer-name resolution (patch 0020): build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0020-ws2_32-resolve-own-computer-name.patch"
KEYS = ("WineComputerNamePatchSHA256", "WineWS2_32ModuleSHA256", "WineWS2_32I386ModuleSHA256")


class ComputerNamePatchTests(unittest.TestCase):
    def test_both_architectures_are_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
            self.assertIn("ws2_32", script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${HEADER_LAYOUT_PATCH_SHA256}:${COMPUTER_NAME_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${COMPUTER_NAME_PATCH}"', build)
        self.assertLess(build.index('apply "${HEADER_LAYOUT_PATCH}"'), build.index('apply "${COMPUTER_NAME_PATCH}"'))
        for target in ("dlls/ws2_32/x86_64-windows/ws2_32.dll", "dlls/ws2_32/i386-windows/ws2_32.dll"):
            self.assertIn(target, build)
        self.assertIn('[ -f "${WS2_32_OUTPUT}" ]', build)
        self.assertIn('[ -f "${WS2_32_I386_OUTPUT}" ]', build)
        self.assertIn("PE32 executable.*Intel 80386", build)
        self.assertIn('${WS2_32_PATCH}" "${WS2_32_TARGET}"', package)
        self.assertIn('${WS2_32_I386_PATCH}" "${WS2_32_I386_TARGET}"', package)
        self.assertIn('wine/lib/wine/x86_64-windows/ws2_32.dll', package)
        self.assertIn('wine/lib/wine/i386-windows/ws2_32.dll', package)
        for key in KEYS:
            self.assertIn(key, package)
            self.assertIn(key, verify)
        self.assertIn('cmp_pe_module ws2_32.dll ', verify)
        self.assertIn('cmp_pe_module ws2_32-i386.dll ', verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if "WineComputerNamePatchSHA256" in l)
            self.assertIn(PATCH_NAME, text)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_only_touches_name_resolution_in_ws2_32(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/ws2_32/protocol.c"])
        additions = "\n".join(l[1:] for l in patch.splitlines()
                              if l.startswith("+") and not l.startswith("+++"))
        for fragment in ("is_local_host_name( name, hostname )", "is_local_host_name( node, fqdn )",
                         "GetComputerNameA", "_stricmp", "do_getaddrinfo( fqdn, service, hints, info )"):
            self.assertIn(fragment, additions)


if __name__ == "__main__":
    unittest.main()
