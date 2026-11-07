import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

private let bootstrapWindowIdentifier = NSUserInterfaceItemIdentifier(BootstrapWindowIdentity.identifier)

@MainActor
enum AppLifecycleBridge {
    static func openLegacySettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsToFront()
    }

    static func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            settingsWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible
                && $0.canBecomeKey
                && !($0 is NSPanel)
                && $0.identifier != bootstrapWindowIdentifier
        }
    }
}

@MainActor
enum OpenPanelService {
    static func chooseInstallationMedia() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.message = "Choose the official SOLIDWORKS ISO or an install media folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The team's MacSW folder, or its macsw-team.json (`TeamConfigLocator.examineChosen`).
    static func chooseTeamFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the team's MacSW folder (it holds macsw-team.json)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The folder with vba71.msi and vba71_1033.msi (VBAPrerequisite).
    static func chooseVBAInstallerFolder(startingAt folder: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Install VBA"
        panel.message = "Choose the folder with vba71.msi and vba71_1033.msi (PreReqs\\VBA of the SOLIDWORKS media)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// At MacSW launch, before the first Wine process: a copy from a downloaded disk image still has the
/// macOS download flag (`DownloadQuarantine`). With the user's consent MacSW removes it from its own
/// bundle; it changes nothing else.
@MainActor
enum DownloadQuarantinePrompt {
    static func presentIfNeeded(bundle: URL = Bundle.main.bundleURL, defaults: UserDefaults = .standard) {
        let suppressedKey = AppPreferences.downloadFlagQuestionSuppressedKey
        let alert = NSAlert()
        switch DownloadQuarantine.decision(bundle: bundle, suppressed: defaults.bool(forKey: suppressedKey)) {
        case .nothing, .suppressed:
            return
        case .translocated:
            alert.alertStyle = .warning
            alert.messageText = "Move MacSW to Applications"
            alert.informativeText = "macOS runs this copy of MacSW from a temporary read-only folder. Quit MacSW, drag it onto Applications, and open it from there."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        case .ask:
            alert.messageText = "Remove the download flag?"
            alert.informativeText = DownloadQuarantine.consentText
            alert.addButton(withTitle: "Remove Download Flag")
            alert.addButton(withTitle: "Not Now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not ask again"
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(true, forKey: suppressedKey) }
        guard response == .alertFirstButtonReturn else { return }
        do {
            try DownloadQuarantine.remove(from: bundle)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "The download flag was not removed"
            failure.informativeText = error.localizedDescription + " macOS can block MacSW's Wine helpers. Run install-helper.sh from the MacSW disk image, or see Read Me First.txt."
            failure.runModal()
        }
    }
}

/// At MacSW launch or a Dock click: SOLIDWORKS is installed, but the bottle's Wine record blocks the start
/// (usually a pending upgrade after an App update). MacSW then lives only in the menu bar, so without this
/// alert nothing visible happens; Settings → Maintenance has the same actions.
@MainActor
enum WineRuntimeLaunchPrompt {
    private static var presenting = false

    static func presentIfBlocked(_ runtime: RuntimeStore) {
        let state = runtime.wineRuntimeState
        guard runtime.isInstalled, !state.allowsLaunch, !runtime.isMigratingWine, !presenting else { return }
        presenting = true
        defer { presenting = false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SOLIDWORKS cannot start yet"
        alert.informativeText = state.message
            + " Settings → Maintenance (the cube icon in the menu bar) has the same actions."
        if state == .upgrade {
            alert.informativeText += "\n\nSave your documents first. All Windows processes in this bottle will be stopped; the old App and a full bottle backup are kept. Do not quit MacSW while it runs."
            alert.addButton(withTitle: "Back Up and Upgrade Bottle")
            alert.addButton(withTitle: "Not Now")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, state == .upgrade else { return }
        runtime.maintainWineRuntime("upgrade")
        Task {
            await runtime.waitForWineMaintenance()
            let ready = runtime.wineRuntimeState.allowsLaunch
            let result = NSAlert()
            result.alertStyle = ready ? .informational : .warning
            result.messageText = ready ? "The bottle is upgraded" : "The bottle upgrade did not finish"
            result.informativeText = runtime.statusMessage
            if ready {
                result.addButton(withTitle: "Start SOLIDWORKS")
                result.addButton(withTitle: "Later")
            }
            NSApp.activate(ignoringOtherApps: true)
            if result.runModal() == .alertFirstButtonReturn, ready { runtime.launch() }
        }
    }
}

/// At MacSW launch: SOLIDWORKS is installed but VBA 7.1 is not, so SOLIDWORKS rejects every equation
/// without saying why. The menu bar panel and Settings → Maintenance keep showing it after this alert.
@MainActor
enum VBALaunchWarning {
    static func presentIfNeeded(_ vba: VBAStore) {
        guard let warning = vba.missingWarning, !vba.warningSuppressed else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Equations and macros will not work"
        alert.informativeText = warning + " Choose the folder with vba71.msi and vba71_1033.msi (PreReqs\\VBA of the SOLIDWORKS media) to install it. Settings → Maintenance has the same action."
        alert.addButton(withTitle: "Install VBA…")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not warn again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { vba.warningSuppressed = true }
        guard response == .alertFirstButtonReturn,
              let folder = OpenPanelService.chooseVBAInstallerFolder(startingAt: vba.installerFolder) else { return }
        Task {
            await vba.install(from: folder)
            let result = NSAlert()
            result.alertStyle = vba.isRegistered == true ? .informational : .warning
            result.messageText = vba.isRegistered == true ? "VBA 7.1 installed" : "VBA 7.1 was not installed"
            result.informativeText = vba.statusMessage
            NSApp.activate(ignoringOtherApps: true)
            result.runModal()
        }
    }
}

/// 设置窗口打开期间把 App 提回常规模式（出现 Dock 图标），关掉后回到纯菜单栏。
/// 没有 Dock 图标时设置窗口很难被找到和置顶，尤其是从菜单栏面板点齿轮进来的时候。
struct SettingsWindowLifecycle: NSViewRepresentable {
    final class Coordinator {
        var observed: NSWindow?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { attach(to: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { self.attach(to: view, coordinator: context.coordinator) }
    }

    private func attach(to view: NSView, coordinator: Coordinator) {
        guard let window = view.window, coordinator.observed !== window else { return }
        // 换窗口（关闭后重开）之前必须摘掉上一个观察者，否则每次重开都留一个永久的监听。
        if let closeObserver = coordinator.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        coordinator.observed = window
        AppShell.shared.settingsWindowVisible = true
        coordinator.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in AppShell.shared.settingsWindowVisible = false }
        }
    }
}
