"""THIRD_PARTY_NOTICES.txt and the source offer (SOURCE.txt) that package_app.sh puts in MacSW.app."""
import hashlib
import importlib.util
import io
import os
import re
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("third_party_notices", PROJECT / "scripts/third_party_notices.py")
NOTICES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTICES)

PACKAGE = (PROJECT / "scripts/package_app.sh").read_text()
VERIFY = (PROJECT / "scripts/verify_app.sh").read_text()
INVENTORY = PROJECT / "config/third-party-notices.tsv"
TEMPLATE = (PROJECT / "resources/licenses/Wine-SOURCE.txt.in").read_text()
HEADER = "component\tversion\tlicence\tpaths\tsource\ttexts\tnote\n"


def passed_values():
    """The NAME=VALUE pairs package_app.sh gives the generator."""
    loop = PACKAGE.split("for NOTICE_KEY in ", 1)[1].split("; do", 1)[0]
    return set(loop.replace("\\\n", " ").split())


class RealInventoryTests(unittest.TestCase):
    def setUp(self):
        values = {name: name.lower() for name in passed_values() | {"PATCHES"}}
        self.rows = NOTICES.read_inventory(INVENTORY, values)

    def test_every_value_in_the_table_is_passed_by_package_app(self):
        rows = [line for line in INVENTORY.read_text().splitlines() if not line.startswith("#")]
        used = set(re.findall(r"\$\{(\w+)\}", "\n".join(rows)))
        self.assertLessEqual(used, passed_values() | {"PATCHES"})

    def test_texts_from_the_tree_exist(self):
        for row in self.rows:
            for reference in row["texts"]:
                kind, _, name = reference.partition(":")
                self.assertIn(kind, {"text", "wine", "bundle", "repo"}, reference)
                if kind == "text":
                    self.assertTrue((PROJECT / "resources/licenses/third-party" / name).is_file(), reference)
                if kind == "repo":
                    self.assertTrue((PROJECT / name).is_file(), reference)

    def test_every_vendored_text_is_used(self):
        used = {r.partition(":")[2] for row in self.rows for r in row["texts"] if r.startswith("text:")}
        present = {p.name for p in (PROJECT / "resources/licenses/third-party").iterdir()}
        self.assertEqual(used, present)

    def test_the_msi_helper_that_package_app_ships_is_listed(self):
        self.assertIn('"${RESOURCES_DIR}/helpers/msi_spatialiop.exe"', PACKAGE)
        macsw = next(row for row in self.rows if row["component"].startswith("MacSW"))
        self.assertIn("Resources/helpers/msi_spatialiop.exe", macsw["paths"])

    def test_the_parts_of_the_plan_inventory_are_listed(self):
        names = " ".join(row["component"] for row in self.rows)
        for part in ("Wine", "GnuTLS", "FreeType", "ICU", "MoltenVK", "Vulkan Loader", "SDL2", "Wine Gecko",
                     "Wine Mono", "7-Zip", "stdole", "Python", "libinotify-kqueue", "zlib", "libpng"):
            self.assertIn(part, names)


class SourceOfferTests(unittest.TestCase):
    def test_no_pointer_to_the_upstream_repository(self):
        self.assertNotIn("github.com/YJBeetle/MacSW", TEMPLATE)

    def test_names_the_build_commit_and_the_wine_archive(self):
        for key in ("@GIT_COMMIT@", "@WINE_SOURCE_URL@", "@WINE_SOURCE_SHA256@", "@APP_RELEASE@"):
            self.assertIn(key, TEMPLATE)

    def test_names_the_fork_repository_and_release_tag(self):
        config = (PROJECT / "scripts/lib/config.sh").read_text()
        self.assertIn('MACSW_SOURCE_URL="${MACSW_SOURCE_URL-https://github.com/NikoWeaver/macsw-solidworks}"', config)
        self.assertIn("@MACSW_SOURCE_ONLINE@\n@MACSW_SOURCE_TAG@\n", TEMPLATE)
        self.assertIn('MACSW_SOURCE_TAG="   Release tag ${APP_RELEASE}: ${MACSW_SOURCE_URL}/releases/tag/${APP_RELEASE}"',
                      PACKAGE)
        self.assertIn("team's Box folder, MacSW/releases", TEMPLATE)

    def test_package_app_fills_every_placeholder(self):
        for key in set(re.findall(r"@(\w+)@", TEMPLATE)) - {"LGPL_SOURCES"}:
            self.assertIn(f'-e "s|@{key}@|', PACKAGE, key)
        self.assertIn('"${WINE_SOURCE_NOTICE_TEMPLATE}" | lgpl_source_lines | cat -s >', PACKAGE)

    def test_the_lgpl_library_and_7zip_sources_are_named_with_their_checksums(self):
        self.assertIn("\n@LGPL_SOURCES@\n", TEMPLATE)
        function = re.search(r"(?ms)^lgpl_source_lines\(\) \{\n.*?^\}\n", PACKAGE).group(0)
        script = f'source "{PROJECT}/scripts/lib/config.sh"\n{function}lgpl_source_lines'
        rendered = subprocess.run(["bash", "-c", script], input=TEMPLATE, capture_output=True, text=True,
                                  check=True).stdout
        self.assertNotIn("@LGPL_SOURCES@", rendered)
        versions = dict(re.findall(r'(?m)^(\w+)="([^"]*)"', (PROJECT / "config/versions.env").read_text()))
        keys = [k[:-len("_SOURCE_URL")] for k in versions if k.endswith("_SOURCE_URL")]
        config = (PROJECT / "scripts/lib/config.sh").read_text()
        listed = re.search(r'MACSW_LGPL_SOURCES="([^"]+)"', config).group(1).split()
        self.assertEqual(sorted(keys), sorted(listed))
        self.assertEqual(len(listed), 9)
        for key in listed:
            if key == "SEVEN_Z":
                self.assertIn("@SEVEN_Z_SOURCE_URL@\n   SHA-256: @SEVEN_Z_SOURCE_SHA256@", TEMPLATE)
                continue
            self.assertIn(f"   {versions[key + '_SOURCE_URL']}\n     SHA-256: {versions[key + '_SOURCE_SHA256']}\n",
                          rendered, key)
            self.assertRegex(versions[key + "_SOURCE_SHA256"], r"^[0-9a-f]{64}$")
            self.assertIn(versions[key + "_VERSION"], versions[key + "_SOURCE_URL"], key)
        self.assertIn('for LGPL_KEY in ${MACSW_LGPL_SOURCES}; do', VERIFY)

    def test_the_lgpl_rows_give_versions_not_library_file_names(self):
        rows = [line.split("\t") for line in INVENTORY.read_text().splitlines() if line and not line.startswith("#")]
        versions = {row[0]: row[1] for row in rows}
        for component, key in (("GnuTLS", "GNUTLS"), ("Nettle", "NETTLE"), ("GMP", "GMP"), ("libtasn1", "LIBTASN1"),
                               ("libunistring", "LIBUNISTRING"), ("libidn2", "LIBIDN2"), ("GNU libiconv", "LIBICONV"),
                               ("GNU gettext (libintl)", "GETTEXT")):
            self.assertTrue(versions[component].startswith("${" + key + "_VERSION}"), component)
            source = next(row[4] for row in rows if row[0] == component)
            self.assertIn("${" + key + "_SOURCE_URL}", source, component)

    def test_commit_is_known_before_the_offer_is_written(self):
        self.assertLess(PACKAGE.index('GIT_COMMIT="$(git'), PACKAGE.index('"s|@GIT_COMMIT@|'))

    def test_both_files_land_in_resources_and_are_verified(self):
        self.assertIn('cp -p "${WINE_LICENSES_DIR}/SOURCE.txt" "${RESOURCES_DIR}/SOURCE.txt"', PACKAGE)
        self.assertIn('--output "${RESOURCES_DIR}/THIRD_PARTY_NOTICES.txt"', PACKAGE)
        self.assertIn('cmp "${WINE_LICENSES_DIR}/SOURCE.txt" "${CONTENTS_DIR}/Resources/SOURCE.txt"', VERIFY)
        self.assertIn('test -s "${THIRD_PARTY_NOTICES}"', VERIFY)
        # A negated command never stops a `set -e` script.
        self.assertNotIn('! grep -Fq "github.com/YJBeetle/MacSW"', VERIFY)

    def test_notices_are_generated_after_the_last_part_is_added(self):
        self.assertLess(PACKAGE.index("package_solidworks_app.sh\" --embed"), PACKAGE.index("third_party_notices.py"))
        self.assertLess(PACKAGE.index("third_party_notices.py"), PACKAGE.index('macsw_codesign "${APP_DIR}"'))

    def test_notice_keeps_upstream_copyright_and_names_the_fork(self):
        notice = (PROJECT / "NOTICE").read_text()
        self.assertIn("Copyright 2026 YJBeetle\n", notice)
        self.assertIn("modified version of MacSW, based on YJBeetle/MacSW commit\n69c5509", notice)
        self.assertTrue((PROJECT / "CHANGES-FROM-UPSTREAM.md").is_file())


class PublishedCommitTests(unittest.TestCase):
    """macsw_commit_is_published (scripts/lib/config.sh): may SOURCE.txt say the commit is online?"""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-published-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.remote = base / "fork.git"
        work = base / "work"
        work.mkdir()
        git(work, "init", "-q")
        (work / "a.txt").write_text("a\n")
        git(work, "add", "a.txt")
        git(work, "commit", "-q", "-m", "one")
        subprocess.run(["git", "clone", "-q", "--bare", str(work), str(self.remote)], check=True, capture_output=True)
        self.clone = base / "clone"
        subprocess.run(["git", "clone", "-q", str(self.remote), str(self.clone)], check=True, capture_output=True)
        self.pushed = subprocess.run(["git", "-C", str(self.clone), "rev-parse", "HEAD"], check=True,
                                     capture_output=True, text=True).stdout.strip()
        (self.clone / "b.txt").write_text("b\n")
        git(self.clone, "add", "b.txt")
        git(self.clone, "commit", "-q", "-m", "two")
        self.local = subprocess.run(["git", "-C", str(self.clone), "rev-parse", "HEAD"], check=True,
                                    capture_output=True, text=True).stdout.strip()

    def published(self, commit, url):
        script = f'source "{PROJECT}/scripts/lib/config.sh"; macsw_commit_is_published "$1" "$2"'
        env = dict(os.environ, MACSW_SOURCE_URL=url)
        return subprocess.run(["bash", "-c", script, "x", str(self.clone), commit], env=env).returncode == 0

    def test_only_a_pushed_commit_of_the_named_repository(self):
        self.assertTrue(self.published(self.pushed, str(self.remote)))
        self.assertTrue(self.published(self.pushed, str(self.remote) + "/"))
        self.assertFalse(self.published(self.local, str(self.remote)), "not pushed")
        self.assertFalse(self.published(self.pushed, ""), "no repository named")
        self.assertFalse(self.published(self.pushed, "https://github.com/NikoWeaver/macsw-solidworks"),
                         "origin is another repository")

    def test_address_forms(self):
        script = f'source "{PROJECT}/scripts/lib/config.sh"; macsw_repo_address "$1"'
        forms = ["https://github.com/NikoWeaver/macsw-solidworks", "https://github.com/nikoweaver/macsw-solidworks.git",
                 "git" + "@" + "github.com:NikoWeaver/macsw-solidworks.git",
                 "ssh://git" + "@" + "github.com/NikoWeaver/macsw-solidworks/"]
        out = {subprocess.run(["bash", "-c", script, "x", f], capture_output=True, text=True).stdout for f in forms}
        self.assertEqual(out, {"https://github.com/nikoweaver/macsw-solidworks\n"})

    def test_package_app_names_the_repository_only_for_a_published_commit(self):
        self.assertIn('if macsw_commit_is_published "${SOURCE_TREE}" "${GIT_COMMIT}"; then', PACKAGE)
        self.assertLess(PACKAGE.index('GIT_COMMIT="$(git'), PACKAGE.index("macsw_commit_is_published"))


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-notices-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.contents = root / "MacSW.app/Contents"
        for relative in ("MacOS/MacSW", "MacOS/7zz", "Resources/Wine/lib/libz.1.dylib",
                         "Resources/Wine/lib/libpng16.16.dylib", "Resources/Wine/bin/wine"):
            path = self.contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\0")
        (self.contents / "Resources/licenses").mkdir(parents=True)
        (self.contents / "Resources/licenses/page.html").write_text(
            "<html><head><style>p{}</style></head><body><p>Mozilla\n   Public &amp; License</p>"
            "<pre>  keep\n    layout</pre></body></html>")
        self.texts = root / "texts"
        self.texts.mkdir()
        (self.texts / "7-Zip.txt").write_text("7-Zip licence\r\n")
        self.repo = root / "repo"
        (self.repo / "patches/wine-crossover").mkdir(parents=True)
        for name in ("0001-a.patch", "0034-b.patch"):
            (self.repo / "patches/wine-crossover" / name).write_text("")
        self.wine = root / "wine.tar.xz"
        with tarfile.open(self.wine, "w:xz") as archive:
            for name, data in {"wine-9.9/COPYING.LIB": b"LGPL 2.1 text\n", "wine-9.9/libs/zlib/LICENSE": b"zlib text\n"}.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        self.inventory = root / "inventory.tsv"
        self.output = root / "THIRD_PARTY_NOTICES.txt"
        self.rows = [
            "MacSW\t${APP_VERSION}\tApache-2.0\tMacOS/MacSW\tupstream\t\tthe app",
            "Wine\t${WINE_VERSION}\tLGPL-2.1-or-later\tResources/Wine/bin/*\twinehq, patches ${PATCHES}\twine:COPYING.LIB\t",
            "zlib\t1.3.1\tZlib\tResources/Wine/lib/libz.*\tzlib.net\twine:libs/zlib/LICENSE",
            "libpng\t1.6\tlibpng-2.0\tResources/Wine/lib/libpng*\tlibpng.org\twine:COPYING.LIB,bundle:Resources/licenses/page.html\t",
            "7-Zip\t23.01\tLGPL\tMacOS/7zz\t7-zip.org\ttext:7-Zip.txt,wine:COPYING.LIB\t",
            "SWCLI\t1\tMIT\t?Resources/SWCLI/runtime/Python311\tswcli\ttext:missing.txt\t",
        ]

    def run_generator(self, rows=None):
        self.inventory.write_text("# comment\n" + "\n".join(rows or self.rows) + "\n")
        return NOTICES.main(["--inventory", str(self.inventory), "--texts", str(self.texts),
                             "--wine-source", str(self.wine), "--repo", str(self.repo),
                             "--contents", str(self.contents), "--output", str(self.output),
                             "--set", "APP_VERSION=0.2.0", "--set", "APP_BUILD=7", "--set", "WINE_VERSION=9.9"])

    def test_every_component_and_each_text_once(self):
        self.assertEqual(self.run_generator(), 0)
        text = self.output.read_text()
        self.assertTrue(text.startswith("MacSW 0.2.0 (build 7): third-party notices\n"))
        self.assertIn("registered trademark of Dassault", text)
        for component in ("1. MacSW", "2. Wine", "3. zlib", "4. libpng", "5. 7-Zip"):
            self.assertIn(component, text)
        self.assertNotIn("SWCLI", text, "an optional row with nothing in the bundle is left out")
        self.assertEqual(text.count("LGPL 2.1 text"), 1)
        self.assertIn("patches 0001-0034", text)
        self.assertIn("7-Zip licence\n", text)
        self.assertNotIn("\r", text)
        self.assertIn("Mozilla Public & License", text)
        self.assertIn("  keep\n    layout", text)
        self.assertNotIn("p{}", text)

    def test_a_part_of_the_bundle_that_is_not_listed_stops_the_build(self):
        (self.contents / "Resources/Wine/lib/libnew.dylib").write_bytes(b"\0")
        self.assertEqual(self.run_generator(), 1)
        self.assertFalse(self.output.exists())

    def test_a_listed_path_that_is_missing_stops_the_build(self):
        (self.contents / "MacOS/7zz").unlink()
        self.assertEqual(self.run_generator(), 1)

    def test_a_missing_text_stops_the_build(self):
        rows = self.rows[:-1] + ["SWCLI\t1\tMIT\t?MacOS/MacSW\tswcli\ttext:missing.txt\t"]
        self.assertEqual(self.run_generator(rows), 1)

    def test_a_row_without_text_needs_a_note(self):
        self.assertEqual(self.run_generator(self.rows[:1] + ["Wine\t1\tLGPL\tResources/Wine/bin/*\tsrc\t\t"]), 1)

    def test_unknown_values_stop_the_build(self):
        self.assertEqual(self.run_generator(self.rows + ["X\t${NOT_SET}\tMIT\tMacOS/MacSW\tsrc\t\tnote"]), 1)


def git(cwd, *args):
    subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                    "-c", "commit.gpgsign=false", "-C", str(cwd), *args],
                   check=True, capture_output=True, text=True)


class SourceRepository:
    """A small git checkout with the staging scripts, the real removal list and fake dist/ archives."""

    COPIED = ("scripts/stage_source_release.sh", "scripts/make_public_tree.sh", "scripts/ci/publication_scan.py",
              "scripts/ci/public-tree-remove.txt", "scripts/lib/config.sh", "config/versions.env")

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macsw-stage-")
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        for relative in self.COPIED:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((PROJECT / relative).read_bytes())
        self.removed = [line.split("#", 1)[0].strip()
                        for line in (PROJECT / "scripts/ci/public-tree-remove.txt").read_text().splitlines()]
        self.removed = [path for path in self.removed if path]
        for path in self.removed:
            target = self.root / path / "x.md" if "." not in Path(path).name else self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("left out\n")
        (self.root / "README.md").write_text("kept\n")
        versions = self.root / "config/versions.env"
        text = versions.read_text()
        values = dict(re.findall(r'(?m)^(\w+)="([^"]*)"', text))
        dist = self.root / "dist"
        dist.mkdir()
        archives = [("WINE_SOURCE_SHA256", "wine-{WINE_VERSION}.tar.xz".format(**values)),
                    ("MONO_SOURCE_SHA256", "mono-{MONO_SOURCE_COMMIT}.tar.gz".format(**values))]
        archives += [(key[:-len("URL")] + "SHA256", url.rsplit("/", 1)[1])
                     for key, url in values.items() if key.endswith("_SOURCE_URL")]
        self.archives = [name for _, name in archives]
        for key, name in archives:
            data = f"fake {key}\n".encode()
            (dist / name).write_bytes(data)
            text = re.sub(rf'(?m)^{key}="[0-9a-f]+"', f'{key}="{hashlib.sha256(data).hexdigest()}"', text)
        versions.write_text(text)
        self.release = dict(re.findall(r'(?m)^(\w+)="([^"]*)"', text))["APP_RELEASE"]
        self.terms = self.base / "terms.txt"
        self.terms.write_text("owner-name word zorblax\nowner-account part quuxacct\ninstitution part frobuni\n")
        git(self.root, "init", "-q")
        git(self.root, "add", "-A", ".", ":!dist")
        git(self.root, "commit", "-q", "-m", "one")

    def stage(self, out, **env):
        environment = dict(os.environ, MACSW_SCAN_TERMS=str(self.terms), MACSW_SOURCE_URL="")
        environment.pop("MACSW_SOURCE_TREE", None)
        environment.update(env)
        return subprocess.run(["bash", str(self.root / "scripts/stage_source_release.sh"), str(out)],
                              capture_output=True, text=True, env=environment)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.temp.cleanup()


class StageSourceReleaseTests(unittest.TestCase):
    def test_archive_is_the_scanned_public_tree(self):
        with SourceRepository() as repo:
            out = repo.base / "out"
            result = repo.stage(out)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            prefix = f"MacSW-{repo.release}-source/"
            with tarfile.open(out / f"MacSW-{repo.release}-source.tar.gz") as archive:
                members = archive.getmembers()
            names = [m.name for m in members]
            self.assertTrue(all(n == prefix.rstrip("/") or n.startswith(prefix) for n in names), names)
            self.assertIn(prefix + "README.md", names)
            self.assertIn(prefix + "scripts/stage_source_release.sh", names)
            for path in repo.removed:
                self.assertFalse(any(n == prefix + path or n.startswith(prefix + path + "/") for n in names), path)
            self.assertFalse(any(n.startswith(prefix + "dist") for n in names), "untracked files")
            self.assertFalse(any(Path(n).name.startswith("._") for n in names))
            for member in members:
                self.assertEqual((member.uid, member.gid, member.uname, member.gname), (0, 0, "", ""), member.name)
                self.assertEqual(member.pax_headers.keys() - {"mtime", "path", "linkpath"}, set(), member.name)
            sums = (out / "SHA256SUMS-source").read_text()
            self.assertIn(f"MacSW-{repo.release}-source.tar.gz", sums)
            self.assertEqual(len(repo.archives), 11, "Wine, Mono, eight LGPL libraries and 7-Zip")
            for name in repo.archives:
                self.assertTrue((out / name).is_file(), name)
                self.assertIn(f"  {name}\n", sums)

    def test_a_missing_or_changed_library_archive_stops_the_staging(self):
        with SourceRepository() as repo:
            gnutls = next(name for name in repo.archives if name.startswith("gnutls-"))
            (repo.root / "dist" / gnutls).write_bytes(b"changed\n")
            result = repo.stage(repo.base / "out")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("Checksum mismatch", result.stderr)
            (repo.root / "dist" / gnutls).unlink()
            result = repo.stage(repo.base / "out")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("make fetch-lgpl-sources", result.stderr)
            self.assertFalse((repo.base / "out").exists())

    def test_a_scan_hit_writes_no_archive(self):
        with SourceRepository() as repo:
            (repo.root / "docs").mkdir(exist_ok=True)
            (repo.root / "docs/notes.md").write_text("built in /Users/" + "zqperson" + "/src\n")
            git(repo.root, "add", "docs/notes.md")
            git(repo.root, "commit", "-q", "-m", "two")
            out = repo.base / "out"
            result = repo.stage(out)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("result: FAIL", result.stdout)
            self.assertFalse((out / f"MacSW-{repo.release}-source.tar.gz").exists())

    def test_without_the_terms_file_nothing_is_written(self):
        with SourceRepository() as repo:
            out = repo.base / "out"
            result = repo.stage(out, MACSW_SCAN_TERMS="")
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse(out.exists())

    def test_a_commit_that_is_not_on_the_fork_repository_is_not_staged(self):
        with SourceRepository() as repo:
            out = repo.base / "out"
            result = repo.stage(out, MACSW_SOURCE_URL="https://github.com/NikoWeaver/macsw-solidworks")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("Never push a branch or tag of the private MacSW repository", result.stderr)
            self.assertFalse(out.exists())

    def test_script_parses(self):
        subprocess.run(["bash", "-n", str(PROJECT / "scripts/stage_source_release.sh")], check=True)

    def test_archive_has_the_release_label_that_source_txt_names(self):
        # Two release candidates of one version must not share a source archive name.
        script = (PROJECT / "scripts/stage_source_release.sh").read_text()
        self.assertIn('TREE_NAME="MacSW-${APP_RELEASE}-source"', script)
        self.assertIn('ARCHIVE="${TREE_NAME}.tar.gz"', script)
        self.assertIn("MacSW-@APP_RELEASE@-source.tar.gz", TEMPLATE)


if __name__ == "__main__":
    unittest.main()
