"""Deploy the bundled Windows backend without changing SOLIDWORKS or Wine.

Shared by the installer, App startup and Windows-side CLI entrypoints. Only
MacSW's managed Python directory is replaced; no package download is involved.
"""
import argparse
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

MARKER = ".macsw-runtime.json"
REQUIRED = ("python.exe", "pythonw.exe", "Lib/site-packages/swcli/__main__.py")


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError(f"SWCLI runtime contains a symbolic link: {path}")
        relative = path.relative_to(root)
        if "__pycache__" in relative.parts or path.suffix == ".pyc" or str(relative) == MARKER:
            continue
        if path.is_file():
            result[relative.as_posix()] = file_hash(path)
    return result


def build_manifest(source, version, commit):
    files = inventory(source)
    if not all(name in files for name in REQUIRED):
        raise RuntimeError("The SWCLI Windows runtime bundled in the App is incomplete; download MacSW again.")
    return {"format": 1, "version": version, "source_commit": commit, "files": files}


def read_manifest(resources):
    manifest = json.loads((resources / "runtime-manifest.json").read_text(encoding="utf-8"))
    if (manifest.get("format") != 1 or not isinstance(manifest.get("files"), dict)
            or not manifest.get("version") or not manifest.get("source_commit")
            or not all(name in manifest["files"] for name in REQUIRED)):
        raise RuntimeError("The SWCLI runtime manifest bundled in the App is invalid; download MacSW again.")
    source = resources / "runtime/Python311"
    if inventory(source) != manifest["files"]:
        raise RuntimeError("Verification of the SWCLI Windows runtime bundled in the App failed; the bottle was not modified.")
    return source, manifest


def current(target, manifest):
    try:
        return (json.loads((target / MARKER).read_text(encoding="utf-8")) == manifest
                and inventory(target) == manifest["files"])
    except (OSError, ValueError, RuntimeError):
        return False


def wine_runtime():
    # Import explicitly: -I excludes the script directory from sys.path.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import wine_runtime as module
    return module


def backend_in_use(contents, prefix):
    # tasklist is a Wine process: the bottle gate first (wine_runtime.prepare_wine_start).
    wine_runtime().prepare_wine_start(prefix)
    # tasklist is scoped by WINEPREFIX. Host ps names alone cannot distinguish
    # identical C:\\MacSW\\Python311 paths in independent Wine containers.
    environment = dict(os.environ, WINEPREFIX=str(prefix), WINEDEBUG="-all")
    environment["WINELOADER"] = str(contents / "Frameworks/wine/bin/wineloader")
    environment["WINESERVER"] = str(contents / "Frameworks/wine/bin/wineserver")
    # Wine's resident descendants inherit pipe handles. Wait for tasklist, not
    # pipe EOF; otherwise an already completed query times out on wineserver.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = subprocess.run(
            [environment["WINELOADER"], r"C:\windows\system32\tasklist.exe", "/fo", "csv", "/nh"],
            env=environment, stdout=output, stderr=errors, timeout=30, check=False,
        )
        output.seek(0)
        captured = output.read()
    if result.returncode:
        raise RuntimeError("Could not confirm that the SWCLI backend in the bottle is stopped; the upgrade was not performed.")
    rows = list(csv.reader(captured.decode("utf-8", errors="replace").splitlines()))
    if not rows or not all(len(row) >= 2 and row[1].strip().isdigit() for row in rows):
        raise RuntimeError("Could not parse the bottle process list; the SWCLI backend upgrade was not performed.")
    return any(row[0].strip().lower() in ("python.exe", "pythonw.exe") for row in rows)


def synchronize(contents, prefix, *, in_use=None):
    prefix = prefix.resolve()
    if not (prefix / "drive_c").is_dir():
        raise RuntimeError("The MacSW bottle is not initialized yet; finish the installation first. A Wine bottle is not created automatically.")
    resources = contents / "Resources/SWCLI"
    source, manifest = read_manifest(resources)
    parent = prefix / "drive_c/MacSW"
    target = parent / "Python311"
    backup = parent / ".Python311.previous"
    if not target.resolve().is_relative_to(prefix) or parent.is_symlink() or target.is_symlink() or backup.is_symlink():
        raise RuntimeError("The SWCLI managed directory cannot point outside the bottle or be a symbolic link; the upgrade was not performed.")
    if (target.exists() and not target.is_dir()) or (backup.exists() and not backup.is_dir()):
        raise RuntimeError("The SWCLI managed path is not a directory; the upgrade was not performed.")
    parent.mkdir(parents=True, exist_ok=True)
    # Non-blocking cross-process lock: App and CLI must never deploy concurrently.
    descriptor = os.open(parent / ".swcli-runtime.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another SWCLI backend sync is in progress; try again later.") from error
        # Recover an interrupted rename before deciding whether deployment is needed.
        if not target.exists() and backup.exists():
            backup.rename(target)
        if current(target, manifest):
            return False
        check_busy = in_use or (lambda: backend_in_use(contents, prefix))
        if check_busy():
            raise RuntimeError("The SWCLI backend is running; files were not overwritten. Run sw-cli daemon stop first, then retry.")
        staging = Path(tempfile.mkdtemp(prefix=".Python311.install-", dir=parent))
        try:
            shutil.copytree(source, staging, dirs_exist_ok=True)
            if inventory(staging) != manifest["files"]:
                raise RuntimeError("Verification of the staged SWCLI backend failed; the original version is kept.")
            (staging / MARKER).write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
            if check_busy():
                raise RuntimeError("The SWCLI backend has started; replacement cancelled. Run sw-cli daemon stop first.")
            if backup.exists():
                shutil.rmtree(backup)
            if target.exists():
                target.rename(backup)
            try:
                staging.rename(target)
            except BaseException:
                if backup.exists() and not target.exists():
                    backup.rename(target)
                raise
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contents", type=Path, required=True)
    parser.add_argument("--prefix", type=Path)
    parser.add_argument("--build-manifest", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--version")
    parser.add_argument("--source-commit")
    parser.add_argument("--installing", action="store_true")
    args = parser.parse_args()
    resources = args.contents / "Resources/SWCLI"
    if args.build_manifest:
        if not args.version or not args.source_commit:
            parser.error("--build-manifest requires --version and --source-commit")
        manifest = build_manifest(resources / "runtime/Python311", args.version, args.source_commit)
        (resources / "runtime-manifest.json").write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
    elif args.verify:
        read_manifest(resources)
    elif args.prefix:
        runtime = wine_runtime()
        if runtime.managed(args.prefix):
            with runtime.launch_lock(args.prefix):
                if not (args.installing and runtime.status(args.contents, args.prefix) == "baseline"):
                    runtime.require_ready(args.contents, args.prefix)
                synchronize(args.contents, args.prefix)
        else:
            synchronize(args.contents, args.prefix)
    else:
        parser.error("--prefix, --build-manifest or --verify is required")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"SWCLI backend sync failed: {error}", file=sys.stderr)
        sys.exit(1)
