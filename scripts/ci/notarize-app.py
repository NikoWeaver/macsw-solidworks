"""Direct Distribution: temporary signing identity, checks, notarize, staple.

Called only by the protected manual job. No private credential is copied into
the App, output directory or logs. All secret command output is suppressed.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "scripts"))
import sign_app

SECRET_NAMES = ("SIGNING_CERTIFICATE_P12_BASE64", "SIGNING_CERTIFICATE_PASSWORD",
                "NOTARY_API_KEY_BASE64", "NOTARY_APPLE_ID", "NOTARY_APP_PASSWORD")
PROFILE = "macsw-ci-notary"
SEARCH_LIST_RECEIPT = "keychain-search-list.json"


def authentication_mode(values, key_id, issuer):
    if values.get("NOTARY_API_KEY_BASE64"):
        if not key_id or not issuer:
            raise RuntimeError("API key is configured but its Key ID / Issuer ID is missing; not falling back")
        return "api-key"
    if not values.get("NOTARY_APPLE_ID", "").strip() or not values.get("NOTARY_APP_PASSWORD"):
        raise RuntimeError("Signing/notarization credentials are not configured")
    return "apple-id"


def store_profile(mode, keychain, key, values, team, key_id, issuer):
    if mode == "api-key":
        credentials = ["--key", key, "--key-id", key_id, "--issuer", issuer]
    else:
        credentials = ["--apple-id", values["NOTARY_APPLE_ID"].strip(),
                       "--password", values["NOTARY_APP_PASSWORD"], "--team-id", team]
    # Validate before signing/probes. A configured but rejected API key must
    # fail, never silently use a different account. No iCloud keychain sync.
    run(["xcrun", "notarytool", "store-credentials", PROFILE,
         *credentials, "--keychain", keychain, "--validate"])
    return ["--keychain-profile", PROFILE, "--keychain", keychain]


def run(arguments, *, timeout=120):
    # Never use check=True here: CalledProcessError renders command arguments,
    # including keychain and P12 passwords, in a traceback.
    result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Distribution step failed: " + str(arguments[0]))
    return result.stdout


def private_file(path, data):
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def validate_search_list(paths):
    if (not isinstance(paths, list) or len(paths) > 256
            or any(not isinstance(path, str) or not Path(path).is_absolute()
                   or any(char in path for char in "\x00\r\n") for path in paths)):
        raise RuntimeError("Invalid keychain search list")
    return paths


def keychain_search_list():
    output = run(["/usr/bin/security", "list-keychains", "-d", "user"])
    try:
        return validate_search_list(shlex.split(output.decode("utf-8")))
    except (ValueError, UnicodeError):
        raise RuntimeError("Unable to read keychain search list") from None


def set_keychain_search_list(paths):
    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *validate_search_list(paths)])
    if keychain_search_list() != paths:
        raise RuntimeError("Keychain search list did not match requested state")


def restore_keychain_search_list(directory):
    receipt = directory / SEARCH_LIST_RECEIPT
    if not receipt.exists():
        return
    # The separate always() cleanup process must also be able to restore the
    # original list after cancellation/failure. Never follow a receipt link or
    # turn unvalidated receipt contents into security command arguments.
    mode = receipt.lstat().st_mode
    if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o600 or receipt.stat().st_size > 131072:
        raise RuntimeError("Invalid keychain search list receipt")
    try:
        state = json.loads(receipt.read_bytes())
    except (ValueError, UnicodeError):
        raise RuntimeError("Invalid keychain search list receipt") from None
    if not isinstance(state, dict) or set(state) != {"version", "paths"} or state["version"] != 1:
        raise RuntimeError("Invalid keychain search list receipt")
    paths = validate_search_list(state["paths"])
    set_keychain_search_list(paths)
    print(json.dumps({"event": "macsw.keychain-search-list", "stage": "restored",
                      "entry_count": len(paths)}), flush=True)


def cleanup(directory):
    # Only the fixed credential directory under RUNNER_TEMP is eligible.
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    if (directory.name != "macsw-signing-credentials" or directory.parent.resolve() != runner
            or directory.is_symlink()):
        raise RuntimeError("Refusing cleanup outside the private signing directory")
    if not directory.exists():
        return
    # Apple Security's AtomicFile names a local keychain lock from the first
    # four SHA-1 bytes of the DB basename. Admit exactly our own lock, not a
    # wildcard of arbitrary sidecars. delete-keychain normally removes it.
    lock_name = keychain_lock_name("signing.keychain-db")
    allowed_names = ("certificate.p12", "AuthKey.p8", "signing.keychain-db", lock_name, SEARCH_LIST_RECEIPT)
    paths = list(directory.iterdir())
    inventory = []
    for path in sorted(paths):
        mode = path.lstat().st_mode  # Diagnostics must not follow links.
        known_name = path.name in allowed_names
        keychain_name = re.fullmatch(r"signing\.keychain(?:-db)?(?:[.-][A-Za-z0-9_-]{1,80})*", path.name)
        inventory.append({"name": path.name if known_name or keychain_name else "<unrecognized>",
                          "kind": "symlink" if stat.S_ISLNK(mode) else "file" if stat.S_ISREG(mode)
                                  else "directory" if stat.S_ISDIR(mode) else "other"})
    print(json.dumps({"event": "macsw.credential-cleanup-inventory", "entries": inventory}), flush=True)
    for path in paths:
        if (path.name not in allowed_names
                or path.is_symlink() or not path.is_file()):
            raise RuntimeError("Unexpected entry in signing credentials directory")
    keychain = directory / "signing.keychain-db"
    # If restoration fails, retain the receipt and keychain for always() to
    # retry; do not silently discard the only record of the original list.
    restore_keychain_search_list(directory)
    if keychain.exists():
        result = subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)],
                                capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError("Unable to remove temporary signing keychain")
    # Refuse unknown entries rather than deleting a broad directory tree.
    for path in paths:
        if path.exists():
            path.unlink()
    directory.rmdir()


def keychain_lock_name(basename):
    # https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_filedb/lib/AtomicFile.cpp
    return ".fl" + hashlib.sha1(basename.encode("utf-8")).hexdigest()[:8].upper()


def prepare(directory, values):
    directory.mkdir(mode=0o700, exist_ok=False)
    keychain = directory / "signing.keychain-db"
    certificate = directory / "certificate.p12"
    key = None
    private_file(certificate, base64.b64decode(values[SECRET_NAMES[0]], validate=True))
    if values.get("NOTARY_API_KEY_BASE64"):
        key = directory / "AuthKey.p8"
        private_file(key, base64.b64decode(values["NOTARY_API_KEY_BASE64"], validate=True))
    original_search_list = keychain_search_list()
    private_file(directory / SEARCH_LIST_RECEIPT,
                 json.dumps({"version": 1, "paths": original_search_list}).encode("utf-8"))
    password = secrets.token_urlsafe(32)
    run(["/usr/bin/security", "create-keychain", "-p", password, keychain])
    run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", keychain])
    run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain])
    run(["/usr/bin/security", "import", certificate, "-P", values[SECRET_NAMES[1]],
         "-k", keychain, "-t", "cert", "-f", "pkcs12", "-T", "/usr/bin/codesign"])
    run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:",
         "-s", "-k", password, keychain])
    # --keychain limits identity lookup but certificate-chain construction
    # still consults the user's search list. Keep every original entry.
    set_keychain_search_list([str(keychain), *[path for path in original_search_list if path != str(keychain)]])
    print(json.dumps({"event": "macsw.keychain-search-list", "stage": "prepared",
                      "original_entry_count": len(original_search_list)}), flush=True)
    certificate.unlink()
    return keychain, key


def signing_probe(keychain, fingerprint, team):
    # Exercise the same private-key access, timestamp and runtime policy on a
    # tiny native executable before modifying any App payload. Nothing here
    # is copied into the sealed App or uploaded as an artifact.
    def progress(stage):
        print(json.dumps({"event": "macsw.signing-probe", "stage": stage}), flush=True)
    with tempfile.TemporaryDirectory(prefix="macsw-signing-probe-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        executable = Path(temporary) / "signing-probe"
        progress("build")
        run(["xcrun", "clang", PROJECT / "native/signing_probe.c", "-o", executable])
        progress("sign")
        sign_app.command(["/usr/bin/codesign", "--force", "--sign", fingerprint,
                          "--keychain", keychain, "--options", "runtime", "--timestamp",
                          "--entitlements", PROJECT / "resources/signing/default.plist", executable])
        progress("verify")
        sign_app.verify_signature(executable, "default", team)
        progress("execute")
        run([executable])
    progress("passed")


def inspect_signing_identity(keychain, identity):
    output = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain])
    entries = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\r\n]+)"', output.decode(errors="replace"), re.M)
    selected = {fingerprint.lower() for fingerprint, name in entries if name == identity}
    print(json.dumps({"event": "macsw.signing-identities", "valid_identity_count": len(entries),
                      "selected_identity_present": bool(selected), "selected_certificate_count": len(selected)}), flush=True)
    if len(selected) != 1:
        raise RuntimeError("Exactly one valid configured Developer ID identity is required")
    return selected.pop()


def notarize(app, output, team, identity, key_id="", issuer=""):
    values = {name: os.environ.pop(name, "") for name in SECRET_NAMES}
    if not all(values[name] for name in SECRET_NAMES[:2]) or not all((team, identity)):
        raise RuntimeError("Signing/notarization credentials are not configured")
    mode = authentication_mode(values, key_id, issuer)
    directory = Path(os.environ["RUNNER_TEMP"]).resolve() / "macsw-signing-credentials"
    if directory.exists() or directory.is_symlink():
        raise RuntimeError("A previous credentials directory needs explicit cleanup")
    sign_app.inventory(app)
    sign_app.verify_payload(app)
    output.mkdir(parents=True, exist_ok=False)
    try:
        keychain, key = prepare(directory, values)
        auth = store_profile(mode, keychain, key, values, team, key_id, issuer)
        values.clear()
        print("Notarization authentication validated: " + mode, flush=True)
        fingerprint = inspect_signing_identity(keychain, identity)
        signing_probe(keychain, fingerprint, team)
        entries = sign_app.sign(app, identity, team, keychain, PROJECT / "resources/signing",
                                identity_sha1=fingerprint)
        (output / "signing-inventory.json").write_text(json.dumps(entries, indent=2) + "\n")
        # Check actual native Python imports and a libffi callback, with no
        # user-site / bytecode writes inside the now sealed bundle.
        python = app / "Contents/Resources/SWCLI/runtime/PythonNative/bin/python3.11"
        run([python, "-I", "-B", "-c", "import ctypes, ssl, jsonschema, rpds; "
             "f=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_int)(lambda x:x+1); "
             "assert f(41)==42; print('NATIVE_PYTHON_SIGNED_PASS')"])
        run([app / "Contents/MacOS/7zz", "i"])
        run([sys.executable, "-B", PROJECT / "scripts/ci/verify-toolbox-native.py",
             "--app", app, "--evidence", output / "native-probes"], timeout=1200)
        # Runtime probes must not have mutated the signed bundle.
        sign_app.verify(app, team)
        submission = output / "notary-submission.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission], timeout=600)
        result = subprocess.run(list(map(str, ["xcrun", "notarytool", "submit", submission,
                                *auth, "--wait", "--timeout", "20m", "--output-format", "json"])),
                                capture_output=True, timeout=1500)
        try:
            response = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError("Notary service did not return a JSON result") from None
        (output / "notary-result.json").write_text(json.dumps(response, indent=2) + "\n")
        if response.get("id"):
            log = run(["xcrun", "notarytool", "log", response["id"], *auth])
            (output / "notary-log.json").write_bytes(log)
        if result.returncode or response.get("status") != "Accepted":
            raise RuntimeError("Notarization was not Accepted; final ZIP was not produced")
        run(["xcrun", "stapler", "staple", app])
        run(["xcrun", "stapler", "validate", app])
        sign_app.verify(app, team)
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version = info["CFBundleShortVersionString"]
        if not re.fullmatch(r"[A-Za-z0-9._-]+", version):
            raise RuntimeError("Unsafe App version")
        final = output / ("MacSW-" + version + "-macOS-signed.zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, final], timeout=600)
        (output / (final.name + ".sha256")).write_text(sign_app.digest(final) + "  " + final.name + "\n")
        submission.unlink()
        print("Developer ID checks, runtime primitives, notarization and stapling passed.")
    finally:
        values.clear()
        failed = sys.exc_info()[0] is not None
        try:
            cleanup(directory)
        except Exception:
            if not failed:
                raise
            print("Credential cleanup failed; original distribution error preserved.", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    try:
        if args.cleanup:
            cleanup(Path(os.environ["RUNNER_TEMP"]).resolve() / "macsw-signing-credentials")
        elif not args.app or not args.output:
            parser.error("--app and --output are required")
        else:
            notarize(args.app, args.output, os.environ.get("SIGNING_TEAM_ID", ""),
                     os.environ.get("SIGNING_IDENTITY", ""), os.environ.get("NOTARY_KEY_ID", ""),
                     os.environ.get("NOTARY_ISSUER_ID", ""))
    except Exception as error:
        # Some subprocess/decoding exceptions include secret input bytes or
        # argument arrays. Only our explicitly sanitized errors are displayed.
        print(str(error) if isinstance(error, RuntimeError) else "Distribution operation failed (details suppressed).",
              file=sys.stderr)
        sys.exit(1)
