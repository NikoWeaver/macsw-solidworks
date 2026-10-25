"""Start-up caches (patches 0032 and 0033, docs/startup-performance.md): build, package, verify and
launch-environment wiring, and the shape of the two patches."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCHES = {
    "0032-windowscodecs-cache-component-registry.patch": {
        "var": "WIC_CACHE_PATCH",
        "key": "WineWICCachePatchSHA256",
        "module_key": "WineWindowsCodecsModuleSHA256",
        "target": "dlls/windowscodecs/x86_64-windows/windowscodecs.dll",
        "dist": "windowscodecs.dll",
        "file": "dlls/windowscodecs/info.c",
        "env": "MACSW_WIC_COMPONENT_CACHE",
    },
    "0033-kernelbase-local-module-reads.patch": {
        "var": "LOCAL_MODULE_READS_PATCH",
        "key": "WineLocalModuleReadsPatchSHA256",
        "module_key": "WineKernelBaseModuleSHA256",
        "target": "dlls/kernelbase/x86_64-windows/kernelbase.dll",
        "dist": "kernelbase.dll",
        "file": "dlls/kernelbase/debug.c",
        "env": "MACSW_LOCAL_MODULE_READS",
    },
}


def additions(patch):
    return "\n".join(l[1:] for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++"))


class StartupCachePatchTests(unittest.TestCase):
    def test_patches_are_applied_after_0028_cached_pinned_and_built(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${WBEMPROX_IPENABLED_PATCH_SHA256}:${WIC_CACHE_PATCH_SHA256}:"
                      "${LOCAL_MODULE_READS_PATCH_SHA256}:", build_key)
        last = build.index('apply "${WBEMPROX_IPENABLED_PATCH}"')
        for name, info in PATCHES.items():
            self.assertIn(name, build)
            self.assertIn('apply --check "${%s}"' % info["var"], build)
            applied = build.index('apply "${%s}"' % info["var"])
            self.assertLess(last, applied)
            last = applied
            self.assertIn(info["target"], build)
            self.assertIn('/%s"' % info["dist"], build)
        # the up-to-date check must require the new outputs, or a stale dist/ would be reused
        check = build.split('if [ -f "${WINEMAC_OUTPUT}" ]', 1)[1].split("then", 1)[0]
        self.assertIn("${WINDOWSCODECS_OUTPUT}", check)
        self.assertIn("${KERNELBASE_OUTPUT}", check)

    def test_package_and_verify_pin_patch_and_module(self):
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for name, info in PATCHES.items():
            for script in (package, verify):
                self.assertIn(name, script)
                self.assertIn(info["key"], script)
                self.assertIn(info["module_key"], script)
            self.assertIn("lib/wine/x86_64-windows/%s" % info["dist"], package)
            self.assertIn('cmp_pe_module %s ' % info["dist"], verify)
            for script in (package, verify):
                line = next(l for l in script.splitlines() if info["key"] in l)
                self.assertNotRegex(line, r"[0-9a-f]{64}")
        # verify_app.sh checks every module key that the manifest declares, and sw-cli verifies them too
        table = verify.split('MANIFEST_MODULES="', 1)[1].split('"\n', 1)[0]
        runtime = (PROJECT / "scripts/swcli/wine_runtime.py").read_text()
        for info in PATCHES.values():
            self.assertIn("%s|" % info["module_key"], table)
            self.assertIn('"%s": "lib/wine/x86_64-windows/%s"' % (info["module_key"], info["dist"]), runtime)

    def test_launch_environments_enable_both_caches_for_solidworks_only(self):
        swift = (PROJECT / "macos/Bootstrap/Sources/MacSWCore/Services/WineService.swift").read_text()
        self.assertIn('startupCacheKeys = ["MACSW_WIC_COMPONENT_CACHE", "MACSW_LOCAL_MODULE_READS"]', swift)
        solidworks_block = swift.split("if solidWorks {", 1)[1].split("return environment", 1)[0]
        self.assertIn("startupCacheKeys", solidworks_block)
        cli = (PROJECT / "scripts/swcli/sw-cli").read_text()
        runtime = (PROJECT / "scripts/swcli/wine_runtime.py").read_text()
        for info in PATCHES.values():
            self.assertIn("%s=1" % info["env"], cli)
            self.assertIn('%s="1"' % info["env"], runtime)

    def test_patches_touch_one_file_and_are_gated(self):
        for name, info in PATCHES.items():
            patch = (PROJECT / "patches/wine-crossover" / name).read_text()
            files = [l.split(" b/", 1)[1] for l in patch.splitlines() if l.startswith("diff --git ")]
            self.assertEqual(files, [info["file"]])
            added = additions(patch)
            self.assertIn('GetEnvironmentVariableW( L"%s"' % info["env"]
                          if "kernelbase" in name else
                          'GetEnvironmentVariableW(L"%s"' % info["env"], added)

    def test_wic_cache_keeps_the_uncached_path(self):
        patch = (PROJECT / "patches/wine-crossover/0032-windowscodecs-cache-component-registry.patch").read_text()
        added = additions(patch)
        self.assertIn("if (component_cache_enabled())\n        return create_cached_component_enumerator", added)
        self.assertIn("if (!component_cache_enabled())\n        return read_guid_value", added)
        # the per-category error handling of the uncached loop is kept
        self.assertIn("list->res != ERROR_SUCCESS && list->res != ERROR_NO_MORE_ITEMS", added)

    def test_local_module_reads_only_for_the_own_process(self):
        patch = (PROJECT / "patches/wine-crossover/0033-kernelbase-local-module-reads.patch").read_text()
        added = additions(patch)
        self.assertIn("pbi.UniqueProcessId == GetCurrentProcessId()", added)
        self.assertIn("process = GetCurrentProcess();", added)
        self.assertNotIn("ReadProcessMemory(", added)  # no new remote reads, only the handle swap
        # the swap comes after the first read through the caller's handle, so PROCESS_VM_READ is still checked
        body = patch.split("static BOOL init_module_iterator( struct module_iterator *iter, HANDLE process )", 1)[1]
        first_read = body.index("ReadProcessMemory( process, &pbi.PebBaseAddress->LdrData")
        self.assertLess(first_read, body.index("process = GetCurrentProcess();"))


if __name__ == "__main__":
    unittest.main()
