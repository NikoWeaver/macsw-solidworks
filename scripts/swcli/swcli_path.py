"""Translate local paths without starting Wine or aliasing its C drive through Z."""

from __future__ import annotations

import os
from pathlib import Path
import re
import sys


def translate(value: str, *, prefix: str | None = None) -> str:
    if re.match(r"^[A-Za-z]:[\\/]", value) or value.startswith("\\\\"):
        return value

    path = Path(value).expanduser().resolve()
    bottle = Path(
        prefix
        or os.environ.get("WINEPREFIX")
        or os.environ.get("MACSW_WINEPREFIX")
        or Path.home() / "Library/Application Support/MacSW/bottle"
    ).expanduser()
    matches = []
    for drive in (bottle / "dosdevices").iterdir():
        if not re.fullmatch(r"[A-Za-z]:", drive.name) or not drive.is_dir():
            continue
        root = drive.resolve()
        try:
            relative = path.relative_to(root)
        except ValueError:
            continue
        matches.append((len(root.parts), drive.name.upper(), relative))
    if not matches:
        raise ValueError(f"no configured Wine drive maps local path: {path}")
    # Prefer the most specific drive root, not a broader root alias such as Z:.
    # Resolve equal-root aliases deterministically by drive letter.
    _, letter, relative = sorted(matches, key=lambda item: (-item[0], item[1]))[0]
    return letter + "\\" + "\\".join(relative.parts)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: swcli-path PATH", file=sys.stderr)
        return 2
    try:
        print(translate(sys.argv[1]))
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"swcli-path: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
