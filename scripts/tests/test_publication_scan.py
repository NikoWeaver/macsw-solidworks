"""scripts/ci/publication_scan.py: every rule finds a planted value, the allowed forms pass, and the
output never shows a matched value.

The planted values are built at run time (joined from parts, or from random digits), so that this
file itself passes the scan of a public tree.
"""
import hashlib
import importlib.util
import io
import os
import random
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
SCANNER = PROJECT / "scripts/ci/publication_scan.py"
SPEC = importlib.util.spec_from_file_location("publication_scan", SCANNER)
SCAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCAN)

RNG = random.Random(20261025)

# Synthetic private terms: one per category, so that a scan with them checks every category.
SYNTHETIC_TERMS = "# a comment\nowner-name word zorblax\nowner-account part quuxacct\ninstitution part frobuni\n"


def random_serial(separator=" "):
    """Six groups of four random digits whose first group is not 0000 (so not an allowed fake)."""
    groups = ["".join(RNG.choice("123456789") for _ in range(4)) for _ in range(6)]
    return separator.join(groups)


def run(*args, env=None):
    """Runs the scanner without the caller's MACSW_SCAN_TERMS, unless env gives one."""
    environment = {k: v for k, v in os.environ.items() if k != SCAN.TERMS_ENVIRONMENT}
    environment.update(env or {})
    result = subprocess.run([sys.executable, "-I", "-B", str(SCANNER), *map(str, args)],
                            capture_output=True, text=True, env=environment)
    return result.returncode, result.stdout + result.stderr


def env_terms():
    """The real private terms when MACSW_SCAN_TERMS names them (local runs), else none."""
    path = os.environ.get(SCAN.TERMS_ENVIRONMENT)
    return SCAN.Terms(SCAN.read_terms(path)) if path and Path(path).is_file() else SCAN.Terms()


class TermsFile:
    def __init__(self, text=SYNTHETIC_TERMS):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name, "terms.txt")
        self.path.write_text(text)

    def __enter__(self):
        return self.path

    def __exit__(self, *exc):
        self.temp.cleanup()


class Tree:
    def __init__(self, files):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content if isinstance(content, bytes) else content.encode())

    def __enter__(self):
        return self.root

    def __exit__(self, *exc):
        self.temp.cleanup()


def counts(root):
    results, _, _ = SCAN.scan_folder(root, SCAN.Terms())
    total = {}
    for found in results.values():
        for category, number in found.items():
            total[category] = total.get(category, 0) + number
    return total


class PlantedValueTests(unittest.TestCase):
    def assertFinds(self, category, content, name="notes.md"):
        with Tree({name: content}) as root:
            self.assertGreaterEqual(counts(root).get(category, 0), 1, category)
            code, output = run(root)
        self.assertEqual(code, 1, output)
        self.assertIn("result: FAIL", output)
        if isinstance(content, str) and content.strip():
            self.assertNotIn(content.strip(), output, "the scan printed a matched value")
            longest = max(content.split(), key=len)
            if not any(longest in category for category in SCAN.CATEGORIES):
                self.assertNotIn(longest, output, "the scan printed a matched value")

    def test_home_folders(self):
        self.assertFinds("home-path", "see /Users/" + "zqperson" + "/Desktop/a.txt\n")
        self.assertFinds("windows-home-path", "C:" + "\\users\\" + "zqperson" + "\\Desktop\n")
        self.assertFinds("windows-home-path", "Z:" + "\\Users\\" + "zqperson" + "\\Box\n")

    def test_email_address(self):
        self.assertFinds("e-mail", "mail " + "zq.person" + "@" + "mailhost" + ".org now\n")

    def test_private_terms_word_and_part_modes(self):
        terms = SCAN.Terms([("owner-name", "word", "zorblax"), ("institution", "part", "quuxy")])
        self.assertEqual(terms.count("by ZorblaxFoo and zorblax.")["owner-name"], 2)
        self.assertEqual(terms.count("zorblaxed")["owner-name"], 0, "word mode: not inside a word")
        self.assertEqual(terms.count("the myQuuxyThing team")["institution"], 1)
        self.assertEqual(terms.count("quuxyquuxy")["institution"], 2)
        self.assertEqual(terms.count("nothing here")["institution"], 0)

    def test_private_terms_from_a_terms_file(self):
        with TermsFile() as terms, Tree({"docs/a.md": "by Zorblax at the FrobUni lab\n"}) as root:
            code, output = run("--terms-file", terms, root)
            self.assertEqual(code, 1, output)
            self.assertIn("owner-name", output)
            self.assertIn("institution", output)
            self.assertNotIn("orblax", output.lower(), "the scan printed a term")
            self.assertNotIn("frobuni", output.lower(), "the scan printed a term")
            self.assertEqual(run(root, env={SCAN.TERMS_ENVIRONMENT: str(terms)})[0], 1, "MACSW_SCAN_TERMS")


    def test_box_account_folders(self):
        self.assertFinds("box-account-folder", "~/Library/CloudStorage/" + "OneDrive-" + "Zq Corp" + "/x\n")
        self.assertFinds("box-account-folder", "copy it to " + "MacSW " + "Transfer" + " first\n")

    def test_mac_address(self):
        self.assertFinds("mac-address", "en0 " + ":".join(["a4", "83", "e7", "10", "20", "30"]) + "\n")

    def test_serial_shaped_strings(self):
        self.assertFinds("serial", "key " + random_serial() + "\n")
        self.assertFinds("serial", "key=" + random_serial("-") + ";\n")
        self.assertFinds("serial", "key " + random_serial("") + "\n")
        self.assertFinds("installer-serial-property", "SERIAL" + "NUMBER=" + random_serial("") + "\n")
        self.assertFinds("activation-request", "SWActivate" + "Request_" + "1234567" + ".xml\n")

    def test_licence_edition_words(self):
        self.assertFinds("licence-edition", "title: SW Design Premium " + "for Stu" + "dents" + " 2026\n")
        self.assertFinds("licence-edition", "a title - " + "Academic " + "Use Only" + "\n")
        self.assertFinds("licence-edition", "the " + "Education" + " Edition" + " of SW\n")
        self.assertFinds("licence-edition", "the " + "Student" + " Edition" + " of SW\n")
        # Wrapped onto the next line of a comment.
        self.assertFinds("licence-edition", "# a title (SW " + "for\n# Stu" + "dents" + ")\n")

    def test_licence_bypass_terms(self):
        self.assertFinds("licence-bypass-term", "the " + "S" + "SQ" + " build\n")
        self.assertFinds("licence-bypass-term", "a " + "cr" + "acked" + " copy\n")
        self.assertFinds("licence-bypass-term", "start " + "lm" + "grd" + " on 27000\n")
        self.assertFinds("licence-bypass-term", "a " + "fake " + "serial" + " for CI\n")
        self.assertFinds("licence-bypass-term", "serials" + "_licensing" + ".json\n")

    def test_proprietary_file_types(self):
        for name in ("models/part.SLD" + "PRT", "macros/a.sw" + "p", "media/solidworks.m" + "si",
                     "media/data1.c" + "ab", "sw.l" + "ic", "lic/x.t" + "sf",
                     "bin/SolidWorks.Interop." + "sldworks.dll", "MacSW.app/Contents/Resources/managed/std" + "ole.dll"):
            with self.subTest(name=name):
                self.assertFinds("proprietary-file", "", name=name)

    def test_secrets(self):
        self.assertFinds("secret", "-----BEGIN " + "RSA PRIV" + "ATE KEY-----\nabc\n")
        self.assertFinds("secret", "token " + "gh" + "p_" + "A1b2" * 9 + "\n")
        self.assertFinds("secret", "export OPENROUTER" + "_API_KEY=" + "sk" + "-or-v1-" + "ab12" * 10 + "\n")
        self.assertFinds("secret", "", name="signing/identity.p" + "12")

    def test_binary_files_are_checked_for_home_folders_only(self):
        with Tree({"a.bin": b"\0\1\2/Users/" + b"zqperson" + b"/src/a.c\0",
                   "b.bin": b"\0\1\2 by Zorblax at FrobUni \0"}) as root:
            self.assertEqual(counts(root), {"home-path": 1})
            with TermsFile() as terms:
                code, output = run("--terms-file", terms, root)
            self.assertEqual(code, 1, output)
            self.assertIn("home-path                      1  a.bin", output)
            self.assertNotIn("b.bin", output, "words are not checked in binary files")


class TermsFileTests(unittest.TestCase):
    def test_the_scanner_has_no_built_in_terms(self):
        self.assertFalse(hasattr(SCAN, "PRIVATE_TERMS"))
        self.assertEqual(SCAN.Terms().unchecked(), list(SCAN.TERM_CATEGORIES))

    def test_without_terms_the_three_categories_are_not_checked(self):
        with Tree({"docs/a.md": "nothing to see\n"}) as root:
            code, output = run(root)
            self.assertEqual(code, 0, output)
            self.assertNotIn("result: PASS", output)
            self.assertIn("result: owner-name, owner-account, institution: not checked", output)
            with TermsFile("institution part frobuni\n") as terms:
                code, output = run("--terms-file", terms, root)
            self.assertIn("result: owner-name, owner-account: not checked", output)
            with TermsFile() as terms:
                code, output = run("--terms-file", terms, root)
            self.assertEqual(code, 0, output)
            self.assertIn("result: PASS (0 hit(s)", output)
            self.assertNotIn("not checked", output)

    def test_a_bad_terms_file_is_a_usage_error_that_does_not_show_the_line(self):
        with Tree({"a.md": "x\n"}) as root:
            for text in ("owner-name zorblax\n", "colleague word zorblax\n", "owner-name word zor-blax\n"):
                with self.subTest(text=text), TermsFile(text) as terms:
                    code, output = run("--terms-file", terms, root)
                    self.assertEqual(code, 2, output)
                    self.assertIn("line 1", output)
                    self.assertNotIn("orblax", output)
            self.assertEqual(run("--terms-file", Path(root, "missing.txt"), root)[0], 2)


class AllowedFormTests(unittest.TestCase):
    def test_allowed_forms_pass(self):
        fork = SCAN.ALLOWED_LITERALS[1]
        identity = SCAN.ALLOWED_LITERALS[0]
        lines = [
            f"source: https://{fork}/releases/tag/0.2.0-rc.1",
            f"git config user.email {identity}",
            "Co-Authored-By: Claude <" + "noreply" + "@" + "anthropic.com>",
            "member" + "@" + "example.com, ops" + "@" + "licenses.example.edu",
            "icon_16x16" + "@" + "2x.png",
            "/Users/" + "Shared" + "/x, /Users/" + "fakeuser" + "/y, C:" + "\\users\\" + "Public",
            "C:" + "\\users\\" + "...",
            "~/Library/CloudStorage/" + "Box-" + "Box" + "/MacSW",
            "MACAddress " + ":".join(["02"] + ["00"] * 5) + " and " + "-".join(["02", "11", "22", "33", "44", "55"]),
            "key " + " ".join(["0000", "1111", "2222", "3333", "4444", "5555"]),
            "ProductCode {" + "-".join(["1234ABCD", "1234", "1234", "1234", "123456789012"]) + "}",
            "Removed in this fork: managed FlexNet/" + "lm" + "grd" + " installation",
            "SOLIDWORKS Premium 2025 SP5.0 and SOLIDWORKS 2026 SP4.1 (any edition), an academic paper",
        ]
        with Tree({"docs/notes.md": "\n".join(lines) + "\n",
                   "resources/licenses/third-party/zlib.txt": "Jean " + "jl" + "@" + "gzip.org\n",
                   "patches/wine-crossover/0017-x.patch": "From: A Author <" + "a" + "@" + "corp.com>\n"}) as root, \
                TermsFile() as terms:
            self.assertEqual(counts(root), {})
            code, output = run("--terms-file", terms, root)
        self.assertEqual(code, 0, output)
        self.assertIn("result: PASS (0 hit(s)", output)

    def test_fork_literal_is_allowed_but_the_name_alone_is_not(self):
        handle = SCAN.ALLOWED_LITERALS[1].split("/")[1]
        words = [handle] + SCAN.CAMEL.findall(handle)
        terms = SCAN.Terms([("owner-name", "word", word.lower()) for word in words])
        self.assertEqual(SCAN.scan_text(f"see {SCAN.ALLOWED_LITERALS[1]}", "x", terms), {})
        self.assertGreaterEqual(SCAN.scan_text(f"by {handle}", "x", terms)["owner-name"], 1)

    def test_e_mail_in_a_patch_body_is_found(self):
        content = "From: MacSW maintainers\n+ contact " + "zq" + "@" + "mailhost.org\n"
        self.assertEqual(SCAN.scan_text(content, "patches/wine-crossover/0040-x.patch", SCAN.Terms())["e-mail"], 1)

    def test_daemon_name_outside_removed_wording(self):
        self.assertEqual(SCAN.scan_text("lm" + "grd" + " was never used\n", "x", SCAN.Terms()), {})
        self.assertEqual(SCAN.scan_text("check " + "lm" + "grd\n", "x", SCAN.Terms())["licence-bypass-term"], 1)

    def test_git_metadata_is_not_scanned(self):
        with Tree({".git": "gitdir: /Users/" + "zqperson" + "/repo/.git/worktrees/x\n",
                   "sub/.git/config": "url = /Users/" + "zqperson" + "/x\n"}) as root:
            self.assertEqual(counts(root), {})


class HomePathsInBytesTests(unittest.TestCase):
    USER = "zq" + "person"

    def test_ascii_and_utf16_forms(self):
        user = self.USER
        found = SCAN.home_paths_in_bytes
        self.assertEqual(found(b"\0/Users/" + user.encode() + b"/x"), {"home-path": 1})
        self.assertEqual(found(("/Users/" + user).encode("utf-16-le")), {"home-path": 1})
        self.assertEqual(found(b"C:" + b"\\users\\" + user.encode()), {"windows-home-path": 1})
        self.assertEqual(found(("C:" + "\\users\\" + user).encode("utf-16-le")), {"windows-home-path": 1})
        for allowed in (b"/Users/" + b"Shared/x", ("C:" + "\\users\\" + "Public").encode("utf-16-le"),
                        b"/Users/" + b"runner/work"):
            self.assertEqual(found(allowed), {}, allowed)

    def test_home_paths_mode_reads_files_and_zip_entries(self):
        user = self.USER.encode()
        with tempfile.TemporaryDirectory() as folder:
            volume = Path(folder, "vol")
            wine = volume / "MacSW.app/Contents/Resources/Wine/lib/wine/x86_64-windows"
            wine.mkdir(parents=True)
            (wine / "kernelbase.dll").write_bytes(b"MZ\0\0" + (b"/Users/" + user + b"/build/a.c\0") * 3)
            (wine / "stock.dll").write_bytes(b"MZ\0\0 C:\\windows\\system32 /Users/" + b"Shared/x\0")
            (volume / "notes.txt").write_bytes(b"from /Users/" + user + b"/x\n")
            with zipfile.ZipFile(volume / "MacSW.app/Contents/Resources/SOLIDWORKS.app.zip", "w",
                                 zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS", b"\xcf\xfa\xed\xfe /Users/" + user + b"/y")
            python = volume / "MacSW.app/Contents/Resources/SWCLI/runtime/PythonNative/lib/python3.11/site-packages/x"
            python.mkdir(parents=True)
            (python / "METADATA").write_bytes(b"e.g. /Users/" + b"trentm" + b"/Library\n")
            code, output = run("--home-paths", volume)
        self.assertEqual(code, 1, output)
        self.assertIn("home-path                      3  MacSW.app/Contents/Resources/Wine/lib/wine/x86_64-windows/kernelbase.dll",
                      output)
        self.assertIn("MacSW.app/Contents/Resources/SOLIDWORKS.app.zip:SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS", output)
        self.assertIn("  notes.txt", output)
        self.assertNotIn("stock.dll", output)
        self.assertIn("allowed: 1 hit(s) in 1 place(s) of the unchanged native Python runtime", output)
        self.assertIn("result: FAIL (5 hit(s) in 3 place(s))", output)
        self.assertNotIn(self.USER, output, "the scan printed a matched value")
        self.assertNotIn(folder, output, "paths are relative to the folder")

    def test_home_paths_mode_passes_a_clean_folder(self):
        with Tree({"a.dll": b"MZ\0\0 nothing\0", "b.txt": "plain\n"}) as root:
            code, output = run("--home-paths", root)
        self.assertEqual(code, 0, output)
        self.assertIn("result: PASS (0 hit(s)", output)

    def test_build_winemac_maps_the_checkout_out_of_the_modules(self):
        script = (PROJECT / "scripts/build_winemac.sh").read_text()
        self.assertIn('PREFIX_MAP="-ffile-prefix-map=${WORKSPACE_ROOT}=/macsw"', script)
        self.assertIn('-ffile-prefix-map=${WORKSPACE_PHYSICAL}=/macsw', script)
        configure = script.split('"${SOURCE_DIR}/configure"', 1)[1].split("popd", 1)[0]
        self.assertIn('    CFLAGS="-O2 ${PREFIX_MAP}" \\\n', configure)
        # Wine's configure takes the flags of the PE (mingw) builds from CROSSCFLAGS.
        self.assertIn('    CROSSCFLAGS="-g -O2 ${PREFIX_MAP}" \\\n', configure)
        self.assertLess(script.index("PREFIX_MAP="), script.index('"${SOURCE_DIR}/configure"'))
        # The build key covers this script, so the change rebuilds the modules.
        self.assertIn(":${SCRIPT_SHA256}", script)


class IconTests(unittest.TestCase):
    def test_solidworks_icon_passes_only_when_it_is_macsw_icon(self):
        own = b"icns-macsw"
        with Tree({"MacSW.app/Contents/Resources/AppIcon.icns": own,
                   "SOLIDWORKS.app/Contents/Resources/AppIcon.icns": own}) as root:
            self.assertEqual(counts(root), {})
        with Tree({"MacSW.app/Contents/Resources/AppIcon.icns": own,
                   "SOLIDWORKS.app/Contents/Resources/AppIcon.icns": b"icns-from-exe"}) as root:
            self.assertEqual(counts(root), {"proprietary-file": 1})


class FileListTests(unittest.TestCase):
    def test_file_list(self):
        own, other = "a" * 64, "b" * 64
        good = ["MacSW.app/", f"MacSW.app/Contents/Resources/AppIcon.icns\tsha256={own}",
                f"MacSW.app/Contents/Resources/SOLIDWORKS.app.zip:SOLIDWORKS.app/Contents/Resources/AppIcon.icns\tsha256={own}",
                "MacSW.app/Contents/Resources/Wine/lib/wine/x86_64-windows/kernelbase.dll",
                "MacSW.app/Contents/Resources/Wine/share/wine/mono/System.Runtime.InteropServices.dll",
                "MacSW.app/Contents/Resources/Wine/lib/wine/x86_64-windows/stdole2.tlb",
                "MacSW.app/Contents/Resources/Wine/lib/wine/i386-windows/stdole32.tlb",
                "Licenses/THIRD_PARTY_NOTICES.txt",
                "MacSW.app/Contents/Resources/Wine/share/wine/mono/wine-mono-11.3.0/support/winemono-support.m" + "si",
                "MacSW.app/Contents/Resources/Wine/share/wine/gecko/x/browser/features/" + "pocket" + "@" + "mozilla.org.xpi"]
        with tempfile.TemporaryDirectory() as folder:
            listing = Path(folder, "list.txt")
            listing.write_text("\n".join(good) + "\n")
            self.assertEqual(run("--file-list", listing)[0], 0)
            listing.write_text("\n".join(good[:2] + [good[2].replace(own, other)]) + "\n")
            code, output = run("--file-list", listing)
            self.assertEqual(code, 1)
            self.assertIn("proprietary-file", output)
            listing.write_text("media/swwi/data/solidworks.m" + "si\n")
            self.assertEqual(run("--file-list", listing)[0], 1)
            listing.write_text("data/x.c" + "ab\n")
            self.assertEqual(run("--file-list", listing)[0], 1)

    def test_list_volume_lists_zip_entries_and_icon_hashes(self):
        with tempfile.TemporaryDirectory() as folder:
            volume = Path(folder, "vol")
            resources = volume / "MacSW.app/Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "AppIcon.icns").write_bytes(b"icns-macsw")
            with zipfile.ZipFile(resources / "SOLIDWORKS.app.zip", "w") as archive:
                archive.writestr("SOLIDWORKS.app/Contents/Resources/AppIcon.icns", b"icns-macsw")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(SCAN.main(["--list-volume", str(volume)]), 0)
            listing = out.getvalue()
            digest = hashlib.sha256(b"icns-macsw").hexdigest()
            self.assertIn(f"MacSW.app/Contents/Resources/AppIcon.icns\tsha256={digest}\n", listing)
            self.assertIn("SOLIDWORKS.app.zip:SOLIDWORKS.app/Contents/Resources/AppIcon.icns\tsha256=" + digest, listing)
            self.assertNotIn(folder, listing, "paths are relative to the volume")
            Path(folder, "list.txt").write_text(listing)
            self.assertEqual(run("--file-list", Path(folder, "list.txt"))[0], 0)


class CommandTests(unittest.TestCase):
    def test_usage_errors(self):
        self.assertEqual(run("/nonexistent/folder")[0], 2)
        self.assertEqual(run()[0], 2)

    def test_the_scanner_and_this_test_pass_their_own_scan(self):
        with Tree({"publication_scan.py": SCANNER.read_bytes(),
                   "test_publication_scan.py": Path(__file__).read_bytes()}) as root:
            results, _, _ = SCAN.scan_folder(root, env_terms())
            self.assertEqual(results, {})


class PublicTreeScriptTests(unittest.TestCase):
    SCRIPT = PROJECT / "scripts/make_public_tree.sh"

    def test_script_parses_and_removes_the_named_paths(self):
        subprocess.run(["bash", "-n", str(self.SCRIPT)], check=True)
        text = self.SCRIPT.read_text()
        removed = (PROJECT / "scripts/ci/public-tree-remove.txt").read_text()
        for path in ("docs/runtime-ci.md", "docs/TODO.md", "docs/superpowers", ".codex", "README.cn.md",
                     "docs/rc3-team.md", "docs/rc3.md"):
            self.assertRegex(removed, rf"(?m)^{re.escape(path)} +#", path)
        self.assertIn('REMOVE_LIST="${SCRIPT_DIR}/ci/public-tree-remove.txt"', text)
        self.assertIn('python3 -I -B "${SCANNER}" --terms-file "${TERMS}" "${OUT}"', text)

    def test_script_refuses_a_bad_ref_and_a_folder_that_is_not_empty(self):
        with tempfile.TemporaryDirectory() as folder, TermsFile() as terms:
            Path(folder, "x").write_text("x")
            env = dict(os.environ, **{SCAN.TERMS_ENVIRONMENT: str(terms)})
            for args in (["no-such-ref-xyz", Path(folder, "new")], ["HEAD", folder], ["HEAD"]):
                result = subprocess.run(["bash", str(self.SCRIPT), *map(str, args)], capture_output=True, text=True,
                                        env=env)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_script_archives_the_ref_of_macsw_source_tree(self):
        with tempfile.TemporaryDirectory() as folder, TermsFile() as terms:
            repo = Path(folder, "repo")
            (repo / "docs").mkdir(parents=True)
            (repo / "README.md").write_text("kept\n")
            (repo / "docs/TODO.md").write_text("left out\n")
            git = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                   "-C", str(repo)]
            for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "one"]):
                subprocess.run(git + args, check=True, capture_output=True)
            env = dict(os.environ, **{SCAN.TERMS_ENVIRONMENT: str(terms), "MACSW_SOURCE_TREE": str(repo)})
            out = Path(folder, "out")
            result = subprocess.run(["bash", str(self.SCRIPT), "HEAD", str(out)], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(sorted(p.relative_to(out).as_posix() for p in out.rglob("*")), ["README.md", "docs"])
            self.assertIn("result: PASS (0 hit(s)", result.stdout)

    def test_script_needs_the_terms_file(self):
        with tempfile.TemporaryDirectory() as folder:
            env = {k: v for k, v in os.environ.items() if k != SCAN.TERMS_ENVIRONMENT}
            for value in (None, str(Path(folder, "missing.txt"))):
                if value:
                    env[SCAN.TERMS_ENVIRONMENT] = value
                result = subprocess.run(["bash", str(self.SCRIPT), "HEAD", str(Path(folder, "out"))],
                                        capture_output=True, text=True, env=env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("MACSW_SCAN_TERMS", result.stderr)
                self.assertFalse(Path(folder, "out").exists())
        self.assertIn('--terms-file "${TERMS}" "${OUT}"', self.SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
