"""Validate the public Wine compatibility patch; never launch Wine in these tests."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = PROJECT / "patches/wine-crossover/0007-combase-wait-solidworks-registration.patch"


class WineCOMActivationTests(unittest.TestCase):
    def test_module_build_package_and_verification_are_connected(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${COM_PATCH}"', build)
        self.assertIn("dlls/combase/x86_64-windows/combase.dll", build)
        self.assertIn("${COM_PATCH_SHA256}:${SCRIPT_SHA256}", build)
        self.assertIn('[ -f "${COMBASE_OUTPUT}" ]', build)
        self.assertIn('cp "${COMBASE_PATCH}" "${COMBASE_TARGET}"', package)
        self.assertIn("lib/wine/x86_64-windows/combase.dll", package)
        for key in ("WineCOMActivationPatchSHA256", "WineCOMBaseModuleSHA256"):
            self.assertIn(key, package)
            self.assertIn(key, verify)
        self.assertIn('cmp_pe_module combase.dll ', verify)
        self.assertIn("file \"${COMBASE_MODULE}\" | grep -q 'PE32+ executable.*x86-64'", verify)
        self.assertIn("'scripts/build_winemac.sh', 'patches/wine-crossover/**'", workflow)

    def test_last_attempt_success_is_not_discarded(self):
        patch = PATCH.read_text()
        self.assertIn("-    if (!objref || tries >= MAXTRIES)", patch)
        self.assertIn("+    if (!objref)", patch)
        # No extra server activation or ROT fallback is added by the patch.
        additions = [line[1:] for line in patch.splitlines() if line.startswith("+")]
        self.assertFalse(any("create_server(" in line or "GetActiveObject(" in line for line in additions))

    @unittest.skipUnless(shutil.which("cc"), "C compiler required")
    def test_timeout_parser_and_clsid_scope(self):
        additions = "\n".join(line[1:] for line in PATCH.read_text().splitlines()
                              if line.startswith("+") and not line.startswith("+++"))
        helper = additions[:additions.index("    const unsigned int MAXTRIES")]
        source = r'''
#include <assert.h>
#include <string.h>
#include <wchar.h>
typedef unsigned int DWORD;
typedef int BOOL;
typedef wchar_t WCHAR;
typedef struct { unsigned int a; unsigned short b,c; unsigned char d[8]; } GUID;
typedef const GUID *REFCLSID;
#define FALSE 0
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define max(a,b) ((a)>(b)?(a):(b))
#define IsEqualGUID(a,b) (!memcmp(a,b,sizeof(GUID)))
static const WCHAR *setting;
static DWORD GetEnvironmentVariableW(const WCHAR *name, WCHAR *out, DWORD size) {
    assert(!wcscmp(name,L"WINE_SOLIDWORKS_STARTUP_TIMEOUT"));
    if (!setting) return 0;
    if (wcslen(setting)>=size) return wcslen(setting)+1;
    wcscpy(out,setting); return wcslen(setting);
}
''' + helper + r'''
int main(void) {
    const GUID sw={0x6af263bb,0xeb9f,0x4176,{0x89,0xe9,0x4f,0x89,0x2e,0xb0,0xca,0x3d}};
    const GUID other={0};
    assert(local_server_wait_seconds(&sw)==300);
    assert(local_server_wait_seconds(&other)==30);
    const struct { const WCHAR *value; unsigned int seconds; } cases[]={
        {L"150",150},{L"0",1},{L"0.1",1},{L"12.01",13},{L"12.00",12},
        {L"3600",3600},{L"3600.000",3600},{L"-1",30},{L"abc",30},
        {L"12s",30},{L".5",30},{L"12.",30},{L"3600.1",30},{L"3601",30},
        {L" 150",30},{L"150 ",30},
        {L"99999999999999999999999999999999999999999999999999999999999999999999",30}
    };
    for (unsigned int i=0;i<ARRAY_SIZE(cases);i++) {
        setting=cases[i].value;
        assert(local_server_wait_seconds(&sw)==cases[i].seconds);
        assert(local_server_wait_seconds(&other)==30);
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "timeout.c").write_text(source)
            subprocess.run(["cc", "-std=c99", "-Wall", "-Werror", str(root / "timeout.c"),
                            "-o", str(root / "timeout")], check=True, capture_output=True)
            subprocess.run([str(root / "timeout")], check=True)


if __name__ == "__main__":
    unittest.main()
