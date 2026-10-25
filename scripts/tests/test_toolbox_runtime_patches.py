"""Offline wiring guards; native probes and real GUI remain separate gates."""
from pathlib import Path
import importlib.util
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class ToolboxRuntimePatchTests(unittest.TestCase):
    def test_ccw_probe_covers_repeated_release_and_reacquisition(self):
        probe = (PROJECT/'native/mono_ccw_release_probe.cs').read_text()
        for fragment in ('CCW_RELEASE_PROBE_PASS','repeated-over-release','reacquire','GC.KeepAlive'):
            self.assertIn(fragment, probe)

    def test_shared_engines_are_downloaded_and_verified_without_local_patching(self):
        config = (PROJECT/'scripts/lib/config.sh').read_text()
        fetch = (PROJECT/'scripts/fetch_dependencies.sh').read_text()
        self.assertIn('${MONO_PATCH_RELEASE}/libmono-2.0-x86_64.dll', config)
        self.assertIn('${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll', config)
        self.assertIn('${MONO_X64_SHA256}', fetch)
        self.assertIn('${MONO_SOURCE_SHA256}', fetch)
        for script in ('scripts/package_app.sh','scripts/verify_app.sh'):
            text = (PROJECT/script).read_text()
            for fragment in ('MonoCCWModuleSHA256','MonoBTLSModuleSHA256', 'MonoSourceSHA256', 'MONO_X64_SHA256'):
                self.assertIn(fragment,text)
            self.assertNotIn('build_mono_ccw.sh', text)
            self.assertNotIn('0001-cominterop-ccw-release-zero.patch', text)
        make = (PROJECT/'Makefile').read_text()
        self.assertNotIn('mono-ccw:',make)
        workflow = (PROJECT/'.github/workflows/build-app.yml').read_text()
        self.assertNotIn('scripts/build_mono_ccw.sh',workflow)
        self.assertNotIn('patches/wine-mono/**',workflow)
        self.assertFalse((PROJECT/'scripts/build_mono_ccw.sh').exists())
        self.assertFalse((PROJECT/'patches/wine-mono/0001-cominterop-ccw-release-zero.patch').exists())

    def test_native_marker_is_required_even_when_process_exits_zero(self):
        spec = importlib.util.spec_from_file_location('toolbox_native',PROJECT/'scripts/ci/verify-toolbox-native.py')
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        marker = 'CCW_RELEASE_PROBE_PASS'
        native.validate_output('initial-addref=2\r\n'+marker+'\r\n',marker,0)
        for output, code in (('Assertion at ccw_release',0),(marker,1),('',0),('prefix '+marker,0),
                             (marker+'\nAssertion at release',0),(marker+'\nUnhandled Exception',0),
                             (marker+'\nNative Crash Reporting',0)):
            with self.subTest(output=output,code=code), self.assertRaises(RuntimeError):
                native.validate_output(output,marker,code)
        workflow = (PROJECT/'.github/workflows/build-app.yml').read_text()
        self.assertLess(workflow.index('- name: Verify packaged Toolbox runtime primitives'),workflow.index('- name: Upload MacSW App Artifact'))
        self.assertNotIn('mono_ccw_release_probe', (PROJECT/'scripts/package_app.sh').read_text())


if __name__ == '__main__':
    unittest.main()
