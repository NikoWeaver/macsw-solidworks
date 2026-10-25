"""SOLIDWORKS.app: patch 0025, the bundle's Info.plist, packaging and the icon extractor."""
from pathlib import Path
import importlib.util
import plistlib
import re
import struct
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0025-winemac-app-bundle-host.patch"
KEY = "WineMacAppBundleHostPatchSHA256"


def load(name):
    spec = importlib.util.spec_from_file_location(name, PROJECT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


icon = load("extract_exe_icon")
app_info = load("solidworks_app_info")


def resource_section(tree, rva):
    """Bytes of a .rsrc section at `rva` for {type: {id: bytes}} (one language per entry)."""
    directories, entries, blobs = [], [], []

    def directory(children):  # children: [(id, ("dir", ...) | ("data", bytes))]
        index = len(directories)
        directories.append(None)
        directories[index] = [(ident, subdirectory(value)) for ident, value in sorted(children)]
        return index

    def subdirectory(value):
        if isinstance(value, bytes):
            entries.append(len(blobs))
            blobs.append(value)
            return ("data", len(entries) - 1)
        return ("dir", directory(list(value.items())))

    directory([(kind, {ident: {0x409: blob} for ident, blob in items.items()}) for kind, items in tree.items()])
    dir_offsets, offset = [], 0
    for children in directories:
        dir_offsets.append(offset)
        offset += 16 + 8 * len(children)
    entry_base = offset
    blob_base = entry_base + 16 * len(entries)
    blob_offsets, cursor = [], blob_base
    for blob in blobs:
        blob_offsets.append(cursor)
        cursor += (len(blob) + 3) & ~3
    out = bytearray()
    for children in directories:
        out += struct.pack("<IIHHHH", 0, 0, 0, 0, 0, len(children))
        for ident, (kind, index) in children:
            target = (dir_offsets[index] | 0x80000000) if kind == "dir" else entry_base + 16 * index
            out += struct.pack("<II", ident, target)
    for index in entries:
        out += struct.pack("<IIII", rva + blob_offsets[index], len(blobs[index]), 0, 0)
    for blob in blobs:
        out += blob + b"\0" * (((len(blob) + 3) & ~3) - len(blob))
    return bytes(out)


def pe_with_resources(tree):
    rva, raw = 0x1000, 0x400
    section = resource_section(tree, rva)
    pe = 0x80
    header = bytearray(raw)
    header[0:2] = b"MZ"
    struct.pack_into("<I", header, 0x3C, pe)
    header[pe:pe + 4] = b"PE\0\0"
    optional_size = 112 + 16 * 8
    struct.pack_into("<HHIIIHH", header, pe + 4, 0x8664, 1, 0, 0, 0, optional_size, 0x22)
    optional = pe + 24
    struct.pack_into("<H", header, optional, 0x20B)
    struct.pack_into("<II", header, optional + 112 + 2 * 8, rva, len(section))
    table = optional + optional_size
    struct.pack_into("<8sIIII", header, table, b".rsrc", len(section), rva, len(section), raw)
    return bytes(header) + section


def group(*images):  # (width, height, bits, icon id)
    data = struct.pack("<HHH", 0, 1, len(images))
    for width, height, bits, ident in images:
        data += struct.pack("<BBBBHHIH", width % 256, height % 256, 0, 0, 1, bits, 0, ident)
    return data


PNG = icon.PNG_SIGNATURE + b"fake png payload"
DIB = struct.pack("<IiiHH", 40, 16, 32, 1, 32) + b"\0" * 24 + b"pixels"


class IconExtractorTests(unittest.TestCase):
    def test_first_icon_group_largest_image_is_used(self):
        exe = pe_with_resources({
            icon.RT_ICON: {1: DIB, 2: PNG, 3: DIB},
            icon.RT_GROUP_ICON: {100: group((16, 16, 32, 1), (256, 256, 32, 2)), 200: group((48, 48, 32, 3))},
        })
        images = icon.icon_images(exe)
        self.assertEqual([image[:3] for image in images], [(16, 16, 32), (256, 256, 32)])
        self.assertEqual(icon.best_image(images), (256, 256, 32, PNG))

    def test_bitmap_images_become_a_one_image_ico(self):
        ico = icon.single_image_ico((16, 16, 32, DIB))
        self.assertEqual(struct.unpack_from("<HHH", ico), (0, 1, 1))
        width, height, _, _, planes, bits, size, offset = struct.unpack_from("<BBBBHHII", ico, 6)
        self.assertEqual((width, height, planes, bits, size, offset), (16, 16, 1, 32, len(DIB), 22))
        self.assertEqual(ico[22:], DIB)
        self.assertEqual(struct.unpack_from("<BB", icon.single_image_ico((256, 256, 32, PNG)), 6), (0, 0))

    def test_files_without_icons_are_rejected(self):
        with self.assertRaises(icon.IconError):
            icon.icon_images(b"not a program")
        with self.assertRaises(icon.IconError):
            icon.icon_images(pe_with_resources({icon.RT_ICON: {1: PNG}}))

    def test_iconset_has_every_size_iconutil_expects(self):
        names = [name for _, name in icon.ICONSET]
        for base in ("16x16", "32x32", "128x128", "256x256", "512x512"):
            self.assertIn(base, names)
            self.assertIn(base + "@2x", names)


class InfoPlistTests(unittest.TestCase):
    def setUp(self):
        self.macsw = plistlib.loads((PROJECT / "resources/Info.plist.in").read_bytes())
        self.template = plistlib.loads((PROJECT / "resources/SOLIDWORKS-Info.plist.in").read_bytes())

    def test_template_matches_the_wine_host_keys(self):
        t = self.template
        self.assertEqual(t["CFBundleIdentifier"], "com.yjbeetle.macsw.solidworks")
        self.assertEqual((t["CFBundleName"], t["CFBundleDisplayName"], t["CFBundleExecutable"]),
                         ("SOLIDWORKS", "SOLIDWORKS", "SOLIDWORKS"))
        # The process becomes the Wine host: same AppKit keys as loader/wine_info.plist.in.
        self.assertEqual(t["NSPrincipalClass"], "WineApplication")
        self.assertNotIn("NSHighResolutionCapable", t)
        # A Dock tile from launch (patch 0025 handles the rest); never the Rosetta checkbox.
        self.assertNotIn("LSUIElement", t)
        self.assertIs(t["LSRequiresNativeExecution"], True)
        self.assertEqual(t["CFBundleIconFile"], "AppIcon")

    def test_solidworks_types_are_owned_and_the_rest_keep_macsw_ranks(self):
        info = app_info.build(self.macsw, self.template)
        self.assertEqual(info["UTImportedTypeDeclarations"], self.macsw["UTImportedTypeDeclarations"])
        ranks = {t["LSItemContentTypes"][0]: t["LSHandlerRank"] for t in info["CFBundleDocumentTypes"]}
        for uti in ("part", "assembly", "drawing", "part-template", "assembly-template", "drawing-template"):
            self.assertEqual(ranks["com.dassault.solidworks." + uti], "Owner")
        for uti in ("org.iso.step", "org.iges.iges", "com.autodesk.dxf", "public.standard-tesselated-geometry-format"):
            self.assertEqual(ranks[uti], "Alternate")
        app_info.check(info, self.macsw)
        # MacSW.app itself is unchanged.
        self.assertEqual({t["LSHandlerRank"] for t in self.macsw["CFBundleDocumentTypes"]}, {"Default", "Alternate"})

    def test_check_rejects_a_bundle_that_does_not_own_the_solidworks_types(self):
        info = app_info.build(self.macsw, self.template)
        info["CFBundleDocumentTypes"][0]["LSHandlerRank"] = "Alternate"
        with self.assertRaises(ValueError):
            app_info.check(info, self.macsw)


class PatchTests(unittest.TestCase):
    def setUp(self):
        text = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        self.patch = text[text.index("diff --git "):]
        self.added = "\n".join(l[1:] for l in self.patch.splitlines() if l.startswith("+") and not l.startswith("+++"))

    def file_added(self, name):
        part = self.patch.split("diff --git a/dlls/winemac.drv/" + name, 1)[1].split("\ndiff --git ", 1)[0]
        return "\n".join(l[1:] for l in part.splitlines() if l.startswith("+") and not l.startswith("+++"))

    def test_patch_is_applied_after_0022_cached_pinned_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        # Apply order: 0001-0022, 0023, 0024, 0025, 0028.
        self.assertIn("${NATIVE_FILE_DIALOG_PATCH_SHA256}:${APP_BUNDLE_HOST_PATCH_SHA256}:${WBEMPROX_IPENABLED_PATCH_SHA256}",
                      build_key)
        self.assertIn('apply --check "${APP_BUNDLE_HOST_PATCH}"', build)
        self.assertLess(build.index('apply "${MSXML_EMPTY_ELEMENT_PATCH}"'), build.index('apply "${APP_BUNDLE_HOST_PATCH}"'))
        self.assertLess(build.index('apply "${NATIVE_FILE_DIALOG_PATCH}"'), build.index('apply "${APP_BUNDLE_HOST_PATCH}"'))
        self.assertLess(build.index('apply "${APP_BUNDLE_HOST_PATCH}"'), build.index('apply "${WBEMPROX_IPENABLED_PATCH}"'))
        # winemac.so is already built, shipped and pinned by module hash.
        self.assertIn("dlls/winemac.drv/winemac.so", build)
        for script in (package, verify):
            self.assertIn(KEY, script)
            line = next(l for l in script.splitlines() if KEY in l)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_patch_changes_only_unix_side_winemac_files(self):
        # winemac.so only (shipped and pinned); the PE module winemac.drv is not rebuilt.
        files = [l.split(" b/", 1)[1] for l in self.patch.splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/winemac.drv/cocoa_app.m", "dlls/winemac.drv/macdrv_cocoa.h",
                                 "dlls/winemac.drv/window.c"])

    def test_every_change_is_gated_by_the_launcher_environment(self):
        added = self.added
        removed = [l[1:].strip() for l in self.patch.splitlines() if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [
            "if ([NSApp activationPolicy] != NSApplicationActivationPolicyRegular)",
            "[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];",
            "ret = NSTerminateLater;",
        ])
        # Without the host condition: same transform condition and Command-Option-Q as before.
        self.assertIn("BOOL bundle_setup = !bundle_setup_done && is_app_bundle_host();", added)
        self.assertIn("!= NSApplicationActivationPolicyRegular || bundle_setup", added)
        self.assertRegex(added, r'if \(is_app_bundle_host\(\)\)\s+\[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand\];\s+'
                                r'else\s+\[item setKeyEquivalentModifierMask:NSEventModifierFlagCommand \| NSEventModifierFlagOption\];')
        # Outside the host (or without a helper) the delegate does not answer open-documents events.
        self.assertRegex(added, r'selector == @selector\(application:openURLs:\) &&\s+'
                                r'!\(is_app_bundle_host\(\) && app_bundle\.open_documents_helper\)\)\s+return NO;')
        self.assertIn("const char* helper = is_app_bundle_host() ? app_bundle.open_documents_helper : NULL;", added)
        # Without the close mode: Wine's session end (NSTerminateLater) as before.
        self.assertIn("ret = close_windows ? NSTerminateCancel : NSTerminateLater;", added)

    def test_switches_count_only_in_the_bundle_main_process(self):
        # Children inherit MACSW_APP_BUNDLE but run MacSW.app's loader: their main bundle differs.
        host = self.added.split("static BOOL is_app_bundle_host(void)", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('const char* path = getenv("MACSW_APP_BUNDLE");', host)
        self.assertRegex(host, r"app_bundle\.host = path && realpath\(path, want\) &&\s+"
                               r"realpath\(\[\[\[NSBundle mainBundle\] bundlePath\] fileSystemRepresentation\], have\) &&\s+"
                               r"!strcmp\(want, have\);")
        self.assertIn("if (!app_bundle.host) return;", host)
        self.assertIn("dispatch_once(&once", host)
        # Every variable is read there, once, and nowhere else.
        for key in ("MACSW_APP_BUNDLE", "MACSW_OPEN_DOCUMENTS_HELPER", "MACSW_APP_QUIT"):
            self.assertEqual(self.added.count('getenv("%s")' % key), 1, key)
            self.assertIn('getenv("%s")' % key, host)
        self.assertEqual(self.added.count("app_bundle.quit_closes_windows"), 2)

    def test_quit_close_mode_posts_wm_close_like_taskkill(self):
        cocoa = self.file_added("cocoa_app.m")
        self.assertRegex(cocoa, r"close_windows = event->app_quit_requested\.reason == QUIT_REASON_NONE &&\s+"
                                r"is_app_bundle_host\(\) && app_bundle\.quit_closes_windows;")
        self.assertIn('app_bundle.quit_closes_windows = (value = getenv("MACSW_APP_QUIT")) && !strcmp(value, "close");', cocoa)
        self.assertIn("QUIT_REASON_CLOSE_WINDOWS,", self.file_added("macdrv_cocoa.h"))
        window = self.file_added("window.c")
        self.assertIn("if (event->app_quit_requested.reason == QUIT_REASON_CLOSE_WINDOWS)", window)
        self.assertIn("NtUserGetWindowRelative(NtUserGetDesktopWindow(), GW_CHILD)", window)
        self.assertIn("NtUserGetWindowThread(hwnd, &pid) && pid == GetCurrentProcessId()", window)
        self.assertIn("NtUserPostMessage(hwnd, WM_CLOSE, 0, 0);", window)
        self.assertNotIn("WM_QUERYENDSESSION", window)

    def test_documents_go_to_the_native_helper(self):
        added = self.added
        self.assertIn('argv[count++] = (char*)"--open-documents";', added)
        self.assertIn("cpu_type_t binpref[] = { CPU_TYPE_ARM64, CPU_TYPE_X86_64 };", added)
        self.assertIn("POSIX_SPAWN_CLOEXEC_DEFAULT", added)
        self.assertIn("waitpid(pid, NULL, 0);", added)
        self.assertNotIn("SOLIDWORKS", re.sub(r"/\*.*?\*/", "", added, flags=re.S))


class PackagingTests(unittest.TestCase):
    def test_launcher_is_built_and_packaged_inside_macsw(self):
        package_swift = (PROJECT / "macos/Bootstrap/Package.swift").read_text()
        self.assertIn('.executable(name: "SOLIDWORKS", targets: ["SolidWorksLauncher"])', package_swift)
        bootstrap = (PROJECT / "macos/Bootstrap/build_bootstrap.sh").read_text()
        self.assertIn("--product SOLIDWORKS", bootstrap)
        self.assertIn('cp "${SWIFT_BIN_DIR}/SOLIDWORKS" "${OUTPUT_DIR}/SOLIDWORKS"', bootstrap)
        makefile = (PROJECT / "Makefile").read_text()
        self.assertIn("MACSW_SKIP_SOLIDWORKS_APP ?= 0\nexport MACSW_SKIP_SOLIDWORKS_APP\n", makefile)
        # package (and so app) depends on launcher: never an old build/bootstrap/SOLIDWORKS.
        self.assertRegex(makefile, r"\npackage: launcher ")
        self.assertIn("\nsolidworks-app: launcher\n", makefile)
        # SOLIDWORKS.app is inside MacSW.app now; make app no longer builds a second copy next to it.
        self.assertNotIn("$(MAKE) solidworks-app", makefile)
        # The archive's copy never carries an icon from the user's own SOLIDWORKS installation.
        self.assertIn("archive: export MACSW_SOLIDWORKS_EXE := none\narchive: app\n", makefile)
        package = (PROJECT / "scripts/package_app.sh").read_text()
        embed = package.index('bash "${WORKSPACE_ROOT}/scripts/package_solidworks_app.sh" --embed')
        self.assertLess(package.index('if [ "${MACSW_SKIP_SOLIDWORKS_APP:-0}" != 1 ]; then'), embed)
        self.assertIn('MACSW_APP_OUTPUT="${APP_DIR}"', package[embed - 80:embed])
        # Signed inside before MacSW.app is sealed, and before the staging app becomes the result.
        self.assertLess(embed, package.index('macsw_codesign "${APP_DIR}"'))
        self.assertLess(embed, package.index('mv "${APP_DIR}" "${FINAL_APP_DIR}"'))
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertIn('bash "${WORKSPACE_ROOT}/scripts/verify_solidworks_app.sh" --embedded "${APP_DIR}"', verify)

    def test_ci_archive_leaves_out_the_copy_that_developer_id_signing_cannot_sign(self):
        # sign-app.yml signs the archive of this step; sign_app.py refuses an embedded app.
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        step = workflow.split("- name: Build, verify and archive MacSW.app\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('MACSW_SKIP_SOLIDWORKS_APP: "1"', step)
        self.assertIn("make archive", step)

    def test_embedded_copy_is_a_zip_that_keeps_the_signature(self):
        script = (PROJECT / "scripts/package_solidworks_app.sh").read_text()
        embed = script.split('if [ "${EMBED}" = 1 ]; then\n    bash', 1)[1].split("\nfi\n", 1)[0]
        # Checked against the MacSW.app being packaged, then zipped as is and described.
        self.assertIn('verify_solidworks_app.sh" "${APP_DIR}" "${MACSW_APP}"', embed)
        self.assertIn('ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${PAYLOAD}"', embed)
        for key in ("CFBundleShortVersionString", "CFBundleVersion", "ExecutableSHA256"):
            self.assertIn("plutil -insert " + key, embed)
        self.assertIn('shasum -a 256 "${CONTENTS_DIR}/MacOS/SOLIDWORKS"', embed)
        self.assertLess(script.index('macsw_codesign "${APP_DIR}"'), script.index(embed))
        self.assertIn('PAYLOAD="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.zip"', script)
        self.assertIn('PAYLOAD_INFO="${MACSW_APP}/Contents/Resources/SOLIDWORKS.app.plist"', script)
        self.assertIn('if [ "${ICON_SOURCE}" = none ]; then', script)
        verify = (PROJECT / "scripts/verify_solidworks_app.sh").read_text()
        embedded = verify.split('if [ "${1:-}" = --embedded ]; then', 1)[1].split("\nelse\n", 1)[0]
        self.assertIn('ditto -x -k --noqtn "${PAYLOAD}" "${UNPACKED}"', embedded)
        self.assertIn('test "$(ls -A "${UNPACKED}")" = "SOLIDWORKS.app"', embedded)
        self.assertIn('test "$(PI ExecutableSHA256)" = "$(shasum -a 256 "${APP_DIR}/Contents/MacOS/SOLIDWORKS"', embedded)
        # MacSW reads the same names (SolidWorksAppInstaller).
        swift = (PROJECT / "macos/Bootstrap/Sources/MacSWCore/Services/SolidWorksAppInstaller.swift").read_text()
        for line in ('payloadName = "SOLIDWORKS.app.zip"', 'payloadInfoName = "SOLIDWORKS.app.plist"',
                     'executableSHA256Key = "ExecutableSHA256"', 'executablePath = "Contents/MacOS/SOLIDWORKS"',
                     'appendingPathComponent("Contents/Resources")'):
            self.assertIn(line, swift)

    def test_installer_never_signs_and_unpacks_with_ditto(self):
        swift = (PROJECT / "macos/Bootstrap/Sources/MacSWCore/Services/SolidWorksAppInstaller.swift").read_text()
        # --noqtn: the installed copy never inherits quarantine from a downloaded MacSW.app.
        self.assertIn('"/usr/bin/ditto"), ["-x", "-k", "--noqtn", archive.path, directory.path]', swift)
        self.assertNotIn("codesign", swift.replace("code signature", ""))
        self.assertIn("UInt32(RENAME_SWAP)", swift)
        self.assertIn("UInt32(RENAME_EXCL)", swift)
        self.assertIn("trashItem(at: item, resultingItemURL: nil)", swift)

    def test_package_combines_the_launcher_with_macsw_own_loader(self):
        script = (PROJECT / "scripts/package_solidworks_app.sh").read_text()
        self.assertIn('WINE_LOADER="${MACSW_APP}/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW"', script)
        self.assertIn('lipo -create "${LAUNCHER_BIN}" "${WINE_LOADER}" -output "${CONTENTS_DIR}/MacOS/SOLIDWORKS"', script)
        self.assertIn("solidworks_app_info.py\" build", script)
        self.assertIn("extract_exe_icon.py", script)
        self.assertIn('macsw_codesign "${APP_DIR}"', script)  # ad hoc unless MACSW_SIGN_IDENTITY
        verify = (PROJECT / "scripts/verify_solidworks_app.sh").read_text()
        self.assertIn('test "$(uuid x86_64 "${BIN}")" = "$(uuid x86_64 "${LOADER}")"', verify)
        self.assertIn("solidworks_app_info.py\" check", verify)
        self.assertIn("grep -o 'cdhash H' | wc -l", verify)

    def test_launcher_checks_in_with_appkit_only_when_it_does_not_exec(self):
        main = (PROJECT / "macos/Bootstrap/Sources/SolidWorksLauncher/main.swift").read_text()
        launch = main.split("case .launch:", 1)[1]
        forward = main.split("case .forward:", 1)[1].split("case .launch:", 1)[0]
        self.assertIn("NSApplication.shared", forward)
        self.assertNotIn("NSApplication", launch)
        self.assertIn("execSolidWorks", launch)
        self.assertEqual(main.count("NSApplication.shared"), 1)

    def test_launcher_refuses_a_stale_loader_before_the_preflight(self):
        main = (PROJECT / "macos/Bootstrap/Sources/SolidWorksLauncher/main.swift").read_text()
        launch = main.split("case .launch:", 1)[1]
        check = launch.index("AppBundleLaunch.loaderSliceMatches(appExecutable: appExecutable, macSW: host)")
        self.assertLess(check, launch.index("runtime.launch()"))
        self.assertIn("case false?:", launch[check:])
        self.assertIn("exit(1)", launch[check:launch.index("runtime.launch()")])
        self.assertIn("environment[AppBundleLaunch.skipLoaderCheckKey] != \"1\"", launch)
        # The validation delay and the font-link stamp only exist in the launcher.
        self.assertIn("AppBundleLaunch.launchDelayKey", launch)
        self.assertIn("AppBundleLaunch.stampedFontLinkRepair", launch)
        self.assertIn("quitClosesWindows: quitClosesWindows", launch)


if __name__ == "__main__":
    unittest.main()
