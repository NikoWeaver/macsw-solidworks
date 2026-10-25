"""The rebuilt PE modules ship stripped (scripts/lib/strip_pe.sh); no keys, Wine or SOLIDWORKS needed."""
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
LIB = PROJECT / "scripts/lib/strip_pe.sh"
MINGW = {"x86_64": "x86_64-w64-mingw32-gcc", "i386": "i686-w64-mingw32-gcc"}
STRIPPERS = {"x86_64": "x86_64-w64-mingw32-strip", "i386": "i686-w64-mingw32-strip"}


def tool(name):
    return shutil.which(name) or (str(Path("/opt/homebrew/bin") / name) if (Path("/opt/homebrew/bin") / name).exists() else None)


def bash(script, *args):
    return subprocess.run(["bash", "-c", f'source "{LIB}"\n{script}', "bash", *args],
                          capture_output=True, text=True)


def pe_header(path):
    data = path.read_bytes()
    pe = int.from_bytes(data[60:64], "little")
    return data, pe, int.from_bytes(data[pe + 12:pe + 16], "little"), int.from_bytes(data[pe + 16:pe + 20], "little")


class StripWiringTests(unittest.TestCase):
    """package_app.sh strips every rebuilt PE module before the manifest hashes them."""

    @classmethod
    def setUpClass(cls):
        cls.package = (PROJECT / "scripts/package_app.sh").read_text()
        cls.verify = (PROJECT / "scripts/verify_app.sh").read_text()

    def test_strip_runs_after_the_copies_and_before_the_manifest_hashes(self):
        strip = self.package.index('macsw_strip_pe \\')
        self.assertGreater(strip, self.package.index('cp "${OPENGL32_PATCH}" "${OPENGL32_TARGET}"'))
        self.assertLess(strip, self.package.index('WINEMAC_MODULE_SHA256="$(shasum'))
        self.assertLess(strip, self.package.index('KERNELBASE_MODULE_SHA256="$(shasum'))
        self.assertIn('source "${WORKSPACE_ROOT}/scripts/lib/strip_pe.sh"', self.package)
        self.assertIn('MACSW_STRIP_PE:-1', self.package)

    def test_every_rebuilt_pe_module_is_stripped_and_pinned_mono_files_are_not(self):
        call = self.package.split("macsw_strip_pe \\\n", 1)[1].split("\nfi", 1)[0]
        stripped = set(re.findall(r"\$\{([A-Z0-9_]+_TARGET)\}", call))
        copied = set(re.findall(r'cp "\$\{[A-Z0-9_]+_PATCH\}" "\$\{([A-Z0-9_]+_TARGET)\}"', self.package))
        pe_copied = {t for t in copied if t not in {"WINEMAC_TARGET", "WIN32U_TARGET", "NTDLL_TARGET",
                                                    "OPENGL32_UNIX_TARGET", "WINESERVER_TARGET"}}
        self.assertEqual(stripped, pe_copied)
        self.assertEqual(len(stripped), 16)
        # regasm.exe and the Mono files are pinned by SHA-256 in versions.env: stripping would break the pins.
        for pinned in ("regasm", "MONO_", "libmono", "mscorlib"):
            self.assertNotIn(pinned, call)

    def test_manifest_records_it_and_verify_checks_the_same_modules(self):
        self.assertIn(":PEModulesStripped bool true", self.package)
        self.assertIn(":PEModulesStripped bool false", self.package)
        call = self.package.split("macsw_strip_pe \\\n", 1)[1].split("\nfi", 1)[0]
        wanted = {re.sub(r"_TARGET$", "", t) for t in re.findall(r"\$\{([A-Z0-9_]+_TARGET)\}", call)}
        checked = set(re.findall(r'"\$\{([A-Z0-9_]+)_MODULE\}"', self.verify.split("PEModulesStripped", 1)[1].split("esac", 1)[0]))
        self.assertEqual(checked - {"STRIPPED"}, wanted)
        self.assertIn("macsw_pe_stripped", self.verify)

    def test_verify_compares_the_stripped_dist_modules(self):
        # dist/winemac-* keeps the unstripped build; the packaged module must equal its stripped copy.
        self.assertNotIn('cmp "${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/', self.verify)
        self.assertEqual(len(re.findall(r"^cmp_pe_module ", self.verify, re.M)), 16)
        self.assertIn("macsw_strip_pe", self.verify.split("cmp_pe_module() {", 1)[1].split("\n}\n", 1)[0])

    def test_bottle_identity_ignores_the_new_key(self):
        # wine_runtime.identity() only takes string values of "Wine*"/"Mono*" keys: a bool must not change receipts.
        self.assertNotRegex(self.package, r'Add :Wine\w*Strip')
        self.assertIn("PEModulesStripped bool", self.package)


@unittest.skipUnless(all(tool(MINGW[a]) and tool(STRIPPERS[a]) for a in MINGW), "MinGW-w64 toolchain not installed")
class StripBehaviourTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-strip-pe-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def dll(self, arch, mark=True):
        source = self.root / "m.c"
        source.write_text("int __declspec(dllexport) answer(int x){ volatile int y = x * 3; return y + 39; }\n"
                          "int __stdcall DllMain(void *h, unsigned long r, void *p){ return 1; }\n")
        out = self.root / f"{arch}-{'marked' if mark else 'plain'}.dll"
        subprocess.run([tool(MINGW[arch]), "-g", "-O1", "-shared", "-o", str(out), str(source)], check=True,
                       capture_output=True)
        if mark:  # winebuild --builtin writes this into the DOS header gap
            data = bytearray(out.read_bytes())
            data[64:64 + 16] = b"Wine builtin DLL"
            out.write_bytes(bytes(data))
        return out

    def test_strip_removes_symbols_keeps_mark_and_loadable_layout(self):
        for arch in ("x86_64", "i386"):
            with self.subTest(arch=arch):
                dll = self.dll(arch)
                before, pe, symtab, nsyms = pe_header(dll)
                self.assertTrue(symtab and nsyms, "test DLL should carry a COFF symbol table")
                self.assertEqual(bash('macsw_pe_stripped "$1"', str(dll)).returncode, 1)
                self.assertEqual(bash('macsw_pe_arch "$1"', str(dll)).stdout.strip(), arch)
                run = bash('macsw_strip_pe "$1"', str(dll))
                self.assertEqual(run.returncode, 0, run.stderr)
                after, pe2, symtab2, nsyms2 = pe_header(dll)
                self.assertEqual(nsyms2, 0)  # the symbol-table pointer is left at the end of the file by binutils
                self.assertLess(len(after), len(before))
                self.assertEqual(after[64:80], b"Wine builtin DLL")
                self.assertEqual(after[:2], b"MZ")
                self.assertEqual(after[pe2:pe2 + 4], b"PE\0\0")
                # same sections the loader maps: name, virtual address, virtual size
                def sections(data, pe_off):
                    count = int.from_bytes(data[pe_off + 6:pe_off + 8], "little")
                    opt = int.from_bytes(data[pe_off + 20:pe_off + 22], "little")
                    table = pe_off + 24 + opt
                    return {data[table + 40 * i:table + 40 * i + 8].rstrip(b"\0"):
                            (int.from_bytes(data[table + 40 * i + 12:table + 40 * i + 16], "little"),
                             int.from_bytes(data[table + 40 * i + 8:table + 40 * i + 12], "little"))
                            for i in range(count)}
                kept = sections(after, pe2)
                original = sections(before, pe)
                for name, geometry in kept.items():
                    self.assertEqual(original[name], geometry)
                self.assertTrue({b".text", b".edata"} <= set(kept))
                self.assertFalse([n for n in kept if n.startswith(b".debug") or n.startswith(b"/")])
                self.assertEqual(bash('macsw_pe_stripped "$1"', str(dll)).returncode, 0)

    def test_strip_is_reproducible_and_keeps_the_link_time_stamp(self):
        # binutils stamps the current time unless SOURCE_DATE_EPOCH is set; the output must depend on the input only,
        # or every packaging run would change the module hashes that are the bottle's runtime identity.
        first, second = self.dll("x86_64"), self.root / "second.dll"
        second.write_bytes(first.read_bytes())
        stamp_before = pe_header(first)[0][pe_header(first)[1] + 8:pe_header(first)[1] + 12]
        self.assertEqual(bash('macsw_strip_pe "$1"', str(first)).returncode, 0)
        time.sleep(2.2)
        self.assertEqual(bash('macsw_strip_pe "$1"', str(second)).returncode, 0)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        data, pe, _, _ = pe_header(first)
        self.assertEqual(data[pe + 8:pe + 12], stamp_before)

    def test_strip_twice_is_harmless(self):
        dll = self.dll("x86_64")
        self.assertEqual(bash('macsw_strip_pe "$1"', str(dll)).returncode, 0)
        once = dll.read_bytes()
        self.assertEqual(bash('macsw_strip_pe "$1"', str(dll)).returncode, 0)
        self.assertEqual(dll.read_bytes(), once)
        self.assertEqual(bash('macsw_pe_stripped "$1"', str(dll)).returncode, 0)

    def test_file_without_the_builtin_mark_is_refused(self):
        dll = self.dll("x86_64", mark=False)
        run = bash('macsw_strip_pe "$1"', str(dll))
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("builtin", run.stderr)

    def test_missing_strip_tool_is_a_clear_error(self):
        dll = self.dll("i386")
        run = bash('PATH=/usr/bin:/bin MACSW_STRIP_I386=/nonexistent/strip macsw_strip_pe "$1"', str(dll))
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(pe_header(dll)[2] != 0, True, "an unstripped file must stay as it was")

    def test_not_a_pe_file_is_rejected(self):
        junk = self.root / "junk.dll"
        junk.write_bytes(b"not a pe file at all" * 20)
        self.assertNotEqual(bash('macsw_pe_arch "$1"', str(junk)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
