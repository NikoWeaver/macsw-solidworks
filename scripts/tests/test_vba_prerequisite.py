"""Guard the VBA 7.1 prerequisite wiring (install step, repair action, launch warning) without Wine."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCES = PROJECT / 'macos/Bootstrap/Sources'
CORE = SOURCES / 'MacSWCore'
APP = SOURCES / 'MacSWApp'


def function_body(source, signature):
    start = source.index(signature)
    end = source.find('\n    }\n', start)
    return source[start:end]


class VBAInstallStepTests(unittest.TestCase):
    def test_vba_runs_after_the_prerequisites_and_before_the_core_msi(self):
        store = (CORE / 'Stores/BootstrapStore.swift').read_text()
        login = store.index('try await prerequisites.installLoginManager(')
        vba = store.index('try await installVBAIfAvailable(media: media, request: request)')
        self.assertIn('vbaFolder: AppPreferences.vbaInstallerFolder()', store)
        # Only the team install requires the known MSIs.
        self.assertIn('knownVBA: requiresKnownVBA ? VBAPrerequisite.knownSHA256 : nil', store)
        self.assertIn('public var requiresKnownVBA = false', store)
        core = store.index('SilentInstallerPlan.coreInstallArguments(')
        self.assertLess(login, vba)
        self.assertLess(vba, core)
        self.assertLess(store.index('state = .installing(.vba)'), vba)

    def test_vba_is_idempotent_optional_and_still_cancellable(self):
        body = function_body((CORE / 'Stores/BootstrapStore.swift').read_text(),
                             'private func installVBAIfAvailable(')
        skip = body.index('VBAPrerequisite.isRegistered(prefix: bottle)')
        search = body.index('VBAPrerequisite.installers(media: media, teamFolder: request.teamVBAFolder,')
        install = body.index('try await prerequisites.installVBA(')
        self.assertLess(skip, search)
        self.assertLess(search, install)
        # Missing installers and failed installs are warnings for the completion page, not failures.
        self.assertIn('report(.vba, .warning, VBAPrerequisite.skippedNote)', body)
        cancel = body.index('if error is CancellationError || Task.isCancelled { throw CancellationError() }')
        self.assertLess(cancel, body.index('report(.vba, .warning, "Not installed:'))
        # Registration after msiexec is checked live: system.reg lags behind wineserver.
        self.assertIn('registry.missingCOMRegistrations(', body)

    def test_installers_are_staged_inside_the_bottle_before_msiexec(self):
        body = function_body((CORE / 'Services/PrerequisiteService.swift').read_text(),
                             'public func installVBA(installers: [URL], prefix: URL')
        self.assertIn('drive_c/windows/temp/MacSW-VBA-', body)
        self.assertLess(body.index('copyItem(at: installer, to: staged)'), body.index('wine.runMSIExec('))
        # The staged copies, the files msiexec reads, are all checked before the first msiexec.
        self.assertLess(body.index('VBAPrerequisite.checkKnownHashes(stagedInstallers'), body.index('wine.runMSIExec('))
        self.assertIn('SilentInstallerPlan.vbaInstallArguments(msi: staged', body)
        self.assertIn('defer { try? fileManager.removeItem(at: staging) }', body)


class VBARepairAndWarningTests(unittest.TestCase):
    def test_settings_has_the_repair_action_with_a_folder_panel(self):
        settings = (APP / 'Features/Settings/SettingsView.swift').read_text()
        self.assertIn('Button("Install VBA (equations and macros)…")', settings)
        self.assertIn('OpenPanelService.chooseVBAInstallerFolder(startingAt: vba.installerFolder)', settings)
        self.assertIn('await vba.install(from: folder)', settings)
        panel = function_body((APP / 'Support/AppKitBridges.swift').read_text(),
                              'static func chooseVBAInstallerFolder(')
        self.assertIn('panel.canChooseDirectories = true', panel)
        self.assertIn('panel.canChooseFiles = false', panel)

    def test_launch_warning_waits_for_launch_and_reads_files_only(self):
        app = (APP / 'App/MacSWApp.swift').read_text()
        self.assertIn('shell.finishLaunching()', app)
        handler = app.index('AppShell.shared.setLaunchHandler')
        self.assertLess(handler, app.index('await vba.refresh()', handler))
        self.assertLess(app.index('await vba.refresh()', handler), app.index('VBALaunchWarning.presentIfNeeded(vba)', handler))
        self.assertIn('forName: .macSWInstallationCompleted', app)
        self.assertIn('await vba?.installationCompleted()', app)
        store = (CORE / 'Stores/VBAStore.swift').read_text()
        self.assertIn('self.fileCheck = fileCheck ?? { VBAPrerequisite.isRegistered(prefix: $0) }', store)
        refresh = function_body(store, 'public func refresh() async')
        self.assertIn('fileCheck', refresh)
        self.assertNotIn('liveCheck', refresh)

    def test_warning_is_suppressible_and_also_in_the_menu_bar(self):
        bridges = (APP / 'Support/AppKitBridges.swift').read_text()
        alert = bridges[bridges.index('enum VBALaunchWarning'):]
        self.assertIn('guard let warning = vba.missingWarning, !vba.warningSuppressed', alert)
        self.assertIn('alert.showsSuppressionButton = true', alert)
        self.assertIn('Equations and macros will not work', alert)
        panel = (APP / 'Features/MenuBar/MenuBarPanelView.swift').read_text()
        self.assertIn('if let warning = vba.missingWarning {', panel)
        self.assertIn('equations and macros will not work', panel)
        core = (CORE / 'Support/VBAPrerequisite.swift').read_text()
        self.assertIn('equations and macros will not work', core)
        self.assertIn('{CFE9F29B-E1B6-4240-AED7-360846769314}', core)


if __name__ == '__main__':
    unittest.main()
