import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("runtime_sync", PROJECT / "scripts/swcli/swcli_runtime.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class RuntimeSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-runtime-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.contents = self.root / "MacSW.app/Contents"
        self.resources = self.contents / "Resources/SWCLI"
        self.source = self.resources / "runtime/Python311"
        self.prefix = self.root / "bottle"
        self.target = self.prefix / "drive_c/MacSW/Python311"
        (self.prefix / "drive_c").mkdir(parents=True)
        for name in SYNC.REQUIRED:
            file = self.source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("new " + name)
        self.manifest()

    def manifest(self, commit="new-commit"):
        self.expected = SYNC.build_manifest(self.source, "0.1.0a6", commit)
        (self.resources / "runtime-manifest.json").write_text(json.dumps(self.expected))

    def sync(self, **kwargs):
        return SYNC.synchronize(self.contents, self.prefix, in_use=kwargs.pop("in_use", lambda: False), **kwargs)

    def test_fresh_deployment_and_same_version_do_not_rewrite(self):
        self.assertTrue(self.sync())
        original = (self.target / "python.exe").stat()
        self.assertFalse(self.sync(in_use=lambda: self.fail("no-op must not probe Wine")))
        self.assertEqual(original, (self.target / "python.exe").stat())

    def test_commit_change_replaces_whole_runtime_and_keeps_backup(self):
        self.sync()
        (self.target / "obsolete.py").write_text("old")
        (self.source / "python.exe").write_text("newer")
        self.manifest("newer-commit")
        self.assertTrue(self.sync())
        self.assertFalse((self.target / "obsolete.py").exists())
        self.assertEqual((self.target / "python.exe").read_text(), "newer")
        self.assertTrue((self.target.parent / ".Python311.previous/obsolete.py").exists())

    def test_missing_or_modified_file_repairs_even_with_current_stamp(self):
        self.sync()
        (self.target / "pythonw.exe").unlink()
        self.assertTrue(self.sync())
        (self.target / "python.exe").write_text("damaged")
        self.assertTrue(self.sync())
        self.assertEqual((self.target / "python.exe").read_text(), "new python.exe")

    def test_legacy_unstamped_runtime_is_migrated(self):
        self.target.mkdir(parents=True)
        (self.target / "legacy.py").write_text("old")
        self.assertTrue(self.sync())
        self.assertFalse((self.target / "legacy.py").exists())

    def test_running_daemon_blocks_upgrade_without_touching_old_runtime(self):
        self.sync()
        self.manifest("another-commit")
        original = (self.target / SYNC.MARKER).read_bytes()
        with self.assertRaisesRegex(RuntimeError, "daemon stop"):
            self.sync(in_use=lambda: True)
        self.assertEqual((self.target / SYNC.MARKER).read_bytes(), original)

    def test_daemon_start_during_copy_aborts_before_replacement(self):
        self.sync()
        self.manifest("another-commit")
        results = iter((False, True))
        with self.assertRaisesRegex(RuntimeError, "replacement cancelled"):
            self.sync(in_use=lambda: next(results))
        self.assertEqual(json.loads((self.target / SYNC.MARKER).read_text())["source_commit"], "new-commit")

    def test_corrupt_bundle_is_rejected_before_any_container_write(self):
        (self.source / "python.exe").write_text("tampered")
        with self.assertRaisesRegex(RuntimeError, "Verification .* failed"):
            self.sync()
        self.assertFalse(self.target.parent.exists())

    def test_missing_bottle_is_not_created(self):
        missing = self.root / "missing-bottle"
        with self.assertRaisesRegex(RuntimeError, "not initialized"):
            SYNC.synchronize(self.contents, missing, in_use=lambda: False)
        self.assertFalse(missing.exists())

    def test_copy_failure_preserves_old_files_and_cleans_staging(self):
        self.sync()
        self.manifest("another-commit")
        with patch.object(SYNC.shutil, "copytree", side_effect=OSError("copy failed")):
            with self.assertRaisesRegex(OSError, "copy failed"):
                self.sync()
        self.assertEqual(json.loads((self.target / SYNC.MARKER).read_text())["source_commit"], "new-commit")
        self.assertFalse(list(self.target.parent.glob(".Python311.install-*")))

    def test_publish_failure_rolls_back_old_runtime(self):
        self.sync()
        self.manifest("another-commit")
        original_rename = Path.rename
        def rename(path, target):
            if path.name.startswith(".Python311.install-"):
                raise OSError("rename failed")
            return original_rename(path, target)
        with patch.object(Path, "rename", rename):
            with self.assertRaisesRegex(OSError, "rename failed"):
                self.sync()
        self.assertEqual(json.loads((self.target / SYNC.MARKER).read_text())["source_commit"], "new-commit")

    def test_interrupted_rename_recovers_backup(self):
        self.sync()
        self.target.rename(self.target.parent / ".Python311.previous")
        self.assertFalse(self.sync())
        self.assertTrue((self.target / "python.exe").exists())

    def test_concurrent_deployments_are_rejected(self):
        self.target.parent.mkdir(parents=True)
        with (self.target.parent / ".swcli-runtime.lock").open("w") as lock:
            SYNC.fcntl.flock(lock, SYNC.fcntl.LOCK_EX | SYNC.fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, "Another SWCLI"):
                self.sync()

    def test_symlink_target_does_not_overwrite_external_files(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symbolic link"):
            self.sync()
        self.assertEqual((outside / "keep").read_text(), "keep")

    def test_python_caches_do_not_force_redeployment(self):
        self.sync()
        cache = self.target / "Lib/site-packages/swcli/__pycache__"
        cache.mkdir()
        (cache / "__main__.cpython-311.pyc").write_bytes(b"cache")
        self.assertFalse(self.sync())

    def test_busy_probe_is_scoped_to_prefix_and_fails_closed(self):
        with patch.object(SYNC.subprocess, "run") as run:
            captured = b'"pythonw.exe","123","Console","1","0 K"\r\n'
            def query(*args, **kwargs):
                kwargs["stdout"].write(captured)
                self.assertNotIn("capture_output", kwargs)
                return run.return_value
            run.side_effect = query
            run.return_value.returncode = 0
            self.assertTrue(SYNC.backend_in_use(self.contents, self.prefix))
            self.assertEqual(run.call_args.kwargs["env"]["WINEPREFIX"], str(self.prefix))
            captured = b"invalid tasklist output"
            with self.assertRaisesRegex(RuntimeError, "Could not parse"):
                SYNC.backend_in_use(self.contents, self.prefix)


if __name__ == "__main__":
    unittest.main()
