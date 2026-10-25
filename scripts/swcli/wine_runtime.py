"""Explicit, recoverable upgrades for MacSW's managed Wine bottle.

No Wine process is used to discover the installed runtime. A migration holds
the same launch lock as the App/CLI, stops only this prefix, clones it on APFS,
and keeps both the old App and the original bottle. No backups are auto-pruned.
Every Wine start of a managed bottle passes the bottle gate first (prepare_wine_start).
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import uuid

MODULES = {
    "WineMacModuleSHA256": "lib/wine/x86_64-unix/winemac.so",
    "WineInputModuleSHA256": "lib/wine/x86_64-unix/win32u.so",
    "WineCOMBaseModuleSHA256": "lib/wine/x86_64-windows/combase.dll",
    "WineComctl32V6ModuleSHA256": "lib/wine/x86_64-windows/comctl32_v6.dll",
    "WineNtdllModuleSHA256": "lib/wine/x86_64-unix/ntdll.so",
    "WineLoaderSHA256": "lib/wine/x86_64-unix/MacSW",
    "MonoPatchSHA256": "share/wine/mono/wine-mono-{MonoVersion}/bin/libmono-2.0-x86.dll",
    "MonoMscorlibSHA256": "share/wine/mono/wine-mono-{MonoVersion}/lib/mono/4.5/mscorlib.dll",
    "MonoRegAsmX86SHA256": "lib/wine/i386-windows/regasm.exe",
    "MonoRegAsmX64SHA256": "lib/wine/x86_64-windows/regasm.exe",
}

MSXML_MODULES = {
    "WineMSXML3ModuleSHA256": "lib/wine/x86_64-windows/msxml3.dll",
}
MSXML_IDENTITY_KEYS = ("WineMSXMLSchemaPatchSHA256", *MSXML_MODULES)

# Older baseline receipts predate these modules. New manifests must bind the
# entire extension group; partial declarations never weaken verification.
TOOLBOX_MODULES = {
    "MonoCCWModuleSHA256": "share/wine/mono/wine-mono-{MonoVersion}/bin/libmono-2.0-x86_64.dll",
    "MonoBTLSModuleSHA256": "share/wine/mono/wine-mono-{MonoVersion}/lib/x86_64/libmono-btls-shared.dll",
}


# Modules that newer manifests declare (patches 0017-0037). Each one a manifest declares is verified
# like MODULES; receipts and Apps from before a key simply do not declare it.
DECLARED_MODULES = {
    "WineServerSHA256": "bin/wineserver",
    "WineMSXML3I386ModuleSHA256": "lib/wine/i386-windows/msxml3.dll",
    "WineWS2_32ModuleSHA256": "lib/wine/x86_64-windows/ws2_32.dll",
    "WineWS2_32I386ModuleSHA256": "lib/wine/i386-windows/ws2_32.dll",
    "WineMacDrvModuleSHA256": "lib/wine/x86_64-windows/winemac.drv",
    "WineMacDrvI386ModuleSHA256": "lib/wine/i386-windows/winemac.drv",
    "WineComdlg32ModuleSHA256": "lib/wine/x86_64-windows/comdlg32.dll",
    "WineComdlg32I386ModuleSHA256": "lib/wine/i386-windows/comdlg32.dll",
    "WineWbemproxModuleSHA256": "lib/wine/x86_64-windows/wbemprox.dll",
    "WineWbemproxI386ModuleSHA256": "lib/wine/i386-windows/wbemprox.dll",
    "WineWindowsCodecsModuleSHA256": "lib/wine/x86_64-windows/windowscodecs.dll",
    "WineKernelBaseModuleSHA256": "lib/wine/x86_64-windows/kernelbase.dll",
    "WineOpenGL32ModuleSHA256": "lib/wine/x86_64-windows/opengl32.dll",
    "WineOpenGL32UnixModuleSHA256": "lib/wine/x86_64-unix/opengl32.so",
    "WineGLU32ModuleSHA256": "lib/wine/x86_64-windows/glu32.dll",
}


def state_root(prefix):
    if prefix.is_symlink() or prefix.name in ("", ".", "..") or len(prefix.parts) < 3:
        raise RuntimeError("The bottle path is unsafe; refusing to migrate.")
    return prefix.parent / ("." + prefix.name + ".wine-runtime")


def identity(contents):
    with (contents / "Resources/BuildManifest.plist").open("rb") as stream:
        manifest = plistlib.load(stream)
    values = {key: value for key, value in manifest.items()
              if key.startswith(("Wine", "Mono")) and isinstance(value, str)}
    if not all(values.get(key) for key in ("WineVersion", "MonoVersion", *MODULES)):
        raise RuntimeError("The App's Wine/Mono build identity is incomplete; download the complete App again.")
    if any(key in values for key in MSXML_IDENTITY_KEYS) and not all(values.get(key) for key in MSXML_IDENTITY_KEYS):
        raise RuntimeError("The App's MSXML runtime identity is incomplete.")
    if any(key in values for key in TOOLBOX_MODULES) and not all(values.get(key) for key in TOOLBOX_MODULES):
        raise RuntimeError("The App's Toolbox runtime identity is incomplete.")
    return values


def fingerprint(values):
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def verify_app(contents, values):
    modules = dict(MODULES)
    if any(key in values for key in MSXML_IDENTITY_KEYS):
        if not all(values.get(key) for key in MSXML_IDENTITY_KEYS):
            raise RuntimeError("The App's MSXML runtime identity is incomplete.")
        modules.update(MSXML_MODULES)
    if any(key in values for key in TOOLBOX_MODULES):
        if not all(values.get(key) for key in TOOLBOX_MODULES):
            raise RuntimeError("The App's Toolbox runtime identity is incomplete.")
        modules.update(TOOLBOX_MODULES)
    modules.update({key: relative for key, relative in DECLARED_MODULES.items() if key in values})
    for key, relative in modules.items():
        path = contents / "Frameworks/wine" / relative.format(**values)
        with path.open("rb") as stream:
            hasher = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
            digest = hasher.hexdigest()
        if digest != values[key]:
            raise RuntimeError(f"Wine/Mono module verification failed: {key}; the bottle was not upgraded.")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, value):
    # fsync before publication so a power loss cannot expose a partial receipt.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, ensure_ascii=False, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def managed(prefix):
    main = Path.home() / "Library/Application Support/MacSW/bottle"
    return prefix.absolute() == main or state_root(prefix).exists()


# Bottle gate: the same rules as WineBottleGate.swift (MacSW.app). No Wine session of a managed
# bottle starts while a drive letter (dosdevices/<x>:) or a profile link
# (drive_c/users/<account>/<name>) points into a cloud folder (iCloud Drive, a folder of
# ~/Library/CloudStorage) that this process has not listed itself with macOS's consent. Wine's
# mountmgr opens every drive root when a session starts, and the first Wine process to open a
# protected folder raises its macOS prompt for this process's app (MacSW, Terminal, ...) while
# wineserver waits. Links to cloud folders macOS refused are moved, unchanged, to
# <prefix>/.macsw-held/<same path> and moved back by the first run that may open the folder.
# Never moved: links into Desktop, Documents or Downloads, and the profile's Desktop, Documents,
# Downloads, Music, Pictures and Videos whatever they point at (Wine links those to $HOME/<folder>
# again as soon as one is missing). While a Wine session of the bottle runs, no link moves at all:
# it read the drive roots already, Wine resolves dosdevices at every path, and the app that
# started it may not have been let into a folder this process may open.
HELD_DIRECTORY = ".macsw-held"
HELD_LOCK = ".macsw-held.lock"
PROTECTED_NAMES = ("Desktop", "Documents", "Downloads")
SHELL_FOLDERS = frozenset(("desktop", "documents", "downloads", "music", "pictures", "videos"))
CONSENT_TIMEOUT = 60
SESSION_END_WAIT = 8
DATA_VOLUME = "/System/Volumes/Data"
# Protected folder -> "granted", "denied", "missing" or "noAnswer", for the life of this process.
_answers = {}


def _comparable(text, case_sensitive):
    """text as the home volume compares it: APFS and HFS+ ignore Unicode normalization, and the
    default (case-insensitive) format also case, so ~/documents is ~/Documents there."""
    decomposed = unicodedata.normalize("NFD", text)
    return decomposed if case_sensitive else decomposed.lower()


def _case_sensitive(path):
    """Whether the volume of path tells Documents from documents; no (the macOS default) when unsure."""
    try:
        return os.pathconf(path, 11) == 1  # _PC_CASE_SENSITIVE (sys/unistd.h); os has no name for it
    except (OSError, ValueError):
        return False


def _protected_root(path, home, case_sensitive):
    """The protected folder that path is or lies in, judged by the path alone, as its parts below
    home in the canonical spelling (the CloudStorage provider as path spells it); or None."""
    parts = [part for part in path.split("/") if part]
    base = [part for part in home.split("/") if part]

    def starts(below):
        root = base + below
        return len(parts) >= len(root) and all(
            _comparable(a, case_sensitive) == _comparable(b, case_sensitive) for a, b in zip(parts, root))
    for name in PROTECTED_NAMES:
        if starts([name]):
            return [name]
    icloud = ["Library", "Mobile Documents", "com~apple~CloudDocs"]
    if starts(icloud):
        return icloud
    storage = ["Library", "CloudStorage"]
    if len(parts) > len(base) + len(storage) and starts(storage):
        return storage + [parts[len(base) + len(storage)]]
    return None


def _same_file(first, second):
    try:
        a, b = os.stat(first), os.stat(second)
    except OSError:
        return False
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


def _standardized(path):
    """path without empty and "." parts, each ".." taken from the real folder before it, as the
    kernel does and as Swift's standardizedFileURL does for WineBottleGate: <home>/BoxAlias/..
    (~/BoxAlias -> Box-Box) is ~/Library/CloudStorage, not <home>. Only the part before a ".."
    is resolved; a path without ".." is not read."""
    parts = []
    for part in str(path).split("/"):
        if part == "..":
            parts = [p for p in os.path.realpath("/" + "/".join(parts)).split("/") if p][:-1]
        elif part not in ("", "."):
            parts.append(part)
    return "/" + "/".join(parts)


def protected_folder(target, home):
    """The protected folder a link to target reaches, following symbolic links on the way
    (~/Box -> ~/Library/CloudStorage/Box-Box), each ".." in target from the real folder before
    it (_standardized). Stops as soon as the path is in a protected folder, so nothing inside one
    is read (only a ".." right after a part inside one, as in Swift); a missing target is judged
    by its path. Other spellings of home count: its real path, the Data volume's name for it (a
    firmlink) and, on a case-insensitive volume, other cases and Unicode forms. Returned under
    home as given."""
    given = os.path.normpath(str(home))
    case_sensitive = _case_sensitive(given)
    homes = [given]
    if os.path.realpath(given) not in homes:
        homes.append(os.path.realpath(given))
    for variant in list(homes):
        other = variant[len(DATA_VOLUME):] if variant.startswith(DATA_VOLUME + "/") else DATA_VOLUME + variant
        if other not in homes and _same_file(other, variant):
            homes.append(other)

    def classify(path):
        for variant in homes:
            below = _protected_root(path, variant, case_sensitive)
            if below is not None:
                return "/".join([given] + below)
        return None

    def parts(path):
        return [part for part in os.path.normpath(path).split("/") if part]

    resolved, rest, hops = "", parts(_standardized(target)), 0
    while True:
        folder = classify("/".join([resolved] + rest) or "/")
        if folder is not None:
            return folder
        if not rest:
            return None
        following = resolved + "/" + rest.pop(0)
        try:
            destination = os.readlink(following)
        except OSError:
            resolved = following
            continue
        hops += 1
        if hops > 32:
            return None
        base = destination if destination.startswith("/") else resolved + "/" + destination
        resolved, rest = "", parts("/".join([base] + rest))


def _is_cloud(folder):
    return os.path.basename(folder) == "com~apple~CloudDocs" or os.path.basename(os.path.dirname(folder)) == "CloudStorage"


def _gated(link):
    """Set aside when this process may not open its folder: a link into a cloud folder, except
    the profile's shell folders (Wine makes those again at once)."""
    if not (link["folder"] and _is_cloud(link["folder"])):
        return False
    parts = link["item"].split("/")
    return not (len(parts) == 4 and parts[:2] == ["drive_c", "users"] and parts[3].lower() in SHELL_FOLDERS)


def _answer(folder):
    """This process's answer for folder, whatever case or Unicode form it was asked under."""
    key = _comparable(folder, False)
    return next((answer for known, answer in _answers.items() if _comparable(known, False) == key), None)


def _listdir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def _items(root):
    """Paths, relative to root, of every profile folder entry and every drive letter."""
    items = []
    users = Path(root) / "drive_c/users"
    for account in _listdir(users):
        items += [f"drive_c/users/{account}/{name}" for name in _listdir(users / account)]
    return items + ["dosdevices/" + name for name in _listdir(Path(root) / "dosdevices")
                    if len(name) == 2 and name[1] == ":" and name[0].isascii() and name[0].isalpha()]


def _link(item, path, prefix, home):
    try:
        destination = os.readlink(path)
    except OSError:
        return None
    directory = os.path.dirname(os.path.join(str(prefix), item))
    target = os.path.join(directory, destination)  # ".." is resolved by protected_folder
    return {"item": item, "destination": destination, "folder": protected_folder(target, home)}


def bottle_links(prefix, home):
    """The links in the bottle that reach a protected folder."""
    links = (_link(item, Path(prefix) / item, prefix, home) for item in _items(prefix))
    return [link for link in links if link and link["folder"]]


def held_links(prefix, home):
    held = Path(prefix) / HELD_DIRECTORY
    links = (_link(item, held / item, prefix, home) for item in _items(held))
    return [link for link in links if link]


def _locked(path):
    """Whether another process holds the write lock on the first byte of path, as wineserver does."""
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return False
    try:
        # struct flock on macOS: off_t l_start, off_t l_len, pid_t l_pid, short l_type, short l_whence.
        query = struct.pack("qqihh", 0, 1, 0, fcntl.F_WRLCK, os.SEEK_SET)
        return struct.unpack("qqihh", fcntl.fcntl(descriptor, fcntl.F_GETLK, query))[3] != fcntl.F_UNLCK
    except OSError:
        return False
    finally:
        os.close(descriptor)


def _accepts_connection(path):
    """Whether a server listens on the Unix socket at path (connects, then closes at once)."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(1)
            client.connect(path)
        return True
    except OSError:
        return False


def session_running(prefix, server_root=None, end_wait=SESSION_END_WAIT):
    """Whether a Wine session of prefix runs: its wineserver holds a write lock on
    /tmp/.wine-<uid>/server-<device>-<inode>/lock while it lives (Wine's server/request.c). While
    that lock is held this is True (fail safe: no link moves); only a cleared lock means no
    session. No new session can start while it is held, and the next start after it clears is
    gated as usual. A server that takes a test connection on socket next to the lock answers at
    once. One that does not (shutting down: socket closed, lock kept for seconds more; or frozen
    on a macOS prompt with its listen(5) backlog full, so connects are refused) is waited for up
    to end_wait seconds: False if the lock clears meanwhile, True otherwise. The test connection
    makes wineserver count a client for a moment (it can put off an idle session's end by 3 s)."""
    try:
        info = os.stat(prefix)
    except OSError:
        return False
    root = server_root or f"/tmp/.wine-{os.getuid()}"
    directory = f"{root}/server-{info.st_dev % (1 << 64):x}-{info.st_ino:x}"
    deadline = time.monotonic() + end_wait
    while _locked(directory + "/lock"):
        if _accepts_connection(directory + "/socket"):
            return True
        if time.monotonic() >= deadline:
            return True  # still held: a live server, maybe frozen with a full listen backlog
        time.sleep(0.1)
    return False


def check_folder(folder, timeout=CONSENT_TIMEOUT, lister=os.listdir):
    """Lists folder natively, at most timeout seconds (its macOS prompt may be on screen); once
    per process."""
    if _answer(folder) is not None:
        return _answer(folder)
    result = {}

    def work():
        try:
            lister(folder)
            result["access"] = "granted"
        except FileNotFoundError:
            result["access"] = "missing"
        except OSError:
            result["access"] = "denied"
    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    worker.join(min(1, timeout))
    if worker.is_alive():
        print(f"macOS is asking for permission to access {folder}; click Allow so SOLIDWORKS can use it "
              f"(waiting up to {max(1, round(timeout))} s).", file=sys.stderr, flush=True)
        worker.join(max(0, timeout - 1))
    _answers[folder] = result.get("access", "noAnswer")
    return _answers[folder]


@contextmanager
def _bottle_lock(prefix):
    descriptor = os.open(Path(prefix) / HELD_LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def _set_aside(prefix, link, report):
    target = Path(prefix) / HELD_DIRECTORY / link["item"]
    try:
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # rename(2) of the link itself; a link held under this name before is replaced.
        os.rename(Path(prefix) / link["item"], target)
        report["set_aside"].append(link["item"])
    except OSError:
        report["failed"].append(link["item"])


def _restore(prefix, link, report):
    source = Path(prefix) / HELD_DIRECTORY / link["item"]
    target = Path(prefix) / link["item"]
    try:
        try:
            info = os.lstat(target)
        except FileNotFoundError:
            info = None
        if info is None:
            if not target.parent.is_dir():
                raise OSError("the folder for the link is gone")
        elif stat.S_ISLNK(info.st_mode):
            # The same link was made again meanwhile.
            if os.readlink(target) != link["destination"]:
                raise OSError("the name is used by another link")
            os.unlink(source)
            report["restored"].append(link["item"])
            return
        elif stat.S_ISDIR(info.st_mode):
            os.rmdir(target)  # an empty folder makes room; OSError for anything else
        else:
            raise OSError("the name is used by a file or folder")
        os.rename(source, target)
        report["restored"].append(link["item"])
    except OSError:
        report["blocked"].append(link["item"])


def prepare_bottle(prefix, home=None, timeout=CONSENT_TIMEOUT, lister=os.listdir, running=session_running):
    """Lists every cloud folder a gated link (present or held) reaches (once per process). Unless a
    Wine session runs (then nothing moves), sets aside the gated links to folders macOS refused and
    moves back the held links to folders it allowed. Returns what it did."""
    prefix = Path(prefix)
    home = os.path.normpath(str(home or Path.home()))
    report = {"checks": {}, "running": False, "set_aside": [], "restored": [],
              "blocked": [], "failed": [], "held": []}
    for link in bottle_links(prefix, home) + held_links(prefix, home):
        if _gated(link) and not any(_comparable(known, False) == _comparable(link["folder"], False)
                                    for known in report["checks"]):
            report["checks"][link["folder"]] = check_folder(link["folder"], timeout, lister)

    def blocked(link):
        return _gated(link) and _answer(link["folder"]) != "granted"
    report["running"] = running(prefix)
    if not report["running"] and (any(blocked(link) for link in bottle_links(prefix, home))
                                  or any(not blocked(link) for link in held_links(prefix, home))):
        with _bottle_lock(prefix):
            for link in bottle_links(prefix, home):
                if blocked(link):
                    _set_aside(prefix, link, report)
            for link in held_links(prefix, home):
                if not blocked(link):
                    _restore(prefix, link, report)
    report["held"] = [link["item"] for link in held_links(prefix, home)]
    return report


def _log_gate(prefix, report):
    parts = [f"{label}: {', '.join(report[key])}" for key, label in (
        ("set_aside", "set aside"), ("restored", "moved back"),
        ("blocked", "cannot move back"), ("failed", "could not set aside")) if report[key]]
    if not parts:
        return
    logs = Path(prefix).parent / "logs"
    try:
        logs.mkdir(mode=0o700, exist_ok=True)
        descriptor = os.open(logs / "folder-consent.log", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
            stream.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} [wine_runtime.py] {'; '.join(parts)}\n")
    except OSError:
        pass


def prepare_wine_start(prefix):
    """The bottle gate before this process starts a Wine program in prefix (not wineserver)."""
    if not managed(Path(prefix)):
        return
    report = prepare_bottle(prefix)
    _log_gate(prefix, report)
    if report["failed"]:
        raise RuntimeError("Could not set aside " + ", ".join(report["failed"])
                           + " in the bottle (macOS has not allowed access to its folder yet); Wine was not started.")


def status(contents, prefix):
    root = state_root(prefix)
    if (root / "pending.json").exists():
        return "recovery"
    if not managed(prefix):
        return "unmanaged"
    if not (prefix / "drive_c").exists():
        return "fresh"
    receipt = root / "receipt.json"
    if not receipt.exists():
        return "baseline"
    old = read_json(receipt)
    marker = prefix / ".macsw-wine-prefix-id"
    if old.get("format") != 1 or not marker.exists() or marker.read_text().strip() != old.get("prefix_id"):
        return "baseline"
    matches_path = not old.get("active_app") or old["active_app"] == str(contents.parent.resolve())
    return "ready" if old["identity"] == identity(contents) and matches_path else "upgrade"


def require_ready(contents, prefix):
    value = status(contents, prefix)
    if value not in ("ready", "fresh", "unmanaged"):
        raise RuntimeError("The Wine bottle needs version confirmation, an upgrade or recovery; handle it in MacSW Settings → Maintenance. The new Wine was not started.")


@contextmanager
def launch_lock(prefix, exclusive=False):
    root = state_root(prefix)
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink():
        raise RuntimeError("The Wine upgrade state directory cannot be a symbolic link.")
    descriptor = os.open(root / "launch.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        os.set_inheritable(descriptor, False)
        try:
            fcntl.flock(lock, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("A Wine bottle upgrade or launch is in progress; try again later.") from error
        yield root


def launch(contents, prefix, arguments):
    # Lock only the check + spawn boundary. The upgrader can stop a running
    # SOLIDWORKS after explicit confirmation, without deadlocking on its lease.
    if not managed(prefix):
        process = subprocess.Popen(arguments)
    else:
        # Before the lock: the gate may wait for a macOS prompt.
        prepare_wine_start(prefix)
        with launch_lock(prefix):
            require_ready(contents, prefix)
            process = subprocess.Popen(arguments)
    return process.wait()


def clone(source, destination):
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("The backup target already exists; refusing to overwrite.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.stat().st_dev == destination.parent.stat().st_dev:
        command = ["/bin/cp", "-cR", str(source), str(destination)]
    else:
        # The App may live on an external/Data volume. Cross-volume archive
        # copies need real space; do not follow bottle links into user folders.
        size = 0
        for directory, _, files in os.walk(source, followlinks=False):
            for name in files:
                file = Path(directory) / name
                if not file.is_symlink():
                    size += file.stat().st_size
        if shutil.disk_usage(destination.parent).free < size + 256 * 1024 * 1024:
            raise RuntimeError("Not enough free space for a cross-volume backup; the copy was refused.")
        command = ["/usr/bin/ditto", "--noqtn", str(source), str(destination)]
    with tempfile.TemporaryFile() as errors:
        result = subprocess.run(command, stdout=errors, stderr=errors, timeout=600)
        if result.returncode:
            errors.seek(0)
            detail = errors.read(2048).decode(errors="replace")
            raise RuntimeError("Bottle/App backup or copy failed; the existing backup is kept: " + detail)


def archive(contents, root, values):
    if contents.parent.is_symlink():
        raise RuntimeError("The App archive source cannot be a symbolic link.")
    target = root / "apps" / fingerprint(values) / "MacSW.app"
    if not target.exists():
        stage = target.parent / ("staging-" + str(uuid.uuid4()) + ".app")
        clone(contents.parent, stage)
        verify_app(stage / "Contents", values)
        stage.rename(target)
    verify_app(target / "Contents", values)
    if identity(target / "Contents") != values:
        raise RuntimeError("The archived App's build identity does not match.")
    return target


def baseline(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "pending.json").exists():
            raise RuntimeError("An unfinished migration exists; recover first.")
        if not (prefix / "drive_c").is_dir():
            raise RuntimeError("Finish the bottle installation first.")
        values = identity(contents)
        receipt = root / "receipt.json"
        marker = prefix / ".macsw-wine-prefix-id"
        if receipt.exists() and marker.exists():
            old = read_json(receipt)
            if old["identity"] != values or (old.get("active_app") and old["active_app"] != str(contents.parent.resolve())):
                raise RuntimeError("Recording a baseline cannot be used to bypass a Wine version upgrade.")
        verify_app(contents, values)
        old_app = archive(contents, root, values)
        if marker.is_symlink():
            raise RuntimeError("The bottle identity marker cannot be a symbolic link.")
        prefix_id = marker.read_text().strip() if marker.exists() else str(uuid.uuid4())
        marker.write_text(prefix_id, encoding="utf-8")
        write_json(receipt, {"format": 1, "prefix_id": prefix_id,
                             "identity": values, "app": str(old_app), "active_app": str(contents.parent.resolve())})
        print("Recorded the current working Wine/Mono and kept the full old App.", flush=True)


WINE_LOCALES = ("en_US.UTF-8", "zh_CN.UTF-8")


def wine_locale():
    """MACSW_WINE_LOCALE, else the app preference MacSW.wineLocale, else en_US.UTF-8."""
    value = os.environ.get("MACSW_WINE_LOCALE")
    if value is None:
        try:
            value = subprocess.run(["defaults", "read", "com.yjbeetle.macsw", "MacSW.wineLocale"],
                                   capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            value = ""
    return value if value in WINE_LOCALES else WINE_LOCALES[0]


# Wine copies its Unix environment into every Windows process, so only these of the caller's
# variables (plus LANG and LC_*) reach it; API keys, tokens, SSH_AUTH_SOCK, DYLD_* and WINE*
# overrides do not (security audit 2026-10-24, finding 3). Same list as
# WineService.inheritedEnvironmentKeys in the app.
INHERITED_ENVIRONMENT = frozenset((
    "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "__CF_USER_TEXT_ENCODING",
    "WINE_SOLIDWORKS_STARTUP_TIMEOUT", "MACSW_OPENGL_RENDERER", "WINEMSYNC", "WINEMSYNC_QLIMIT",
    "MACSW_WINE_LOCALE", "MACSW_GL_BATCH", "MACSW_GL_MPENGINE",
))
SANITIZED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def environment(contents, prefix):
    result = {key: value for key, value in os.environ.items()
              if key in INHERITED_ENVIRONMENT or key == "LANG" or key.startswith("LC_")}
    result["PATH"] = SANITIZED_PATH
    wine = contents / "Frameworks/wine"
    locale = wine_locale()
    result.update(WINEPREFIX=str(prefix), WINELOADER=str(wine / "lib/wine/x86_64-unix/MacSW"),
                  WINESERVER=str(wine / "bin/wineserver"), WINEDEBUG="-all", WINE_MONO_AOT="none",
                  LANG=locale, LC_ALL=locale, MACSW_CROSS_PROCESS_SURFACES="1",
                  MACSW_WIC_COMPONENT_CACHE="1", MACSW_LOCAL_MODULE_READS="1")
    return result


def run(contents, prefix, arguments, log, *, server=False):
    env = environment(contents, prefix)
    binary = env["WINESERVER" if server else "WINELOADER"]
    if not server:
        prepare_wine_start(prefix)
    with log.open("ab") as output:
        subprocess.run([binary, *arguments], env=env, stdout=output, stderr=output,
                       timeout=120, check=True)


def stop(contents, prefix, log):
    # -k may report no server (1); still require a successful bounded -w.
    try:
        run(contents, prefix, ["-k"], log, server=True)
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
    run(contents, prefix, ["-w"], log, server=True)


def boot(contents, prefix, log):
    values = identity(contents)
    verify_app(contents, values)
    run(contents, prefix, [r"C:\windows\system32\wineboot.exe", "-u"], log)
    runtime = contents / "Frameworks/wine"
    mono = runtime / f"share/wine/mono/wine-mono-{values['MonoVersion']}"
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "add", r"HKCU\Software\Wine\Mono",
                          "/v", "RuntimePath", "/t", "REG_SZ", "/d",
                          "Z:" + str(mono).replace("/", "\\"), "/f"], log)
    for arch, framework in (("i386-windows", "Framework"), ("x86_64-windows", "Framework64")):
        target = prefix / f"drive_c/windows/Microsoft.NET/{framework}/v4.0.30319/regasm.exe"
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.parent.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError("The RegAsm target directory points outside the bottle.")
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            staging = Path(stream.name)
        shutil.copy2(runtime / f"lib/wine/{arch}/regasm.exe", staging)
        os.replace(staging, target)
    # Check protocol dependencies, not just wineboot's exit status. CAD modeling
    # and visible rendering remain an explicit post-upgrade acceptance step.
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "query", r"HKCR\SldWorks.Application\CLSID"], log)
    # The SWCLI backend exists only in builds that package SWCLI.
    if (contents / "Resources/SWCLI/runtime-manifest.json").exists():
        run(contents, prefix, [r"C:\MacSW\Python311\python.exe", "-c",
                              "import pythoncom, win32com.client, swcli; print('backend imports OK')"], log)
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "query",
                          r"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink",
                          "/v", "Tahoma"], log)


def restore(root, prefix, log):
    journal = read_json(root / "pending.json")
    backup = Path(journal["backup"])
    # Journal paths are untrusted input. Never rename/delete arbitrary paths.
    if (backup.parent.parent != root / "backups" or backup.name != "bottle" or backup.is_symlink()
            or not backup.resolve().is_relative_to(root.resolve())):
        raise RuntimeError("The backup path in the recovery record is unsafe.")
    old = journal["previous"]
    if (backup / ".macsw-wine-prefix-id").read_text().strip() != old["prefix_id"]:
        raise RuntimeError("The backup bottle identity does not match; refusing to restore.")
    old_contents = Path(old["app"]) / "Contents"
    expected = root / "apps" / fingerprint(old["identity"]) / "MacSW.app/Contents"
    if old_contents != expected or identity(old_contents) != old["identity"]:
        raise RuntimeError("The old App identity does not match; the backup is kept for manual recovery.")
    verify_app(old_contents, old["identity"])
    new_contents = Path(journal["new_app"]) / "Contents"
    if new_contents.parent.parent.parent != root / "apps":
        raise RuntimeError("The new App archive path is invalid.")
    verify_app(new_contents, identity(new_contents))
    stop(new_contents, prefix, log)
    stop(old_contents, prefix, log)
    if journal.get("phase") != "restored":
        if not backup.is_dir():
            raise RuntimeError("The original bottle backup is missing; refusing to restore.")
        failed = backup.parent / "failed-bottle"
        # Make restoration idempotent after interruption between the renames.
        if prefix.exists():
            if failed.exists():
                failed = backup.parent / ("interrupted-restore-" + str(uuid.uuid4()))
            prefix.rename(failed)
        if not prefix.exists():
            clone(backup, prefix)
        journal["phase"] = "restored"
        write_json(root / "pending.json", journal)
    # Builtin DLL links and Mono RuntimePath may refer to the overwritten App.
    # Rebind them to the archived old App before declaring recovery complete.
    if not (prefix / "drive_c").is_dir() or (prefix / ".macsw-wine-prefix-id").read_text().strip() != old["prefix_id"]:
        raise RuntimeError("The restored bottle identity does not match; the backup is kept pending recovery.")
    boot(old_contents, prefix, log)
    stop(old_contents, prefix, log)
    write_json(root / "receipt.json", {**old, "active_app": str(old_contents.parent.resolve())})
    (root / "pending.json").unlink()
    return old["app"]


def migrate(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if status(contents, prefix) == "ready":
            print("Wine/Mono is unchanged; no migration needed.")
            return
        if status(contents, prefix) != "upgrade":
            raise RuntimeError("Record a known-working version first, or recover the unfinished migration.")
        old = read_json(root / "receipt.json")
        old_contents = Path(old["app"]) / "Contents"
        if (old_contents != root / "apps" / fingerprint(old["identity"]) / "MacSW.app/Contents"
                or identity(old_contents) != old["identity"]):
            raise RuntimeError("The old App archive path is invalid.")
        verify_app(old_contents, old["identity"])
        values = identity(contents)
        verify_app(contents, values)
        new_app = archive(contents, root, values)
        log = root / "migration.log"
        print("Stopping the selected bottle and creating a full APFS backup…", flush=True)
        stop(old_contents, prefix, log)
        backup = root / "backups" / str(uuid.uuid4()) / "bottle"
        clone(prefix, backup)
        journal = {"format": 1, "previous": old, "backup": str(backup),
                   "new_app": str(new_app), "new_identity": values, "phase": "upgrading"}
        write_json(root / "pending.json", journal)
        try:
            print("Updating Wine, Mono and the COM registration tools and checking dependencies…", flush=True)
            boot(contents, prefix, log)
            stop(contents, prefix, log)
            write_json(root / "last-upgrade.json", journal)
            write_json(root / "receipt.json", {**old, "identity": values, "app": str(new_app),
                                               "active_app": str(contents.parent.resolve())})
            (root / "pending.json").unlink()
            print(f"Migration and dependency checks finished; launch SOLIDWORKS to verify. Backup: {backup}", flush=True)
        except Exception as error:
            try:
                app = restore(root, prefix, log)
            except Exception as recovery_error:
                raise RuntimeError(f"Migration failed: {error}; recovery incomplete: {recovery_error}; backup: {backup}") from error
            raise RuntimeError(f"Migration failed and the old bottle was restored. Quit the new version and open: {app}. Log: {log}") from error


def rollback(prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "pending.json").exists():
            raise RuntimeError("An unfinished migration exists; recover first.")
        journal = read_json(root / "last-upgrade.json")
        receipt = read_json(root / "receipt.json")
        marker = (prefix / ".macsw-wine-prefix-id").read_text().strip()
        if (receipt["identity"] != journal["new_identity"] or marker != receipt["prefix_id"]
                or journal["previous"]["prefix_id"] != receipt["prefix_id"]):
            raise RuntimeError("The rollback record does not match the current bottle; refusing to restore.")
        write_json(root / "pending.json", {**journal, "phase": "upgrading"})
        app = restore(root, prefix, root / "migration.log")
        print("Restored the pre-upgrade bottle; quit the new version and open: " + app, flush=True)


def shutdown(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "receipt.json").exists():
            receipt = read_json(root / "receipt.json")
            contents = root / "apps" / fingerprint(receipt["identity"]) / "MacSW.app/Contents"
            verify_app(contents, receipt["identity"])
        # Only wineserver: shutting down must not boot the new runtime.
        stop(contents, prefix, root / "migration.log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "baseline", "upgrade", "recover", "rollback", "stop", "launch"))
    parser.add_argument("--contents", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    args, command = parser.parse_known_args()
    if command and args.command != "launch":
        parser.error("unexpected arguments: " + " ".join(command))
    contents, prefix = args.contents.absolute(), args.prefix.absolute()
    try:
        if args.command == "check":
            require_ready(contents, prefix)
        elif args.command == "baseline":
            baseline(contents, prefix)
        elif args.command == "upgrade":
            migrate(contents, prefix)
        elif args.command == "rollback":
            rollback(prefix)
        elif args.command == "stop":
            shutdown(contents, prefix)
        elif args.command == "recover":
            with launch_lock(prefix, exclusive=True) as root:
                print("Restored the old bottle; quit the new version and open: " + restore(root, prefix, root / "migration.log"))
        else:
            return launch(contents, prefix, command[1:] if command[:1] == ["--"] else command)
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
