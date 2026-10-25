"""XMLHTTP send() of DOM document / stream bodies (patch 0021): build, package and verify wiring."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0021-msxml3-xmlhttp-send-domdocument.patch"
KEYS = ("WineMSXMLSendPatchSHA256", "WineMSXML3I386ModuleSHA256")


class MSXMLSendBodyPatchTests(unittest.TestCase):
    def test_both_architectures_are_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
            self.assertIn("msxml3-i386.dll", script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${COMPUTER_NAME_PATCH_SHA256}:${MSXML_SEND_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${MSXML_SEND_PATCH}"', build)
        # 0021 builds on the msxml3 code that 0014 changes.
        self.assertLess(build.index('apply "${MSXML_SCHEMA_PATCH}"'), build.index('apply "${MSXML_SEND_PATCH}"'))
        self.assertLess(build.index('apply "${COMPUTER_NAME_PATCH}"'), build.index('apply "${MSXML_SEND_PATCH}"'))
        for target in ("dlls/msxml3/x86_64-windows/msxml3.dll", "dlls/msxml3/i386-windows/msxml3.dll"):
            self.assertIn(target, build)
        self.assertIn('[ -f "${MSXML3_I386_OUTPUT}" ]', build)
        self.assertIn("PE32 executable.*Intel 80386", build)
        self.assertIn('cp "${MSXML3_I386_PATCH}" "${MSXML3_I386_TARGET}"', package)
        self.assertIn('wine/lib/wine/i386-windows/msxml3.dll', package)
        for key in KEYS:
            self.assertIn(key, package)
            self.assertIn(key, verify)
        self.assertIn('cmp_pe_module msxml3-i386.dll ', verify)
        # The x86-64 module keeps its existing pins.
        self.assertIn("WineMSXML3ModuleSHA256", package)
        self.assertIn("WineMSXML3ModuleSHA256", verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if "WineMSXMLSendPatchSHA256" in l)
            self.assertIn(PATCH_NAME, text)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_sends_documents_and_streams_without_changing_other_bodies(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/msxml3/httprequest.c"])
        additions = "\n".join(l[1:] for l in patch.splitlines()
                              if l.startswith("+") and not l.startswith("+++"))
        for fragment in ("get_body_object_data", "IID_IXMLDOMDocument", "IXMLDOMDocument_save",
                         "IID_ISequentialStream", "case VT_DISPATCH:", "case VT_UNKNOWN:",
                         "E_NOTIMPL", "free_ptr"):
            self.assertIn(fragment, additions)


if __name__ == "__main__":
    unittest.main()
