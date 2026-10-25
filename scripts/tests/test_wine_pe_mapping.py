"""PE mapping wiring and installer bootstrap contract; no keys or SW needed."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = '0015-ntdll-probe-executable-file-mappings.patch'
MEM_RESET_PATCH = '0016-ntdll-macos-release-decommitted-memory.patch'
MSYNC_PATCH = '0017-ntdll-server-msync.patch'
SURFACES_PATCH = '0018-win32u-cross-process-window-surfaces.patch'
spec = importlib.util.spec_from_file_location('bootstrap_probe', PROJECT/'scripts/ci/verify-toolbox-native.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class PEMappingPatchTests(unittest.TestCase):
    def test_patched_ntdll_is_built_cached_packaged_and_checked(self):
        build = (PROJECT/'scripts/build_winemac.sh').read_text()
        package = (PROJECT/'scripts/package_app.sh').read_text()
        verify = (PROJECT/'scripts/verify_app.sh').read_text()
        for text in (build, package, verify):
            self.assertIn(PATCH, text)
            self.assertIn(MEM_RESET_PATCH, text)
            self.assertIn(MSYNC_PATCH, text)
            self.assertIn(SURFACES_PATCH, text)
        self.assertIn('${PE_MAPPING_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('[ -f "${NTDLL_OUTPUT}" ]', build)
        self.assertIn('apply --check "${PE_MAPPING_PATCH}"', build)
        self.assertIn('dlls/ntdll/ntdll.so', build)
        self.assertIn('cp "${NTDLL_PATCH}" "${NTDLL_TARGET}"', package)
        self.assertIn("Print :WineNtdllModuleSHA256", verify)
        self.assertIn('shasum -a 256 "${NTDLL_UNIX}"', verify)
        self.assertIn('${MEM_RESET_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        key = build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0]
        self.assertIn('${MSYNC_PATCH_SHA256}:${CROSS_PROCESS_SURFACES_PATCH_SHA256}', key)
        self.assertIn('apply --check "${CROSS_PROCESS_SURFACES_PATCH}"', build)
        self.assertLess(build.index('apply "${MSYNC_PATCH}"'), build.index('apply "${CROSS_PROCESS_SURFACES_PATCH}"'))
        for text in (package, verify):
            self.assertIn('WineCrossProcessSurfacesPatchSHA256', text)
            self.assertIn('WinePEMappingPatchSHA256', text)
            self.assertIn('WineMemResetPatchSHA256', text)

    def test_execute_access_is_probed_without_new_entitlements(self):
        patch = (PROJECT/'patches/wine-crossover'/PATCH).read_text()
        self.assertIn('+#ifdef __APPLE__', patch)
        self.assertIn('+    if (vprot & VPROT_EXEC) prot |= PROT_EXEC;', patch)
        self.assertIn('IMAGE_SCN_MEM_EXECUTE) vprot |= VPROT_EXEC;', patch)
        self.assertIn('anon_mmap_fixed( host_addr, host_size, PROT_READ | PROT_WRITE, 0 )', patch)
        self.assertNotIn('disable-executable-page-protection', (PROJECT/'resources/signing/wine.plist').read_text())
        self.assertNotIn('allow-jit', (PROJECT/'resources/signing/wine.plist').read_text())

    def test_final_signed_zip_is_tested_on_macos_15_without_signing_credentials(self):
        workflow = (PROJECT/'.github/workflows/sign-app.yml').read_text()
        child = workflow.split('  verify-signed-bootstrap:', 1)[1]
        for fragment in ('needs: sign-and-notarize', 'runs-on: macos-15',
                         'MacSW-Developer-ID-candidate', 'shasum -a 256 -c',
                         'stapler validate', '--bootstrap-only', 'sign_app.py" verify'):
            self.assertIn(fragment, child)
        self.assertNotIn('secrets.', child)
        self.assertNotIn('--sign', child)


class BootstrapProbeTests(unittest.TestCase):
    def deploy(self, prefix):
        for relative in probe.BOOTSTRAP_PE_FILES:
            path = prefix/'drive_c/windows'/relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'MZfixture-PE')

    def test_installer_absolute_path_and_both_architectures_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)/'bottle'
            calls = []
            loader = Path('/fixture/wine/MacSW')
            def run(name, args, marker=None, **kwargs):
                calls.append((name, args, marker, kwargs))
                if name == 'wineboot':
                    self.assertFalse(prefix.exists())
                    self.deploy(prefix)
            probe.initialize_prefix(run, prefix, loader)
            self.assertEqual(calls[0], ('wineboot', [loader, r'C:\windows\system32\wineboot.exe', '-u'],
                                        None, {'timeout': 240}))
            self.assertEqual([call[2] for call in calls[1:]],
                             ['WINE_BOOTSTRAP_X64_PASS', 'WINE_BOOTSTRAP_X86_PASS'])
            self.assertEqual([call[1][1] for call in calls[1:]],
                             [r'C:\windows\system32\cmd.exe', r'C:\windows\syswow64\cmd.exe'])

    def test_zero_exit_without_deployed_pe_files_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for invalid in (None, 'missing', 'empty', 'not-pe'):
                with self.subTest(invalid=invalid):
                    prefix = Path(directory)/str(invalid)
                    def run(*args, **kwargs):
                        if invalid is not None:
                            self.deploy(prefix)
                            path = prefix/'drive_c/windows'/probe.BOOTSTRAP_PE_FILES[-1]
                            if invalid == 'missing':
                                path.unlink()
                            else:
                                path.write_bytes(b'' if invalid == 'empty' else b'bad')
                    with self.assertRaisesRegex(RuntimeError, 'did not deploy a PE module'):
                        probe.initialize_prefix(run, prefix, Path('/fixture/loader'))

    def test_existing_prefix_and_boot_failure_do_not_continue(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)/'existing'
            prefix.mkdir()
            def fail(*args, **kwargs):
                raise AssertionError('Must not run against an existing prefix')
            with self.assertRaisesRegex(RuntimeError, 'fresh Wine prefix'):
                probe.initialize_prefix(fail, prefix, Path('/fixture/loader'))
            def boot_failure(*args, **kwargs):
                self.assertEqual(args[0], 'wineboot')
                raise RuntimeError('bootstrap failed')
            with self.assertRaisesRegex(RuntimeError, 'bootstrap failed'):
                probe.initialize_prefix(boot_failure, Path(directory)/'new', Path('/fixture/loader'))

    def test_noexec_error_is_not_hidden_by_a_later_success_marker(self):
        marker = 'WINE_BOOTSTRAP_X64_PASS'
        with self.assertRaises(RuntimeError):
            probe.validate_output('noexec filesystem?\n'+marker+'\n', marker, 0)


if __name__ == '__main__':
    unittest.main()
