"""Inventory and sign a disposable MacSW distribution bundle, inside out.

No credentials are exported here. Inventory is read-only; sign is deliberately
explicit and must target a distribution staging copy, never the running App.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts/swcli"))
import wine_runtime
import swcli_runtime

# Each new executable requires review, rather than inheriting Wine exceptions.
WINE_ROOT = "Contents/Resources/Wine"
WINE_ALIAS = "Contents/Frameworks/wine"
# SOLIDWORKS.app inside MacSW.app (package_solidworks_app.sh --embed) is code in a zip, sealed here
# as data: Developer ID signing would leave it ad hoc and not notarized. No policy for it yet.
EMBEDDED_APPS = ("Contents/Resources/SOLIDWORKS.app.zip",)
EXECUTABLES = {
    "Contents/MacOS/MacSW": "app",
    "Contents/MacOS/7zz": "default",
    WINE_ROOT + "/bin/wine": "wine",
    WINE_ROOT + "/bin/wineserver": "default",
    WINE_ROOT + "/lib/wine/x86_64-unix/MacSW": "wine",
    "Contents/Resources/SWCLI/runtime/PythonNative/bin/python3.11": "default",
}
LIBRARY_ROOTS = (WINE_ROOT + "/lib/",
                 "Contents/Resources/SWCLI/runtime/PythonNative/lib/")
ENTITLEMENTS = {
    "default": {},
    "app": {"com.apple.security.automation.apple-events": True},
    # PE code / Mono JIT memory is not signed Mach-O and does not use MAP_JIT.
    # Keep library validation enabled: all native dependencies share one Team.
    "wine": {"com.apple.security.cs.allow-unsigned-executable-memory": True},
}
SIGNED_MODULES = ("WineMacModuleSHA256", "WineInputModuleSHA256",
                  "WineNtdllModuleSHA256", "WineLoaderSHA256")
# Also re-signed (bin/wineserver is in EXECUTABLES); refreshed when the manifest declares it.
DECLARED_SIGNED_MODULES = ("WineServerSHA256",)
THIN = {b"\xce\xfa\xed\xfe": "<", b"\xcf\xfa\xed\xfe": "<",
        b"\xfe\xed\xfa\xce": ">", b"\xfe\xed\xfa\xcf": ">"}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}


def macho_type(path):
    """Read headers, not filename extensions (Wine .so files are Mach-O)."""
    with path.open("rb") as stream:
        header = stream.read(16)
        magic = header[:4]
        if magic in THIN:
            if len(header) != 16:
                raise RuntimeError("Truncated Mach-O: " + str(path))
            return struct.unpack(THIN[magic] + "I", header[12:16])[0]
        if magic not in FAT:
            return None
        endian, wide = FAT[magic]
        if len(header) < 8:
            raise RuntimeError("Truncated universal header")
        count = struct.unpack(endian + "I", header[4:8])[0]
        if not 1 <= count <= 16:
            raise RuntimeError("Invalid universal architecture count")
        size = 32 if wide else 20
        stream.seek(8)
        table = stream.read(size * count)
        if len(table) != size * count:
            raise RuntimeError("Truncated universal architecture table")
        kinds = set()
        total = path.stat().st_size
        for index in range(count):
            record = table[index * size:(index + 1) * size]
            offset, length = struct.unpack(endian + ("QQ" if wide else "II"),
                                           record[8:24] if wide else record[8:16])
            if offset < 8 + size * count or length < 16 or offset + length > total:
                raise RuntimeError("Invalid universal slice bounds")
            stream.seek(offset)
            thin = stream.read(16)
            if thin[:4] not in THIN:
                raise RuntimeError("Non Mach-O universal slice")
            kinds.add(struct.unpack(THIN[thin[:4]] + "I", thin[12:16])[0])
        if len(kinds) != 1:
            raise RuntimeError("Universal slices have different file types")
        return kinds.pop()


def inventory(app):
    if app.is_symlink() or app.suffix != ".app" or not app.is_dir():
        raise RuntimeError("Expected a real .app staging directory")
    app = app.resolve()
    # rglob deliberately does not recurse through directory symlinks. Walk the
    # real resource tree and sign each Mach-O there, not the compatibility alias.
    if ((app / WINE_ROOT).is_symlink() or not (app / WINE_ROOT).is_dir()
            or not (app / WINE_ALIAS).is_symlink()
            or os.readlink(app / WINE_ALIAS) != "../Resources/Wine"):
        raise RuntimeError("Wine must be stored in Resources with its reviewed compatibility alias")
    for relative in EMBEDDED_APPS:
        if os.path.lexists(app / relative):
            raise RuntimeError("Embedded app needs a signing policy; build with MACSW_SKIP_SOLIDWORKS_APP=1: " + relative)
    result = []
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(app) or not path.exists():
                raise RuntimeError("External, absolute or broken bundle link: " + relative)
            continue
        if path.is_dir():
            if path.suffix in (".app", ".framework", ".xpc", ".bundle"):
                raise RuntimeError("Nested code bundle needs an explicit signing policy: " + relative)
            if relative.startswith("Contents/Frameworks/") and "." in path.name:
                raise RuntimeError("Dotted data directory in native code location: " + relative)
            continue
        kind = macho_type(path)
        if kind is None:
            if relative.startswith("Contents/MacOS/"):
                raise RuntimeError("Non-Mach-O file in native code directory; move it to Resources: " + relative)
            continue  # Scripts in Resources and other data are sealed by the outer App.
        if kind == 2 and relative in EXECUTABLES:
            policy = EXECUTABLES[relative]
        elif kind in (6, 8) and any(relative.startswith(root) for root in LIBRARY_ROOTS):
            policy = "default"
        else:
            raise RuntimeError("Unreviewed native code: " + relative)
        result.append({"path": relative, "type": kind, "policy": policy})
    found = {item["path"] for item in result}
    if not set(EXECUTABLES).issubset(found):
        raise RuntimeError("Required native executables are missing: " + ", ".join(sorted(set(EXECUTABLES) - found)))
    # All libraries/bundles first; standalone executables last. The App's main
    # executable is signed as part of the final outer bundle, not separately.
    return sorted(result, key=lambda item: (item["type"] == 2, item["path"]))


def digest(path):
    return swcli_runtime.file_hash(path)


def verify_payload(app):
    contents = app / "Contents"
    wine_runtime.verify_app(contents, wine_runtime.identity(contents))
    # SWCLI is optional; its manifest exists only when it was packaged.
    if (contents / "Resources/SWCLI/runtime-manifest.json").exists():
        swcli_runtime.read_manifest(contents / "Resources/SWCLI")


def refresh_signed_hashes(app):
    path = app / "Contents/Resources/BuildManifest.plist"
    values = plistlib.loads(path.read_bytes())
    for key in SIGNED_MODULES:
        if key not in values:
            raise RuntimeError("Missing signed module identity: " + key)
        relative = wine_runtime.MODULES[key].format(**values)
        values[key] = digest(app / WINE_ALIAS / relative)
    for key in DECLARED_SIGNED_MODULES:
        if key in values:
            values[key] = digest(app / WINE_ALIAS / wine_runtime.DECLARED_MODULES[key])
    # Everything else, including PE/Mono/source digests, remains unchanged.
    path.write_bytes(plistlib.dumps(values, sort_keys=False))


def codesign_context(arguments):
    """Public bundle-relative target only, never argv or a credential path."""
    args = list(map(str, arguments))
    if not args or args[0] != "/usr/bin/codesign":
        return {"stage": "command", "target": "<unknown>"}
    stage = ("sign" if "--sign" in args else "verify" if "--verify" in args
             else "entitlements" if "--entitlements" in args else "details")
    target = Path(args[-1])
    if "Contents" in target.parts:
        relative = Path(*target.parts[target.parts.index("Contents"):]).as_posix()
        label = relative if re.fullmatch(r"[A-Za-z0-9._+ /-]{1,512}", relative) else "<bundle-code>"
    else:
        label = "<outer-app>" if target.suffix == ".app" else "<code-target>"
    return {"stage": stage, "target": label}


def codesign_errors(stderr):
    # Output fixed classifications, not raw messages which could contain
    # credential-looking data. Unrecognized errors remain explicit gaps.
    text = (stderr.decode(errors="replace") if isinstance(stderr, bytes) else (stderr or "")).lower()
    patterns = {
        "identity-not-found": ("no identity found",),
        "keychain-item-not-found": ("specified item could not be found in the keychain",),
        "identity-not-usable": ("this identity cannot be used for signing code",),
        "keychain-internal-error": ("errsecinternalcomponent",),
        "keychain-interaction-denied": ("user interaction is not allowed",),
        "certificate-chain-untrusted": ("unable to build chain to self-signed root", "cssmerr_tp_not_trusted"),
        "certificate-expired": ("cssmerr_tp_cert_expired", "certificate has expired"),
        "timestamp-unavailable": ("timestamp service is not available",),
        "bundle-extended-attributes": ("resource fork, finder information, or similar detritus not allowed",),
        "bundle-format": ("bundle format unrecognized",),
        "unsigned-code": ("code object is not signed at all",),
        "signature-invalid": ("invalid signature", "code or signature modified"),
    }
    return [label for label, messages in patterns.items() if any(message in text for message in messages)] or ["unclassified"]


def command(arguments):
    context = codesign_context(arguments)
    try:
        result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"event": "macsw.codesign-failure", **context,
                          "exception_type": type(error).__name__}), flush=True)
        raise RuntimeError("Distribution command failed during " + context["stage"]
                           + ": " + type(error).__name__) from None
    if result.returncode:
        print(json.dumps({"event": "macsw.codesign-failure", **context,
                          "exit_code": result.returncode,
                          "errors": codesign_errors(getattr(result, "stderr", b""))}), flush=True)
        raise RuntimeError("Distribution command failed during " + context["stage"]
                           + " (exit " + str(result.returncode) + ")")
    return result.stdout + result.stderr


def validate_details(details, team):
    text = details.decode(errors="replace")
    if ("TeamIdentifier=" + team + "\n" not in text
            or not re.search(r"^Authority=Developer ID Application:", text, re.M)
            or not re.search(r"^Timestamp=.+$", text, re.M)
            or not re.search(r"^CodeDirectory .*flags=.*\bruntime\b", text, re.M)):
        raise RuntimeError("Developer ID / Team / timestamp / hardened runtime check failed")


def verify_signature(path, policy, team, *, outer=False):
    command(["/usr/bin/codesign", "--verify", "--strict", *(["--deep"] if outer else []), path])
    validate_details(command(["/usr/bin/codesign", "-dvvv", path]), team)
    output = command(["/usr/bin/codesign", "-d", "--entitlements", ":-", path])
    start = output.find(b"<?xml")
    end = output.find(b"</plist>", start)
    actual = plistlib.loads(output[start:end + 8]) if start >= 0 and end >= 0 else {}
    if actual != ENTITLEMENTS[policy]:
        raise RuntimeError("Unexpected entitlements: " + str(path))


def verify(app, team):
    entries = inventory(app)
    verify_payload(app)
    for item in entries:
        if item["policy"] != "app":
            verify_signature(app / item["path"], item["policy"], team)
    verify_signature(app, "app", team, outer=True)
    return entries


def sign(app, identity, team, keychain, entitlement_dir, *, identity_sha1=None):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise RuntimeError("Invalid Developer Team ID")
    if not identity.startswith("Developer ID Application:"):
        raise RuntimeError("Direct Distribution requires a Developer ID Application identity")
    if identity_sha1 is not None and not re.fullmatch(r"[A-Fa-f0-9]{40}", identity_sha1):
        raise RuntimeError("Invalid resolved signing certificate fingerprint")
    entries = inventory(app)
    verify_payload(app)  # Verify pre-signing provenance before changing hashes.
    for policy, expected in ENTITLEMENTS.items():
        if plistlib.loads((entitlement_dir / (policy + ".plist")).read_bytes()) != expected:
            raise RuntimeError("Signing policy plist differs from reviewed entitlements")
    def sign_one(target, policy):
        print(json.dumps({"event": "macsw.signing-target", "policy": policy,
                          "target": target.relative_to(app).as_posix() if target != app else "<outer-app>"}), flush=True)
        command(["/usr/bin/codesign", "--force", "--sign", identity_sha1 or identity, "--keychain", keychain,
                 "--options", "runtime", "--timestamp", "--entitlements",
                 entitlement_dir / (policy + ".plist"), target])
        print("signed " + str(target.relative_to(app)) if target != app else "signed outer App", flush=True)
    for item in entries:
        if item["policy"] != "app":
            sign_one(app / item["path"], item["policy"])
    refresh_signed_hashes(app)
    verify_payload(app)
    sign_one(app, "app")
    verify(app, team)
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("inventory", "sign", "verify"))
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--team")
    parser.add_argument("--identity")
    parser.add_argument("--keychain", type=Path)
    args = parser.parse_args()
    if args.operation == "inventory":
        print(json.dumps(inventory(args.app), indent=2))
    elif not args.team:
        parser.error("--team is required")
    elif args.operation == "verify":
        verify(args.app, args.team)
    elif not args.identity or not args.keychain:
        parser.error("sign requires --identity and --keychain")
    else:
        sign(args.app, args.identity, args.team, args.keychain, PROJECT / "resources/signing")


if __name__ == "__main__":
    main()
