"""Separate official installation identity from independently deployed SWCLI.

Only digests are emitted. Configuration is read as literal assignments, never
executed; unknown configuration keys conservatively remain identity inputs.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import sys

PROJECT = Path(__file__).resolve().parents[2]
RELEASE_ONLY = {"APP_VERSION", "APP_BUILD", "APP_RELEASE"}
SWCLI_SOURCE_ONLY = {"SWCLI_VERSION", "SWCLI_SOURCE_COMMIT"}


def read_versions(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)="([^"$`\\]+)"', line.strip())
        if match is None or match[1] in values or not match[2].strip():
            raise ValueError("Invalid literal version configuration")
        values[match[1]] = match[2]
    if not values:
        raise ValueError("Empty version configuration")
    return values


def context_digest(scope, versions, source_hash, *, macos="", architecture="",
                   media_path="", language="", serial=""):
    if scope not in ("assets", "installed-base"):
        raise ValueError("Invalid cache scope")
    if not isinstance(source_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", source_hash):
        raise ValueError("Invalid cache source hash")
    if not versions or any(not isinstance(key, str) or not isinstance(value, str)
                           or not value.strip() for key, value in versions.items()):
        raise ValueError("Invalid version configuration")
    filtered = {key: value for key, value in versions.items()
                if key not in RELEASE_ONLY
                and not (key.startswith("SWCLI_") if scope == "installed-base"
                         else key in SWCLI_SOURCE_ONLY)}
    if not filtered:
        raise ValueError("Missing official runtime configuration")
    context = {"scope": scope, "versions": filtered, "source_hash": source_hash}
    if scope == "installed-base":
        inputs = {"macos": macos, "architecture": architecture,
                  "media_path": media_path, "language": language}
        if any(not isinstance(value, str) or not value.strip() for value in (*inputs.values(), serial)):
            raise ValueError("Incomplete official installation context")
        context.update(inputs, ci_serial_sha256=hashlib.sha256(serial.encode()).hexdigest())
    return hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scope", choices=("assets", "installed-base"))
    args = parser.parse_args()
    versions = read_versions(PROJECT / "config/versions.env")
    if args.scope == "assets":
        digest = context_digest(args.scope, versions, os.environ["MACSW_ASSETS_HASH"])
    else:
        digest = context_digest(args.scope, versions, os.environ["MACSW_INSTALLER_HASH"],
                                macos=platform.mac_ver()[0], architecture=platform.machine(),
                                media_path=os.environ["MACSW_MEDIA_PATH"],
                                language=os.environ["MACSW_CI_LANGUAGE"],
                                serial=os.environ["SW_SERIAL_SOLIDWORKS"])
    print(digest)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Cache identity configuration is invalid.", file=sys.stderr)
        raise SystemExit(1)
