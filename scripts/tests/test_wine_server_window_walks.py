"""wineserver window walks (patch 0034): no walk starts on, or runs around, a parent's unlinked list."""
from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0034-server-unlinked-window-walks.patch"
KEY = "WineServerWindowWalksPatchSHA256"


def patch_text():
    return (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()


def hunks():
    """(hunk header, hunk text) of every hunk."""
    body = patch_text().split("diff --git ", 1)[1]
    return [(h.split(" @@", 1)[1].split("\n", 1)[0], h) for h in body.split("\n@@ ")[1:]]


def hunk(context):
    found = [text for header, text in hunks() if context in header]
    assert len(found) == 1, context
    return found[0]


def added(text):
    return "\n".join(l[1:] for l in text.splitlines() if l.startswith("+") and not l.startswith("+++"))


class ServerWindowWalksPatchTests(unittest.TestCase):
    def test_patch_only_touches_server_window_c(self):
        files = [l.split(" b/", 1)[1] for l in patch_text().splitlines() if l.startswith("diff --git ")]
        self.assertEqual(files, ["server/window.c"])
        # no removed lines: the patch only adds checks
        removed = [l for l in patch_text().split("diff --git ", 1)[1].splitlines()
                   if l.startswith("-") and not l.startswith("---")]
        self.assertEqual(removed, [])

    def test_find_window_ex_after_an_unlinked_child_returns_nothing(self):
        text = hunk("DECL_HANDLER(get_class_windows)")
        # return, not just a NULL win: a NULL win would fall through to the whole desktop list
        self.assertIn("+        if (!win->is_linked) return;", text)
        self.assertLess(text.index("if (win->parent != parent) return;"), text.index("if (!win->is_linked) return;"))
        self.assertLess(text.index("if (!win->is_linked) return;"), text.index("if (!(win = get_next_window( win ))) return;"))

    def test_sibling_list_from_an_unlinked_window_starts_at_the_first_child(self):
        text = hunk("static void get_window_list(")
        self.assertIn("+        if (!win->is_linked) win = get_first_child( win->parent );", text)
        self.assertLess(text.index("if (!win->is_linked)"), text.index("for (child = win; child; child = get_next_window( child ))"))

    def test_unlinked_insert_after_window_keeps_the_z_order(self):
        text = hunk("DECL_HANDLER(set_window_pos)")
        self.assertIn("+            if (!previous->is_linked) flags |= SWP_NOZORDER;", text)
        # inside the "previous is a window handle" case, after its sibling check (STATUS_INVALID_PARAMETER)
        self.assertLess(text.index("set_error( STATUS_INVALID_PARAMETER );"), text.index("if (!previous->is_linked)"))
        self.assertLess(text.index("if (!previous->is_linked)"), text.index("if (previous == win) flags |= SWP_NOZORDER;"))

    def test_walk_helpers_stop_at_the_unlinked_list_head(self):
        code = added(patch_text())
        self.assertEqual(code.count("if (ptr == &win->parent->unlinked) return NULL;"), 2)
        text = patch_text()
        nxt = text.split("static inline struct window *get_next_window( struct window *win )", 1)[1].split("\n }\n", 1)[0]
        prv = text.split("static inline struct window *get_prev_window( struct window *win )", 1)[1].split("\n }\n", 1)[0]
        for body in (nxt, prv):
            self.assertLess(body.index("if (ptr == &win->parent->unlinked) return NULL;"), body.index("LIST_ENTRY"))

    def test_build_package_and_verify_wiring(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        for script in (build, package, verify):
            self.assertIn(PATCH_NAME, script)
        self.assertNotIn("0034-diag-window-list-checks", build)   # the diagnostics are not shipped
        build_key = build.split("BUILD_KEY=", 1)[1].split("\n", 1)[0]
        self.assertIn("${SERVER_WINDOW_WALKS_PATCH_SHA256}", build_key)
        self.assertIn('apply --check "${SERVER_WINDOW_WALKS_PATCH}"', build)
        applies = re.findall(r'git -C "\$\{SOURCE_DIR\}" apply "\$\{(\w+)\}"', build)
        self.assertEqual(applies.count("SERVER_WINDOW_WALKS_PATCH"), 1)
        self.assertEqual(applies[-2:], ["SERVER_WINDOW_WALKS_PATCH", "OPENGL32_BATCH_PATCH"])   # 0030 stays last
        self.assertIn("server/wineserver", build)
        self.assertIn(KEY, package)
        self.assertIn(KEY, verify)

    def test_pin_is_computed_from_the_patch_file(self):
        for name in ("package_app.sh", "verify_app.sh"):
            text = (PROJECT / "scripts" / name).read_text()
            line = next(l for l in text.splitlines() if KEY in l)
            self.assertNotRegex(line, r"[0-9a-f]{64}")

    def test_description_names_the_requests(self):
        header = " ".join(patch_text().split("diff --git ", 1)[0].split())
        for word in ("get_class_windows", "get_window_list", "set_window_pos", "WM_NCDESTROY",
                     "docs/native-file-dialogs.md"):
            self.assertIn(word, header)


if __name__ == "__main__":
    unittest.main()
