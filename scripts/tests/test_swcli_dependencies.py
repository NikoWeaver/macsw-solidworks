"""Offline checks for platform-specific, checksum-locked SWCLI packaging."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parents[2]


class DependencyPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for relative in (
            "config/versions.env",
            "scripts/lib/config.sh",
            "scripts/package_swcli_dependencies.sh",
        ):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / relative, destination)
        (self.root / "dist").mkdir()
        self.windows = self.root / "windows"
        self.native = self.root / "native"
        self.manifest = self.root / "config/swcli-wheels.tsv"
        rows = ["# fixture wheel inventory"]
        for target in ("common", "windows", "native"):
            asset = target + "-1.0-py3-none-any.whl"
            wheel = self.root / "dist" / asset
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr(target + "/__init__.py", "")
                archive.writestr(target + "-1.0.dist-info/licenses/LICENSE", "license")
            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            rows.append(f"{target} {asset} {digest} https://example.invalid/{asset}")
        self.manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")

    def run_packaging(self, *arguments):
        return subprocess.run(
            [
                "bash",
                str(self.root / "scripts/package_swcli_dependencies.sh"),
                *(arguments or (str(self.windows), str(self.native))),
            ],
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_platforms_and_licenses_are_preserved(self):
        result = self.run_packaging()
        self.assertEqual(result.returncode, 0, result.stderr)
        for destination, platform in (
            (self.windows, "windows"),
            (self.native, "native"),
        ):
            self.assertTrue((destination / "common/__init__.py").is_file())
            self.assertTrue((destination / f"{platform}/__init__.py").is_file())
            self.assertTrue(
                (destination / f"{platform}-1.0.dist-info/licenses/LICENSE").is_file()
            )
        self.assertFalse((self.windows / "native").exists())
        self.assertFalse((self.native / "windows").exists())

    def test_tampered_wheel_is_rejected(self):
        with (self.root / "dist/common-1.0-py3-none-any.whl").open("ab") as wheel:
            wheel.write(b"tampered")
        result = self.run_packaging()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.windows.exists())

    def test_missing_wheel_is_rejected(self):
        (self.root / "dist/common-1.0-py3-none-any.whl").unlink()
        self.assertNotEqual(self.run_packaging().returncode, 0)

    def test_unknown_platform_is_rejected(self):
        self.manifest.write_text("unknown absent.whl unused https://example.invalid/\n")
        result = self.run_packaging()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown SWCLI wheel target", result.stderr)

    def test_required_arguments(self):
        self.assertEqual(self.run_packaging("only-one-path").returncode, 2)


if __name__ == "__main__":
    unittest.main()
