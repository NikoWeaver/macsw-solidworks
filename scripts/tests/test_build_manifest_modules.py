"""BuildManifest integrity: wineserver hash, and every declared module hash is checked (audit finding 10)."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import re
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("wine_runtime", PROJECT / "scripts/swcli/wine_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)
sys.path.insert(0, str(PROJECT / "scripts"))
import sign_app  # noqa: E402

PACKAGE = (PROJECT / "scripts/package_app.sh").read_text()
VERIFY = (PROJECT / "scripts/verify_app.sh").read_text()
HASH_KEY = re.compile(r"Add :(\w*(?:ModuleSHA256|LoaderSHA256|ServerSHA256)) string")


class ManifestScriptTests(unittest.TestCase):
    def test_wineserver_is_hashed_after_it_is_signed(self):
        self.assertIn('Add :WineServerSHA256 string ${WINESERVER_SHA256}', PACKAGE)
        lines = PACKAGE.splitlines()
        signed = max(i for i, l in enumerate(lines) if '"${WINESERVER_TARGET}"' in l and "sign" in l)
        hashed = next(i for i, l in enumerate(lines) if l.startswith("WINESERVER_SHA256="))
        self.assertLess(signed, hashed)
        self.assertIn('shasum -a 256 "${WINESERVER_TARGET}"', lines[hashed])

    def test_verify_checks_every_module_key_that_package_declares(self):
        declared = set(HASH_KEY.findall(PACKAGE))
        self.assertGreaterEqual(declared, {
            "WineServerSHA256", "WineLoaderSHA256", "WineWS2_32ModuleSHA256", "WineWS2_32I386ModuleSHA256",
            "WineMSXML3I386ModuleSHA256", "WineWbemproxModuleSHA256", "WineWbemproxI386ModuleSHA256",
            "WineComdlg32ModuleSHA256", "WineComdlg32I386ModuleSHA256", "WineMacDrvModuleSHA256",
            "WineMacDrvI386ModuleSHA256"})
        table = VERIFY.split('MANIFEST_MODULES="', 1)[1].split('"\n', 1)[0]
        checked = {line.split("|", 1)[0] for line in table.splitlines() if "|" in line}
        self.assertEqual(declared, checked)
        # The run-time loop also rejects a manifest key that the table lacks.
        self.assertIn("which verify_app.sh does not check", VERIFY)
        self.assertIn("BuildManifest does not declare ${MODULE_KEY}", VERIFY)


class DeclaredModuleVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-manifest-")
        self.addCleanup(self.temporary.cleanup)
        self.contents = Path(self.temporary.name) / "MacSW.app/Contents"
        self.values = {"WineVersion": "11.16", "MonoVersion": "11.3.0"}
        for key, relative in {**RUNTIME.MODULES, **RUNTIME.DECLARED_MODULES}.items():
            self.write(key, relative, b"fixture-" + key.encode())
        (self.contents / "Resources").mkdir(parents=True)
        with (self.contents / "Resources/BuildManifest.plist").open("wb") as stream:
            plistlib.dump(self.values, stream)

    def write(self, key, relative, data):
        path = self.contents / "Frameworks/wine" / relative.format(**self.values)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.values[key] = hashlib.sha256(data).hexdigest()

    def test_every_declared_module_is_verified(self):
        values = RUNTIME.identity(self.contents)
        RUNTIME.verify_app(self.contents, values)
        for key, relative in RUNTIME.DECLARED_MODULES.items():
            with self.subTest(key=key):
                path = self.contents / "Frameworks/wine" / relative
                good = path.read_bytes()
                path.write_bytes(b"tampered")
                with self.assertRaisesRegex(RuntimeError, key):
                    RUNTIME.verify_app(self.contents, values)
                path.write_bytes(good)

    def test_older_manifests_without_the_new_keys_still_verify(self):
        values = {key: value for key, value in RUNTIME.identity(self.contents).items()
                  if key not in RUNTIME.DECLARED_MODULES}
        (self.contents / "Frameworks/wine" / RUNTIME.DECLARED_MODULES["WineServerSHA256"]).write_bytes(b"other")
        RUNTIME.verify_app(self.contents, values)

    def test_developer_id_signing_refreshes_the_wineserver_hash(self):
        app = self.contents.parent
        (self.contents / "Frameworks/wine/bin/wineserver").write_bytes(b"re-signed wineserver")
        sign_app.refresh_signed_hashes(app)
        values = plistlib.loads((self.contents / "Resources/BuildManifest.plist").read_bytes())
        self.assertEqual(values["WineServerSHA256"], hashlib.sha256(b"re-signed wineserver").hexdigest())
        self.assertIn("WineServerSHA256", sign_app.DECLARED_SIGNED_MODULES)


if __name__ == "__main__":
    unittest.main()
