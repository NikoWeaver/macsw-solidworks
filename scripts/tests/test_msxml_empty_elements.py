"""Empty elements serialise as <tag></tag> (patch 0022): build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0022-msxml3-expand-empty-elements.patch"
KEY = "WineMSXMLEmptyElementPatchSHA256"


class MSXMLEmptyElementPatchTests(unittest.TestCase):
    def test_patch_is_applied_after_0021_cached_pinned_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${MSXML_SEND_PATCH_SHA256}:${MSXML_EMPTY_ELEMENT_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${MSXML_EMPTY_ELEMENT_PATCH}"', build)
        self.assertLess(build.index('apply "${MSXML_SEND_PATCH}"'),
                        build.index('apply "${MSXML_EMPTY_ELEMENT_PATCH}"'))
        # The fix is in msxml3's node.c: both shipped msxml3 builds contain it.
        self.assertIn("dlls/msxml3/x86_64-windows/msxml3.dll", build)
        self.assertIn("dlls/msxml3/i386-windows/msxml3.dll", build)
        for script in (package, verify):
            self.assertIn(KEY, script)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if KEY in l)
            self.assertIn(PATCH_NAME, text)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_expands_empty_elements_in_node_dump_only(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/msxml3/node.c"])
        removals = [l[1:] for l in patch.splitlines() if l.startswith("-") and not l.startswith("---")]
        additions = [l[1:] for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++")]
        self.assertEqual([l.strip() for l in removals], ['node_dump_append(context, L"/>", 2);'])
        code = "\n".join(l for l in additions if not l.lstrip().startswith(("/*", "*")))
        self.assertIn('node_dump_append(context, L"</", 2);', code)
        self.assertIn("node_dump_qualified_name(context, node);", code)
        self.assertNotIn('L"/>"', code)


if __name__ == "__main__":
    unittest.main()
