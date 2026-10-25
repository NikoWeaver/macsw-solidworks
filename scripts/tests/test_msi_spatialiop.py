"""The SpatialIOP MSI helper (docs/spatialiop-fix.md).

The wiring tests always run. The fixture tests build the helper with MinGW and run it under Wine on
tiny MSIs made with Wine's msidb; they run only when MACSW_TEST_WINE_RUNTIME names a Wine runtime
root (for example runtime/wine-11.16-macsw). MACSW_TEST_WINE_PREFIX reuses a prefix; without it a
temporary one is made with wineboot.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCE = PROJECT / 'native/msi_spatialiop.c'
ACTIONS = ('CopySpatialIOP', 'set_InstallSpatialIOP', 'InstallSpatialIOP')
ORIGINAL = 'NOT REMOVE~="ALL"'

SEQUENCE_HEADER = 'Action\tCondition\tSequence\ns72\tS255\tI2\nInstallExecuteSequence\tAction\n'
CUSTOM_ACTION_HEADER = 'Action\tType\tSource\tTarget\ns72\ti2\tS72\tS255\nCustomAction\tAction\n'
CUSTOM_ACTIONS = {
    'CopySpatialIOP': (1, 'SwInst', 'WIDll_CopySpatialIOP'),
    'set_InstallSpatialIOP': (51, 'InstallSpatialIOP', '[SpatialIOPTempFile];$[SPIOP]files'),
    'InstallSpatialIOP': (3073, 'SwInst', 'WIDll_InstallSpatialIOP'),
}


class HelperWiringTests(unittest.TestCase):
    def test_helper_knows_exactly_the_three_actions_and_both_conditions(self):
        source = SOURCE.read_text()
        for action, (kind, origin, target) in CUSTOM_ACTIONS.items():
            self.assertIn(f'{{ L"{action}", {kind}, L"{origin}", L"{target}" }}', source)
        self.assertIn('#define ORIGINAL_CONDITION L"NOT REMOVE~=\\"ALL\\""', source)
        self.assertIn('#define DISABLED_CONDITION L"0"', source)
        self.assertIn('MSIDBOPEN_TRANSACT', source)
        self.assertIn('MSIDBOPEN_READONLY', source)
        # Refusals return before the only commit.
        disable = source.split('static int disable(', 1)[1]
        self.assertLess(disable.index('inspect(database, states)'), disable.index('MsiDatabaseCommit'))

    def test_helper_is_built_shipped_and_verified(self):
        build = (PROJECT / 'scripts/build_msi_spatialiop_helper.sh').read_text()
        package = (PROJECT / 'scripts/package_app.sh').read_text()
        verify = (PROJECT / 'scripts/verify_app.sh').read_text()
        for flag in ('-lmsi', '--no-insert-timestamp', ' -s ', '-Werror'):
            self.assertTrue(flag in build, flag)
        self.assertTrue('msi-helper:' in (PROJECT / 'Makefile').read_text())
        # package_app.sh builds it before its input check, then ships it next to the other resources.
        self.assertLess(package.index('build_msi_spatialiop_helper.sh'), package.index('require_file "${PACKAGE_INPUT}"'))
        self.assertTrue('cp -p "${MSI_SPATIALIOP_HELPER}" "${RESOURCES_DIR}/helpers/msi_spatialiop.exe"' in package)
        self.assertTrue('Resources/helpers/msi_spatialiop.exe' in verify)
        swift = (PROJECT / 'macos/Bootstrap/Sources/MacSWCore/Support/SpatialIOP.swift').read_text()
        self.assertTrue('"Contents/Resources/helpers/msi_spatialiop.exe"' in swift)


def wine_runtime():
    root = os.environ.get('MACSW_TEST_WINE_RUNTIME')
    if not root:
        return None
    loader = Path(root) / 'lib/wine/x86_64-unix/MacSW'
    if not loader.exists():
        loader = Path(root) / 'lib/wine/x86_64-unix/wine'
    return Path(root), loader


@unittest.skipUnless(wine_runtime() and shutil.which('x86_64-w64-mingw32-gcc'),
                     'set MACSW_TEST_WINE_RUNTIME (and install mingw-w64) to run the helper under Wine')
class HelperFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='macsw-msi-spatialiop-')
        cls.root = Path(cls.temporary.name)
        cls.helper = cls.root / 'msi_spatialiop.exe'
        subprocess.run(['x86_64-w64-mingw32-gcc', '-Os', '-municode', '-Wall', '-Wextra', '-Werror',
                        '-o', str(cls.helper), str(SOURCE), '-lmsi'], check=True)
        runtime, loader = wine_runtime()
        cls.environment = {
            'HOME': os.environ.get('HOME', '/tmp'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'WINEPREFIX': os.environ.get('MACSW_TEST_WINE_PREFIX') or str(cls.root / 'prefix'),
            'WINELOADER': str(loader), 'WINESERVER': str(runtime / 'bin/wineserver'),
            'WINEDLLOVERRIDES': 'mscoree,mshtml=', 'WINEDEBUG': '-all',
        }
        cls.loader = str(loader)
        if not (Path(cls.environment['WINEPREFIX']) / 'system.reg').exists():
            subprocess.run([cls.loader, 'wineboot', '-u'], env=cls.environment, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        subprocess.run([cls.environment['WINESERVER'], '-w'], env=cls.environment, check=False)
        cls.temporary.cleanup()

    @staticmethod
    def windows(path):
        return 'Z:' + str(path).replace('/', '\\')

    def wine(self, *arguments):
        result = subprocess.run([self.loader, *arguments], env=self.environment, capture_output=True, text=True)
        return result.returncode, result.stdout.replace('\r', '')

    def make_msi(self, conditions, custom_actions=CUSTOM_ACTIONS):
        """An MSI with an InstallExecuteSequence row per (action, condition) and the given CustomAction rows."""
        folder = Path(tempfile.mkdtemp(dir=self.root))
        rows = ''.join(f'{action}\t{condition}\t{6543 + index}\n' for index, (action, condition) in enumerate(conditions))
        (folder / 'InstallExecuteSequence.idt').write_text(SEQUENCE_HEADER + rows + 'InstallFinalize\t\t6600\n')
        actions = ''.join(f'{action}\t{kind}\t{origin}\t{target}\n'
                          for action, (kind, origin, target) in custom_actions.items())
        (folder / 'CustomAction.idt').write_text(CUSTOM_ACTION_HEADER + actions)
        msi = folder / 'package.msi'
        code, output = self.wine('msidb.exe', '-c', '-d', self.windows(msi), '-f', self.windows(folder),
                                 '-i', 'InstallExecuteSequence.idt', 'CustomAction.idt')
        self.assertEqual(code, 0, output)
        return msi

    def exported_conditions(self, msi):
        folder = Path(tempfile.mkdtemp(dir=self.root))
        code, output = self.wine('msidb.exe', '-d', self.windows(msi), '-f', self.windows(folder),
                                 '-e', 'InstallExecuteSequence')
        self.assertEqual(code, 0, output)
        lines = (folder / 'InstallExecuteSequence.idt').read_text().replace('\r', '').splitlines()[3:]
        return {line.split('\t')[0]: line.split('\t')[1] for line in lines}

    def assert_refused(self, msi, expected_code, expected_text):
        before = hashlib.sha256(msi.read_bytes()).hexdigest()
        code, output = self.wine(str(self.helper), self.windows(msi))
        self.assertEqual(code, expected_code, output)
        self.assertIn(expected_text, output)
        self.assertEqual(hashlib.sha256(msi.read_bytes()).hexdigest(), before, 'a refused package must stay unchanged')

    def test_disables_the_three_actions_and_is_idempotent(self):
        msi = self.make_msi([(action, ORIGINAL) for action in ACTIONS])
        code, output = self.wine(str(self.helper), '--check', self.windows(msi))
        self.assertEqual(code, 8, output)
        code, output = self.wine(str(self.helper), self.windows(msi))
        self.assertEqual(code, 0, output)
        for action in ACTIONS:
            self.assertIn(f"{action}: condition '{ORIGINAL}' -> '0'", output)
        conditions = self.exported_conditions(msi)
        self.assertEqual([conditions[action] for action in ACTIONS], ['0', '0', '0'])
        self.assertEqual(conditions['InstallFinalize'], '')
        code, output = self.wine(str(self.helper), self.windows(msi))
        self.assertEqual(code, 0, output)
        self.assertIn('changed 0 of 3', output)
        code, output = self.wine(str(self.helper), '--check', self.windows(msi))
        self.assertEqual(code, 0, output)

    def test_finishes_a_partly_edited_package(self):
        msi = self.make_msi([('CopySpatialIOP', '0'), ('set_InstallSpatialIOP', ORIGINAL), ('InstallSpatialIOP', ORIGINAL)])
        code, output = self.wine(str(self.helper), self.windows(msi))
        self.assertEqual(code, 0, output)
        self.assertIn("CopySpatialIOP: condition is already '0'", output)
        self.assertIn('changed 2 of 3', output)

    def test_package_without_the_actions_is_left_alone(self):
        self.assert_refused(self.make_msi([], custom_actions={}), 3, 'none of the SpatialIOP actions')

    def test_refuses_when_an_action_is_missing(self):
        self.assert_refused(self.make_msi([(action, ORIGINAL) for action in ACTIONS[:2]]), 4,
                            'InstallSpatialIOP: missing from InstallExecuteSequence')

    def test_refuses_an_unknown_condition(self):
        msi = self.make_msi([('CopySpatialIOP', ORIGINAL), ('set_InstallSpatialIOP', ORIGINAL),
                             ('InstallSpatialIOP', 'NOT Installed')])
        self.assert_refused(msi, 5, "InstallSpatialIOP: unknown condition 'NOT Installed'")

    def test_refuses_an_unknown_custom_action(self):
        changed = dict(CUSTOM_ACTIONS, InstallSpatialIOP=(3073, 'SwInst', 'WIDll_InstallSpatialIOP2'))
        msi = self.make_msi([(action, ORIGINAL) for action in ACTIONS], custom_actions=changed)
        self.assert_refused(msi, 6, 'InstallSpatialIOP: unknown custom action')


if __name__ == '__main__':
    unittest.main()
