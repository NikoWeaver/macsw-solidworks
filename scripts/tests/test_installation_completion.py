"""Guard the explicit acknowledgement flow without running an installer."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
VIEWS = PROJECT / 'macos/Bootstrap/Sources/MacSWApp/Features/Bootstrap'


class InstallationCompletionTests(unittest.TestCase):
    def test_completion_notification_does_not_close_or_launch(self):
        root = (VIEWS / 'BootstrapSceneRoot.swift').read_text()
        self.assertNotIn('.onReceive', root)
        self.assertNotIn('macSWInstallationCompleted', root)
        self.assertIn('BootstrapView(store: store, team: team) {', root)
        self.assertIn('guard store.state == .completed else { return }', root)
        self.assertIn('if AppPreferences.autoLaunchSolidWorks() { runtime.launch() }', root)
        self.assertIn('AppShell.shared.closeBootstrapWindow()', root)
        self.assertLess(root.index('closeBootstrapWindow()'), root.index('store.resetAfterFailure()'))

    def test_success_has_its_own_branch_and_preserves_warnings(self):
        view = (VIEWS / 'BootstrapView.swift').read_text()
        self.assertIn('if store.state == .completed {', view)
        self.assertIn('InstallationCompletionView(', view)
        self.assertIn('store.stepStatuses[step] == .warning', view)
        self.assertIn('store.stepDetails[step]', view)
        self.assertIn('onFinish: onFinish', view)
        self.assertIn('case .cancelled, .failed: return true', view)

    def test_success_has_explicit_keyboard_action_and_logs(self):
        view = (VIEWS / 'InstallationCompletionView.swift').read_text()
        for text in ('Installation Complete', 'checkmark.circle.fill', 'Install Notes', 'autoLaunch',
                     'Button("Done", action: onFinish)', '.keyboardShortcut(.defaultAction)',
                     'Button("Show Log", action: onRevealLogs)'):
            self.assertIn(text, view)

    def test_success_still_requires_validation_and_receipt(self):
        store = (PROJECT / 'macos/Bootstrap/Sources/MacSWCore/Stores/BootstrapStore.swift').read_text()
        validation = store.index('try await validateInstalledRuntime()')
        receipt = store.index('try writeInstallationReceipt()', validation)
        success = store.index('state = .completed', receipt)
        notification = store.index('NotificationCenter.default.post', success)
        self.assertLess(validation, receipt)
        self.assertLess(receipt, success)
        self.assertLess(success, notification)


if __name__ == '__main__':
    unittest.main()
