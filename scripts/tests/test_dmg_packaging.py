"""The release disk image: scripts/package_dmg.sh, resources/dmg/install-helper.sh and the release
label of config/versions.env (docs/packaging.md). Every external command is a fake on PATH."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
HELPER = PROJECT / "resources/dmg/install-helper.sh"
PACKAGE = PROJECT / "scripts/package_dmg.sh"
README = PROJECT / "resources/dmg/ReadMeFirst.txt.in"
LEAF = "616428ae1195eb76e27758ae5b88122911551f7f"
QUESTION = "Copy MacSW to /Applications and remove the macOS download flag from MacSW only? [y/N] "

# Records its arguments. Fails a requirement test (-R) when FAKE_REQUIREMENT_FAILS is set and every
# verification when FAKE_VERIFY_FAILS is set.
FAKE_CODESIGN = """#!/bin/bash
printf 'codesign %s\\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *" -R "*) [ -z "${FAKE_REQUIREMENT_FAILS:-}" ] || exit 3 ;;
esac
case "$1" in --verify) [ -z "${FAKE_VERIFY_FAILS:-}" ] || exit 1 ;; esac
exit 0
"""
FAKE_RECORDER = """#!/bin/bash
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
"""
# The answer of "is MacSW running": FAKE_PGREP_STATUS (default 1, nothing runs).
FAKE_PGREP = """#!/bin/bash
printf 'pgrep %s\\n' "$*" >> "$FAKE_LOG"
exit "${FAKE_PGREP_STATUS:-1}"
"""
# ditto <source> <target>: a real copy, so the test sees what lands where.
FAKE_DITTO = """#!/bin/bash
printf 'ditto %s\\n' "$*" >> "$FAKE_LOG"
/usr/bin/ditto "$@"
"""
# hdiutil create -volname V -srcfolder S ... <image>: records the staged tree, writes a fake image.
FAKE_HDIUTIL = """#!/bin/bash
printf 'hdiutil %s\\n' "$*" >> "$FAKE_LOG"
if [ "$1" = create ]; then
  while [ $# -gt 1 ]; do
    case "$1" in -srcfolder) source_folder="$2" ;; esac
    shift
  done
  /usr/bin/ditto "$source_folder" "$FAKE_STAGE_COPY"
  printf 'fake image\\n' > "$1"
fi
"""


def write_tool(directory, name, text):
    path = directory / name
    path.write_text(text)
    path.chmod(0o755)


class FakeTools:
    def __init__(self, root):
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        self.log = root / "calls.log"
        write_tool(self.bin, "codesign", FAKE_CODESIGN)
        write_tool(self.bin, "pgrep", FAKE_PGREP)
        write_tool(self.bin, "ditto", FAKE_DITTO)
        write_tool(self.bin, "hdiutil", FAKE_HDIUTIL)
        for name in ("xattr", "open"):
            write_tool(self.bin, name, FAKE_RECORDER)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def environment(self, **settings):
        environment = {"PATH": f"{self.bin}:/usr/bin:/bin", "FAKE_LOG": str(self.log),
                       "HOME": str(self.root / "home")}
        environment.update(settings)
        return environment


def make_app(directory, manifest=None, notices=True):
    app = directory / "MacSW.app"
    licenses = app / "Contents/Resources/licenses"
    (licenses / "Wine").mkdir(parents=True)
    (licenses / "MacSW").mkdir()
    (licenses / "Wine/SOURCE.txt").write_text("Wine source offer\n")
    (licenses / "MacSW/NOTICE").write_text("MacSW notice\n")
    # package_app.sh writes the source offer and the notices to Contents/Resources.
    (app / "Contents/Resources/SOURCE.txt").write_text("Wine source offer\n")
    if notices:
        (app / "Contents/Resources/THIRD_PARTY_NOTICES.txt").write_text("notices\n")
    (app / "Contents/Resources/SWCLI/licenses").mkdir(parents=True)
    (app / "Contents/Resources/SWCLI/licenses/Python-Native-LICENSE.txt").write_text("PSF\n")
    (app / "Contents/MacOS").mkdir()
    (app / "Contents/MacOS/MacSW").write_text("launcher\n")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "com.yjbeetle.macsw", "CFBundleVersion": "5"}, stream)
    with (app / "Contents/Resources/BuildManifest.plist").open("wb") as stream:
        plistlib.dump(manifest if manifest is not None
                      else {"AppVersion": "0.2.0", "AppBuild": "5", "AppRelease": "0.2.0-rc.1"}, stream)
    return app


class InstallHelperTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="macsw-helper-"))
        self.addCleanup(shutil.rmtree, self.root)
        self.tools = FakeTools(self.root)
        (self.root / "home/.Trash").mkdir(parents=True)
        (self.root / "Applications").mkdir()
        self.volume = self.root / "Volume"
        self.volume.mkdir()
        self.source = make_app(self.volume)
        self.target = self.root / "Applications/MacSW.app"

    def run_main(self, answer, **settings):
        """Sources the helper, points it at the test folders, and runs main with `answer` on stdin."""
        command = (f'source "{HELPER}"; PATH="$TEST_PATH"; SOURCE_APP="{self.source}"; '
                   f'TARGET_APP="{self.target}"; main')
        environment = self.tools.environment(**settings)
        environment["TEST_PATH"] = environment["PATH"]
        return subprocess.run(["/bin/bash", "-c", command], input=answer, env=environment,
                              capture_output=True, text=True)

    def run_function(self, command):
        return subprocess.run(["/bin/bash", "-c", f'source "{HELPER}"; {command}'],
                              capture_output=True, text=True)

    def test_yes_checks_copies_clears_the_flag_on_the_copy_only_and_opens_it(self):
        result = self.run_main("y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(QUESTION, result.stdout)
        self.assertEqual(self.tools.calls(), [
            f"codesign --verify --deep --strict {self.source}",
            f'codesign --verify -R =identifier "com.yjbeetle.macsw" and certificate leaf = H"{LEAF}" {self.source}',
            f"ditto {self.source} {self.target}",
            f"xattr -dr com.apple.quarantine {self.target}",
            f"open {self.target}",
        ])
        self.assertTrue((self.target / "Contents/MacOS/MacSW").is_file())
        for number in range(1, 6):
            self.assertIn(f"==> {number}/5 ", result.stdout, "each step is printed")
        self.assertLess(result.stdout.index("xattr -dr com.apple.quarantine"),
                        result.stdout.index("==> 5/5"), "the command is printed before it runs")

    def test_anything_but_yes_changes_nothing(self):
        for answer in ("n\n", "\n", "", "yes please\n", "no\n"):
            with self.subTest(answer=answer):
                self.tools.log.unlink(missing_ok=True)
                result = self.run_main(answer)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Nothing was changed.", result.stdout)
                self.assertTrue(all(call.startswith("codesign --verify") for call in self.tools.calls()))
                self.assertFalse(self.target.exists())

    def test_a_bad_signature_or_another_certificate_stops_before_the_question(self):
        for setting in ("FAKE_VERIFY_FAILS", "FAKE_REQUIREMENT_FAILS"):
            with self.subTest(setting=setting):
                result = self.run_main("y\n", **{setting: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Do not install this copy.", result.stderr)
                self.assertNotIn(QUESTION, result.stdout)
                self.assertFalse(self.target.exists())

    def test_running_macsw_stops_before_the_old_copy_is_touched(self):
        make_app(self.root / "Applications")
        result = self.run_main("y\n", FAKE_PGREP_STATUS="0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit SOLIDWORKS, then quit MacSW", result.stderr)
        self.assertTrue((self.target / "Contents/Info.plist").is_file())
        self.assertEqual(list((self.root / "home/.Trash").iterdir()), [])
        self.assertFalse(any(call.startswith(("ditto", "xattr", "open")) for call in self.tools.calls()))

    def test_an_old_copy_goes_to_the_trash_before_the_new_one_is_copied(self):
        make_app(self.root / "Applications")
        (self.target / "old-marker").write_text("old\n")
        result = self.run_main("y\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        trashed = list((self.root / "home/.Trash").iterdir())
        self.assertEqual(len(trashed), 1)
        self.assertRegex(trashed[0].name, r"^MacSW \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d\.app$")
        self.assertTrue((trashed[0] / "old-marker").is_file())
        self.assertFalse((self.target / "old-marker").exists(), "ditto never merges into the old bundle")
        running = [call for call in self.tools.calls() if call.startswith("pgrep")]
        installed = str(self.target).replace(".", "\\.")
        self.assertEqual(running, ["pgrep -x MacSW", f"pgrep -f ^{installed}/"])

    def test_trash_destination_never_reuses_a_name(self):
        trash = self.root / "home/.Trash"
        result = self.run_function(f'trash_destination "{trash}" "2026-10-25 03.00.00"')
        self.assertEqual(result.stdout.strip(), f"{trash}/MacSW 2026-10-25 03.00.00.app")
        (trash / "MacSW 2026-10-25 03.00.00.app").mkdir()
        (trash / "MacSW 2026-10-25 03.00.00 2.app").symlink_to("/nonexistent")
        result = self.run_function(f'trash_destination "{trash}" "2026-10-25 03.00.00"')
        self.assertEqual(result.stdout.strip(), f"{trash}/MacSW 2026-10-25 03.00.00 3.app")

    def test_only_an_explicit_yes_is_yes(self):
        for answer, expected in (("y", 0), ("Y", 0), ("yes", 0), (" YES ", 0), ("n", 1), ("", 1),
                                 ("yy", 1), ("yes please", 1), ("ja", 1)):
            with self.subTest(answer=answer):
                self.assertEqual(self.run_function(f'is_yes "{answer}"').returncode, expected)

    def test_run_with_bash_it_stops_when_no_app_is_next_to_it(self):
        copy = self.root / "empty/install-helper.sh"
        copy.parent.mkdir()
        shutil.copy(HELPER, copy)
        result = subprocess.run(["/bin/bash", str(copy)], input="y\n", capture_output=True, text=True,
                                env=self.tools.environment())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MacSW.app is not next to this script.", result.stderr)
        self.assertEqual(self.tools.calls(), [], "the helper sets its own PATH and changes nothing")

    def test_the_script_pins_the_certificate_and_touches_only_the_installed_app(self):
        text = HELPER.read_text()
        code = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
        self.assertIn(f'MACSW_CERTIFICATE_LEAF="{LEAF}"', text)
        self.assertIn('TARGET_APP="/Applications/MacSW.app"', text)
        self.assertIn("export PATH=/usr/bin:/bin:/usr/sbin:/sbin", text)
        self.assertFalse([line for line in code if re.search(r"\bsudo\b", line)])
        xattr = [line.strip() for line in code if re.match(r"\s*xattr\b", line)]
        self.assertEqual(xattr, ['xattr -dr com.apple.quarantine "${TARGET_APP}"'])
        writes = [line.strip() for line in code if re.match(r"\s*(ditto|mv|cp|rm|xattr|defaults|chmod)\b", line)]
        self.assertEqual(len(writes), 3, writes)


class PackageDMGTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="macsw-dmg-"))
        self.addCleanup(shutil.rmtree, self.root)
        self.tools = FakeTools(self.root)
        self.output = self.root / "out"
        self.stage = self.root / "staged"

    def package(self, app, **settings):
        environment = self.tools.environment(MACSW_SIGN_IDENTITY="MacSW Local Code Signing",
                                             FAKE_STAGE_COPY=str(self.stage))
        environment.update(settings)
        return subprocess.run([str(PACKAGE), str(app), str(self.output)], env=environment,
                              capture_output=True, text=True)

    def test_layout_signature_order_and_checksum(self):
        app = make_app(self.root / "build")
        result = self.package(app)
        self.assertEqual(result.returncode, 0, result.stderr)
        image = self.output / "MacSW-0.2.0-rc.1.dmg"
        self.assertTrue(image.is_file())
        self.assertEqual(sorted(path.name for path in self.stage.iterdir()),
                         ["Applications", "Licenses", "MacSW.app", "Read Me First.txt", "install-helper.sh"])
        self.assertEqual(os.readlink(self.stage / "Applications"), "/Applications")
        self.assertEqual((self.stage / "install-helper.sh").read_text(), HELPER.read_text())
        self.assertEqual((self.stage / "MacSW.app/Contents/MacOS/MacSW").read_text(), "launcher\n")
        licenses = self.stage / "Licenses"
        self.assertEqual((licenses / "THIRD_PARTY_NOTICES.txt").read_text(), "notices\n")
        self.assertEqual((licenses / "SOURCE.txt").read_text(), "Wine source offer\n")
        self.assertTrue((licenses / "MacSW/NOTICE").is_file())
        self.assertTrue((licenses / "SWCLI/Python-Native-LICENSE.txt").is_file())
        readme = (self.stage / "Read Me First.txt").read_text()
        self.assertIn('bash "/Volumes/MacSW 0.2.0-rc.1/install-helper.sh"', readme)
        self.assertIn("MacSW 0.2.0-rc.1 for SOLIDWORKS 2026 SP4.1", readme)
        self.assertIn("Copy MacSW-0.2.0-rc.1.dmg to Downloads", readme)
        self.assertIn("Open Anyway", readme)
        self.assertNotRegex(readme, r"@[A-Z]+@")

        calls = self.tools.calls()
        steps = [call.split(" ", 1)[0] + (" " + call.split()[1] if call.split()[1] in
                 ("create", "verify", "--verify", "--force") else "") for call in calls]
        create = steps.index("hdiutil create")
        self.assertLess(create, steps.index("codesign --force"))
        self.assertLess(steps.index("codesign --force"), steps.index("hdiutil verify"))
        self.assertIn('hdiutil create -volname MacSW 0.2.0-rc.1 -srcfolder', calls[create])
        self.assertIn(f"-fs HFS+ -format UDZO -ov {image}", calls[create])
        self.assertIn(f"codesign --force --sign MacSW Local Code Signing --identifier com.yjbeetle.macsw.dmg {image}",
                      calls)
        self.assertIn(f'codesign --verify -R =identifier "com.yjbeetle.macsw.dmg" and certificate leaf = H"{LEAF}" '
                      f'{image}', calls)
        self.assertIn(f'codesign --verify -R =identifier "com.yjbeetle.macsw" and certificate leaf = H"{LEAF}" {app}',
                      calls[:create])
        self.assertFalse([call for call in calls if call.startswith("codesign --force") and "MacSW.app" in call],
                         "the app is never re-signed")
        digest = subprocess.run(["shasum", "-a", "256", image.name], cwd=self.output,
                                capture_output=True, text=True, check=True).stdout
        self.assertEqual((self.output / "SHA256SUMS").read_text(), digest)
        self.assertEqual([path.name for path in self.output.iterdir() if path.name.startswith(".")], [],
                         "the staging folder is removed")

    def test_older_builds_are_named_after_their_app_version(self):
        app = make_app(self.root / "build", manifest={"AppVersion": "0.1.2", "AppBuild": "4"})
        result = self.package(app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / "MacSW-0.1.2.dmg").is_file())
        self.assertIn('bash "/Volumes/MacSW 0.1.2/install-helper.sh"',
                      (self.stage / "Read Me First.txt").read_text())

    def test_refusals_before_any_image_is_made(self):
        cases = {
            "no identity": ({"MACSW_SIGN_IDENTITY": ""}, "set MACSW_SIGN_IDENTITY"),
            "another certificate": ({"FAKE_REQUIREMENT_FAILS": "1"}, "not signed with certificate leaf"),
            "bad signature": ({"FAKE_VERIFY_FAILS": "1"}, "signature is not valid"),
        }
        app = make_app(self.root / "build")
        for name, (settings, message) in cases.items():
            with self.subTest(name):
                result = self.package(app, **settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(any(call.startswith("hdiutil") for call in self.tools.calls()))

    def test_missing_notices_stop_unless_explicitly_allowed(self):
        app = make_app(self.root / "build", notices=False)
        result = self.package(app)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.txt", result.stderr)
        result = self.package(app, MACSW_DMG_ALLOW_MISSING_NOTICES="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)
        self.assertFalse((self.stage / "Licenses/THIRD_PARTY_NOTICES.txt").exists())
        self.assertTrue((self.stage / "Licenses/SOURCE.txt").is_file())

    def test_unexpected_release_labels_are_refused(self):
        for label in ("0.2.0-beta", "0.2", "0.2.0-rc.0", "0.2.0/../x"):
            with self.subTest(label=label):
                app = make_app(self.root / label.replace("/", "_"), manifest={"AppRelease": label})
                result = self.package(app)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected release label", result.stderr)

    def test_the_readme_has_the_steps_the_plan_names(self):
        text = README.read_text()
        for phrase in ("Drag MacSW onto Applications", "System Settings > Privacy & Security", "Open Anyway",
                       "MacSW will remove the download flag from its own files so that macOS does not "
                       "block its\n   Wine helpers.", "Click Remove Download Flag", "@VOLUME@/install-helper.sh",
                       "shasum -a 256 -c SHA256SUMS", "Help > Licenses >\n  Deactivate"):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)

    def test_the_readme_promises_no_feature_the_build_does_not_have(self):
        # Sharing plan C0.7 (time estimates), C0.8 (activation card), C0.10 (Keep in Dock) and C3
        # (update check) are not in 0.2.0-rc.1 (docs/packaging.md, "Not done yet").
        text = README.read_text()
        for phrase in ("time estimate", "shows a card", "Keep in Dock", "Update available"):
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, text)
        self.assertIn("click Install SOLIDWORKS App", text)


class ReleaseLabelTests(unittest.TestCase):
    def load(self, **values):
        assignments = "".join(f'{key}="{value}"; ' for key, value in values.items())
        check = (PROJECT / "scripts/lib/config.sh").read_text().split(
            "# APP_RELEASE is APP_VERSION, or APP_VERSION-rc.N for a release candidate.\n", 1)[1]
        check = check.split("\nesac\n", 1)[0] + "\nesac\n"
        script = f'MACSW_VERSIONS_FILE=versions.env; {assignments}\n{check}'
        return subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True)

    def test_real_configuration_is_a_release_or_release_candidate_of_app_version(self):
        result = subprocess.run(["/bin/bash", "-c", f'source "{PROJECT}/scripts/lib/config.sh" && '
                                 'printf "%s %s %s" "$APP_VERSION" "$APP_BUILD" "$APP_RELEASE"'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        version, build, release = result.stdout.split()
        self.assertRegex(version, r"^\d+\.\d+\.\d+$", "CFBundleShortVersionString is numbers only")
        self.assertRegex(build, r"^\d+$")
        self.assertRegex(release, rf"^{re.escape(version)}(-rc\.[1-9]\d*)?$")

    def test_release_label_check(self):
        for release, accepted in (("0.2.0", True), ("0.2.0-rc.1", True), ("0.2.0-rc.12", True),
                                  ("0.2.0-rc.0", False), ("0.2.1-rc.1", False), ("0.2.0-beta", False),
                                  ("", False)):
            with self.subTest(release=release):
                result = self.load(APP_VERSION="0.2.0", APP_RELEASE=release)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_manifest_and_file_names_carry_the_release_label(self):
        package = (PROJECT / "scripts/package_app.sh").read_text()
        self.assertIn('Add :AppRelease string ${APP_RELEASE}', package)
        self.assertIn("Print :AppRelease", (PROJECT / "scripts/verify_app.sh").read_text())
        self.assertIn("MacSW-$${APP_RELEASE}-macOS.zip", (PROJECT / "Makefile").read_text())
        self.assertNotIn("MacSW-$${APP_VERSION}", (PROJECT / "Makefile").read_text())


if __name__ == "__main__":
    unittest.main()
