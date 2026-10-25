"""The team admin's media manifest tool, and guards for the team wizard's trust rules."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / 'scripts/make_media_manifest.sh'
CORE = PROJECT / 'macos/Bootstrap/Sources/MacSWCore'
LINE = re.compile(r'^([0-9a-f]{64})  \./(.+)$')


def run(folder):
    return subprocess.run(['bash', str(SCRIPT), str(folder)], capture_output=True, text=True)


class MediaManifestScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'SOLIDWORKS 2026 SP04.1'
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write(self, relative, data=b'payload'):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_lists_every_visible_file_sorted_with_its_sha256(self):
        self.write('setup.exe', b'exe')
        self.write('swwi/data/solidworks.msi', b'msi')
        self.write('PreReqs/VBA/vba71.msi', b'vba')
        self.write('with space/name.txt', b'space')
        self.write('.DS_Store')
        self.write('swwi/.hidden')
        self.write('.Trashes/old.msi')
        (self.root / 'link.exe').symlink_to(self.root / 'setup.exe')
        self.write('media-manifest.sha256', b'old manifest')

        result = run(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = (self.root / 'media-manifest.sha256').read_bytes()
        lines = manifest.decode().splitlines()
        paths = [LINE.match(line).group(2) for line in lines]
        self.assertEqual(paths, ['PreReqs/VBA/vba71.msi', 'setup.exe', 'swwi/data/solidworks.msi', 'with space/name.txt'])
        for line in lines:
            digest, path = LINE.match(line).groups()
            self.assertEqual(digest, hashlib.sha256((self.root / path).read_bytes()).hexdigest())
        # The last line is the value for macsw-team.json.
        self.assertEqual(result.stdout.split()[-1], hashlib.sha256(manifest).hexdigest())
        self.assertFalse((self.root / '.media-manifest.sha256.partial').exists())

    def test_refuses_names_that_shasum_would_escape(self):
        self.write('setup.exe')
        self.write('bad\\name.cab')
        result = run(self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('bad\\name.cab', result.stderr)
        self.assertFalse((self.root / 'media-manifest.sha256').exists())

    def test_refuses_an_empty_folder_and_a_missing_argument(self):
        self.write('.DS_Store')
        self.assertNotEqual(run(self.root).returncode, 0)
        self.assertFalse((self.root / 'media-manifest.sha256').exists())
        self.assertEqual(subprocess.run(['bash', str(SCRIPT)], capture_output=True).returncode, 2)


class TeamConfigTrustTests(unittest.TestCase):
    def test_team_config_model_has_no_serial_field(self):
        # The config is shared and writable by editors: it must never carry a serial (commit 2c62301).
        for name in ('Models/TeamConfig.swift', 'Services/TeamConfigLocator.swift', 'Stores/TeamSetupStore.swift'):
            source = (CORE / name).read_text()
            self.assertIsNone(re.search(r'\b(let|var)\s+\w*serial', source, re.IGNORECASE), name)
            self.assertNotIn('InstallSerials', source, name)

    def test_example_config_holds_no_secret_and_only_relative_paths(self):
        example = json.loads((PROJECT / 'team/macsw-team.example.json').read_text())
        self.assertEqual(example['schema'], 1)
        text = json.dumps(example).lower()
        self.assertNotIn('serial', text)
        for path in (example['media']['path'], example['vba']['path'], example['updates']['feed'],
                     example['support']['guide']):
            self.assertFalse(path.startswith(('/', '~')), path)
            self.assertNotIn('..', path.split('/'))


if __name__ == '__main__':
    unittest.main()
