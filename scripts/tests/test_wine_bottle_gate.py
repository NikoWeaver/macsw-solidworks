"""The bottle gate of wine_runtime.py (same rules as WineBottleGate.swift).

Everything runs on a fake home and bottle in a temporary directory with a fake lister standing
in for macOS: no real home, cloud folder, Wine process or macOS prompt is involved.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("wine_runtime", PROJECT / "scripts/swcli/wine_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class Lister:
    """macOS stand-in: refuses (EPERM) or never answers by folder name; records the listings."""

    def __init__(self, deny=(), hang=()):
        self.deny, self.hang, self.listed = set(deny), set(hang), []

    def __call__(self, path):
        name = os.path.basename(path)
        self.listed.append(name)
        if name in self.deny:
            raise PermissionError(1, "Operation not permitted", path)
        if name in self.hang:
            time.sleep(1.5)
        return []


class BottleGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(os.path.realpath(self.temporary.name))
        self.home = self.root / "home"
        self.prefix = self.root / "support/bottle"
        for directory in ("home/Documents", "home/Library/CloudStorage/Box-Box/Project",
                          "home/Library/CloudStorage/OneDrive-Personal", "elsewhere",
                          "support/bottle/dosdevices", "support/bottle/drive_c/users/me"):
            (self.root / directory).mkdir(parents=True)
        self.links = {
            "dosdevices/c:": "../drive_c", "dosdevices/z:": "/", "dosdevices/h:": str(self.home),
            "dosdevices/b:": self.cloud("Box-Box"), "dosdevices/y:": self.cloud("OneDrive-Personal"),
            "dosdevices/q:": str(self.root / "elsewhere"),
            "drive_c/users/me/Projects": str(self.root / "elsewhere"),
            "drive_c/users/me/Box": self.cloud("Box-Box"),
            "drive_c/users/me/Documents": str(self.home / "Documents"),
        }
        for item, destination in self.links.items():
            os.symlink(destination, self.prefix / item)
        RUNTIME._answers.clear()
        self.addCleanup(RUNTIME._answers.clear)

    def cloud(self, name):
        return str(self.home / "Library/CloudStorage" / name)

    def destination(self, item):
        try:
            return os.readlink(self.prefix / item)
        except OSError:
            return None

    def held(self, item):
        return self.destination(RUNTIME.HELD_DIRECTORY + "/" + item)

    def prepare(self, lister, running=False, **options):
        return RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=options.pop("timeout", 2), lister=lister,
                                      running=lambda prefix: running, **options)

    def test_links_reach_protected_folders_through_symbolic_links(self):
        os.symlink(self.cloud("Box-Box"), self.home / "Box")
        os.symlink(str(self.home / "Box/Project"), self.prefix / "dosdevices/x:")
        found = {link["item"]: link["folder"] for link in RUNTIME.bottle_links(self.prefix, str(self.home))}
        self.assertEqual(found, {
            "drive_c/users/me/Box": self.cloud("Box-Box"), "drive_c/users/me/Documents": str(self.home / "Documents"),
            "dosdevices/b:": self.cloud("Box-Box"), "dosdevices/x:": self.cloud("Box-Box"),
            "dosdevices/y:": self.cloud("OneDrive-Personal")})

    def test_refused_folders_are_set_aside_unchanged_and_the_rest_stays(self):
        lister = Lister(deny={"OneDrive-Personal", "Documents"}, hang={"Box-Box"})
        started = time.monotonic()
        report = self.prepare(lister, timeout=0.3)
        self.assertLess(time.monotonic() - started, 1.4, "an unanswered prompt is waited for at most the timeout")
        self.assertEqual(sorted(set(lister.listed)), ["Box-Box", "OneDrive-Personal"], "only cloud folders are asked")
        self.assertEqual(report["set_aside"], ["drive_c/users/me/Box", "dosdevices/b:", "dosdevices/y:"])
        self.assertEqual(report["held"], ["drive_c/users/me/Box", "dosdevices/b:", "dosdevices/y:"])
        self.assertIsNone(self.destination("dosdevices/y:"))
        self.assertEqual(self.held("dosdevices/y:"), self.links["dosdevices/y:"])
        self.assertEqual(self.held("dosdevices/b:"), self.links["dosdevices/b:"])
        for item in ("drive_c/users/me/Documents", "dosdevices/c:", "dosdevices/z:", "dosdevices/h:",
                     "dosdevices/q:", "drive_c/users/me/Projects"):
            self.assertEqual(self.destination(item), self.links[item], item)

    def test_held_links_come_back_once_allowed(self):
        self.prepare(Lister(deny={"Box-Box", "Documents", "OneDrive-Personal"}))
        self.assertIsNone(self.destination("dosdevices/b:"))
        RUNTIME._answers.clear()  # a later run (another process) that macOS lets open them
        report = self.prepare(Lister())
        self.assertEqual(sorted(report["restored"]), ["dosdevices/b:", "dosdevices/y:", "drive_c/users/me/Box"])
        self.assertEqual({item: self.destination(item) for item in self.links}, self.links)
        self.assertEqual(report["held"], [])

    def test_layout_written_by_the_app_is_moved_back(self):
        # WineBottleGate.swift keeps a held link under .macsw-held/<same path>, unchanged.
        held = self.prefix / RUNTIME.HELD_DIRECTORY / "dosdevices"
        held.mkdir(parents=True)
        os.rename(self.prefix / "dosdevices/b:", held / "b:")
        report = self.prepare(Lister())
        self.assertIn("dosdevices/b:", report["restored"])
        self.assertEqual(self.destination("dosdevices/b:"), self.cloud("Box-Box"))

    def test_no_link_moves_while_a_wine_session_runs(self):
        self.prepare(Lister(deny={"Box-Box"}))
        RUNTIME._answers.clear()  # another process, allowed into Box, refused OneDrive
        os.symlink(self.cloud("OneDrive-Personal"), self.prefix / "dosdevices/v:")
        report = self.prepare(Lister(deny={"OneDrive-Personal"}), running=True)
        self.assertTrue(report["running"])
        self.assertEqual((report["set_aside"], report["restored"]), ([], []))
        self.assertIsNone(self.destination("dosdevices/b:"), "not moved back into the running session")
        self.assertEqual(self.destination("dosdevices/y:"), self.links["dosdevices/y:"])
        self.assertEqual(report["held"], ["drive_c/users/me/Box", "dosdevices/b:"])
        # The session ended: the next run sets aside and moves back.
        report = self.prepare(Lister(deny={"OneDrive-Personal"}))
        self.assertEqual(report["restored"], ["drive_c/users/me/Box", "dosdevices/b:"])
        self.assertEqual(report["set_aside"], ["dosdevices/v:", "dosdevices/y:"])

    def test_names_taken_while_held_block_or_make_room(self):
        self.prepare(Lister(deny={"Box-Box", "OneDrive-Personal"}))
        profile = self.prefix / "drive_c/users/me"
        (profile / "Box").mkdir()
        (profile / "Box/mine.txt").write_text("x")
        (self.prefix / "dosdevices/y:").mkdir()
        RUNTIME._answers.clear()
        report = self.prepare(Lister())
        self.assertEqual(self.destination("dosdevices/y:"), self.links["dosdevices/y:"], "an empty folder makes room")
        self.assertEqual(self.destination("dosdevices/b:"), self.links["dosdevices/b:"])
        self.assertEqual(report["blocked"], ["drive_c/users/me/Box"], "a folder of the user's own stays")
        self.assertEqual(self.held("drive_c/users/me/Box"), self.cloud("Box-Box"))
        self.assertEqual((profile / "Box/mine.txt").read_text(), "x")

    def test_same_link_made_again_is_merged(self):
        self.prepare(Lister(deny={"Box-Box"}))
        os.symlink(self.links["drive_c/users/me/Box"], self.prefix / "drive_c/users/me/Box")
        RUNTIME._answers.clear()
        report = self.prepare(Lister())
        self.assertEqual(report["restored"], ["drive_c/users/me/Box", "dosdevices/b:"])
        self.assertIsNone(self.held("drive_c/users/me/Box"))
        self.assertEqual(self.destination("drive_c/users/me/Box"), self.links["drive_c/users/me/Box"])

    def test_shell_folder_links_are_never_moved_so_wine_has_nothing_to_make_again(self):
        """Wine links a missing Desktop, Documents, Downloads, Music, Pictures or Videos to $HOME/<folder>
        in the session (shell32 SHGetFolderPath with CSIDL_FLAG_CREATE -> mountmgr set_shell_folder), so
        the gate never empties those names, not even one pointed into a cloud folder."""
        profile = self.prefix / "drive_c/users/me"
        (self.home / "Desktop").mkdir()
        (self.home / "Downloads").mkdir()
        os.symlink(str(self.home / "Desktop"), profile / "Desktop")
        os.symlink(self.cloud("Box-Box") + "/Pictures", profile / "Pictures")
        names = ("Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos")

        def entries():
            return {name: self.destination(f"drive_c/users/me/{name}") for name in names}

        def wine_makes_shell_folders():
            made = []
            for name in names:
                if not os.path.lexists(profile / name) and (self.home / name).is_dir():
                    os.symlink(str(self.home / name), profile / name)
                    made.append(name)
            return made
        before = entries()
        lister = Lister(deny={"Box-Box", "OneDrive-Personal", "Documents", "Desktop"})
        self.prepare(lister)
        self.assertIsNone(self.destination("drive_c/users/me/Box"), "the cloud link is set aside")
        self.assertEqual(entries(), before)
        self.assertEqual(wine_makes_shell_folders(), ["Downloads"], "Wine finds only what was never there")
        after_wine = entries()
        RUNTIME._answers.clear()
        self.prepare(lister)
        self.prepare(lister, running=True)
        self.assertEqual(entries(), after_wine)
        self.assertEqual(wine_makes_shell_folders(), [])
        self.assertFalse({"Documents", "Desktop"} & set(lister.listed), lister.listed)
        self.assertFalse(os.path.lexists(self.prefix / RUNTIME.HELD_DIRECTORY / "drive_c/users/me/Documents"))

    def test_probe_case_variant_link_is_protected(self):
        """The re-review's probe: APFS ignores case and Unicode form, so ~/documents is ~/Documents."""
        if not os.path.isdir(self.home / "documents"):
            self.skipTest("case-sensitive volume")
        self.assertEqual(RUNTIME.protected_folder(str(self.home / "documents"), str(self.home)), str(self.home / "Documents"))
        variant = str(self.home / "library/cloudstorage/box-box")
        self.assertEqual(RUNTIME.protected_folder(variant, str(self.home)), str(self.home / "Library/CloudStorage/box-box"))
        decomposed = str(self.home / "LIBRARY/Mobile Documents/com~apple~CloudDocs/Café")
        self.assertEqual(RUNTIME.protected_folder(decomposed, str(self.home)),
                         str(self.home / "Library/Mobile Documents/com~apple~CloudDocs"))
        # e: to Box under another spelling is set aside, and one answer covers every spelling.
        os.symlink(variant, self.prefix / "dosdevices/e:")
        os.symlink(str(self.home / "documents"), self.prefix / "dosdevices/d:")
        lister = Lister(deny={"Box-Box", "box-box", "OneDrive-Personal"})
        report = self.prepare(lister)
        self.assertIn("dosdevices/e:", report["set_aside"])
        self.assertTrue(self.destination("dosdevices/d:"), "Documents is not set aside")
        self.assertEqual(sum(name.lower() == "box-box" for name in lister.listed), 1, lister.listed)
        RUNTIME._answers.clear()
        RUNTIME._answers[self.cloud("Box-Box")] = "granted"
        report = self.prepare(Lister(deny={"OneDrive-Personal"}))
        self.assertEqual(report["restored"], ["drive_c/users/me/Box", "dosdevices/b:", "dosdevices/e:"])

    def test_probe_firmlink_path_is_protected(self):
        data = "/System/Volumes/Data" + str(self.home)
        if not os.path.isdir(data + "/Documents"):
            self.skipTest("no Data firmlink path here")
        self.assertEqual(RUNTIME.protected_folder(data + "/Documents", str(self.home)), str(self.home / "Documents"))
        os.symlink(data + "/Library/CloudStorage/Box-Box", self.prefix / "dosdevices/e:")
        report = self.prepare(Lister(deny={"Box-Box"}))
        self.assertIn("dosdevices/e:", report["set_aside"])

    def test_probe_no_move_back_into_a_running_session(self):
        """The re-review's probe: another identity's session runs (it was refused Box); this process
        may open Box: b: must stay away."""
        RUNTIME._answers[self.cloud("Box-Box")] = "denied"
        RUNTIME._answers[str(self.home / "Documents")] = "denied"
        RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, running=lambda prefix: False)
        self.assertIsNone(self.destination("dosdevices/b:"))
        RUNTIME._answers.clear()  # e.g. Terminal running sw-cli, allowed into Box
        report = RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, lister=Lister(),
                                        running=lambda prefix: True)
        self.assertEqual(report["restored"], [])
        self.assertIsNone(self.destination("dosdevices/b:"))

    def test_session_runs_while_the_wineserver_lock_is_held(self):
        """A held lock is a running session (no link moves); one whose socket does not answer is
        waited for, and only a cleared lock means no session."""
        # A socket path must fit in sockaddr_un (104 bytes): work relative to the test folder.
        previous = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        server_root = "wine-tmp"
        info = os.stat(self.prefix)
        directory = f"{server_root}/server-{info.st_dev % (1 << 64):x}-{info.st_ino:x}"

        def running(wait):
            started = time.monotonic()
            return RUNTIME.session_running(self.prefix, server_root, end_wait=wait), time.monotonic() - started
        self.assertFalse(running(5)[0], "no server directory")
        os.makedirs(directory)
        Path(directory, "lock").write_bytes(b"")
        self.assertLess(running(5)[1], 1, "a leftover lock file: not running, no wait")
        holder = subprocess.Popen(
            [sys.executable, "-c", HOLDER, directory + "/lock", directory + "/socket"], cwd=self.root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.kill)
        self.addCleanup(holder.stdin.close)
        self.addCleanup(holder.stdout.close)

        def send(command):
            holder.stdin.write(command + "\n")
            holder.stdin.flush()
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        stopping, waited = running(0.3)
        self.assertTrue(stopping, "a held lock is a running session")
        self.assertGreaterEqual(waited, 0.3)
        send("listen-later")
        self.assertTrue(running(5)[0], "a server that was just starting")
        self.assertEqual(holder.stdout.readline().strip(), "done")
        self.assertTrue(running(0)[0])
        send("close")
        self.assertEqual(holder.stdout.readline().strip(), "done")
        self.assertTrue(running(0.3)[0], "no longer taking clients, lock still held")
        send("unlock-later")
        ended, took = running(5)
        self.assertFalse(ended)
        self.assertLess(took, 2, "returns once the lock is gone")
        self.assertEqual(holder.stdout.readline().strip(), "done")
        holder.kill()
        holder.wait()
        self.assertFalse(running(5)[0])

    # The third review's probes ------------------------------------------------------------------

    def frozen_server(self):
        """A stand-in wineserver frozen on a macOS prompt: holds the lock, listen(5), never accepts.
        Returns session_running for it (server root relative: a socket path must fit sockaddr_un)."""
        previous = os.getcwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        info = os.stat(self.prefix)
        directory = f"wine-tmp/server-{info.st_dev % (1 << 64):x}-{info.st_ino:x}"
        os.makedirs(directory)
        Path(directory, "lock").write_bytes(b"")
        holder = subprocess.Popen(
            [sys.executable, "-c", HOLDER, directory + "/lock", directory + "/socket"], cwd=self.root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.addCleanup(holder.stdin.close)
        self.addCleanup(holder.stdout.close)
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        holder.stdin.write("listen\n")
        holder.stdin.flush()
        self.assertEqual(holder.stdout.readline().strip(), "done")
        return lambda prefix: RUNTIME.session_running(prefix, "wine-tmp", end_wait=0.3)

    def test_frozen_wineserver_with_a_full_backlog_still_counts_as_running(self):
        """A frozen wineserver refuses connections once its listen backlog is full (a closed test
        client does not free its slot), but its lock is held: the session still runs, so nothing
        moves back into it or out of it."""
        running = self.frozen_server()
        self.assertEqual([running(self.prefix) for _ in range(7)], [True] * 7)
        RUNTIME._answers[self.cloud("Box-Box")] = "denied"  # an earlier gate of another identity held Box
        RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, running=lambda prefix: False)
        self.assertIsNone(self.destination("dosdevices/b:"))
        RUNTIME._answers.clear()  # this process may open Box, not OneDrive
        report = RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, lister=Lister(deny={"OneDrive-Personal"}),
                                        running=running)
        self.assertTrue(report["running"])
        self.assertEqual((report["set_aside"], report["restored"]), ([], []))
        self.assertIsNone(self.destination("dosdevices/b:"), "not moved back into a live (frozen) session")
        self.assertEqual(self.destination("dosdevices/y:"), self.links["dosdevices/y:"], "not taken away from it")

    def test_a_session_that_starts_during_the_native_check_is_not_changed(self):
        RUNTIME._answers[self.cloud("Box-Box")] = "denied"
        RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, running=lambda prefix: False)
        self.assertIsNone(self.destination("dosdevices/b:"))
        RUNTIME._answers.clear()  # allowed into Box now, but another app starts a session meanwhile
        started = []

        def lister(path):
            started.append(path)
            return []
        report = RUNTIME.prepare_bottle(self.prefix, home=self.home, timeout=1, lister=lister,
                                        running=lambda prefix: bool(started))
        self.assertTrue(started)
        self.assertEqual((report["set_aside"], report["restored"]), ([], []))
        self.assertIsNone(self.destination("dosdevices/b:"))

    def test_wine_finds_nothing_to_make_again_after_any_gate(self):
        """After every gate (all refused; no session, a session, none), Wine's own step (a link to
        $HOME/<folder> where nothing is, Videos -> Movies) finds nothing to make, no gated link is
        left and none is held under a shell folder name."""
        profile = self.prefix / "drive_c/users/me"
        for folder in ("Desktop", "Downloads", "Music", "Pictures", "Movies"):
            (self.home / folder).mkdir()
        targets = {"Desktop": "Desktop", "Documents": "Documents", "Downloads": "Downloads",
                   "Music": "Music", "Pictures": "Pictures", "Videos": "Movies"}

        def wine_step():
            made = []
            for name, folder in sorted(targets.items()):
                if not os.path.lexists(profile / name) and (self.home / folder).is_dir():
                    os.symlink(str(self.home / folder), profile / name)
                    made.append(name)
            return made
        wine_step()  # wineboot's profile
        os.symlink(self.cloud("OneDrive-Personal"), profile / "OneDrive")
        for running in (False, True, False):
            RUNTIME._answers.clear()
            self.prepare(Lister(deny={"Box-Box", "OneDrive-Personal", "Documents", "Desktop", "Downloads"}),
                         running=running)
            self.assertEqual(wine_step(), [], "Wine made a shell folder again")
        self.assertEqual([link["item"] for link in RUNTIME.bottle_links(self.prefix, str(self.home))
                          if RUNTIME._gated(link)], [])
        self.assertEqual([link["item"] for link in RUNTIME.held_links(self.prefix, str(self.home))],
                         ["drive_c/users/me/Box", "drive_c/users/me/OneDrive", "dosdevices/b:", "dosdevices/y:"])

    def test_other_spellings_of_a_cloud_folder_are_gated(self):
        """As WineBottleGate.swift reads them: '..' after a symbolic link taken the kernel's way
        (~/BoxAlias/.. is ~/Library/CloudStorage, not the home), a relative target, double and
        trailing slashes, '.' and '..', a link outside the home, the boot volume alias and the Data
        volume in capitals."""
        os.symlink(self.cloud("Box-Box"), self.home / "BoxAlias")  # like Box Drive's ~/Box
        os.symlink(self.cloud("Box-Box"), self.root / "elsewhere/x")
        box = self.cloud("Box-Box")
        cases = [("f", str(self.home / "BoxAlias") + "/../OneDrive-Personal", self.cloud("OneDrive-Personal")),
                 ("g", "../../../home/Library/CloudStorage/Box-Box", box),
                 ("j", str(self.home) + "//Library//CloudStorage/Box-Box/", box),
                 ("k", str(self.home) + "/./Library/CloudStorage/../CloudStorage/Box-Box/Project", box),
                 ("l", str(self.root / "elsewhere/x/Project"), box),
                 ("o", str(self.home / "Documents") + "/../Library/CloudStorage/Box-Box", box)]
        if os.path.islink("/Volumes/Macintosh HD") and os.readlink("/Volumes/Macintosh HD") == "/":
            cases.append(("e", "/Volumes/Macintosh HD" + box, box))
        upper = ("/System/Volumes/Data" + os.path.realpath(self.home) + "/Library/CloudStorage/Box-Box").upper()
        if os.path.isdir(upper):
            cases.append(("m", upper, box))
        for letter, target, _ in cases:
            os.symlink(target, self.prefix / f"dosdevices/{letter}:")
        found = {link["item"]: link for link in RUNTIME.bottle_links(self.prefix, str(self.home))}
        for letter, target, folder in cases:
            link = found.get(f"dosdevices/{letter}:")
            self.assertIsNotNone(link, f"{letter}: -> {target}")
            self.assertEqual(link["folder"].lower(), folder.lower(), f"{letter}: -> {target}")
            self.assertTrue(RUNTIME._gated(link), f"{letter}: -> {target}")

    def test_a_non_ascii_home_is_recognised_in_either_unicode_form(self):
        """A home folder with a non-ASCII name, stored NFC, linked NFD (and the reverse)."""
        nfc, nfd = "José", "José"
        (self.root / nfc / "Library/CloudStorage/Box-Box").mkdir(parents=True)
        os.symlink(str(self.root / nfd / "Library/CloudStorage/Box-Box"), self.prefix / "dosdevices/n:")
        for home in (nfc, nfd):
            found = [link for link in RUNTIME.bottle_links(self.prefix, str(self.root / home))
                     if link["item"] == "dosdevices/n:"]
            self.assertTrue(found and RUNTIME._gated(found[0]), home)


# A stand-in wineserver: takes the write lock the way wineserver does (fcntl F_SETLK, first byte),
# then listens on, closes or releases on command.
HOLDER = """
import fcntl, os, socket, sys, time
fd = os.open(sys.argv[1], os.O_RDWR); fcntl.lockf(fd, fcntl.LOCK_EX, 1); server = None
print("locked", flush=True)
for line in sys.stdin:
    command = line.strip()
    if command.endswith("-later"): time.sleep(0.3)
    if command.startswith("listen"):
        server = socket.socket(socket.AF_UNIX); server.bind(sys.argv[2]); server.listen(5)
    elif command == "close": server.close()  # wineserver keeps the socket file until it exits
    elif command.startswith("unlock"): fcntl.lockf(fd, fcntl.LOCK_UN, 1)
    print("done", flush=True)
"""


class WineStartGateTests(unittest.TestCase):
    """launch(), run() and swcli_runtime's tasklist pass the gate before any Wine process starts."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-gate-start-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(os.path.realpath(self.temporary.name))
        self.home = self.root / "home"
        self.box = self.home / "Library/CloudStorage/Box-Box"
        self.box.mkdir(parents=True)
        self.prefix = self.root / "bottle"
        (self.prefix / "dosdevices").mkdir(parents=True)
        os.symlink(str(self.box), self.prefix / "dosdevices/b:")
        RUNTIME._answers.clear()
        self.addCleanup(RUNTIME._answers.clear)
        # This process has not been let into Box (macOS said no).
        RUNTIME._answers[str(self.box)] = "denied"
        environment = patch.dict(os.environ, {"HOME": str(self.home), "MACSW_WINE_LOCALE": "en_US.UTF-8"})
        environment.start()
        self.addCleanup(environment.stop)
        self.contents = self.root / "MacSW.app/Contents"

    def letter_present(self):
        return os.path.islink(self.prefix / "dosdevices/b:")

    def test_unmanaged_bottle_is_left_alone(self):
        with patch.object(RUNTIME.subprocess, "Popen") as popen:
            popen.return_value.wait.return_value = 0
            RUNTIME.launch(self.contents, self.prefix, ["wine", "cmd"])
        self.assertTrue(self.letter_present())

    def test_launch_sets_aside_before_the_wine_process_starts(self):
        RUNTIME.state_root(self.prefix).mkdir()
        seen = []
        with patch.object(RUNTIME, "require_ready"), patch.object(RUNTIME.subprocess, "Popen") as popen:
            popen.side_effect = lambda arguments: seen.append(self.letter_present()) or popen.return_value
            popen.return_value.wait.return_value = 0
            self.assertEqual(RUNTIME.launch(self.contents, self.prefix, ["wine", "cmd"]), 0)
        self.assertEqual(seen, [False])
        self.assertEqual(os.readlink(self.prefix / ".macsw-held/dosdevices/b:"), str(self.box))
        log = (self.root / "logs/folder-consent.log").read_text()
        self.assertIn("set aside: dosdevices/b:", log)

    def test_run_gates_the_loader_but_not_wineserver(self):
        RUNTIME.state_root(self.prefix).mkdir()
        seen = []
        with patch.object(RUNTIME.subprocess, "run", side_effect=lambda *a, **k: seen.append(self.letter_present())):
            RUNTIME.run(self.contents, self.prefix, ["-k"], self.root / "server.log", server=True)
            RUNTIME.run(self.contents, self.prefix, [r"C:\windows\system32\wineboot.exe", "-u"], self.root / "boot.log")
        self.assertEqual(seen, [True, False])

    def test_wine_is_not_started_when_a_link_cannot_be_set_aside(self):
        RUNTIME.state_root(self.prefix).mkdir()
        (self.prefix / ".macsw-held").write_text("not a directory")
        with patch.object(RUNTIME, "require_ready"), patch.object(RUNTIME.subprocess, "Popen") as popen:
            self.assertRaisesRegex(RuntimeError, "Wine was not started", RUNTIME.prepare_wine_start, self.prefix)
            popen.assert_not_called()
        with patch.object(RUNTIME, "require_ready"), patch.object(RUNTIME.subprocess, "Popen") as popen:
            with patch.object(sys, "argv", ["wine_runtime.py", "launch", "--contents", str(self.contents),
                                            "--prefix", str(self.prefix), "--", "wine", "cmd"]):
                with patch.object(sys, "stderr"):
                    self.assertEqual(RUNTIME.main(), 1)
            popen.assert_not_called()

    def test_upgrade_boot_gates_every_loader_run(self):
        """From the re-review: wine_runtime.boot (migrate and restore) runs no loader with a cloud link
        this process may not open; wineserver is not gated; the Documents link stays."""
        RUNTIME.state_root(self.prefix).mkdir()
        (self.prefix / "drive_c/users/me").mkdir(parents=True)
        (self.home / "Documents").mkdir()
        os.symlink(str(self.box), self.prefix / "drive_c/users/me/Box")
        os.symlink(str(self.home / "Documents"), self.prefix / "drive_c/users/me/Documents")
        seen = []

        def fake_run(command, **kwargs):
            seen.append((Path(command[0]).name, self.letter_present(), os.path.islink(self.prefix / "drive_c/users/me/Box"),
                         os.path.islink(self.prefix / "drive_c/users/me/Documents")))
        log = self.root / "migration.log"
        with patch.object(RUNTIME, "identity", return_value={"MonoVersion": "1"}), \
                patch.object(RUNTIME, "verify_app"), patch.object(RUNTIME.shutil, "copy2"), \
                patch.object(RUNTIME.subprocess, "run", side_effect=fake_run):
            RUNTIME.stop(self.contents, self.prefix, log)
            RUNTIME.boot(self.contents, self.prefix, log)
        servers = [entry for entry in seen if entry[0] == "wineserver"]
        loaders = [entry for entry in seen if entry[0] != "wineserver"]
        self.assertEqual(len(servers), 2)
        self.assertTrue(all(entry[1] for entry in servers), "wineserver -k/-w runs before any gate, links untouched")
        self.assertGreaterEqual(len(loaders), 4)
        self.assertTrue(all(entry[1:] == (False, False, True) for entry in loaders), seen)

    def test_swcli_tasklist_probe_passes_the_gate(self):
        spec = importlib.util.spec_from_file_location("runtime_sync_gate", PROJECT / "scripts/swcli/swcli_runtime.py")
        sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sync)
        RUNTIME.state_root(self.prefix).mkdir()
        seen = []

        def tasklist(*args, **kwargs):
            seen.append(self.letter_present())
            kwargs["stdout"].write(b'"explorer.exe","12","Console","1","0 K"\r\n')
            return subprocess.CompletedProcess(args, 0)
        # swcli_runtime imports wine_runtime by name; give it this module and its answers.
        with patch.dict(sys.modules, {"wine_runtime": RUNTIME}), patch.object(sync.subprocess, "run", side_effect=tasklist):
            self.assertFalse(sync.backend_in_use(self.contents, self.prefix))
        self.assertEqual(seen, [False])


if __name__ == "__main__":
    unittest.main()
