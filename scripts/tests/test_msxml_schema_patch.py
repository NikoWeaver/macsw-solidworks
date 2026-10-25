"""ASM save patch wiring; native validation and CAD evidence remain separate."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class MSXMLSchemaPatchTests(unittest.TestCase):
    def test_module_is_built_cached_packaged_and_verified(self):
        build = (PROJECT/'scripts/build_winemac.sh').read_text()
        package = (PROJECT/'scripts/package_app.sh').read_text()
        verify = (PROJECT/'scripts/verify_app.sh').read_text()
        for script in (build, package, verify):
            self.assertIn('0014-msxml-schema-cache-namespace.patch', script)
            self.assertIn('msxml3.dll', script)
        self.assertIn('${MSXML_SCHEMA_PATCH_SHA256}', build.split('BUILD_KEY=',1)[1].split('\n',1)[0])
        self.assertIn('[ -f "${MSXML3_OUTPUT}" ]', build)
        self.assertIn('apply --check "${MSXML_SCHEMA_PATCH}"', build)
        self.assertIn('dlls/msxml3/x86_64-windows/msxml3.dll', build)
        for script in (package, verify):
            self.assertIn('WineMSXMLSchemaPatchSHA256', script)
            self.assertIn('WineMSXML3ModuleSHA256', script)
        self.assertIn('cmp_pe_module msxml3.dll ', verify)

    def test_private_schema_adoption_preserves_validation(self):
        patch = (PROJECT/'patches/wine-crossover/0014-msxml-schema-cache-namespace.patch').read_text()
        for fragment in ('xmlHasNsProp(root, BAD_CAST "targetNamespace", NULL)',
                         'xmlGetNoNsProp', 'xmlSearchNs', 'adopt_schema_qnames',
                         'xmlFreeDoc(new_doc)', 'annotation', 'memberTypes'):
            self.assertIn(fragment, patch)
        probe = (PROJECT/'native/msxml_schema_namespace_probe.c').read_text()
        for fragment in ('XML_NAMESPACE_PROBE_PASS', 'reject-invalid', 'local-empty-namespace',
                         'named-type-and-ref', 'explicit-target', 'caller DOM changed'):
            self.assertIn(fragment, probe)
        self.assertNotIn('msxml_schema_namespace_probe', (PROJECT/'scripts/package_app.sh').read_text())


if __name__ == '__main__':
    unittest.main()
