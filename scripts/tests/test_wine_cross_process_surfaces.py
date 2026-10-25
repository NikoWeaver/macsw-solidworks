"""Patch 0018 (WebView2 cross-process surfaces): the receiver treats the shared header as untrusted."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = PROJECT / "patches/wine-crossover/0018-win32u-cross-process-window-surfaces.patch"


def added(text):
    return "\n".join(l[1:] for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))


class CrossProcessSurfaceReceiverTests(unittest.TestCase):
    def setUp(self):
        self.patch = PATCH.read_text()
        code = added(self.patch)
        self.receiver = code.split("void update_foreign_surface( HWND hwnd, HWND child, LPARAM lparam )", 1)[1]
        self.receiver = self.receiver.split("\n}\n", 1)[0]
        self.sender = code.split("static struct window_surface *get_foreign_surface(", 1)[1].split("\n}\n", 1)[0]

    def test_receiver_acts_only_with_the_variable(self):
        # MACSW_CROSS_PROCESS_SURFACES gates both sides; any process of the prefix can post the message.
        self.assertIn("if (!foreign_surfaces_enabled()) return;", self.receiver)
        self.assertLess(self.receiver.index("if (!foreign_surfaces_enabled()) return;"),
                        self.receiver.index("NtOpenSection"))
        self.assertIn('getenv( "MACSW_CROSS_PROCESS_SURFACES" )', added(self.patch))

    def test_shared_header_is_read_once_into_locals(self):
        self.assertIn("const volatile struct foreign_surface_header *shared;", self.receiver)
        for line in ("magic  = shared->magic;", "width  = shared->width;", "height = shared->height;"):
            self.assertIn(line, self.receiver)
        # After the copy, only the locals are used (no double fetch from shared memory).
        after = self.receiver.split("height = shared->height;", 1)[1]
        for field in ("header->width", "header->height", "header->magic", "shared->"):
            self.assertNotIn(field, after)

    def test_size_is_capped_and_checked_without_overflow(self):
        self.assertIn("#define FOREIGN_SURFACE_MAX_SIZE 16384", added(self.patch))
        self.assertIn("width > FOREIGN_SURFACE_MAX_SIZE || height > FOREIGN_SURFACE_MAX_SIZE", self.sender)
        self.assertIn("width <= FOREIGN_SURFACE_MAX_SIZE && height <= FOREIGN_SURFACE_MAX_SIZE", self.receiver)
        self.assertIn("magic == FOREIGN_SURFACE_MAGIC && width && height", self.receiver)
        self.assertIn("view_size > FOREIGN_SURFACE_OFFSET", self.receiver)
        self.assertIn("(view_size - FOREIGN_SURFACE_OFFSET) / 4 / width >= height", self.receiver)
        self.assertNotIn("FOREIGN_SURFACE_OFFSET + (SIZE_T)", self.receiver)

    def test_description_matches_the_behaviour(self):
        header = self.patch.split("diff --git ", 1)[0]
        self.assertIn("neither side acts, and WM_WINE_FOREIGN_SURFACE is ignored", header)
        self.assertIn("16384", header)


if __name__ == "__main__":
    unittest.main()
