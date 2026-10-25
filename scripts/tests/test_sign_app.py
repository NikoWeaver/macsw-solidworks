"""Offline signing policy/provenance tests; no keys or Apple service needed."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, PROJECT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load("macsw_signing", "scripts/sign_app.py")
source = load("macsw_signing_input", "scripts/ci/signing-input.py")
notary = load("macsw_notary", "scripts/ci/notarize-app.py")


def thin(kind, *, endian="<", wide=True):
    magic = 0xFEEDFACF if wide else 0xFEEDFACE
    return struct.pack(endian + "IIIIIIII", magic, 0, 0, kind, 0, 0, 0, 0)


class SigningInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "MacSW.app"
        self.app.mkdir()
        for relative in signing.EXECUTABLES:
            self.file(relative, thin(2))
        (self.app / "Contents/Frameworks").mkdir()
        (self.app / signing.WINE_ALIAS).symlink_to("../Resources/Wine")

    def file(self, relative, data):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_actual_headers_not_extensions_and_order(self):
        module = signing.WINE_ROOT + "/lib/wine/x86_64-unix/winemac.so"
        self.file(module, thin(6))
        self.file("Contents/Resources/sw-cli", b"#!/bin/sh\n")
        (self.app / "Contents/MacOS/sw-cli").symlink_to("../Resources/sw-cli")
        self.file(signing.WINE_ROOT + "/lib/native-looking.dll", b"MZPE")
        entries = signing.inventory(self.app)
        self.assertEqual(entries[0]["path"], module)
        self.assertEqual(len(entries), len(signing.EXECUTABLES) + 1)
        self.assertEqual(sum(item["policy"] == "wine" for item in entries), 2)

    def test_non_macho_in_macos_directory_is_rejected_before_signing(self):
        for name, data in (("sw-cli", b"#!/bin/sh\n"), ("data.txt", b"data"), ("helper.exe", b"MZPE")):
            with self.subTest(name=name):
                path = self.file("Contents/MacOS/" + name, data)
                with self.assertRaisesRegex(RuntimeError, "move it to Resources"), \
                        patch.object(signing, "command") as command:
                    signing.sign(self.app, "Developer ID Application: Fixture", "ABCDEFGHIJ",
                                 Path("private"), PROJECT / "resources/signing")
                command.assert_not_called()
                path.unlink()

    def test_universal_32_and_64_endian_headers(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                magic = 0xCAFEBABF if wide else 0xCAFEBABE
                fmt = "IIQQII" if wide else "IIIII"
                offset = 40 if wide else 28
                data = struct.pack(endian + "II", magic, 1)
                data += struct.pack(endian + fmt, *([0, 0, offset, 32, 0, 0] if wide
                                                    else [0, 0, offset, 32, 0]))
                data += thin(2, endian=endian)
                path = self.file("universal", data)
                self.assertEqual(signing.macho_type(path), 2)

    def test_universal_inconsistent_slices_are_rejected(self):
        data = struct.pack(">II", 0xCAFEBABE, 2)
        data += struct.pack(">IIIII", 0, 0, 48, 32, 0)
        data += struct.pack(">IIIII", 0, 0, 80, 32, 0)
        path = self.file("universal", data + thin(2) + thin(6))
        with self.assertRaisesRegex(RuntimeError, "different file types"):
            signing.macho_type(path)

    def test_bad_macho_headers_fail_closed(self):
        for data in (b"\xcf\xfa\xed\xfe", struct.pack(">II", 0xCAFEBABE, 30),
                     struct.pack(">II", 0xCAFEBABE, 1),
                     struct.pack(">IIIIIII", 0xCAFEBABE, 1, 0, 0, 3, 32, 0) + thin(6)):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                signing.macho_type(self.file("broken", data))

    def test_internal_alias_not_signed_twice(self):
        path = self.app / "Contents/Frameworks/wine/bin/wineloader"
        path.symlink_to("wine")
        self.assertEqual(len(signing.inventory(self.app)), len(signing.EXECUTABLES))

    def test_wine_resource_tree_is_inventoried_once_including_unknown_native_code(self):
        module = self.file(signing.WINE_ROOT + "/lib/probe.so", thin(6))
        entries = signing.inventory(self.app)
        self.assertEqual(len(entries), len(signing.EXECUTABLES) + 1)
        self.assertTrue(any(item["path"] == module.relative_to(self.app).as_posix() for item in entries))
        self.assertFalse(any(item["path"].startswith(signing.WINE_ALIAS + "/") for item in entries))
        unknown = self.file(signing.WINE_ROOT + "/share/hidden-native", thin(2))
        with self.assertRaisesRegex(RuntimeError, "Unreviewed native"):
            signing.inventory(self.app)
        unknown.unlink()
        (self.app / "Contents/Frameworks/data.d").mkdir()
        with self.assertRaisesRegex(RuntimeError, "Dotted data directory"):
            signing.inventory(self.app)

    def test_missing_or_unreviewed_wine_alias_fails_before_credentials(self):
        alias = self.app / signing.WINE_ALIAS
        alias.unlink()
        for target in (None, "../Resources", str(self.app / signing.WINE_ROOT)):
            with self.subTest(target=target):
                if target is not None:
                    alias.symlink_to(target)
                with self.assertRaisesRegex(RuntimeError, "compatibility alias"):
                    signing.inventory(self.app)
                if alias.is_symlink():
                    alias.unlink()

    def test_external_absolute_and_broken_links_rejected(self):
        link = self.app / "bad-link"
        for target in ("../external", "missing", str(self.app / "Contents/MacOS/MacSW")):
            link.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, "bundle link"):
                signing.inventory(self.app)
            link.unlink()

    def test_unknown_code_or_nested_bundle_requires_review(self):
        for relative, kind in (("Contents/MacOS/new-helper", 2),
                               ("Contents/Resources/hidden.bin", 6),
                               ("Contents/Frameworks/wine/lib/object.o", 1)):
            path = self.file(relative, thin(kind))
            with self.assertRaisesRegex(RuntimeError, "Unreviewed"):
                signing.inventory(self.app)
            path.unlink()
        (self.app / "Contents/Frameworks/Unexpected.framework").mkdir()
        with self.assertRaisesRegex(RuntimeError, "Nested code bundle"):
            signing.inventory(self.app)

    def test_embedded_solidworks_app_fails_closed_until_it_has_a_policy(self):
        # Code in a zip is sealed as data: Developer ID would ship it ad hoc and not notarized.
        path = self.file("Contents/Resources/SOLIDWORKS.app.zip", b"PK\x03\x04")
        with self.assertRaisesRegex(RuntimeError, "Embedded app needs a signing policy"):
            signing.inventory(self.app)
        path.unlink()
        signing.inventory(self.app)

    def test_required_executable_missing(self):
        (self.app / "Contents/MacOS/7zz").unlink()
        with self.assertRaisesRegex(RuntimeError, "Required native"):
            signing.inventory(self.app)

    def test_entitlement_files_exact_and_no_blanket_exceptions(self):
        for policy, expected in signing.ENTITLEMENTS.items():
            self.assertEqual(plistlib.loads((PROJECT / "resources/signing" / (policy + ".plist")).read_bytes()),
                             expected)
        self.assertEqual(signing.ENTITLEMENTS["default"], {})
        for forbidden in ("com.apple.security.cs.disable-library-validation",
                          "com.apple.security.get-task-allow", "com.apple.security.app-sandbox",
                          "com.apple.security.cs.allow-dyld-environment-variables"):
            self.assertFalse(any(forbidden in policy for policy in signing.ENTITLEMENTS.values()))

    def manifest(self):
        values = {"MonoVersion": "11.3.0", "WineVersion": "fixture", "SourceSHA256": "keep"}
        for key, relative in signing.wine_runtime.MODULES.items():
            values[key] = "old"
            self.file("Contents/Frameworks/wine/" + relative.format(**values), b"fixture")
        path = self.app / "Contents/Resources/BuildManifest.plist"
        self.file(str(path.relative_to(self.app)), plistlib.dumps(values))
        return path, values

    def test_rehash_only_four_signed_modules_not_pe_or_mono(self):
        path, old = self.manifest()
        signing.refresh_signed_hashes(self.app)
        new = plistlib.loads(path.read_bytes())
        self.assertEqual({key for key in old if old[key] != new[key]}, set(signing.SIGNED_MODULES))
        for key in signing.SIGNED_MODULES:
            self.assertEqual(new[key], signing.digest(self.app / "Contents/Frameworks/wine" /
                                                     signing.wine_runtime.MODULES[key]))

    def test_payload_reads_swcli_manifest_only_when_swcli_is_packaged(self):
        with patch.object(signing.wine_runtime, "identity"), patch.object(signing.wine_runtime, "verify_app"), \
                patch.object(signing.swcli_runtime, "read_manifest") as read:
            signing.verify_payload(self.app)
            read.assert_not_called()
            self.file("Contents/Resources/SWCLI/runtime-manifest.json", b"{}")
            signing.verify_payload(self.app)
            read.assert_called_once_with(self.app / "Contents/Resources/SWCLI")

    def test_verification_checks_each_resource_macho_before_outer_app(self):
        self.file(signing.WINE_ROOT + "/lib/probe.so", thin(6))
        entries = signing.inventory(self.app)
        with patch.object(signing, "verify_payload"), patch.object(signing, "verify_signature") as verify:
            self.assertEqual(signing.verify(self.app, "ABCDEFGHIJ"), entries)
        self.assertEqual(verify.call_count, len(entries))
        checked = {call.args[0] for call in verify.call_args_list[:-1]}
        self.assertEqual(checked, {self.app / item["path"] for item in entries if item["policy"] != "app"})
        verify.assert_called_with(self.app, "app", "ABCDEFGHIJ", outer=True)

    def test_sign_order_no_deep_and_payload_checked_before_rehash(self):
        calls = []
        entries = signing.inventory(self.app)
        with patch.object(signing, "command", side_effect=lambda command: calls.append(command) or b""), \
                patch.object(signing, "verify_payload", side_effect=lambda _: calls.append(["payload"])), \
                patch.object(signing, "refresh_signed_hashes", side_effect=lambda _: calls.append(["rehash"])), \
                patch.object(signing, "verify"), contextlib.redirect_stdout(io.StringIO()):
            signing.sign(self.app, "Developer ID Application: Fixture (ABCDEFGHIJ)", "ABCDEFGHIJ",
                         Path("fixture.keychain-db"), PROJECT / "resources/signing")
        self.assertEqual(calls[0], ["payload"])
        self.assertEqual(calls[-3:-1], [["rehash"], ["payload"]])
        self.assertEqual(calls[-1][-1], self.app)
        sign_calls = [call for call in calls if call[0] == "/usr/bin/codesign"]
        self.assertEqual(len(sign_calls), len(entries))
        for call in sign_calls:
            self.assertNotIn("--deep", call)
            self.assertIn("--timestamp", call)
            self.assertIn("runtime", call)

    def test_developer_id_not_adhoc_and_team_required(self):
        for identity, team in (("-", "ABCDEFGHIJ"), ("Apple Development: Fixture", "ABCDEFGHIJ"),
                               ("Developer ID Application: Fixture", "bad")):
            with self.assertRaises(RuntimeError):
                signing.sign(self.app, identity, team, Path("unused"), PROJECT / "resources/signing")

    def test_resolved_certificate_fingerprint_is_used_without_relaxing_policy(self):
        calls = []
        with patch.object(signing, "command", side_effect=lambda args: calls.append(args) or b""), \
                patch.object(signing, "verify_payload"), patch.object(signing, "refresh_signed_hashes"), \
                patch.object(signing, "verify") as verify, contextlib.redirect_stdout(io.StringIO()):
            signing.sign(self.app, "Developer ID Application: Fixture", "ABCDEFGHIJ", Path("private.keychain-db"),
                         PROJECT / "resources/signing", identity_sha1="a" * 40)
        for args in calls:
            self.assertEqual(args[args.index("--sign") + 1], "a" * 40)
            self.assertIn("--timestamp", args)
            self.assertIn("runtime", args)
            self.assertNotIn("--deep", args)
        verify.assert_called_once_with(self.app, "ABCDEFGHIJ")
        with patch.object(signing, "command") as command:
            with self.assertRaisesRegex(RuntimeError, "fingerprint"):
                signing.sign(self.app, "Developer ID Application: Fixture", "ABCDEFGHIJ", Path("private"),
                             PROJECT / "resources/signing", identity_sha1="not-a-certificate")
            command.assert_not_called()

    def test_signature_checks_team_developer_id_timestamp_runtime(self):
        good = b"Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 11\nCodeDirectory v=20500 flags=0x10000(runtime)\n"
        signing.validate_details(good, "ABCDEFGHIJ")
        for missing in (b"Authority=Developer ID Application: Fixture\n", b"TeamIdentifier=ABCDEFGHIJ\n",
                        b"Timestamp=Oct 11\n", b"CodeDirectory v=20500 flags=0x10000(runtime)\n"):
            with self.assertRaises(RuntimeError):
                signing.validate_details(good.replace(missing, b""), "ABCDEFGHIJ")

    def test_entitlements_mismatch_rejected(self):
        good = b"Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 11\nCodeDirectory flags=0x10000(runtime)\n"
        with patch.object(signing, "command", side_effect=[b"", good, plistlib.dumps({"unexpected": True})]):
            with self.assertRaisesRegex(RuntimeError, "Unexpected entitlements"):
                signing.verify_signature(self.app, "app", "ABCDEFGHIJ")


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS codesign and ditto")
class NativeBundleLayoutTests(unittest.TestCase):
    def test_mixed_wine_resource_tree_signatures_and_alias_survive_zip_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="macsw Wine layout ") as temporary:
            root = Path(temporary)
            app = root / "Probe.app"
            contents = app / "Contents"
            (contents / "Resources").mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "MacSW", "CFBundleIdentifier": "org.macsw.wine-layout-probe",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}))
            executable = root / "probe"
            subprocess.run(["xcrun", "clang", str(PROJECT / "native/signing_probe.c"), "-o", str(executable)],
                           check=True, capture_output=True, timeout=60)
            legacy = app / signing.WINE_ALIAS
            targets = []
            for relative, policy in signing.EXECUTABLES.items():
                path = app / relative.replace(signing.WINE_ROOT, signing.WINE_ALIAS)
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(executable, path)
                path.chmod(0o755)
                if policy != "app":
                    targets.append((path, policy))
            library = legacy / "lib/probe.dylib"
            subprocess.run(["xcrun", "clang", "-dynamiclib", str(PROJECT / "native/signing_probe.c"),
                            "-o", str(library)], check=True, capture_output=True, timeout=60)
            targets.append((library, "default"))
            for relative in ("lib/wine/x86_64-unix/vulkan/icd.d/MoltenVK_icd.json",
                             "share/wine/mono/wine-mono-11.3.0/lib/mono/4.5/mscorlib.dll",
                             "share/wine/gecko/wine-gecko-2.47.4-x86_64/data"):
                path = legacy / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture-data")
            for path, policy in targets:
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
                                "--entitlements", str(PROJECT / "resources/signing" / (policy + ".plist")),
                                str(path)], check=True, capture_output=True, timeout=60)
            command = ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(app)]
            rejected = subprocess.run(command, capture_output=True, timeout=60)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"bundle format unrecognized", rejected.stderr)
            legacy.rename(app / signing.WINE_ROOT)
            legacy.symlink_to("../Resources/Wine")
            entries = signing.inventory(app)
            self.assertEqual(len(entries), len(signing.EXECUTABLES) + 1)
            self.assertEqual(sum(item["policy"] == "wine" for item in entries), 2)
            subprocess.run(command, check=True, capture_output=True, timeout=60)
            archive = root / "Probe.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(app), str(archive)], check=True, capture_output=True, timeout=60)
            restored = root / "restored"
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(restored)],
                           check=True, capture_output=True, timeout=60)
            restored_app = restored / app.name
            self.assertEqual(os.readlink(restored_app / signing.WINE_ALIAS), "../Resources/Wine")
            self.assertEqual(signing.inventory(restored_app), entries)
            # --deep alone does not cover the Mach-O files inside Resources.
            for item in entries:
                if item["policy"] != "app":
                    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(restored_app / item["path"])],
                                   check=True, capture_output=True, timeout=60)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(restored_app)],
                           check=True, capture_output=True, timeout=60)
            changed = restored_app / signing.WINE_ROOT / "share/wine/gecko/wine-gecko-2.47.4-x86_64/data"
            changed.write_bytes(b"tampered")
            rejected = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(restored_app)],
                                      capture_output=True, timeout=60)
            self.assertNotEqual(rejected.returncode, 0)

    def test_resource_script_alias_survives_signing_and_zip_round_trip(self):
        with tempfile.TemporaryDirectory(prefix="macsw signing layout ") as temporary:
            root = Path(temporary)
            app = root / "Probe.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources").mkdir()
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "MacSW", "CFBundleIdentifier": "org.macsw.signing-layout-probe",
                "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}))
            subprocess.run(["xcrun", "clang", str(PROJECT / "native/signing_probe.c"),
                            "-o", str(contents / "MacOS/MacSW")], check=True, capture_output=True, timeout=60)
            launcher = contents / "MacOS/sw-cli"
            launcher.write_bytes((PROJECT / "scripts/swcli/sw-cli").read_bytes())
            launcher.chmod(0o755)
            # Reproduce the actual outer-App failure without a private key.
            command = ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(app)]
            rejected = subprocess.run(command, capture_output=True, timeout=60)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn(b"code object is not signed at all", rejected.stderr)
            self.assertIn(b"Contents/MacOS/sw-cli", rejected.stderr)
            launcher.rename(contents / "Resources/sw-cli")
            launcher.symlink_to("../Resources/sw-cli")
            subprocess.run(command, check=True, capture_output=True, timeout=60)
            verify = ["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)]
            subprocess.run(verify, check=True, capture_output=True, timeout=60)
            archive = root / "Probe.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(app), str(archive)], check=True, capture_output=True, timeout=60)
            restored = root / "restored"
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(restored)],
                           check=True, capture_output=True, timeout=60)
            restored_app = restored / app.name
            link = restored_app / "Contents/MacOS/sw-cli"
            self.assertEqual(os.readlink(link), "../Resources/sw-cli")
            self.assertTrue(os.access(link, os.X_OK))
            self.assertEqual(link.read_bytes(), (PROJECT / "scripts/swcli/sw-cli").read_bytes())
            subprocess.run([*verify[:-1], str(restored_app)], check=True, capture_output=True, timeout=60)

    def test_both_cli_entry_paths_resolve_the_same_runtime_without_starting_wine(self):
        with tempfile.TemporaryDirectory(prefix="macsw CLI layout ") as temporary:
            contents = Path(temporary).resolve() / "Probe.app/Contents"
            resource = contents / "Resources/sw-cli"
            resource.parent.mkdir(parents=True)
            shutil.copyfile(PROJECT / "scripts/swcli/sw-cli", resource)
            resource.chmod(0o755)
            launcher = contents / "MacOS/sw-cli"
            launcher.parent.mkdir()
            launcher.symlink_to("../Resources/sw-cli")
            (contents / "Resources/Wine").mkdir()
            (contents / "Frameworks").mkdir()
            (contents / "Frameworks/wine").symlink_to("../Resources/Wine")
            # Only the launcher's native CLI branch executes. Fake Wine files
            # satisfy its presence check but fail if accidentally launched.
            for relative in ("Frameworks/wine/bin/wineloader", "Frameworks/wine/bin/wineserver",
                             "Resources/SWCLI/bin/swcli-path"):
                path = contents / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("#!/bin/sh\nexit 99\n")
                path.chmod(0o755)
            runtime = contents / "Resources/SWCLI/runtime/PythonNative"
            (runtime / "bin").mkdir(parents=True)
            (runtime / "bin/python3").symlink_to(sys.executable)
            modules = runtime / "lib/python3.11/site-packages"
            modules.mkdir(parents=True)
            (modules / "swcli.py").write_text(
                "import json, os, sys\n"
                "print(json.dumps({'args': sys.argv[1:], 'loader': os.environ['WINELOADER'], "
                "'server': os.environ['WINESERVER'], 'path_helper': os.environ['SWCLI_PATH_TRANSLATE_CMD']}))\n")
            expected = {"args": ["version", "--json"],
                        "loader": str(contents / "Frameworks/wine/bin/wineloader"),
                        "server": str(contents / "Frameworks/wine/bin/wineserver"),
                        "path_helper": str(contents / "Resources/SWCLI/bin/swcli-path")}
            for entry in (launcher, resource):
                with self.subTest(entry=entry.relative_to(contents)):
                    result = subprocess.run([str(entry), "version", "--json"], capture_output=True,
                                            check=True, timeout=30)
                    self.assertEqual(json.loads(result.stdout), expected)


class SigningDiagnosticTests(unittest.TestCase):
    def test_failure_reports_classification_target_and_exit_not_stderr_or_argv(self):
        output = io.StringIO()
        result = SimpleNamespace(returncode=1, stdout=b"private output",
            stderr=b"unable to build chain to self-signed root; errSecInternalComponent; never-print-secret")
        args = ["/usr/bin/codesign", "--sign", "private-identity", "--keychain", "/private/private-keychain",
                "/staging/MacSW.app/Contents/Frameworks/wine/lib/module.so"]
        with patch.object(signing.subprocess, "run", return_value=result), contextlib.redirect_stdout(output):
            with self.assertRaises(RuntimeError) as error:
                signing.command(args)
        record = json.loads(output.getvalue())
        self.assertEqual(record["target"], "Contents/Frameworks/wine/lib/module.so")
        self.assertEqual(record["stage"], "sign")
        self.assertEqual(record["exit_code"], 1)
        self.assertEqual(set(record["errors"]), {"certificate-chain-untrusted", "keychain-internal-error"})
        for secret in ("private output", "never-print-secret", "private-identity", "private-keychain", "/staging"):
            self.assertNotIn(secret, output.getvalue() + str(error.exception))

    def test_unknown_error_is_a_diagnostic_gap_not_raw_output(self):
        self.assertEqual(signing.codesign_errors(b"unrecognized-private-output"), ["unclassified"])
        self.assertEqual(signing.codesign_errors(b"no identity found"), ["identity-not-found"])
        self.assertEqual(signing.codesign_errors(b"User interaction is not allowed."), ["keychain-interaction-denied"])

    def test_only_bundle_relative_paths_and_known_stages_are_reported(self):
        cases = [("--force", "details"), ("--sign", "sign"), ("--verify", "verify"),
                 ("--entitlements", "entitlements")]
        for flag, stage in cases:
            record = signing.codesign_context(["/usr/bin/codesign", flag, "/private/MacSW.app"])
            self.assertEqual(record, {"stage": stage, "target": "<outer-app>"})
        for target in ("/private/secret", "/private/MacSW.app/Contents/secret\nescape"):
            record = signing.codesign_context(["/usr/bin/codesign", "--verify", target])
            self.assertNotIn("secret", record["target"])

    def test_timeout_does_not_render_command_or_captured_output(self):
        args = ["/usr/bin/codesign", "--sign", "private-identity", "/staging/MacSW.app"]
        output = io.StringIO()
        for failure in (subprocess.TimeoutExpired(args, 120, output=b"private-data"),
                        OSError("private-error")):
            with self.subTest(kind=type(failure).__name__), \
                    patch.object(signing.subprocess, "run", side_effect=failure), \
                    contextlib.redirect_stdout(output):
                with self.assertRaises(RuntimeError) as error:
                    signing.command(args)
                for secret in ("private-identity", "private-data", "private-error"):
                    self.assertNotIn(secret, str(error.exception) + output.getvalue())


class SigningProvenanceTests(unittest.TestCase):
    def smoke_jobs(self):
        return [{"name": "Build & package", "conclusion": "success"},
            {"name": "SOLIDWORKS installation & runtime", "conclusion": "success",
             "steps": [{"name": "Lightweight visible SOLIDWORKS smoke",
                        "conclusion": "success"}]}]

    def test_corrupt_download_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs = self.smoke_jobs()
            artifact = {"id": 123, "name": "MacSW-macOS-App", "expired": False, "digest": "sha256:" + "a" * 64}
            destination = Path(directory) / "download"
            def download(args, **kwargs):
                kwargs["stdout"].write(b"corrupted-artifact")
                return SimpleNamespace(returncode=0)
            with patch.dict(os.environ, GITHUB_REPOSITORY=source.REPOSITORY,
                            GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_dispatch"), \
                    patch.object(source, "api", side_effect=[self.run_record(),
                        {"total_count": 2, "jobs": jobs}, {"total_count": 1, "artifacts": [artifact]}]), \
                    patch.object(source.subprocess, "run", side_effect=download):
                with self.assertRaisesRegex(RuntimeError, "digest mismatch"):
                    source.fetch("123", "a" * 40, destination)
            self.assertFalse((destination / "app.zip").exists())

    def test_archive_paths_and_symlinks_validated_before_ditto(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("MacSW.app/Contents/MacOS/MacSW", b"fixture")
                link = zipfile.ZipInfo("MacSW.app/Contents/MacOS/alias")
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, "MacSW")
                archive.writestr("__MACOSX/MacSW.app/Contents/._Info.plist", b"metadata")
            source.validate_app_zip(path)
            for name in ("../outside", "MacSW.app/../outside", "/absolute", "other.app/Contents/file"):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(name, b"fixture")
                with self.assertRaises(RuntimeError):
                    source.validate_app_zip(path)
            for target in ("../../../../outside", "/tmp/outside"):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(link, target)
                with self.assertRaises(RuntimeError):
                    source.validate_app_zip(path)

    def run_record(self):
        return {"status": "completed", "conclusion": "success", "head_sha": "a" * 40,
                "head_branch": "main", "path": ".github/workflows/build-app.yml", "event": "push",
                "repository": {"full_name": source.REPOSITORY},
                "head_repository": {"full_name": source.REPOSITORY}}

    def test_only_successful_exact_main_trusted_build(self):
        record = self.run_record()
        source.validate_run(record, "a" * 40)
        for field, value in (("status", "in_progress"), ("conclusion", "failure"),
                             ("head_sha", "b" * 40), ("head_branch", "branch"), ("event", "pull_request"),
                             ("path", "other.yml"), ("head_repository", {"full_name": "fork/MacSW"})):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                source.validate_run(dict(record, **{field: value}), "a" * 40)

    def test_visible_smoke_required_not_skipped_install_only(self):
        jobs = self.smoke_jobs()
        source.validate_jobs(jobs)
        for conclusion in ("skipped", "failure", "cancelled", None):
            jobs[1]["steps"][0]["conclusion"] = conclusion
            with self.assertRaises(RuntimeError):
                source.validate_jobs(jobs)
        with self.assertRaises(RuntimeError):
            source.validate_jobs(jobs[:1])

    def test_missing_failed_or_duplicate_mode_cannot_authorize_signing(self):
        for index in (1,):
            for conclusion in ("failure", "skipped", "cancelled", None):
                jobs = self.smoke_jobs()
                jobs[index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(RuntimeError):
                    source.validate_jobs(jobs)
            jobs = self.smoke_jobs()
            with self.assertRaises(RuntimeError):
                source.validate_jobs(jobs[:index] + jobs[index + 1:])
            with self.assertRaises(RuntimeError):
                source.validate_jobs(jobs + [jobs[index]])

    def test_successful_jobs_still_require_exact_smoke_step(self):
        for index in (1,):
            jobs = self.smoke_jobs()
            jobs[index]["steps"][0]["name"] = "Diagnostic hidden full CAD tests (not a signing gate)"
            with self.subTest(index=index), self.assertRaises(RuntimeError):
                source.validate_jobs(jobs)
            jobs = self.smoke_jobs()
            jobs[index]["steps"] *= 2
            with self.assertRaises(RuntimeError):
                source.validate_jobs(jobs)

    def test_legacy_or_diagnostic_steps_cannot_replace_visible_smoke(self):
        for name in ("Shared modeling, driving dimensions and Toolbox on one host (core, visible)",
                     "Shared modeling, driving dimensions and Toolbox on one host (full, visible)",
                     "Shared modeling, driving dimensions and Toolbox on one host",
                     "Shared isolated functional test sets (full, visible+hidden)",
                     "Diagnostic hidden full CAD tests (not a signing gate)"):
            jobs = [{"name": "Build & package", "conclusion": "success"},
                    {"name": "SOLIDWORKS installation & runtime", "conclusion": "success",
                     "steps": [{"name": name, "conclusion": "success"}]}]
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, "visible smoke"):
                source.validate_jobs(jobs)

    def test_hidden_diagnostic_result_is_not_consulted(self):
        jobs = self.smoke_jobs()
        jobs[1]["steps"].append({"name": "Diagnostic hidden full CAD tests (not a signing gate)",
                                 "conclusion": "skipped"})
        source.validate_jobs(jobs)
        # A separate diagnostic run (including failure) is not fetched by this
        # helper. The selected lightweight build must still succeed as a run.
        record = self.run_record()
        source.validate_run(record, record["head_sha"])

    def test_exact_unexpired_artifact_requires_sha256(self):
        artifact = {"id": 123, "name": "MacSW-macOS-App", "expired": False, "digest": "sha256:" + "a" * 64}
        self.assertEqual(source.validate_artifact([artifact]), artifact)
        for changes in ({"expired": True}, {"digest": ""}, {"id": "123"}):
            with self.assertRaises(RuntimeError):
                source.validate_artifact([dict(artifact, **changes)])
        with self.assertRaises(RuntimeError):
            source.validate_artifact([artifact, artifact])


class CredentialTests(unittest.TestCase):
    def test_api_key_has_priority_even_when_account_also_configured(self):
        values = {"NOTARY_API_KEY_BASE64": "fixture-key", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        self.assertEqual(notary.authentication_mode(values, "KEY", "ISSUER"), "api-key")

    def test_missing_api_key_uses_account_and_ignores_leftover_key_ids(self):
        values = {"NOTARY_API_KEY_BASE64": "", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        for key_id, issuer in (("", ""), ("OLDKEY", "OLDISSUER")):
            self.assertEqual(notary.authentication_mode(values, key_id, issuer), "apple-id")

    def test_partial_api_configuration_cannot_fall_back_to_account(self):
        values = {"NOTARY_API_KEY_BASE64": "fixture-key", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        for key_id, issuer in (("KEY", ""), ("", "ISSUER"), ("", "")):
            with self.assertRaisesRegex(RuntimeError, "not falling back"):
                notary.authentication_mode(values, key_id, issuer)

    def test_account_requires_both_email_and_app_password(self):
        for values in ({}, {"NOTARY_APPLE_ID": "fixture@example.test"},
                       {"NOTARY_APP_PASSWORD": "fixture"},
                       {"NOTARY_APPLE_ID": "  ", "NOTARY_APP_PASSWORD": "fixture"}):
            with self.assertRaisesRegex(RuntimeError, "not configured"):
                notary.authentication_mode(values, "", "")

    def test_both_modes_use_validated_profile_in_explicit_temporary_keychain(self):
        values = {"NOTARY_APPLE_ID": " fixture@example.test ", "NOTARY_APP_PASSWORD": "do-not-log"}
        keychain, key = Path("temporary.keychain-db"), Path("AuthKey.p8")
        for mode in ("api-key", "apple-id"):
            with patch.object(notary, "run") as run:
                auth = notary.store_profile(mode, keychain, key, values, "ABCDEFGHIJ", "KEY", "ISSUER")
            command = run.call_args.args[0]
            self.assertEqual(command[:4], ["xcrun", "notarytool", "store-credentials", notary.PROFILE])
            self.assertIn("--validate", command)
            self.assertNotIn("--sync", command)
            self.assertEqual(command[-3:-1], ["--keychain", keychain])
            self.assertEqual(auth, ["--keychain-profile", notary.PROFILE, "--keychain", keychain])
            self.assertNotIn("--password", auth)
            self.assertNotIn("do-not-log", auth)
            if mode == "apple-id":
                self.assertIn("fixture@example.test", command)
                self.assertIn("--team-id", command)
                self.assertNotIn("--key", command)
            else:
                self.assertIn("--key", command)
                self.assertNotIn("--apple-id", command)

    def test_account_preparation_does_not_create_p8(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(notary, "run"), \
                patch.object(notary, "keychain_search_list", return_value=[]), \
                patch.object(notary, "set_keychain_search_list"):
            directory = Path(temporary) / "private"
            values = {"SIGNING_CERTIFICATE_P12_BASE64": base64.b64encode(b"fixture-p12").decode(),
                      "SIGNING_CERTIFICATE_PASSWORD": "fixture", "NOTARY_API_KEY_BASE64": ""}
            keychain, key = notary.prepare(directory, values)
            self.assertIsNone(key)
            self.assertFalse((directory / "AuthKey.p8").exists())
            self.assertEqual(keychain, directory / "signing.keychain-db")

    def test_authentication_failure_stops_before_signing_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {"RUNNER_TEMP": temporary,
                   "SIGNING_CERTIFICATE_P12_BASE64": "fixture-p12",
                   "SIGNING_CERTIFICATE_PASSWORD": "fixture-p12-password",
                   "NOTARY_API_KEY_BASE64": "fixture-key",
                   "NOTARY_APPLE_ID": "fixture@example.test", "NOTARY_APP_PASSWORD": "fixture-password"}
            with patch.dict(os.environ, env), \
                    patch.object(notary, "prepare", return_value=(root / "keychain", root / "key")), \
                    patch.object(notary, "cleanup") as cleanup, \
                    patch.object(notary.sign_app, "inventory"), patch.object(notary.sign_app, "verify_payload"), \
                    patch.object(notary.sign_app, "sign") as sign, \
                    patch.object(notary, "store_profile", side_effect=RuntimeError("Authentication failed")) as store:
                with self.assertRaisesRegex(RuntimeError, "Authentication failed"):
                    notary.notarize(root / "MacSW.app", root / "output", "ABCDEFGHIJ",
                                    "Developer ID Application: Fixture", "KEY", "ISSUER")
                self.assertEqual(store.call_count, 1)
                self.assertEqual(store.call_args.args[0], "api-key")
                sign.assert_not_called()
                cleanup.assert_called_once()
                self.assertFalse(any(name in os.environ for name in notary.SECRET_NAMES))

    def test_notarization_rejected_never_staples_or_produces_final_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "MacSW.app"
            output = root / "output"
            commands = []
            env = {"RUNNER_TEMP": temporary, **{name: "fixture-secret" for name in notary.SECRET_NAMES}}
            def command(args, **kwargs):
                self.assertFalse(any(name in os.environ for name in notary.SECRET_NAMES))
                commands.append(args)
                return b"{}"
            with patch.dict(os.environ, env), patch.object(notary, "prepare", return_value=(root / "keychain", root / "key")), \
                    patch.object(notary, "cleanup") as cleanup, \
                    patch.object(notary.sign_app, "inventory"), patch.object(notary.sign_app, "verify_payload"), \
                    patch.object(notary.sign_app, "sign", return_value=[]), patch.object(notary.sign_app, "verify"), \
                    patch.object(notary, "signing_probe"), \
                    patch.object(notary, "inspect_signing_identity", return_value="a" * 40), \
                    patch.object(notary, "run", side_effect=command), \
                    patch.object(notary.subprocess, "run", return_value=SimpleNamespace(
                        returncode=1, stdout=json.dumps({"id": "fixture-id", "status": "Invalid"}).encode())):
                with self.assertRaisesRegex(RuntimeError, "not Accepted"):
                    notary.notarize(app, output, "ABCDEFGHIJ", "Developer ID Application: Fixture", "KEY", "ISSUER")
                cleanup.assert_called_once()
                self.assertFalse(any("stapler" in args for args in commands))
                self.assertEqual(list(output.glob("*-signed.zip")), [])
                self.assertTrue((output / "notary-result.json").exists())

    def test_no_credentials_means_no_signing_or_files(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True), \
                patch.object(notary, "prepare") as prepare:
            with self.assertRaisesRegex(RuntimeError, "not configured"):
                notary.notarize(Path(directory) / "MacSW.app", Path(directory) / "output", "", "", "", "")
            prepare.assert_not_called()
            self.assertFalse((Path(directory) / "output").exists())

    def test_private_file_permissions_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            notary.private_file(path, b"fake-key")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                notary.private_file(path, b"new")

    def test_credential_commands_suppressed_and_no_allow_all_import(self):
        calls = []
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(notary, "run", side_effect=lambda cmd: calls.append(cmd)), \
                patch.object(notary, "keychain_search_list", return_value=[]), \
                patch.object(notary, "set_keychain_search_list"):
            root = Path(directory) / "private"
            values = {notary.SECRET_NAMES[0]: base64.b64encode(b"fixture-p12").decode(),
                      notary.SECRET_NAMES[1]: "never-log-this-password",
                      notary.SECRET_NAMES[2]: base64.b64encode(b"fixture-p8").decode()}
            keychain, key = notary.prepare(root, values)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertFalse((root / "certificate.p12").exists())
            self.assertEqual(key.read_bytes(), b"fixture-p8")
            import_call = next(cmd for cmd in calls if cmd[1] == "import")
            self.assertNotIn("-A", import_call)
            self.assertIn("/usr/bin/codesign", import_call)

    def test_cleanup_scoped_known_files_only(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            directory.mkdir()
            (directory / "AuthKey.p8").write_text("fixture")
            notary.cleanup(directory)
            self.assertFalse(directory.exists())
            with self.assertRaisesRegex(RuntimeError, "Refusing cleanup"):
                notary.cleanup(Path(temporary))
            directory.mkdir()
            unknown = directory / "user-data"
            unknown.write_text("preserve")
            with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                notary.cleanup(directory)
            self.assertEqual(unknown.read_text(), "preserve")
            unknown.unlink()
            external = Path(temporary) / "other.keychain-db"
            external.write_text("preserve")
            (directory / "signing.keychain-db").symlink_to(external)
            with patch.object(notary.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                    notary.cleanup(directory)
                run.assert_not_called()
            self.assertEqual(external.read_text(), "preserve")

    def test_command_failure_does_not_print_arguments_or_password(self):
        with patch.object(notary.subprocess, "run", return_value=type("Result", (), {"returncode": 1})()):
            with self.assertRaises(RuntimeError) as error:
                notary.run(["security", "import", "private", "-P", "never-print"])
            self.assertNotIn("never-print", str(error.exception))

    def test_identity_diagnostic_does_not_print_identity_names_or_keychain(self):
        public_name = "Developer ID Application: Fixture (ABCDEFGHIJ)"
        record = ('  1) ' + 'A' * 40 + ' "' + public_name + '"\n 1 valid identities found\n').encode()
        output = io.StringIO()
        with patch.object(notary, "run", return_value=record) as run, contextlib.redirect_stdout(output):
            fingerprint = notary.inspect_signing_identity(Path("/private/credential-directory/keychain"), public_name)
        self.assertEqual(fingerprint, "a" * 40)
        run.assert_called_once_with(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning",
                                     Path("/private/credential-directory/keychain")])
        self.assertEqual(json.loads(output.getvalue()), {"event": "macsw.signing-identities",
                         "valid_identity_count": 1, "selected_identity_present": True, "selected_certificate_count": 1})
        self.assertNotIn(public_name, output.getvalue())
        self.assertNotIn("credential-directory", output.getvalue())
        with patch.object(notary, "run", return_value=b"0 valid identities found"), \
                contextlib.redirect_stdout(output := io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "Exactly one"):
                notary.inspect_signing_identity(Path("private"), public_name)
        self.assertFalse(json.loads(output.getvalue())["selected_identity_present"])

    def test_ambiguous_configured_identity_fails_without_guessing(self):
        identity = "Developer ID Application: Fixture"
        record = ('1) ' + 'a' * 40 + ' "' + identity + '"\n2) ' + 'b' * 40 + ' "' + identity + '"').encode()
        output = io.StringIO()
        with patch.object(notary, "run", return_value=record), contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(RuntimeError, "Exactly one"):
                notary.inspect_signing_identity(Path("private"), identity)
        self.assertEqual(json.loads(output.getvalue())["selected_certificate_count"], 2)
        self.assertNotIn(identity, output.getvalue())

    def test_cleanup_accepts_only_this_keychains_native_lock(self):
        self.assertEqual(notary.keychain_lock_name("signing.keychain-db"), ".flD3051040")
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            directory.mkdir()
            keychain = directory / "signing.keychain-db"
            keychain.write_text("private")
            lock = directory / ".flD3051040"
            lock.write_text("private")
            with patch.object(notary.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run, \
                    contextlib.redirect_stdout(io.StringIO()):
                notary.cleanup(directory)
            run.assert_called_once_with(["/usr/bin/security", "delete-keychain", str(keychain)],
                                        capture_output=True, timeout=30)
            self.assertFalse(directory.exists())
            for name, symlink in ((".fl12345678", False), (".flD3051040", True)):
                directory.mkdir()
                path = directory / name
                path.symlink_to("/missing/private") if symlink else path.write_text("preserve")
                with patch.object(notary.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                        notary.cleanup(directory)
                run.assert_not_called()
                path.unlink()
                directory.rmdir()

    def test_cleanup_reports_sidecar_type_without_widening_deletion_allowlist(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            directory.mkdir()
            sidecar = directory / "signing.keychain-db.sb-123ABC"
            sidecar.write_bytes(b"never-print-content")
            unknown = directory / "never-print-filename"
            unknown.symlink_to("/missing/never-follow-link")
            output = io.StringIO()
            with patch.object(notary.subprocess, "run") as run, contextlib.redirect_stdout(output):
                with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                    notary.cleanup(directory)
            run.assert_not_called()
            self.assertEqual(sidecar.read_bytes(), b"never-print-content")
            self.assertTrue(unknown.is_symlink())
            record = json.loads(output.getvalue())
            self.assertEqual(record["entries"], [{"name": "<unrecognized>", "kind": "symlink"},
                                               {"name": sidecar.name, "kind": "file"}])
            for secret in ("never-print-content", "never-print-filename", "never-follow-link", temporary):
                self.assertNotIn(secret, output.getvalue())

    def test_base64_still_rejects_multiline_without_creating_a_keychain(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(notary, "run") as run:
            values = {notary.SECRET_NAMES[0]: base64.b64encode(b"fixture-p12").decode() + "\n"}
            with self.assertRaises(ValueError):
                notary.prepare(Path(temporary) / "private", values)
            run.assert_not_called()

    def test_probe_failure_stops_before_app_signing_or_submission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {"RUNNER_TEMP": temporary, **{name: "fixture-secret" for name in notary.SECRET_NAMES}}
            with patch.dict(os.environ, env), \
                    patch.object(notary, "prepare", return_value=(root / "keychain", root / "key")), \
                    patch.object(notary, "cleanup") as cleanup, patch.object(notary, "store_profile"), \
                    patch.object(notary.sign_app, "inventory"), patch.object(notary.sign_app, "verify_payload"), \
                    patch.object(notary.sign_app, "sign") as sign, \
                    patch.object(notary, "inspect_signing_identity", return_value="a" * 40), \
                    patch.object(notary, "signing_probe", side_effect=RuntimeError("Probe failed")), \
                    patch.object(notary.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "Probe failed"):
                    notary.notarize(root / "MacSW.app", root / "output", "ABCDEFGHIJ",
                                    "Developer ID Application: Fixture", "KEY", "ISSUER")
                sign.assert_not_called()
                run.assert_not_called()
                cleanup.assert_called_once()

    def test_signing_workflow_is_manual_protected_and_no_release(self):
        workflow = (PROJECT / ".github/workflows/sign-app.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("environment: macsw-release", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        # The default branch is main: no workflow names master.
        for name in ("build-app.yml", "publication-scan.yml", "sign-app.yml"):
            text = (PROJECT / ".github/workflows" / name).read_text()
            self.assertNotIn("master", text, name)
        for name in ("build-app.yml", "publication-scan.yml"):
            text = (PROJECT / ".github/workflows" / name).read_text()
            self.assertIn("    branches:\n      - main\n", text, name)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("action-gh-release", workflow)
        self.assertNotIn("pull_request", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertLess(workflow.index("scripts/ci/signing-input.py"), workflow.index("secrets.SIGNING_CERTIFICATE"))
        self.assertIn("if: always()", workflow)
        self.assertIn("NOTARY_APPLE_ID: ${{ secrets.NOTARY_APPLE_ID || vars.NOTARY_APPLE_ID }}", workflow)
        self.assertIn("NOTARY_APP_PASSWORD: ${{ secrets.NOTARY_APP_PASSWORD }}", workflow)
        self.assertNotIn("vars.NOTARY_APP_PASSWORD", workflow)
        self.assertIn("NOTARY_API_KEY_BASE64: ${{ secrets.NOTARY_API_KEY_BASE64 }}", workflow)
        self.assertIn("NOTARY_KEY_ID: ${{ vars.NOTARY_KEY_ID }}", workflow)
        self.assertIn("NOTARY_ISSUER_ID: ${{ vars.NOTARY_ISSUER_ID }}", workflow)
        signing_job = workflow.split("  verify-signed-bootstrap:", 1)[0]
        self.assertEqual(workflow.count("uses: actions/upload-artifact@v7"), 3)
        uploads = signing_job.split("uses: actions/upload-artifact@v7")[1:]
        self.assertEqual(len(uploads), 2)
        for upload in uploads:
            self.assertNotIn("macsw-signing-credentials", upload)
            self.assertNotIn("notary-submission.zip", upload)
            self.assertNotIn("native-probes", upload)


class KeychainLifecycleTests(unittest.TestCase):
    """Mock every Security call; never touch the developer's actual keychains."""

    def fixture(self, original):
        self.state = list(original)
        self.commands = []
        def command(arguments, **kwargs):
            arguments = list(map(str, arguments))
            self.commands.append(arguments)
            if arguments[1:5] == ["list-keychains", "-d", "user", "-s"]:
                self.state = arguments[5:]
            elif arguments[1:] == ["list-keychains", "-d", "user"]:
                return "\n".join(json.dumps(path, ensure_ascii=False) for path in self.state).encode()
            return b""
        return command

    def values(self):
        return {notary.SECRET_NAMES[0]: base64.b64encode(b"fixture-p12").decode(),
                notary.SECRET_NAMES[1]: "never-log-password"}

    def test_prepare_preserves_search_entries_and_separate_cleanup_restores_before_delete(self):
        original = ["/Users/fixture/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain",
                    '/private/keychain with spaces and "quotes".keychain-db']
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            with patch.object(notary, "run", side_effect=self.fixture(original)), contextlib.redirect_stdout(output):
                keychain, _ = notary.prepare(directory, self.values())
                receipt = directory / notary.SEARCH_LIST_RECEIPT
                self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads(receipt.read_bytes()), {"version": 1, "paths": original})
                self.assertEqual(self.state, [str(keychain), *original])
                self.assertLess(next(i for i, cmd in enumerate(self.commands) if cmd[1] == "list-keychains"),
                                next(i for i, cmd in enumerate(self.commands) if cmd[1] == "create-keychain"))
                keychain.write_bytes(b"fixture-keychain")
                def delete(arguments, **kwargs):
                    self.assertEqual(self.state, original)
                    self.assertEqual(arguments, ["/usr/bin/security", "delete-keychain", str(keychain)])
                    return SimpleNamespace(returncode=0)
                with patch.object(notary.subprocess, "run", side_effect=delete) as run:
                    notary.cleanup(directory)
                    notary.cleanup(directory)  # always() after finally is idempotent.
                    run.assert_called_once()
                self.assertFalse(directory.exists())
                self.assertEqual(self.state, original)
        for private in (*original, temporary, "never-log-password"):
            self.assertNotIn(private, output.getvalue())
        self.assertFalse(any("default-keychain" in cmd or "-A" in cmd for cmd in self.commands))

    def test_import_failure_keeps_receipt_and_cleanup_restores_original_list(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            command = self.fixture(["/private/original.keychain-db"])
            def fail_import(arguments, **kwargs):
                if arguments[1] == "import":
                    self.assertTrue((directory / notary.SEARCH_LIST_RECEIPT).exists())
                    raise RuntimeError("Import failed")
                return command(arguments, **kwargs)
            with patch.object(notary, "run", side_effect=fail_import), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "Import failed"):
                    notary.prepare(directory, self.values())
                notary.cleanup(directory)
            self.assertEqual(self.state, ["/private/original.keychain-db"])
            self.assertFalse(directory.exists())

    def test_failed_restoration_retains_keychain_and_receipt_for_retry(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            directory.mkdir()
            keychain = directory / "signing.keychain-db"
            keychain.write_bytes(b"fixture")
            receipt = directory / notary.SEARCH_LIST_RECEIPT
            notary.private_file(receipt, b'{"version":1,"paths":[]}')
            with patch.object(notary, "run", side_effect=RuntimeError("Restore failed")), \
                    patch.object(notary.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "Restore failed"):
                    notary.cleanup(directory)
                run.assert_not_called()
                self.assertTrue(keychain.exists())
                self.assertTrue(receipt.exists())
            with patch.object(notary, "run", side_effect=self.fixture([])), \
                    patch.object(notary.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
                    contextlib.redirect_stdout(io.StringIO()):
                notary.cleanup(directory)
            self.assertFalse(directory.exists())

    def test_bad_receipt_is_rejected_without_security_calls_or_deletion(self):
        fixtures = (b"not-json", b"[]", b'{"version":2,"paths":[]}',
                    b'{"version":1,"paths":["-s"]}', b'{"version":1,"paths":null}',
                    b'{"version":1,"paths":["/private/unsafe\\npath"]}')
        for contents in fixtures:
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict(os.environ, RUNNER_TEMP=temporary):
                directory = Path(temporary) / "macsw-signing-credentials"
                directory.mkdir()
                receipt = directory / notary.SEARCH_LIST_RECEIPT
                notary.private_file(receipt, contents)
                with patch.object(notary, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(RuntimeError):
                        notary.cleanup(directory)
                    run.assert_not_called()
                self.assertEqual(receipt.read_bytes(), contents)

    def test_receipt_symlink_and_public_permissions_are_rejected(self):
        for symlink in (True, False):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict(os.environ, RUNNER_TEMP=temporary):
                directory = Path(temporary) / "macsw-signing-credentials"
                directory.mkdir()
                receipt = directory / notary.SEARCH_LIST_RECEIPT
                if symlink:
                    receipt.symlink_to("/missing/do-not-follow")
                else:
                    notary.private_file(receipt, b'{"version":1,"paths":[]}')
                    receipt.chmod(0o644)
                with patch.object(notary, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(RuntimeError):
                        notary.cleanup(directory)
                    run.assert_not_called()

    def test_search_list_must_be_absolute_parseable_and_round_trip(self):
        for data in (b'"unterminated', b'"relative.keychain-db"', b"\xff"):
            with self.subTest(data=data), patch.object(notary, "run", return_value=data):
                with self.assertRaises(RuntimeError):
                    notary.keychain_search_list()
        with patch.object(notary, "run", return_value=b'"/private/different.keychain-db"'):
            with self.assertRaisesRegex(RuntimeError, "did not match"):
                notary.set_keychain_search_list(["/private/expected.keychain-db"])


class SigningProbeTests(unittest.TestCase):
    def test_probe_signs_verifies_and_executes_before_removing_its_private_directory(self):
        for failure in (None, "build", "sign", "verify", "execute"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict(os.environ, RUNNER_TEMP=temporary):
                stages = []
                binaries = []
                def stage(name):
                    stages.append(name)
                    if name == failure:
                        raise RuntimeError("Probe " + name + " failed")
                def command(arguments, **kwargs):
                    if arguments[0] == "xcrun":
                        stage("build")
                        self.assertEqual(arguments[:2], ["xcrun", "clang"])
                        self.assertEqual(arguments[2], PROJECT / "native/signing_probe.c")
                        binaries.append(arguments[-1])
                        arguments[-1].write_bytes(b"fixture-executable")
                    else:
                        stage("execute")
                        self.assertEqual(arguments, [binaries[0]])
                def codesign(arguments):
                    stage("sign")
                    self.assertEqual(arguments, ["/usr/bin/codesign", "--force", "--sign", "a" * 40,
                                     "--keychain", Path("fixture.keychain-db"), "--options", "runtime",
                                     "--timestamp", "--entitlements", PROJECT / "resources/signing/default.plist",
                                     binaries[0]])
                def verify(path, policy, team):
                    stage("verify")
                    self.assertEqual((path, policy, team), (binaries[0], "default", "ABCDEFGHIJ"))
                output = io.StringIO()
                with patch.object(notary, "run", side_effect=command), \
                        patch.object(notary.sign_app, "command", side_effect=codesign), \
                        patch.object(notary.sign_app, "verify_signature", side_effect=verify), \
                        contextlib.redirect_stdout(output):
                    if failure:
                        with self.assertRaisesRegex(RuntimeError, "Probe .* failed"):
                            notary.signing_probe(Path("fixture.keychain-db"), "a" * 40, "ABCDEFGHIJ")
                    else:
                        notary.signing_probe(Path("fixture.keychain-db"), "a" * 40, "ABCDEFGHIJ")
                expected = ["build", "sign", "verify", "execute"]
                self.assertEqual(stages, expected[:expected.index(failure) + 1] if failure else expected)
                self.assertEqual(list(Path(temporary).iterdir()), [])
                self.assertEqual("passed" in output.getvalue(), failure is None)
                self.assertNotIn(temporary, output.getvalue())


if __name__ == "__main__":
    unittest.main()
