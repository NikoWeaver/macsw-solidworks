"""Hermetic tests for the bundled native path translator; never start Wine."""

import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

translate = runpy.run_path(
    str(Path(__file__).resolve().parents[1] / "swcli/swcli_path.py")
)["translate"]


class NativePathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.prefix = self.root / "bottle with spaces"
        (self.prefix / "drive_c").mkdir(parents=True)
        self.devices = self.prefix / "dosdevices"
        self.devices.mkdir()
        (self.devices / "c:").symlink_to("../drive_c", target_is_directory=True)
        (self.devices / "z:").symlink_to("/", target_is_directory=True)

    def convert(self, value):
        return translate(str(value), prefix=str(self.prefix))

    def test_c_drive_nonexistent_output_and_root(self):
        self.assertEqual(self.convert(self.prefix / "drive_c"), "C:\\")
        self.assertEqual(
            self.convert(self.prefix / "drive_c/models/part with spaces.SLDPRT"),
            "C:\\models\\part with spaces.SLDPRT",
        )

    def test_symlink_to_bottle(self):
        alias = self.root / "bottle-alias"
        alias.symlink_to(self.prefix, target_is_directory=True)
        self.assertEqual(self.convert(alias / "drive_c/a.STEP"), "C:\\a.STEP")

    def test_other_mac_paths_and_boundary_are_z(self):
        for path in (self.root / "out.STEP", self.prefix / "drive_c-other/a.STEP"):
            self.assertEqual(self.convert(path), "Z:" + str(path).replace("/", "\\"))

    def test_dotdot_and_symlink_escape_are_not_c(self):
        external = self.root / "external"
        external.mkdir()
        (self.prefix / "drive_c/outside").symlink_to(external, target_is_directory=True)
        for path in (
            self.prefix / "drive_c/outside/a.STEP",
            self.prefix / "drive_c/../../external/a.STEP",
        ):
            self.assertEqual(
                self.convert(path), "Z:" + str(external / "a.STEP").replace("/", "\\")
            )

    def test_relative_path_uses_actual_working_directory(self):
        previous = Path.cwd()
        try:
            os.chdir(self.prefix / "drive_c")
            self.assertEqual(self.convert("models/a.STEP"), "C:\\models\\a.STEP")
        finally:
            os.chdir(previous)

    def test_windows_paths_are_unchanged(self):
        for value in (
            "C:\\models\\a.SLDPRT",
            "D:/models/a.STEP",
            "\\\\server\\share\\a.STEP",
        ):
            self.assertEqual(self.convert(value), value)

    def test_launcher_prefix_environment(self):
        with patch.dict(os.environ, {"WINEPREFIX": str(self.prefix)}):
            self.assertEqual(
                translate(str(self.prefix / "drive_c/a.STEP")), "C:\\a.STEP"
            )

    def test_no_z_drive_is_required_for_c(self):
        (self.devices / "z:").unlink()
        self.assertEqual(self.convert(self.prefix / "drive_c/a.STEP"), "C:\\a.STEP")
        with self.assertRaisesRegex(ValueError, "no configured Wine drive"):
            self.convert(self.root / "unmapped.STEP")

    def test_custom_drive_without_z(self):
        (self.devices / "z:").unlink()
        workspace = self.root / "workspace"
        workspace.mkdir()
        (self.devices / "h:").symlink_to(workspace, target_is_directory=True)
        self.assertEqual(self.convert(workspace / "a.STEP"), "H:\\a.STEP")

    def test_most_specific_root_and_ignored_raw_device(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        (self.devices / "h:").symlink_to(workspace, target_is_directory=True)
        (self.devices / "d::").symlink_to(workspace, target_is_directory=True)
        (self.devices / "e:").symlink_to("/missing-drive", target_is_directory=True)
        self.assertEqual(self.convert(workspace / "a.STEP"), "H:\\a.STEP")

    def test_missing_mapping_directory_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            translate(str(self.root / "a.STEP"), prefix=str(self.root / "missing"))


if __name__ == "__main__":
    unittest.main()
