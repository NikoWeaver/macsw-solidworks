"""Offline cache identities retain installer inputs without following SWCLI bumps."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "macsw_cache_identity", PROJECT / "scripts/ci/cache-identity.py"
)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)

SOURCE_HASH = "a" * 64
VERSIONS = {
    "APP_VERSION": "0.1.0",
    "APP_BUILD": "1",
    "APP_RELEASE": "0.1.0-rc.1",
    "MACOS_DEPLOYMENT_TARGET": "13.0",
    "WINE_VERSION": "11.16",
    "WINE_RUNTIME_SHA256": "b" * 64,
    "WINE_SOURCE_SHA256": "c" * 64,
    "WINE_MONO_VERSION": "11.3.0",
    "MONO_PATCH_SHA256": "d" * 64,
    "STDOLE_VERSION": "7.0.3300",
    "STDOLE_DLL_SHA256": "e" * 64,
    "SEVEN_Z_VERSION": "23.01",
    "SEVEN_Z_SHA256": "f" * 64,
    "SWCLI_VERSION": "0.1.0a6.dev0",
    "SWCLI_SOURCE_COMMIT": "1" * 40,
    "SWCLI_PYTHON_VERSION": "3.11.9",
    "SWCLI_PYTHON_ARCHIVE_SHA256": "2" * 64,
    "SWCLI_PYWIN32_VERSION": "312",
    "SWCLI_PYWIN32_WHEEL_SHA256": "3" * 64,
    "SWCLI_NATIVE_PYTHON_VERSION": "3.11.16",
    "SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256": "4" * 64,
}
INSTALL_CONTEXT = {
    "macos": "15.7.1",
    "architecture": "arm64",
    "media_path": "remote:/SOLIDWORKS/2025/installation.iso",
    "language": "ChineseSimplified",
    "serial": "private-test-license-value-not-for-publication",
}


class VersionsReaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "versions.env"

    def read(self, text):
        self.path.write_text(text, encoding="utf-8")
        return identity.read_versions(self.path)

    def test_comments_blank_lines_and_literal_assignments(self):
        self.assertEqual(
            self.read('# versions\n\nWINE_VERSION="11.16"\nNEW_INPUT="literal value"\n'),
            {"WINE_VERSION": "11.16", "NEW_INPUT": "literal value"},
        )

    def test_real_version_configuration_uses_supported_syntax(self):
        values = identity.read_versions(PROJECT / "config/versions.env")
        self.assertIn("WINE_VERSION", values)
        self.assertIn("SWCLI_SOURCE_COMMIT", values)
        self.assertTrue(all(isinstance(value, str) and value for value in values.values()))

    def test_duplicate_assignments_fail_even_with_equal_values(self):
        with self.assertRaises((ValueError, RuntimeError)):
            self.read('WINE_VERSION="11.16"\nWINE_VERSION="11.16"\n')

    def test_empty_values_fail(self):
        for text in ('WINE_VERSION=""\n', 'WINE_VERSION="   "\n'):
            with self.subTest(text=text), self.assertRaises((ValueError, RuntimeError)):
                self.read(text)

    def test_missing_configuration_fails(self):
        with self.assertRaises((FileNotFoundError, ValueError, RuntimeError)):
            identity.read_versions(self.path)

    def test_empty_configuration_fails(self):
        for text in ("", "# comments only\n\n"):
            with self.subTest(text=text), self.assertRaises((ValueError, RuntimeError)):
                self.read(text)

    def test_nonliteral_shell_syntax_fails_closed(self):
        invalid = (
            "WINE_VERSION=11.16\n",
            "WINE_VERSION='11.16'\n",
            'export WINE_VERSION="11.16"\n',
            'WINE_VERSION="11.16"; echo unexpected\n',
            'WINE_VERSION="11.16" # inline command syntax\n',
            'WINE_VERSION="${OTHER_VERSION}"\n',
            'WINE_VERSION="$OTHER_VERSION"\n',
            'WINE_VERSION="$(echo unexpected)"\n',
            'WINE_VERSION="`echo unexpected`"\n',
            'WINE_VERSION="11.16\\"quoted"\n',
            'WINE_VERSION="11.16\ncontinued"\n',
            'WINE_VERSION="11.16"\necho unexpected\n',
        )
        for text in invalid:
            with self.subTest(text=text), self.assertRaises((ValueError, RuntimeError)):
                self.read(text)


class CacheIdentityTests(unittest.TestCase):
    def digest(self, scope, versions=None, source_hash=SOURCE_HASH, **context):
        if scope == "installed-base":
            supplied = dict(INSTALL_CONTEXT)
            supplied.update(context)
        else:
            supplied = context
        return identity.context_digest(
            scope, dict(VERSIONS if versions is None else versions), source_hash, **supplied
        )

    def test_identity_is_a_sha256_hex_digest(self):
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope):
                self.assertRegex(self.digest(scope), r"\A[0-9a-f]{64}\Z")

    def test_assets_do_not_require_installation_context(self):
        self.assertRegex(
            identity.context_digest("assets", dict(VERSIONS), SOURCE_HASH),
            r"\A[0-9a-f]{64}\Z",
        )

    def test_application_release_identity_does_not_invalidate_either_cache(self):
        for scope in ("assets", "installed-base"):
            for name in ("APP_VERSION", "APP_BUILD", "APP_RELEASE"):
                changed = dict(VERSIONS)
                changed[name] += ".next"
                with self.subTest(scope=scope, name=name):
                    self.assertEqual(self.digest(scope), self.digest(scope, changed))

    def test_swcli_source_only_bumps_keep_both_cache_identities(self):
        changed = dict(VERSIONS)
        changed.update(SWCLI_VERSION="0.1.0a7.dev0", SWCLI_SOURCE_COMMIT="5" * 40)
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope):
                self.assertEqual(self.digest(scope), self.digest(scope, changed))

    def test_native_runtime_dependencies_invalidate_both_scopes(self):
        names = (
            "MACOS_DEPLOYMENT_TARGET", "WINE_VERSION", "WINE_RUNTIME_SHA256",
            "WINE_SOURCE_SHA256", "WINE_MONO_VERSION", "MONO_PATCH_SHA256",
            "STDOLE_VERSION", "STDOLE_DLL_SHA256", "SEVEN_Z_VERSION", "SEVEN_Z_SHA256",
        )
        for scope in ("assets", "installed-base"):
            for name in names:
                changed = dict(VERSIONS)
                changed[name] += ".next"
                with self.subTest(scope=scope, name=name):
                    self.assertNotEqual(self.digest(scope), self.digest(scope, changed))

    def test_unknown_new_configuration_inputs_invalidate_both_scopes(self):
        changed = dict(VERSIONS, FUTURE_INSTALLER_DEPENDENCY="new-input")
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope):
                self.assertNotEqual(self.digest(scope), self.digest(scope, changed))

    def test_python_dependencies_invalidate_assets_but_not_installed_base(self):
        names = (
            "SWCLI_PYTHON_VERSION", "SWCLI_PYTHON_ARCHIVE_SHA256",
            "SWCLI_PYWIN32_VERSION", "SWCLI_PYWIN32_WHEEL_SHA256",
            "SWCLI_NATIVE_PYTHON_VERSION", "SWCLI_NATIVE_PYTHON_ARCHIVE_SHA256",
        )
        for name in names:
            changed = dict(VERSIONS)
            changed[name] += ".next"
            with self.subTest(name=name):
                self.assertNotEqual(self.digest("assets"), self.digest("assets", changed))
                self.assertEqual(
                    self.digest("installed-base"), self.digest("installed-base", changed)
                )

    def test_installed_base_excludes_future_swcli_configuration_too(self):
        changed = dict(VERSIONS, SWCLI_FUTURE_DEPENDENCY="future-version")
        self.assertEqual(self.digest("installed-base"), self.digest("installed-base", changed))
        self.assertNotEqual(self.digest("assets"), self.digest("assets", changed))

    def test_installer_source_digest_is_required_and_changes_both_scopes(self):
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope):
                self.assertNotEqual(self.digest(scope), self.digest(scope, source_hash="6" * 64))
                with self.assertRaises(TypeError):
                    identity.context_digest(scope, dict(VERSIONS))

    def test_invalid_installer_source_digests_fail_closed(self):
        for scope in ("assets", "installed-base"):
            for invalid in ("", "a" * 63, "a" * 65, "g" * 64, " " + "a" * 64, None, 7):
                with self.subTest(scope=scope, invalid=invalid):
                    with self.assertRaises((ValueError, TypeError, RuntimeError)):
                        self.digest(scope, source_hash=invalid)

    def test_each_installation_context_boundary_invalidates_base(self):
        for name, value in INSTALL_CONTEXT.items():
            with self.subTest(name=name):
                self.assertNotEqual(
                    self.digest("installed-base"),
                    self.digest("installed-base", **{name: value + ".next"}),
                )

    def test_missing_installation_context_fails_closed(self):
        for name in INSTALL_CONTEXT:
            context = dict(INSTALL_CONTEXT)
            del context[name]
            with self.subTest(name=name), self.assertRaises((ValueError, TypeError, RuntimeError)):
                identity.context_digest("installed-base", dict(VERSIONS), SOURCE_HASH, **context)

    def test_empty_or_wrong_type_installation_context_fails_closed(self):
        for name in INSTALL_CONTEXT:
            for value in ("", "   ", None, 7):
                with self.subTest(name=name, value=value):
                    with self.assertRaises((ValueError, TypeError, RuntimeError)):
                        self.digest("installed-base", **{name: value})

    def test_unknown_scopes_fail_closed(self):
        for scope in ("", "base", "installed", "assets-next", None):
            with self.subTest(scope=scope), self.assertRaises((ValueError, TypeError, RuntimeError)):
                self.digest(scope)

    def test_empty_or_malformed_configuration_fails_closed(self):
        invalid = ({}, {"WINE_VERSION": ""}, {"WINE_VERSION": "   "},
                   {"WINE_VERSION": 11}, {7: "11.16"})
        for scope in ("assets", "installed-base"):
            for versions in invalid:
                with self.subTest(scope=scope, versions=versions):
                    with self.assertRaises((ValueError, TypeError, RuntimeError)):
                        self.digest(scope, versions=versions)

    def test_excluded_metadata_alone_cannot_supply_runtime_identity(self):
        metadata = {name: VERSIONS[name] for name in (
            "APP_VERSION", "APP_BUILD", "APP_RELEASE", "SWCLI_VERSION", "SWCLI_SOURCE_COMMIT"
        )}
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope), self.assertRaises((ValueError, TypeError, RuntimeError)):
                self.digest(scope, versions=metadata)

    def test_configuration_order_does_not_change_identity_or_mutate_inputs(self):
        original = dict(VERSIONS)
        reversed_versions = dict(reversed(list(original.items())))
        for scope in ("assets", "installed-base"):
            with self.subTest(scope=scope):
                context = INSTALL_CONTEXT if scope == "installed-base" else {}
                self.assertEqual(
                    identity.context_digest(scope, original, SOURCE_HASH, **context),
                    identity.context_digest(scope, reversed_versions, SOURCE_HASH, **context),
                )
        self.assertEqual(VERSIONS, original)
        self.assertEqual(list(reversed_versions), list(reversed(list(VERSIONS))))

    def test_serial_is_not_exposed_in_identity_or_output(self):
        serial = INSTALL_CONTEXT["serial"]
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            digest = self.digest("installed-base")
        for result in (digest, output.getvalue(), errors.getvalue()):
            self.assertNotIn(serial, result)

    def test_invalid_context_diagnostics_do_not_include_serial(self):
        with self.assertRaises((ValueError, TypeError, RuntimeError)) as raised:
            self.digest("installed-base", macos="")
        self.assertNotIn(INSTALL_CONTEXT["serial"], str(raised.exception))

    def test_cli_emits_only_a_digest_not_private_installation_context(self):
        environment = {
            "MACSW_INSTALLER_HASH": SOURCE_HASH,
            "MACSW_MEDIA_PATH": INSTALL_CONTEXT["media_path"],
            "MACSW_CI_LANGUAGE": INSTALL_CONTEXT["language"],
            "SW_SERIAL_SOLIDWORKS": INSTALL_CONTEXT["serial"],
        }
        output, errors = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, environment, clear=True), \
                patch.object(sys, "argv", ["cache-identity.py", "installed-base"]), \
                patch.object(identity, "read_versions", return_value=dict(VERSIONS)), \
                patch.object(identity.platform, "mac_ver", return_value=(INSTALL_CONTEXT["macos"], (), "")), \
                patch.object(identity.platform, "machine", return_value=INSTALL_CONTEXT["architecture"]), \
                redirect_stdout(output), redirect_stderr(errors):
            identity.main()
        self.assertRegex(output.getvalue(), r"\A[0-9a-f]{64}\n\Z")
        self.assertEqual(errors.getvalue(), "")
        for private_value in (INSTALL_CONTEXT["serial"], INSTALL_CONTEXT["media_path"]):
            self.assertNotIn(private_value, output.getvalue())


if __name__ == "__main__":
    unittest.main()
