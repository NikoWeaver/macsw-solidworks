#!/usr/bin/env python3
"""Document types of SOLIDWORKS.app, taken from MacSW.app's Info.plist.

    solidworks_app_info.py build <MacSW Info.plist> <SOLIDWORKS Info.plist>   (updates the second file)
    solidworks_app_info.py check <SOLIDWORKS Info.plist> <MacSW Info.plist>

SOLIDWORKS.app declares the same document types and imported UTIs as MacSW.app. It owns the
SOLIDWORKS types (rank Owner, above MacSW's Default), so Finder opens .sldprt/.sldasm/.slddrw
and the templates with it. Neutral CAD formats keep MacSW's rank (Alternate): SOLIDWORKS is
offered in "Open With" but does not take them from other CAD apps. MacSW.app is not changed and
handles every type again when SOLIDWORKS.app is removed.
"""
import plistlib
import sys

NATIVE_PREFIX = "com.dassault.solidworks."


def is_native(entry):
    return all(uti.startswith(NATIVE_PREFIX) for uti in entry["LSItemContentTypes"])


def build(macsw, info):
    info = dict(info)
    types = []
    for entry in macsw["CFBundleDocumentTypes"]:
        entry = dict(entry)
        if is_native(entry):
            entry["LSHandlerRank"] = "Owner"
        types.append(entry)
    info["CFBundleDocumentTypes"] = types
    info["UTImportedTypeDeclarations"] = macsw["UTImportedTypeDeclarations"]
    return info


def check(info, macsw):
    if info.get("UTImportedTypeDeclarations") != macsw["UTImportedTypeDeclarations"]:
        raise ValueError("imported UTIs differ from MacSW.app")
    ours = {tuple(t["LSItemContentTypes"]): t for t in info.get("CFBundleDocumentTypes", [])}
    theirs = {tuple(t["LSItemContentTypes"]): t for t in macsw["CFBundleDocumentTypes"]}
    if ours.keys() != theirs.keys():
        raise ValueError("document types differ from MacSW.app")
    for utis, entry in ours.items():
        expected = "Owner" if is_native(entry) else theirs[utis]["LSHandlerRank"]
        if entry["LSHandlerRank"] != expected:
            raise ValueError("%s: rank %s, expected %s" % (",".join(utis), entry["LSHandlerRank"], expected))
    if not any(is_native(entry) for entry in ours.values()):
        raise ValueError("no SOLIDWORKS document types")


def main(argv):
    if len(argv) != 4 or argv[1] not in ("build", "check"):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    with open(argv[2], "rb") as handle:
        first = plistlib.load(handle)
    with open(argv[3], "rb") as handle:
        second = plistlib.load(handle)
    if argv[1] == "build":
        with open(argv[3], "wb") as handle:
            plistlib.dump(build(first, second), handle)
        return 0
    try:
        check(first, second)
    except (KeyError, ValueError) as error:
        print("solidworks_app_info: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
