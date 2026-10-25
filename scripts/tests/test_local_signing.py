"""Local code signatures: ad hoc by default, MACSW_SIGN_IDENTITY / MACSW_SIGN_KEYCHAIN optional
(scripts/lib/codesign.sh and the packaging and verify scripts that use it)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
HELPER = PROJECT / "scripts/lib/codesign.sh"
# Records its arguments; answers -dv / -d -r- with the text in FAKE_DETAILS / FAKE_REQUIREMENT.
FAKE_CODESIGN = """#!/bin/bash
printf '%s\\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "-dv "*) printf '%s\\n' "$FAKE_DETAILS" >&2 ;;
  "-d -r- "*) printf '%s\\n' "$FAKE_REQUIREMENT" ;;
esac
"""
ADHOC = "Executable=/x\nIdentifier=x\nSignature=adhoc\nflags=0x2(adhoc)"
CERTIFICATE = "Executable=/x\nIdentifier=x\nAuthority=MacSW Local Code Signing\nSigned Time=Oct 24, 2026"
CERTIFICATE_REQUIREMENT = 'designated => identifier "x" and certificate leaf = H"616428ae"'
CDHASH_REQUIREMENT = 'designated => cdhash H"0123abcd"'


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        fake = self.directory / "bin/codesign"
        fake.parent.mkdir()
        fake.write_text(FAKE_CODESIGN)
        fake.chmod(0o755)
        self.log = self.directory / "codesign.log"

    def run_helper(self, command, details=ADHOC, requirement=CDHASH_REQUIREMENT, **settings):
        environment = {"PATH": f"{self.directory / 'bin'}:/usr/bin:/bin", "FAKE_LOG": str(self.log),
                       "FAKE_DETAILS": details, "FAKE_REQUIREMENT": requirement}
        environment.update(settings)
        return subprocess.run(["/bin/bash", "-c", f'source "{HELPER}"; {command}'], env=environment,
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_unset_identity_signs_ad_hoc(self):
        result = self.run_helper('macsw_codesign "/tmp/A B.app"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["--force --sign - /tmp/A B.app"])
        result = self.run_helper('macsw_codesign /tmp/C.app', MACSW_SIGN_IDENTITY="")
        self.assertEqual(self.calls()[-1], "--force --sign - /tmp/C.app", "empty means unset")

    def test_identity_and_keychain_are_passed_to_codesign(self):
        result = self.run_helper('macsw_codesign /tmp/A.app', MACSW_SIGN_IDENTITY="MacSW Local Code Signing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["--force --sign MacSW Local Code Signing /tmp/A.app"])
        result = self.run_helper('macsw_codesign /tmp/A.app', MACSW_SIGN_IDENTITY="MacSW Local Code Signing",
                                 MACSW_SIGN_KEYCHAIN="/Users/me/Library/Keychains/k.keychain-db")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[-1], "--force --sign MacSW Local Code Signing "
                         "--keychain /Users/me/Library/Keychains/k.keychain-db /tmp/A.app")

    def test_keychain_without_identity_fails_before_signing(self):
        result = self.run_helper('macsw_codesign /tmp/A.app', MACSW_SIGN_KEYCHAIN="/tmp/k.keychain-db")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MACSW_SIGN_IDENTITY", result.stderr)
        self.assertEqual(self.calls(), [], "no ad hoc signature when a keychain was asked for")

    def test_signature_kind_accepts_both_and_the_identity_setting_decides(self):
        adhoc = self.run_helper("macsw_signature_kind /tmp/A.app")
        self.assertEqual((adhoc.returncode, adhoc.stdout.strip()), (0, "adhoc"))
        certificate = self.run_helper("macsw_signature_kind /tmp/A.app", details=CERTIFICATE,
                                      requirement=CERTIFICATE_REQUIREMENT)
        self.assertEqual((certificate.returncode, certificate.stdout.strip()), (0, "certificate"))
        unset_check = self.run_helper("macsw_signature_kind /tmp/A.app", details=CERTIFICATE,
                                      requirement=CERTIFICATE_REQUIREMENT, MACSW_SIGN_IDENTITY="X")
        self.assertEqual(unset_check.stdout.strip(), "certificate")
        refused = self.run_helper("macsw_signature_kind /tmp/A.app", MACSW_SIGN_IDENTITY="X")
        self.assertNotEqual(refused.returncode, 0, "ad hoc although the identity was asked for")
        neither = self.run_helper("macsw_signature_kind /tmp/A.app", details=CERTIFICATE,
                                  requirement=CDHASH_REQUIREMENT)
        self.assertNotEqual(neither.returncode, 0)

    def test_real_ad_hoc_signature_is_recognised(self):
        target = self.directory / "tool"
        shutil.copyfile("/usr/bin/true", target)
        target.chmod(0o755)
        environment = {"PATH": "/usr/bin:/bin"}
        script = f'source "{HELPER}"; macsw_codesign "{target}" 2>/dev/null && macsw_signature_kind "{target}"'
        result = subprocess.run(["/bin/bash", "-c", script], env=environment, capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "adhoc"), result.stderr)


class ScriptTests(unittest.TestCase):
    PACKAGE = (PROJECT / "scripts/package_app.sh").read_text()

    def test_scripts_use_the_helper(self):
        for name in ("package_app.sh", "package_solidworks_app.sh", "verify_app.sh", "verify_solidworks_app.sh"):
            self.assertIn('source "${WORKSPACE_ROOT}/scripts/lib/codesign.sh"',
                          (PROJECT / "scripts" / name).read_text(), name)
        self.assertIn('macsw_codesign "${APP_DIR}"', (PROJECT / "scripts/package_solidworks_app.sh").read_text())

    def test_wine_modules_stay_ad_hoc_because_their_hashes_are_the_runtime_identity(self):
        for target in ("WINEMAC_TARGET", "WIN32U_TARGET", "NTDLL_TARGET", "BRANDED_WINE_LOADER", "WINESERVER_TARGET"):
            self.assertIn(f'codesign --force --sign - "${{{target}}}"', self.PACKAGE)
            self.assertNotIn(f'macsw_codesign "${{{target}}}"', self.PACKAGE)

    def test_bundle_gets_the_identity_only_when_one_is_set_and_after_the_manifest(self):
        block = self.PACKAGE.split('if [ -n "${MACSW_SIGN_IDENTITY:-}" ]; then', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn('macsw_codesign "${NESTED_CODE}"', block)
        self.assertIn('macsw_codesign "${APP_DIR}"', block)
        self.assertIn('= certificate', block)
        lines = self.PACKAGE.splitlines()
        sealed = lines.index('    macsw_codesign "${APP_DIR}"')
        last_write = max(i for i, line in enumerate(lines) if '"${BUILD_MANIFEST}"' in line)
        moved = lines.index('mv "${APP_DIR}" "${FINAL_APP_DIR}"')
        self.assertLess(last_write, sealed)
        self.assertLess(sealed, moved)


if __name__ == "__main__":
    unittest.main()
