#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES.txt for a packaged MacSW.app from config/third-party-notices.tsv.

    third_party_notices.py --inventory TSV --texts DIR --wine-source TAR --repo DIR
                           --contents APP/Contents --output FILE [--set NAME=VALUE ...]

The build stops (exit 1) when a part of the bundle is not in the table, when a listed path is
missing, or when a licence text cannot be read. Each licence text is printed once, at the end.
"""
import argparse
import fnmatch
import html.parser
import re
import sys
import tarfile
import textwrap
from pathlib import Path

COLUMNS = ("component", "version", "licence", "paths", "source", "texts", "note")
# Every entry directly in these folders must belong to a component (relative to Contents/).
COVERED = ("MacOS", "Resources/managed", "Resources/Wine/bin", "Resources/Wine/lib",
           "Resources/Wine/share/wine", "Resources/SWCLI/runtime")
RULE = "-" * 78
TRADEMARK = (
    "SOLIDWORKS is a registered trademark of Dassault Systemes SolidWorks Corporation. This app is "
    "not made, endorsed or supported by Dassault Systemes. It contains no SOLIDWORKS program files; "
    "you install SOLIDWORKS from your own licensed media."
)


class NoticeError(Exception):
    pass


def expand(text, values):
    def replace(match):
        name = match.group(1)
        if name not in values:
            raise NoticeError(f"unknown value ${{{name}}} in the inventory")
        return values[name]
    return re.sub(r"\$\{(\w+)\}", replace, text)


def read_inventory(path, values):
    rows = []
    for number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) == len(COLUMNS) - 1:
            fields.append("")  # an empty note: editors drop the trailing tab
        if len(fields) != len(COLUMNS):
            raise NoticeError(f"{path}:{number}: {len(fields)} columns, expected {len(COLUMNS)}")
        row = {key: expand(value.strip(), values) for key, value in zip(COLUMNS, fields)}
        row["paths"] = [p for p in row["paths"].split(",") if p]
        row["texts"] = [t for t in row["texts"].split(",") if t]
        if not row["paths"]:
            raise NoticeError(f"{path}:{number}: {row['component']} has no paths")
        if not row["texts"] and not row["note"]:
            raise NoticeError(f"{path}:{number}: {row['component']} has no licence text and no note")
        rows.append(row)
    return rows


def bundle_entries(contents):
    """Relative paths of every entry in the COVERED folders (directories are not entered)."""
    entries = []
    for folder in COVERED:
        base = contents / folder
        if base.is_dir():
            entries += [f"{folder}/{child.name}" for child in sorted(base.iterdir())]
    return entries


def matches(pattern, relative):
    return fnmatch.fnmatchcase(relative, pattern.lstrip("?"))


def select_rows(rows, contents):
    """Drops optional rows that match nothing, and checks that every required path exists."""
    kept = []
    for row in rows:
        optional = all(p.startswith("?") for p in row["paths"])
        found = [p for p in row["paths"] if list(contents.glob(p.lstrip("?")))]
        missing = [p for p in row["paths"] if not p.startswith("?") and p not in found]
        if optional and not found:
            continue
        if missing:
            raise NoticeError(f"{row['component']}: not in the bundle: {', '.join(missing)}")
        kept.append(row)
    return kept


def check_coverage(rows, contents):
    patterns = [p for row in rows for p in row["paths"]]
    unlisted = [entry for entry in bundle_entries(contents)
                if not any(matches(p, entry) for p in patterns)]
    if unlisted:
        raise NoticeError("not in config/third-party-notices.tsv: " + ", ".join(unlisted))


class _HTMLText(html.parser.HTMLParser):
    BLOCKS = {"p", "br", "div", "pre", "li", "tr", "dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "hr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.skip, self.pre = [], 0, 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        elif tag in self.BLOCKS:
            self.pre += tag == "pre"
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCKS:
            self.pre = max(0, self.pre - (tag == "pre"))
            self.parts.append("\n")

    def handle_data(self, data):
        # Licence texts are in <pre> and keep their layout; other text is reflowed by the page.
        if not self.skip:
            self.parts.append(data if self.pre else re.sub(r"\s+", " ", data))


def html_to_text(markup):
    parser = _HTMLText()
    parser.feed(markup)
    lines = [line.rstrip() for line in "".join(parser.parts).splitlines()]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip() + "\n"


def wine_files(args, references):
    """The wine: texts, read in one pass over the archive (it is xz-compressed)."""
    wanted = {f"{args.wine_root}/{r.partition(':')[2]}": r for r in references if r.startswith("wine:")}
    found = {}
    if wanted:
        with tarfile.open(args.wine_source) as archive:
            for member in archive:
                if member.name in wanted and member.isfile():
                    found[wanted[member.name]] = archive.extractfile(member).read()
                    if len(found) == len(wanted):
                        break
    missing = sorted(set(wanted.values()) - set(found))
    if missing:
        raise NoticeError(f"not in {args.wine_source}: {', '.join(missing)}")
    return found


def read_text(reference, args, wine):
    kind, _, name = reference.partition(":")
    if kind == "text":
        data = (Path(args.texts) / name).read_bytes()
    elif kind == "repo":
        data = (Path(args.repo) / name).read_bytes()
    elif kind == "bundle":
        data = (Path(args.contents) / name).read_bytes()
    elif kind == "wine":
        data = wine[reference]
    else:
        raise NoticeError(f"{reference}: unknown text kind")
    text = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
    if name.endswith(".html"):
        text = html_to_text(text)
    if not text.strip():
        raise NoticeError(f"{reference}: empty")
    return text.rstrip("\n") + "\n"


def text_title(reference, wine_root):
    kind, _, name = reference.partition(":")
    return {"text": f"resources/licenses/third-party/{name}", "repo": name,
            "bundle": f"MacSW.app/Contents/{name}", "wine": f"{wine_root}/{name}"}[kind]


def render(rows, args, values):
    texts = []
    for row in rows:
        texts += [t for t in row["texts"] if t not in texts]
    label = {reference: f"T{number}" for number, reference in enumerate(texts, 1)}
    out = [f"MacSW {values['APP_VERSION']} (build {values['APP_BUILD']}): third-party notices",
           "=" * 78, "",
           "MacSW.app contains the software listed below. Each part keeps its own licence and",
           "copyright notices; the licence texts follow the list. SOURCE.txt says where to get",
           "the source code of the parts under the GNU LGPL and of MacSW itself.", ""]
    out += textwrap.wrap(TRADEMARK, 78) + ["", "Contents:"]
    for number, row in enumerate(rows, 1):
        out += textwrap.wrap(f"{row['component']} ({row['licence']})", 78,
                             initial_indent=f"  {number:2}. ", subsequent_indent=" " * 6, break_on_hyphens=False)
    for number, row in enumerate(rows, 1):
        fields = [("Version", row["version"]), ("Licence", row["licence"]),
                  ("In MacSW.app", ", ".join("Contents/" + p.lstrip("?") for p in row["paths"])),
                  ("Source", row["source"])]
        if row["texts"]:
            fields.append(("Texts", ", ".join(f"[{label[t]}]" for t in row["texts"])))
        out += ["", RULE, f"{number}. {row['component']}", ""]
        for name, value in fields:
            out += textwrap.wrap(value, 78, initial_indent=f"   {name + ':':14}", subsequent_indent=" " * 17,
                                 break_on_hyphens=False, break_long_words=False)
        if row["note"]:
            out += [""] + textwrap.wrap(row["note"], 78, initial_indent="   ", subsequent_indent="   ",
                                        break_on_hyphens=False, break_long_words=False)
    out += ["", RULE, "Licence texts", RULE]
    wine = wine_files(args, texts)
    for reference in texts:
        out += ["", f"[{label[reference]}] {text_title(reference, args.wine_root)}", "", read_text(reference, args, wine)]
    return "\n".join(out).rstrip("\n") + "\n"


def patch_range(repo):
    numbers = sorted(p.name[:4] for p in (Path(repo) / "patches/wine-crossover").glob("[0-9][0-9][0-9][0-9]-*.patch"))
    if not numbers:
        raise NoticeError("no patches in patches/wine-crossover")
    return f"{numbers[0]}-{numbers[-1]}"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for option in ("inventory", "texts", "wine-source", "repo", "contents", "output"):
        parser.add_argument(f"--{option}", required=True)
    parser.add_argument("--wine-root", help="top folder of the Wine archive (default: wine-<WINE_VERSION>)")
    parser.add_argument("--set", action="append", default=[], metavar="NAME=VALUE")
    args = parser.parse_args(argv)
    values = dict(item.split("=", 1) for item in args.set)
    try:
        values.setdefault("PATCHES", patch_range(args.repo))
        args.wine_root = args.wine_root or f"wine-{values.get('WINE_VERSION', '')}"
        contents = Path(args.contents)
        rows = select_rows(read_inventory(args.inventory, values), contents)
        check_coverage(rows, contents)
        Path(args.output).write_text(render(rows, args, values), encoding="utf-8")
    except (NoticeError, OSError, KeyError, tarfile.TarError) as error:
        print(f"third_party_notices.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
