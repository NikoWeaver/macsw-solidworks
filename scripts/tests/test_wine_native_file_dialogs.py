"""macOS native file dialogs (patches 0023 + 0024): build, package and verify wiring."""
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
DRIVER_PATCH = "0023-winemac-native-file-dialogs.patch"
COMDLG_PATCH = "0024-comdlg32-native-file-dialogs.patch"
PATCH_KEYS = ("WineNativeFileDialogDriverPatchSHA256", "WineNativeFileDialogPatchSHA256")
MODULE_KEYS = ("WineMacDrvModuleSHA256", "WineMacDrvI386ModuleSHA256",
               "WineComdlg32ModuleSHA256", "WineComdlg32I386ModuleSHA256")
OUTPUTS = ("winemac.drv", "winemac-i386.drv", "comdlg32.dll", "comdlg32-i386.dll")


def patch_files(name):
    patch = (PROJECT / "patches/wine-crossover" / name).read_text()
    return patch, [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]


def additions(patch):
    return "\n".join(l[1:] for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++"))


class NativeFileDialogWiringTests(unittest.TestCase):
    def setUp(self):
        self.build = (PROJECT / "scripts/build_winemac.sh").read_text()
        self.package = (PROJECT / "scripts/package_app.sh").read_text()
        self.verify = (PROJECT / "scripts/verify_app.sh").read_text()

    def test_patches_are_applied_after_0022_and_pinned_in_the_build_key(self):
        for script in (self.build, self.package, self.verify):
            self.assertIn(DRIVER_PATCH, script)
            self.assertIn(COMDLG_PATCH, script)
        build_key = self.build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${MSXML_EMPTY_ELEMENT_PATCH_SHA256}:${NATIVE_FILE_DIALOG_DRIVER_PATCH_SHA256}"
                      ":${NATIVE_FILE_DIALOG_PATCH_SHA256}", build_key)
        for var in ("NATIVE_FILE_DIALOG_DRIVER_PATCH", "NATIVE_FILE_DIALOG_PATCH"):
            self.assertIn('apply --check "${%s}"' % var, self.build)
        self.assertLess(self.build.index('apply "${MSXML_EMPTY_ELEMENT_PATCH}"'),
                        self.build.index('apply "${NATIVE_FILE_DIALOG_DRIVER_PATCH}"'))
        self.assertLess(self.build.index('apply "${NATIVE_FILE_DIALOG_DRIVER_PATCH}"'),
                        self.build.index('apply "${NATIVE_FILE_DIALOG_PATCH}"'))

    def test_pe_modules_are_built_cached_and_checked_for_both_architectures(self):
        for target in ("dlls/winemac.drv/x86_64-windows/winemac.drv", "dlls/winemac.drv/i386-windows/winemac.drv",
                       "dlls/comdlg32/x86_64-windows/comdlg32.dll", "dlls/comdlg32/i386-windows/comdlg32.dll"):
            self.assertIn(target, self.build)
        # winemac.so carries the unix side and was already built and shipped.
        self.assertIn("dlls/winemac.drv/winemac.so", self.build)
        for var in ("WINEMAC_DRV_OUTPUT", "WINEMAC_DRV_I386_OUTPUT", "COMDLG32_OUTPUT", "COMDLG32_I386_OUTPUT"):
            self.assertIn('[ -f "${%s}" ]' % var, self.build)
            self.assertIn('mv "${%s}.new" "${%s}"' % (var, var), self.build)
        for var, kind in (("WINEMAC_DRV_OUTPUT", "PE32+ executable.*x86-64"),
                          ("WINEMAC_DRV_I386_OUTPUT", "PE32 executable.*Intel 80386"),
                          ("COMDLG32_OUTPUT", "PE32+ executable.*x86-64"),
                          ("COMDLG32_I386_OUTPUT", "PE32 executable.*Intel 80386")):
            self.assertIn('file "${%s}.new" | grep -q \'%s\'' % (var, kind), self.build)
        for name in OUTPUTS:
            self.assertIn('${OUTPUT_DIR}/%s"' % name, self.build)

    def test_modules_are_packaged_and_verified(self):
        for target in ("wine/lib/wine/x86_64-windows/winemac.drv", "wine/lib/wine/i386-windows/winemac.drv",
                       "wine/lib/wine/x86_64-windows/comdlg32.dll", "wine/lib/wine/i386-windows/comdlg32.dll"):
            self.assertIn(target, self.package)
        for var in ("WINEMAC_DRV", "WINEMAC_DRV_I386", "COMDLG32", "COMDLG32_I386"):
            self.assertIn('cp "${%s_PATCH}" "${%s_TARGET}"' % (var, var), self.package)
            self.assertIn('"${%s_PATCH}"' % var, self.package.split("for PACKAGE_INPUT in", 1)[1].split("; do", 1)[0])
        for key in PATCH_KEYS + MODULE_KEYS:
            self.assertIn(key, self.package)
            self.assertIn(key, self.verify)
        for name in OUTPUTS:
            self.assertIn('cmp_pe_module %s ' % name, self.verify)

    def test_pins_are_computed_from_the_patch_files(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            for key in PATCH_KEYS:
                line = next(l for l in text.splitlines() if key in l and ("Add :" in l or "Print :" in l))
                self.assertNotRegex(line, r"[0-9a-f]{64}")


class NativeFileDialogPatchTests(unittest.TestCase):
    def test_driver_patch_stays_in_winemac_and_has_a_wow64_entry(self):
        patch, files = patch_files(DRIVER_PATCH)
        self.assertEqual(sorted(files), sorted([
            "dlls/winemac.drv/Makefile.in", "dlls/winemac.drv/cocoa_filedialog.m", "dlls/winemac.drv/dllmain.c",
            "dlls/winemac.drv/macdrv_cocoa.h", "dlls/winemac.drv/macdrv_main.c", "dlls/winemac.drv/unixlib.h",
            "dlls/winemac.drv/winemac.drv.spec"]))
        added = additions(patch)
        self.assertIn("@ stdcall -private macsw_file_dialog(long long long ptr long ptr long ptr)", added)
        self.assertIn("winemac.drv.spec", added)
        self.assertIn("cocoa_filedialog.m", added)
        # Same parameter layout on 32 and 64 bit: one function in both unix call tables.
        self.assertEqual(added.count("    macdrv_file_dialog,"), 2)
        struct = added.split("struct file_dialog_params", 1)[1].split("};", 1)[0]
        self.assertNotRegex(struct, r"\b(void|char|HWND|WCHAR)\s*\*")
        # The unix call never waits for the user: the panel is started asynchronously.
        self.assertIn("OnMainThreadAsync", added)
        self.assertNotIn("runModal", added)
        self.assertIn("beginSheetModalForWindow", added)
        self.assertIn("tryToActivateIgnoringOtherApps", added)
        # A standalone panel stays at its owner's level so dialogs opened from it come up in front.
        self.assertNotIn("NSModalPanelWindowLevel", added)
        # The panel says when it is up; set-up exceptions end it without that line.
        self.assertIn('[self queueLine:@"started"];', added)
        self.assertIn("@catch", added)
        # Save panels refuse names that Windows programs cannot create.
        self.assertIn("validateURL:(NSURL*)url error:(NSError**)outError", added)
        # The test hook goes to the answer's folder and selects it (open panels) before it answers.
        run_test = added.split("- (void) runTest", 1)[1].split("- (void) present", 1)[0]
        self.assertIn("[self panel:panel didChangeToDirectoryURL:[testURLs[0] URLByDeletingLastPathComponent]];",
                      run_test)
        self.assertIn('[NSMutableString stringWithString:@"selection"]', run_test)
        self.assertIn("if (![self isSave])", run_test)
        self.assertLess(run_test.index("[self queueLine:line];"), run_test.index("testDone = YES;"))

    def test_comdlg_patch_is_gated_and_keeps_wine_dialogs_for_hooks(self):
        patch, files = patch_files(COMDLG_PATCH)
        self.assertEqual(sorted(files), sorted([
            "dlls/comdlg32/Makefile.in", "dlls/comdlg32/filedlg.c", "dlls/comdlg32/itemdlg.c",
            "dlls/comdlg32/macdlg.c", "dlls/comdlg32/macdlg.h"]))
        added = additions(patch)
        self.assertIn('get_env(L"MACSW_NATIVE_FILE_DIALOGS")', added)
        self.assertIn('!wcscmp(value, L"1")', added)
        self.assertIn('!wcscmp(value, L"all")', added)
        # A native Show has the Wine dialog's window, hidden, from before the first event:
        # GetWindow returns it (SOLIDWORKS's sldfileopen.dll crashed without it), and a program
        # that asks for it while the dialog opens gets the visible Wine dialog unless "all".
        self.assertIn("This->native_window_asked = TRUE;\n+        if (!This->dlg_hwnd) return E_FAIL;", patch)
        self.assertNotIn("This->native_window_asked = TRUE;\n+        return E_FAIL;", patch)
        self.assertIn("if (This->native_window_asked && !macdlg_everywhere())", added)
        show = added.split("static BOOL native_dialog_show", 1)[1]
        self.assertLess(show.index("This->native_active = TRUE;"), show.index("events_OnFolderChanging(This, folder);"))
        self.assertLess(show.index("macdlg_disable_owner(&owner_state, owner);"),
                        show.index("native_shadow_create(This, owner)"))
        self.assertLess(show.index("native_shadow_create(This, owner)"),
                        show.index("events_OnFolderChanging(This, folder);"))
        self.assertIn("if (This->native_active) return E_UNEXPECTED;", added)
        # The hidden window: same template without WS_VISIBLE, no browser, no focus, kept
        # hidden and inactive, never ended with EndDialog, destroyed after OnFileOk.
        shadow = added.split("static BOOL native_shadow_create", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("MAKEINTRESOURCEW(NEWFILEOPENV3ORD)", shadow)
        self.assertIn("&= ~WS_VISIBLE;", shadow)
        self.assertIn("CreateDialogIndirectParamW(", shadow)
        self.assertIn("if (!This->native_shadow)\n+        init_explorerbrowser(This);", patch)
        self.assertIn("((WINDOWPOS *)lparam)->flags &= ~SWP_SHOWWINDOW;", added)
        self.assertIn("((WINDOWPOS *)lparam)->flags |= SWP_NOACTIVATE;", added)
        self.assertIn("((STYLESTRUCT *)lparam)->styleNew &= ~WS_VISIBLE;", added)
        self.assertIn("ShowWindow(This->dlg_hwnd, SW_HIDE);", added)
        self.assertIn("static void end_dialog(FileDialogImpl *This, HRESULT hr)", added)
        self.assertLess(show.index("native_shadow_destroy(This);"), show.index("macdlg_restore_owner(&owner_state, TRUE);"))
        # Behind a Wine dialog (rule 5 or a panel that did not start) it stays until Show() returns.
        self.assertEqual(show.count("native_shadow_park(This);"), 2)
        # A panel that never comes up falls back to the Wine dialog.
        self.assertIn("MACDLG_NOT_STARTED", added)
        self.assertIn("if (state != MACDLG_NOT_STARTED)", added)
        self.assertIn('GetModuleHandleW(L"winemac.drv")', added)
        self.assertIn('"macsw_file_dialog"', added)
        self.assertIn("is_dialog_hooked(info) || (ofn->Flags & (OFN_ENABLETEMPLATE | OFN_ENABLETEMPLATEHANDLE))",
                      added)
        # NSOpenPanel cannot take a new file name: create-prompt open dialogs stay Wine too.
        self.assertIn("if (!save && (ofn->Flags & OFN_CREATEPROMPT)) return FALSE;", added)
        self.assertIn("(This->options & FOS_CREATEPROMPT)) return FALSE;", added)
        # Every native entry point falls back to the Wine dialog when the panel cannot start.
        self.assertIn("if (!native_get_file_name(info, FALSE, &ret))\n            ret = GetFileName95(info);", added)
        self.assertIn("if (!native_get_file_name(info, TRUE, &ret))\n            ret = GetFileName95(info);", added)
        self.assertIn("+    if (native_dialog_show(This, hwndOwner, &hr, &parked))\n+        return hr;\n+\n"
                      "+    hr = create_dialog(This, hwndOwner);\n+    if (parked)\n+        native_shadow_destroy(This);",
                      patch)
        # A modal loop that keeps the thread's messages flowing.
        self.assertIn("MsgWaitForMultipleObjectsEx", added)
        self.assertIn("PostQuitMessage", added)
        self.assertIn("EnableWindow(owner, FALSE)", added)
        for env in ("MACSW_NATIVE_FILE_DIALOG_TEST", "MACSW_NATIVE_FILE_DIALOG_TEST_DELAY_MS",
                    "MACSW_NATIVE_FILE_DIALOG_TEST_TYPE", "MACSW_NATIVE_FILE_DIALOG_TEST_CONTROLS"):
            self.assertIn('L"%s"' % env, added)

    def test_ops_match_between_comdlg32_and_the_driver(self):
        driver = additions(patch_files(DRIVER_PATCH)[0])
        comdlg = additions(patch_files(COMDLG_PATCH)[0])
        driver_ops = re.findall(r"MACDRV_FILE_DIALOG_(\w+),", driver.split("enum macdrv_file_dialog_op", 1)[1])
        comdlg_ops = re.findall(r"MACDLG_(\w+),", comdlg.split("enum macdrv_file_dialog_op in", 1)[1])
        self.assertEqual(driver_ops, ["BEGIN", "POLL", "UPDATE", "CANCEL", "RELEASE"])
        self.assertEqual(comdlg_ops[:5], driver_ops)


class NativeFileDialogProbeTests(unittest.TestCase):
    def test_probe_builds_for_both_architectures(self):
        script = (PROJECT / "scripts/build_wine_file_dialog_probe.sh").read_text()
        self.assertIn("native/wine_file_dialog_probe.c", script)
        self.assertIn("for ARCH in x86_64 i686", script)
        self.assertIn("-Werror", script)
        source = (PROJECT / "native/wine_file_dialog_probe.c").read_text()
        for api in ("CLSID_FileOpenDialog", "CLSID_FileSaveDialog", "IFileDialogCustomize", "FOS_PICKFOLDERS",
                    "FOS_ALLOWMULTISELECT", "GetOpenFileNameW", "GetSaveFileNameW", "GetOpenFileNameA",
                    "OFN_ALLOWMULTISELECT", "OFN_ENABLEHOOK", "MACSW_NATIVE_FILE_DIALOG_TEST"):
            self.assertIn(api, source)


# Filter patterns that SOLIDWORKS 2026 gave the panel: the "patterns" arrays in the comdlg32 request traces
# (build.nosync/rc23/evidence/smoke/runs/*/wine-trace.log), the Save As types it lists
# (build.nosync/swdialogs/bottle-t1/saveas-types.txt), the bug hunt's fnm.c set, and the other entries of its
# File > Open type list. docs/sw-file-dialog-callsites.md is read as well when the outer repository is there.
FILTER_PATTERNS = (
    "*.SLDPRT", "*.SLDASM", "*.SLDDRW", "*.PRT", "*.ASM", "*.txt", "*.step", "*.stp",
    "*.asm", "*.sldasm", "*.prt", "*.sldprt", "*.slddrw", "*.3mf", "*.3dxml", "*.sat", "*.amf", "*.ai", "*.psd",
    "*.pdf", "*.asmdot", "*.prtdot", "*.drwdot", "*.dwg", "*.dxf", "*.easm", "*.eprt", "*.gltf", "*.glb", "*.hcg",
    "*.hsf", "*.ifc", "*.igs", "*.iges", "*.jpg", "*.xaml", "*.x_t", "*.x_b", "*.xmt_txt", "*.ply", "*.png",
    "*.tif", "*.wrl", "*.stl", "*.bmp", "*.analysis.eprt", "*.analysis.easm", "*.sldlfp", "*.sldxml", "*.sldblk",
    "*.prt.*", "*.asm.*", "*.xpr", "*.xas", "*.catpart", "*.CATProduct", "*.ipt", "*.iam", "*.par", "*.psm",
    "*.3dm", "*.dll", "*.PRT;*.ASM", "*.*", "*",
    # not from SOLIDWORKS: wildcard shapes the fast path must leave to the full matcher
    "*.?", "*a*", "a*", "?*.sld???", "*.", "", "Perf*", "*Test ?.*", "*[1].SLDPRT",
)
FILE_NAMES = (
    "Block Assembly 1.SLDASM", "Block Test 1.SLDPRT", "Block Test 2.SLDPRT", "Journey Asm.SLDASM",
    "Journey Base.SLDPRT", "Journey Part.SLDDRW", "Journey Part.SLDPRT", "Journey Part.pdf", "Journey Part.step",
    "Multi Config Part.SLDPRT", "Perf Assembly 9.SLDASM", "Perf Plate 50.SLDPRT",
    ".hidden.sldprt", ".sldprt", "sldprt", "noext", "lower.sldprt", "Mixed.SlDpRt", "a.prt.12", "a.PRT.3",
    "part.prt", "double..sldprt", "[bracket] Part.SLDPRT", "Part[1].SLDPRT", "Teil Ü.SLDPRT",
    "部品.sldprt", "x.analysis.eprt", "x.eprt", "Thing.STP", "file.x_t", "ends.with.dot.", "a", "",
    "star*name.sldprt", "q?.SLDASM", "back\\slash.SLDPRT", "a" * 200 + ".SLDPRT",
)
MATCH_HARNESS = r"""
#include <fnmatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
%s
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
int main(int argc, char** argv)
{
    /* argv: npatterns patterns... names... ; prints mismatches, then the worst-case time */
    int np = atoi(argv[1]), i, j, bad = 0, pairs = 0, k;
    char name[256];
    double t, worst = 0;
    for (i = 0; i < np; i++)
        for (j = 2 + np; j < argc; j++, pairs++)
            if (!filter_match(argv[2 + i], argv[j]) != !!fnmatch(argv[2 + i], argv[j], FNM_CASEFOLD))
            {
                printf("MISMATCH pattern=\"%%s\" name=\"%%s\" ours=%%d\n", argv[2 + i], argv[j], filter_match(argv[2 + i], argv[j]));
                bad++;
            }
    /* '[' and ']' are literal (Windows); fnmatch would read a bracket expression */
    if (!filter_match("*[1].SLDPRT", "Part[1].SLDPRT") || filter_match("*[1].SLDPRT", "Part1.SLDPRT")) bad++;
    memset(name, 'a', 255); name[255] = 0;
    for (k = 0; k < 200; k++)
    {
        t = now_ms();
        if (filter_match("*a*a*a*a*a*a*a*a*b", name)) bad++;
        t = now_ms() - t;
        if (t > worst) worst = t;
    }
    printf("pairs=%%d mismatches=%%d worst_ms=%%.4f\n", pairs, bad, worst);
    return bad != 0;
}
"""


def matcher_source():
    added = additions(patch_files(DRIVER_PATCH)[0])
    begin = added.index("/* MACSW_FILTER_MATCH_BEGIN")
    end = added.index("/* MACSW_FILTER_MATCH_END */")
    return added[begin:end]


class NativeFileDialogMatcherTests(unittest.TestCase):
    """F1: the open panel's listing query never calls libc fnmatch (it once kept the main thread busy for minutes)."""

    def test_driver_uses_its_own_matcher_with_a_cache(self):
        added = additions(patch_files(DRIVER_PATCH)[0])
        self.assertNotIn("fnmatch(", added)
        self.assertNotIn("<fnmatch.h>", added)
        self.assertIn("static int filter_match(const char* pattern, const char* name)", added)
        self.assertIn("static int filter_wildcard_match(const char* pattern, const char* name)", added)
        self.assertIn("filter_match(cpattern, cname)", added.split("static BOOL name_matches", 1)[1])
        enable = added.split("shouldEnableURL:(NSURL*)url\n", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("matchCache objectForKey:key", enable)
        self.assertIn('stringWithFormat:@"%ld/%@", (long)filterIndex, name', enable)
        self.assertIn("ms > 50.0", enable)
        self.assertIn("ERR(@\"shouldEnableURL took", enable)
        apply_filter = added.split("- (void) applyFilterFrom:(NSInteger)previous", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("[matchCache removeAllObjects]", apply_filter)

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64" and shutil.which("clang"),
                         "needs clang on an arm64 Mac (the matcher is compiled natively, not under Rosetta)")
    def test_matcher_agrees_with_fnmatch_and_is_fast(self):
        patterns = list(FILTER_PATTERNS)
        names = list(FILE_NAMES)
        outer = PROJECT.parent
        doc = outer / "docs/sw-file-dialog-callsites.md"
        if doc.is_file():
            patterns += sorted(set(re.findall(r"\*\.[A-Za-z0-9_.]*[A-Za-z0-9_]", doc.read_text())))
        for folder in ("build.nosync/testfiles", "build.nosync/bughunt/work"):
            if (outer / folder).is_dir():
                names += sorted(p.name for p in (outer / folder).iterdir())
        # fnmatch reads '[' ']' and '\\' in a pattern as syntax; the matcher keeps them literal, as Windows does.
        compared = [p for p in patterns if not set(p) & set("[]\\")]
        with tempfile.TemporaryDirectory() as tmp:
            src, exe = Path(tmp) / "m.c", Path(tmp) / "m"
            src.write_text(MATCH_HARNESS % matcher_source())
            subprocess.run(["clang", "-arch", "arm64", "-O2", "-Wall", "-o", str(exe), str(src)], check=True)
            out = subprocess.run([str(exe), str(len(compared))] + compared + names,
                                 capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stdout)
        result = dict(kv.split("=") for kv in out.stdout.split())
        self.assertEqual(result["mismatches"], "0")
        self.assertLess(float(result["worst_ms"]), 1.0)
        self.assertGreater(int(result["pairs"]), 3000)


if __name__ == "__main__":
    unittest.main()
