#!/usr/bin/env -S python3 -I
"""Checks a source tree, or the file list of a release DMG, before it is published.

    python3 -I scripts/ci/publication_scan.py --terms-file <terms> <folder>
    python3 -I scripts/ci/publication_scan.py --terms-file <terms> --file-list <list.txt>
    python3 -I scripts/ci/publication_scan.py --list-volume <mounted DMG> > <list.txt>
    python3 -I scripts/ci/publication_scan.py --home-paths <mounted DMG or app>

It looks for personal data (home folders, e-mail addresses, the owner's name, the university's
name, Box account folders, MAC addresses, the edition words of a student or academic licence, as
in a SOLIDWORKS window title), serial-shaped strings, the words of the upstream CI
that bypassed licensing (removed in this fork), proprietary file types (SOLIDWORKS documents and macros, interop DLLs,
installer packages, licence files, an icon taken from SLDWORKS.exe, a stdole.dll that is not MacSW's clean-room build) and
secrets (private keys, tokens).

It prints counts and paths only, never a matched value. Exit status: 0 when nothing is found,
1 on any hit, 2 on a usage error.

A folder scan reads every file below the folder except `.git`. Files with a NUL byte in their
first 8 KiB are binary: their names are checked, and their bytes for home folders only (as
`--home-paths` does). A file list has one path per line, as `--list-volume` writes it: paths
relative to the volume, entries of a `.zip` archive as `<archive>.zip:<entry>`, and a tab and
`sha256=<hex>` after each `.icns` and `stdole.dll` file. A file list has names only, so for a DMG
also run `--home-paths` on the mounted volume.

`--home-paths` reads the bytes of every file below a folder, and of every entry of each zip
archive in it (`.zip`, `.whl`, `.jar`, `.xpi`, `.ja`, `.nupkg`), and counts home folders of real
users (`/Users/<user>`, `C:\\users\\<user>`) in ASCII and UTF-16. A compiled module keeps the
folder it was built in (debug information, `__FILE__`). Run it on the mounted DMG before the DMG
goes on a release. It checks no other category: word lists and data tables in a bundle give
false hits for words. Allowed: the unchanged native Python runtime
(`SWCLI/runtime/PythonNative/lib/python3.*/` site-packages, ensurepip and venv): examples in
its packages and pip's launchers name their authors' folders. The report counts these apart.

The private terms (the owner's name, the owner's account name and the university's name) are
not in this tree. They come from a terms file outside the tree: `--terms-file <file>`, or the
file that the environment variable MACSW_SCAN_TERMS names. In CI, write the file from a
repository secret. One term per line, `<category> <mode> <word>`: the category is owner-name,
owner-account or institution; the mode is `word` (a whole word, after camelCase is split:
"FooBar" is "foo" and "bar") or `part` (also inside a longer word). Lines that start with `#`
are comments. A category with no term in the file is not checked, and the report says so
("owner-name, owner-account, institution: not checked") instead of PASS.

Allowed on purpose (documented placeholders and fixtures):
- the fork's repository `github.com/NikoWeaver/macsw-solidworks` and the noreply commit
  identity (ALLOWED_LITERALS); e-mail addresses with `noreply`, domains with an `example`
  label (example.com, licenses.example.edu) or the TLDs `.example`, `.invalid`, `.test`,
  `.localhost`, image names such as `icon@2x.png`, and Gecko add-on files (`<id>@<host>.xpi`);
- e-mail addresses in licence texts and in the `From:` line of a `.patch` file (credits that
  the licences ask us to keep);
- home folders of placeholder users (PLACEHOLDER_USERS: `/Users/Shared`, `/Users/fakeuser`,
  `C:\\users\\Public`, `C:\\users\\...`) and placeholder cloud accounts (`Box-Box`);
- the MAC address 02:00:00:00:00:00 that macOS shows to apps, and fake MAC addresses with a
  first pair of 00 or 02 and five pairs of one repeated hex digit (`02:11:22:33:44:55`);
- serial-shaped strings whose first group is 0000 and whose every group is one digit four
  times (`0000 1111 2222 3333 4444 5555`); GUIDs are taken out before the serial check;
- the name of the removed licence server daemon on a line that says it was removed or is never
  used;
- the support installer of Wine Mono (`share/wine/mono/.../winemono-support.msi` and `.cab`).
"""
import argparse
import hashlib
import os
import re
import sys
import zipfile
from collections import Counter
from pathlib import Path

TERMS_ENVIRONMENT = "MACSW_SCAN_TERMS"
TERM_CATEGORIES = ("owner-name", "owner-account", "institution")
TERM_WORD = re.compile(r"^[A-Za-z]{3,}$")

# Taken out of the text (case-insensitive) before any rule runs.
ALLOWED_LITERALS = (
    "32555502+NikoWeaver@users.noreply.github.com",
    "github.com/NikoWeaver/macsw-solidworks",
    "NikoWeaver/macsw-solidworks",
)

CATEGORIES = (
    "home-path", "windows-home-path", "e-mail", "owner-name", "owner-account", "institution",
    "box-account-folder", "mac-address", "serial", "installer-serial-property",
    "activation-request", "licence-edition", "licence-bypass-term", "proprietary-file", "secret",
)

PLACEHOLDER_USERS = {
    "shared", "you", "user", "username", "name", "me", "runner", "example", "test", "tester",
    "fake", "fakeuser", "otheruser", "fixture", "dev", "member", "someone", "public", "default",
    "default user", "all users", "guest",
}
PLACEHOLDER_TLDS = (".example", ".invalid", ".test", ".localhost")
IMAGE_SCALE = re.compile(r"(?i)^[0-9]+x\.")
HOME_CATEGORIES = ("home-path", "windows-home-path")
ZIP_SUFFIXES = (".zip", ".whl", ".jar", ".xpi", ".ja", ".nupkg")
THIRD_PARTY_HOME_PATHS = re.compile(
    r"(^|/)SWCLI/runtime/PythonNative/lib/python3\.[0-9]+/(site-packages|ensurepip/_bundled|venv/scripts)/"
)

# Character classes keep these patterns from matching this file itself.
HOME_PATH = re.compile(r"/Users/([^/\s\"'<>$`\\(){}\[\]*,;:|]+)")
WINDOWS_HOME = re.compile(r"(?i)\b[a-z]:(?:\\{1,2}|/)users(?:\\{1,2}|/)([^\\/\s\"'<>%$`{}\[\]*,;:|]+)")
LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@(" + LABEL + r"(?:\." + LABEL + r")*\.[A-Za-z]{2,})(?![A-Za-z0-9-])")
CLOUD_ACCOUNT = re.compile(r"CloudStorage/(Box|OneDrive|GoogleDrive|Dropbox)-([^/\s\"'<>`)\]]+)")
CLOUD_ACCOUNT_PLACEHOLDERS = {"box", "personal", "work", "team", "account", "*"}
BOX_FOLDER = re.compile(r"(?i)MacSW[ _-]?Tr[a]nsfer")
MAC = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}([:-]))(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
GUID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
SERIAL = re.compile(r"(?<![0-9A-Za-z])[0-9]{4}(?:[ -]?[0-9]{4}){5}(?![0-9A-Za-z])")
SERIAL_PROPERTY = re.compile(r"SERIALNUMBER\s*=\s*['\"]?(?!0000)[0-9]{4}")
ACTIVATION_REQUEST = re.compile(r"SWActivate[R]equest_[0-9]{6,}")
# The edition words of a student or academic licence (the main-window title of SOLIDWORKS names
# them). They tell the kind of the owner's own licence. The words can wrap onto the next line, also
# in a comment or a quote ("#", "*", "/", ">").
EDITION_GAP = r"[\s#*/>]+"
LICENCE_EDITION = re.compile(
    r"(?i)\bfor" + EDITION_GAP + r"stud[e]nts?\b"
    r"|\bacad[e]mic" + EDITION_GAP + r"use\b"
    r"|\b(?:educ[a]tion(?:al)?|stud[e]nt|acad[e]mic)" + EDITION_GAP + r"edition\b"
)
BYPASS_TERMS = (
    re.compile(r"\bS[S]Q\b"),
    re.compile(r"(?i)cr[a]ck"),
    re.compile(r"(?i)serials[_]licensing"),
    re.compile(r"(?i)fake[ _-]serial"),
    re.compile(r"(?i)private/[a]ssets"),
)
# The same home folders in bytes, in ASCII and in UTF-16LE (wide strings of Windows modules).
NAME_BYTES = rb"[A-Za-z0-9._-]"
HOME_PATH_BYTES = (
    re.compile(rb"/Us[e]rs/(" + NAME_BYTES + rb"+)"),
    re.compile(rb"/\0U\0s\0e\0r\0s\0/\0((?:" + NAME_BYTES + rb"\0)+)"),
)
WINDOWS_HOME_BYTES = (
    re.compile(rb"(?i)(?<![A-Za-z])[a-z]:(?:\\{1,2}|/)us[e]rs(?:\\{1,2}|/)(" + NAME_BYTES + rb"+)"),
    re.compile(rb"(?i)(?<![A-Za-z]\0)[a-z]\0:\0(?:\\\0){1,2}u\0s\0e\0r\0s\0(?:\\\0){1,2}((?:" + NAME_BYTES + rb"\0)+)"),
)
DAEMON = re.compile(r"(?i)lm[g]rd")
DAEMON_OK = re.compile(r"(?i)remov|never|no longer")
SECRETS = (
    re.compile(r"-----BEGIN[ A-Z]*PRIV[A]TE KEY-----"),
    re.compile(r"\bsk-(?:ant-|proj-|or-v1-)?[A-Za-z0-9_-]{32,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36}\b"),
    re.compile(r"\bgithub_p[a]t_[A-Za-z0-9_]{40,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{20,}"),
    re.compile(r"\bAK[I]A[0-9A-Z]{16}\b"),
    re.compile(r"\bAI[z]a[0-9A-Za-z_-]{35}\b"),
    re.compile(r"(?i)\b[A-Z0-9_]*(?:API_?KEY|SECRET|TOKEN|PASSWORD)\b\s*[:=]\s*['\"][A-Za-z0-9/+_.=-]{20,}['\"]"),
    re.compile(r"(?m)^\s*(?:export\s+)?[A-Z0-9_]*(?:API_KEY|SECRET|TOKEN|PASSWORD)=[A-Za-z0-9/+_.=-]{20,}\s*$"),
)

PROPRIETARY_NAME = re.compile(
    r"(?i)(\.sld[a-z]*|\.swp|\.swb|\.msi|\.msp|\.cab|\.lic|\.tsf)$"
    r"|(^|[/:])(?:solidworks|sldworks)[^/]*\.(?:dll|exe)$"
    r"|(^|[/:.])interop\.[^/]*\.dll$"  # SolidWorks.Interop.*.dll, Interop.*.dll; not InteropServices.dll
)
# Microsoft's stdole.dll: its licence terms allow no distribution (not Wine's stdole2.tlb). Allowed only
# with the SHA-256 of MacSW's clean-room build (third_party/stdole-clean, STDOLE_DLL_SHA256).
STDOLE_NAME = re.compile(r"(?i)(^|[/:])stdole\.dll$")
CLEAN_STDOLE_SHA256 = "e5d0ce39bfc7620ace151778527ebefeb92a255678c83ff6cc3cb8f550f1bac9"
WINE_MONO_INSTALLER = re.compile(r"(?i)(^|/)share/wine/mono/(?:[^/]+/)*winemono-[^/]*\.(?:msi|cab)$")
SECRET_NAME = re.compile(r"(?i)(\.p12|\.pfx|\.keychain|\.keychain-db|\.mobileprovision)$|(^|/)id_(rsa|ecdsa|ed25519)$")
SOLIDWORKS_BUNDLE = re.compile(r"(?i)(solidworks\.app[/:]|sldworks)")
LICENCE_TEXT = re.compile(
    r"(?i)(^|/)(resources/licenses/|third_party/)|(^|/)(license|licence|copying|notice|patents)[^/]*$"
)
WORD = re.compile(r"[A-Za-z]+")
CAMEL = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])")


class TermsFileError(ValueError):
    pass


def read_terms(path):
    """(category, mode, word) of each line of a terms file. Errors name the line, never its text."""
    terms = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if (len(parts) != 3 or parts[0] not in TERM_CATEGORIES or parts[1] not in ("word", "part")
                or not TERM_WORD.match(parts[2])):
            raise TermsFileError(f"line {number}: expected '<category> word|part <letters>'"
                                 f" with a category of {', '.join(TERM_CATEGORIES)}")
        terms.append((parts[0], parts[1], parts[2].lower()))
    return terms


class Terms:
    """Finds the private terms (from a terms file) in a text."""

    def __init__(self, terms=()):
        self.word = {}   # word -> category
        self.part = {}
        for category, mode, word in terms:
            (self.word if mode == "word" else self.part)[word.lower()] = category
        self.categories = set(self.word.values()) | set(self.part.values())
        self.cache = {}

    def unchecked(self):
        return [c for c in TERM_CATEGORIES if c not in self.categories]

    def _run_hits(self, run):
        hits = self.cache.get(run)
        if hits is None:
            hits = [self.word[p.lower()] for p in CAMEL.findall(run) if p.lower() in self.word]
            lower = run.lower()
            for word, category in self.part.items():
                hits += [category] * lower.count(word)
            self.cache[run] = hits
        return hits

    def count(self, text):
        found = Counter()
        for run in WORD.findall(text):
            found.update(self._run_hits(run))
        return found


def placeholder_user(name):
    name = name.strip().lower()
    return name in PLACEHOLDER_USERS or not any(c.isalnum() for c in name)


def allowed_email(domain, address, line, path):
    lower = address.lower()
    if "noreply" in lower or "no-reply" in lower:
        return True
    domain = domain.lower()
    if "example" in domain.split(".") or domain.endswith(PLACEHOLDER_TLDS + (".xpi",)) or IMAGE_SCALE.match(domain):
        return True
    if LICENCE_TEXT.search(path):
        return True
    if path.endswith(".patch") and line.startswith("From:"):
        return True
    return False


def placeholder_mac(value):
    pairs = re.split(r"[:-]", value.lower())
    if pairs == ["02", "00", "00", "00", "00", "00"]:
        return True
    return pairs[0] in ("00", "02") and all(p[0] == p[1] for p in pairs[1:])


def placeholder_serial(value):
    digits = re.sub(r"[^0-9]", "", value)
    groups = [digits[i:i + 4] for i in range(0, 24, 4)]
    return groups[0] == "0000" and all(len(set(g)) == 1 for g in groups)


def scan_text(text, path, terms):
    """Counts of each category in one text (a file's content or a path)."""
    found = Counter()
    for literal in ALLOWED_LITERALS:
        text = re.sub(re.escape(literal), " " * len(literal), text, flags=re.I)
    found.update(terms.count(text))
    found["licence-edition"] += len(LICENCE_EDITION.findall(text))
    for line in text.splitlines():
        for m in HOME_PATH.finditer(line):
            if not placeholder_user(m.group(1)):
                found["home-path"] += 1
        for m in WINDOWS_HOME.finditer(line):
            if not placeholder_user(m.group(1)):
                found["windows-home-path"] += 1
        for m in EMAIL.finditer(line):
            if not allowed_email(m.group(1), m.group(0), line, path):
                found["e-mail"] += 1
        for m in CLOUD_ACCOUNT.finditer(line):
            account = m.group(2).lower()
            if account not in CLOUD_ACCOUNT_PLACEHOLDERS and "example" not in account:
                found["box-account-folder"] += 1
        found["box-account-folder"] += len(BOX_FOLDER.findall(line))
        for m in MAC.finditer(line):
            if not placeholder_mac(m.group(0)):
                found["mac-address"] += 1
        no_guids = GUID.sub(lambda m: " " * len(m.group(0)), line)
        for m in SERIAL.finditer(no_guids):
            if not placeholder_serial(m.group(0)):
                found["serial"] += 1
        found["installer-serial-property"] += len(SERIAL_PROPERTY.findall(line))
        found["activation-request"] += len(ACTIVATION_REQUEST.findall(line))
        for pattern in BYPASS_TERMS:
            found["licence-bypass-term"] += len(pattern.findall(line))
        if DAEMON.search(line) and not DAEMON_OK.search(line):
            found["licence-bypass-term"] += len(DAEMON.findall(line))
        for pattern in SECRETS:
            found["secret"] += len(pattern.findall(line))
    return +found


def home_paths_in_bytes(data):
    """Counts of home folders of real users in the bytes of a file (ASCII and UTF-16LE)."""
    found = Counter()
    for category, patterns in (("home-path", HOME_PATH_BYTES), ("windows-home-path", WINDOWS_HOME_BYTES)):
        for pattern in patterns:
            for m in pattern.finditer(data):
                if not placeholder_user(m.group(1).replace(b"\0", b"").decode("ascii")):
                    found[category] += 1
    return found


def scan_home_paths(root):
    """home_paths_in_bytes of every file below root and of every entry of its zip archives.

    Returns the results, the number of files and entries read, the archives that zipfile cannot
    open (their bytes are still read as one file) and the count of allowed third-party hits."""
    results = {}
    allowed = Counter()
    count = 0
    unread = []

    def add(where, data):
        found = home_paths_in_bytes(data)
        if found and THIRD_PARTY_HOME_PATHS.search(where):
            allowed.update({"hits": sum(found.values()), "places": 1})
        elif found:
            results[where] = found
    for folder, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in sorted(names):
            path = Path(folder, name)
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(root).as_posix()
            count += 1
            add(relative, path.read_bytes())
            if not name.lower().endswith(ZIP_SUFFIXES) or not zipfile.is_zipfile(path):
                continue
            try:
                with zipfile.ZipFile(path) as archive:
                    for info in archive.infolist():
                        if info.is_dir():
                            continue
                        count += 1
                        add(f"{relative}:{info.filename}", archive.read(info))
            except (zipfile.BadZipFile, NotImplementedError, OSError):
                unread.append(relative)
    return results, count, unread, allowed


def scan_name(name):
    found = Counter()
    if PROPRIETARY_NAME.search(name) and not WINE_MONO_INSTALLER.search(name):
        found["proprietary-file"] += 1
    if SECRET_NAME.search(name):
        found["secret"] += 1
    return found


def foreign_stdole(name, digest):
    """A stdole.dll that is not MacSW's clean-room build (no digest: not known, so a hit)."""
    return bool(STDOLE_NAME.search(name)) and digest != CLEAN_STDOLE_SHA256


def icns_from_solidworks(name, digest, own_icons):
    """An .icns of SOLIDWORKS.app (or named after SLDWORKS) that is not MacSW's own icon."""
    if not name.lower().endswith(".icns") or not SOLIDWORKS_BUNDLE.search(name):
        return False
    return digest is None or digest not in own_icons


def scan_folder(root, terms):
    results = {}
    binary = 0
    files = []
    for folder, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in sorted(names):
            if name != ".git":  # a worktree's .git file names the main repository
                files.append(Path(folder, name))
    icons = {}
    for path in files:
        if path.suffix.lower() == ".icns" and path.is_file():
            icons[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    own_icons = {d for n, d in icons.items() if not SOLIDWORKS_BUNDLE.search(n)}
    for path in files:
        relative = path.relative_to(root).as_posix()
        found = scan_name(relative)
        found.update(scan_text(relative, relative, terms))
        if icns_from_solidworks(relative, icons.get(relative), own_icons):
            found["proprietary-file"] += 1
        if STDOLE_NAME.search(relative):
            digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() and not path.is_symlink() else None
            if foreign_stdole(relative, digest):
                found["proprietary-file"] += 1
        if path.is_file() and not path.is_symlink():
            data = path.read_bytes()
            if b"\0" in data[:8192]:
                binary += 1
                found.update(home_paths_in_bytes(data))
            else:
                found.update(scan_text(data.decode("utf-8", "replace"), relative, terms))
        if found:
            results[relative] = found
    return results, len(files), binary


def read_file_list(list_path):
    entries = []
    for line in Path(list_path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        name, _, extra = line.partition("\t")
        digest = extra[len("sha256="):] if extra.startswith("sha256=") else None
        entries.append((name, digest))
    return entries


def scan_file_list(entries, terms):
    results = {}
    own_icons = {d for n, d in entries if d and n.lower().endswith(".icns") and not SOLIDWORKS_BUNDLE.search(n)}
    for number, (name, digest) in enumerate(entries, 1):
        found = scan_name(name)
        found.update(scan_text(name, name, terms))
        if icns_from_solidworks(name, digest, own_icons):
            found["proprietary-file"] += 1
        if foreign_stdole(name, digest):
            found["proprietary-file"] += 1
        if found:
            results[f"line {number}"] = found
    return results, len(entries)


def list_volume(volume, out):
    """Writes the file list of a mounted DMG: relative paths, .zip entries, .icns hashes."""
    volume = Path(volume)
    for folder, dirs, names in os.walk(volume):
        dirs.sort()
        for name in sorted(dirs + names):
            path = Path(folder, name)
            relative = path.relative_to(volume).as_posix()
            if path.is_dir() and not path.is_symlink():
                out.write(relative + "/\n")
                continue
            extra = ""
            if (name.lower().endswith(".icns") or STDOLE_NAME.search(name)) and path.is_file():
                extra = "\tsha256=" + hashlib.sha256(path.read_bytes()).hexdigest()
            out.write(relative + extra + "\n")
            if name.lower().endswith(".zip") and path.is_file() and not path.is_symlink():
                with zipfile.ZipFile(path) as archive:
                    for info in archive.infolist():
                        if info.filename.startswith("__MACOSX/"):
                            continue
                        entry = f"{relative}:{info.filename}"
                        if info.filename.lower().endswith(".icns") or STDOLE_NAME.search(info.filename):
                            entry += "\tsha256=" + hashlib.sha256(archive.read(info)).hexdigest()
                        out.write(entry + "\n")


def report(results, out, unchecked=(), categories=CATEGORIES):
    totals = Counter()
    files = Counter()
    for found in results.values():
        totals.update(found)
        files.update(found.keys())
    for where in sorted(results):
        for category in categories:
            if results[where][category]:
                out.write(f"  {category:<26} {results[where][category]:>5}  {where}\n")
    out.write("counts:\n")
    for category in categories:
        if category in unchecked:
            out.write(f"  {category:<26}   not checked (no term in the terms file)\n")
        else:
            out.write(f"  {category:<26} {totals[category]:>5} in {files[category]} file(s)\n")
    hits = sum(totals.values())
    summary = f"{hits} hit(s) in {len(results)} place(s)"
    if hits:
        result = f"FAIL ({summary})"
    elif unchecked:
        result = f"{', '.join(unchecked)}: not checked; the other categories: {summary}"
    else:
        result = f"PASS ({summary})"
    if hits and unchecked:
        result += f"; {', '.join(unchecked)}: not checked"
    out.write(f"result: {result}\n")
    return hits


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("folder", nargs="?", help="the folder to scan")
    group.add_argument("--file-list", help="a file list, one path per line")
    group.add_argument("--list-volume", help="print the file list of a mounted DMG")
    group.add_argument("--home-paths", help="count home folders in the bytes of every file below a folder")
    parser.add_argument("--terms-file", default=os.environ.get(TERMS_ENVIRONMENT) or None,
                        help=f"the private terms, outside the tree (default: ${TERMS_ENVIRONMENT})")
    args = parser.parse_args(argv)
    out = sys.stdout
    if args.list_volume:
        if not Path(args.list_volume).is_dir():
            parser.error(f"not a folder: {args.list_volume}")
        list_volume(args.list_volume, out)
        return 0
    if args.home_paths:
        if not Path(args.home_paths).is_dir():
            parser.error(f"not a folder: {args.home_paths}")
        results, count, unread, allowed = scan_home_paths(Path(args.home_paths))
        out.write(f"home folders in bytes: {count} files and zip entries\n")
        for relative in unread:
            out.write(f"  note: read as one file, not as a zip archive: {relative}\n")
        if allowed:
            out.write(f"  allowed: {allowed['hits']} hit(s) in {allowed['places']} place(s) of the unchanged"
                      " native Python runtime\n")
        return 1 if report(results, out, categories=HOME_CATEGORIES) else 0
    terms = Terms()
    if args.terms_file:
        if not Path(args.terms_file).is_file():
            parser.error("the terms file does not exist")
        try:
            terms = Terms(read_terms(args.terms_file))
        except (TermsFileError, UnicodeDecodeError) as error:
            parser.error(f"terms file, {error}")
    if args.file_list:
        entries = read_file_list(args.file_list)
        results, count = scan_file_list(entries, terms)
        out.write(f"publication scan: file list, {count} entries\n")
    else:
        root = Path(args.folder)
        if not root.is_dir():
            parser.error(f"not a folder: {args.folder}")
        results, count, binary = scan_folder(root, terms)
        out.write(f"publication scan: {count} files ({binary} binary: name, and bytes for home folders)\n")
    return 1 if report(results, out, terms.unchecked()) else 0


if __name__ == "__main__":
    sys.exit(main())
