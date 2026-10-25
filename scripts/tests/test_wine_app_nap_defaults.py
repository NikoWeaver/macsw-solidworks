"""winemac App Nap default (patch 0035): NSAppSleepDisabled is registered before the NSApplication exists."""
from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0035-winemac-app-nap-defaults.patch"
KEY = "WineMacAppNapDefaultsPatchSHA256"


def patch_text():
    return (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()


def added(text):
    return "\n".join(l[1:] for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))


class AppNapDefaultsPatchTests(unittest.TestCase):
    def test_patch_only_adds_to_cocoa_main(self):
        files = [l.split(" b/", 1)[1] for l in patch_text().splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["dlls/winemac.drv/cocoa_main.m"])
        removed = [l for l in patch_text().split("diff --git ", 1)[1].splitlines()
                   if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])

    def test_default_is_registered_before_the_application_is_created(self):
        body = patch_text().split("diff --git ", 1)[1]
        code = added(body)
        # registration domain only (registerDefaults), never the user's persistent defaults
        self.assertIn("registerDefaults:", code)
        self.assertIn('forKey:@"NSAppSleepDisabled"', code)
        self.assertNotIn("setBool:", code)
        self.assertNotIn("setObject:", code)
        # only while App Nap is disabled (EnableAppNap unset or "n"), as the activity in cocoa_app.m
        self.assertIn("if (!enable_app_nap)", code)
        self.assertLess(body.index("registerDefaults:"), body.index("[WineApplication sharedApplication];"))
        self.assertLess(body.index("if (!NSApp)"), body.index("registerDefaults:"))

    def test_build_package_and_verify_wiring(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${APP_NAP_DEFAULTS_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${APP_NAP_DEFAULTS_PATCH}"', build)
        applies = re.findall(r'git -C "\$\{SOURCE_DIR\}" apply "\$\{(\w+)\}"', build)
        self.assertEqual(applies.count("APP_NAP_DEFAULTS_PATCH"), 1)
        self.assertEqual(applies[-1], "OPENGL32_BATCH_PATCH")   # 0030 stays last
        self.assertIn("dlls/winemac.drv/winemac.so", build)      # the module this patch changes ships
        self.assertIn(KEY, package)
        self.assertIn(KEY, verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if KEY in l)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_description_names_the_cause_and_the_rejected_alternatives(self):
        header = " ".join(patch_text().split("diff --git ", 1)[0].split())
        for word in ("macOS 27", "utility QoS", "NSActivityUserInitiatedAllowingIdleSystemSleep",
                     "LSAppNapIsDisabled", "EnableAppNap", "docs/cpu-scheduling-night.md"):
            self.assertIn(word, header)


if __name__ == "__main__":
    unittest.main()
