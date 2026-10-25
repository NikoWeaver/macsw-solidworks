"""Offline source contracts for the copy-only agent entry point."""

from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCES = PROJECT / "macos/Bootstrap/Sources"


class AIConnectionContractTests(unittest.TestCase):
    def test_menu_status_polls_only_while_visible_and_refreshes_on_reopening(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        self.assertIn("Timer.publish(every: 2", view)
        tick = view.split(".onReceive(Self.tick)", 1)[1].split("private var header", 1)[0]
        self.assertIn("panelWindow?.isVisible == true", tick)
        self.assertLess(tick.index("panelWindow?.isVisible == true"), tick.index("await refresh()"))
        self.assertIn("NSWindow.didBecomeKeyNotification", view)
        self.assertIn("window === panelWindow, window.isVisible", view)
        self.assertIn("swcliDaemon.refresh()", view)

    def test_copy_action_is_between_solidworks_and_logs_without_dismissing_panel(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        self.assertLess(view.index('"Launch SOLIDWORKS"'), view.index('"Copy AI Connection Info"'))
        self.assertLess(view.index('"Copy AI Connection Info"'), view.index('"Show Log"'))
        action = view.split("private func copyAIConnectionInfo()", 1)[1].split("private var summaryText", 1)[0]
        self.assertIn("AIConnectionClipboard.copy(paths: runtime.paths)", action)
        self.assertNotIn("dismissPanel()", action)
        self.assertIn('"Copied"', view)

    def test_copy_feedback_uses_one_shot_common_mode_timer_not_view_task(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        action = view.split("private func copyAIConnectionInfo()", 1)[1].split("private var summaryText", 1)[0]
        self.assertIn("copyFeedbackTimer?.invalidate()", action)
        self.assertIn("Timer(timeInterval: 2, repeats: false)", action)
        self.assertIn("MainActor.assumeIsolated", action)
        self.assertIn("copySucceeded = nil", action)
        self.assertIn("copyFeedbackTimer = nil", action)
        self.assertIn("RunLoop.main.add(timer, forMode: .common)", action)
        self.assertLess(action.index("copyFeedbackTimer?.invalidate()"), action.index("let timer = Timer("))
        self.assertNotIn("copyFeedbackID", view)
        self.assertNotIn("Task.sleep", view)

    def test_clipboard_bridge_only_reads_resources_and_copies_plain_text(self):
        bridge = (SOURCES / "MacSWApp/Support/AIConnectionClipboard.swift").read_text()
        self.assertIn("@MainActor", bridge)
        self.assertIn("Bundle.main.bundleURL", bridge)
        self.assertIn("NSPasteboard.general", bridge)
        self.assertIn("pasteboard.setString(information.text, forType: .string)", bridge)
        self.assertLess(bridge.index("throw CopyError.missingResource"), bridge.index("pasteboard.clearContents()"))
        for forbidden in ("WineService", "createDirectory", "Process(", "CommandRunner", "AppPaths.live"):
            self.assertNotIn(forbidden, bridge)

    def test_pure_info_does_not_read_bottle_or_start_processes(self):
        info = (SOURCES / "MacSWCore/Models/AIConnectionInfo.swift").read_text()
        launcher = (PROJECT / "scripts/swcli/sw-cli").read_text()
        endpoint = re.search(r'defaultEndpoint = "([^"]+)"', info).group(1)
        self.assertIn("${SWCLI_ENDPOINT:-" + endpoint + "}", launcher)
        for forbidden in ("AppKit", "FileManager", "Process(", "CommandRunner", "AppPaths.live"):
            self.assertNotIn(forbidden, info)

    def test_advertised_skill_is_checked_against_current_pinned_source(self):
        info = (SOURCES / "MacSWCore/Models/AIConnectionInfo.swift").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        relative = re.search(r'"runtime/PythonNative/([^"]+/skills/swcli)"', info).group(1)
        for document in ("SKILL.md", "references/usage.md"):
            packaged = "${SWCLI_NATIVE_RUNTIME}/" + relative + "/" + document
            self.assertIn('test -s "' + packaged + '"', verify)
            self.assertIn('cmp "${WORKSPACE_ROOT}/Dependencies/SWCLI/src/swcli/skills/swcli/' + document + '"', verify)


if __name__ == "__main__":
    unittest.main()
