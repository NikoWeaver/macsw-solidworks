import AppKit
import MacSWCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let shell = AppShell.shared
        NSApp.setActivationPolicy(shell.activationPolicyAtLaunch)
        // 未安装时引导安装是唯一入口；已安装时只保留菜单栏，需要时由菜单或设置打开。
        if !shell.solidWorksInstalled {
            shell.showBootstrapWindow()
        }
        shell.finishLaunching()
    }

    // Double-click in Finder, dropping on the Dock icon and `open -a` all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppShell.shared.openDocuments(urls)
    }

    // Dock icon click while the app is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppShell.shared.handleReopen()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
enum MacSWEntry {
    static func main() {
        guard HeadlessInstallOptions.isRequested(CommandLine.arguments) else {
            MacSWApplication.main()
            return
        }
        // No windows, no menu bar item: the install pipeline runs on the main actor and exits.
        Task { @MainActor in
            let code = await HeadlessInstaller.run(arguments: CommandLine.arguments, paths: AppPaths.live()) { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            }
            exit(code)
        }
        dispatchMain()
    }
}

struct MacSWApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap: BootstrapStore
    @StateObject private var licenseServer: LicenseServerStore
    @StateObject private var resourceMonitor: SolidWorksResourceMonitorStore
    @StateObject private var keyboardShortcuts: WineKeyboardShortcutStore
    @StateObject private var runtime: RuntimeStore
    @StateObject private var solidWorksApp: SolidWorksAppStore
    @StateObject private var vba: VBAStore

    init() {
        let paths = AppPaths.live()
        let licenseServer = LicenseServerStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licenseServer)
        let bootstrap = BootstrapStore(paths: paths, licensing: licenseServer, runtime: runtime)
        let resourceMonitor = SolidWorksResourceMonitorStore(paths: paths)
        let keyboardShortcuts = WineKeyboardShortcutStore(paths: paths)
        let solidWorksApp = SolidWorksAppStore(paths: paths)
        let vba = VBAStore(paths: paths)
        let team = TeamSetupStore(paths: paths)
        // The team setup is for the first install; a reinstall from Settings uses the install window.
        if paths.solidWorksInstalled { team.useManualInstall(bootstrap) }
        _bootstrap = StateObject(wrappedValue: bootstrap)
        _licenseServer = StateObject(wrappedValue: licenseServer)
        _resourceMonitor = StateObject(wrappedValue: resourceMonitor)
        _keyboardShortcuts = StateObject(wrappedValue: keyboardShortcuts)
        _runtime = StateObject(wrappedValue: runtime)
        _solidWorksApp = StateObject(wrappedValue: solidWorksApp)
        _vba = StateObject(wrappedValue: vba)
        AppShell.shared.configure {
            AnyView(BootstrapSceneRoot(store: bootstrap, team: team, runtime: runtime).environmentObject(solidWorksApp))
        }
        AppShell.shared.setReopenHandler { [weak runtime, weak solidWorksApp] in
            // SOLIDWORKS.app's "out of date" alert sends the user here ("Open MacSW").
            await solidWorksApp?.updateIfStale()
            guard let runtime else { return }
            await runtime.handleDockReopen { pid in
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) ?? false
            }
        }
        let autoLaunch = AppPreferences.autoLaunchSolidWorks()
        AppShell.shared.setLaunchHandler { [weak vba, weak runtime] in
            // The download-flag question comes first: no Wine process (font check, SOLIDWORKS for a
            // document from Finder) starts before it is answered. Documents queue in AppShell until then.
            DownloadQuarantinePrompt.presentIfNeeded()
            AppShell.shared.setDocumentHandler { [weak runtime] urls in
                Task { @MainActor in runtime?.open(documents: urls) }
            }
            runtime?.prepareFontLinkAtAppLaunch()
            Task { @MainActor in
                await runtime?.startup(autoLaunch: autoLaunch)
            }
            // Launch-time VBA check (registry files only, no Wine process); warns when equations and macros will not work.
            guard let vba else { return }
            await vba.refresh()
            VBALaunchWarning.presentIfNeeded(vba)
        }
        _ = NotificationCenter.default.addObserver(forName: .macSWInstallationCompleted, object: nil, queue: .main) { [weak vba] _ in
            Task { @MainActor in await vba?.installationCompleted() }
        }
        // After a MacSW update: bring an installed SOLIDWORKS.app to this build (docs/solidworks-app.md, section 4).
        Task { @MainActor in
            await solidWorksApp.updateIfStale()
        }
    }

    var body: some Scene {
        MenuBarExtra("MacSW", systemImage: "cube.fill") {
            MenuBarPanelView(runtime: runtime, solidWorksApp: solidWorksApp, vba: vba)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                runtime: runtime,
                licenseServer: licenseServer,
                resourceMonitor: resourceMonitor,
                keyboardShortcuts: keyboardShortcuts,
                solidWorksApp: solidWorksApp,
                vba: vba
            )
        }
    }
}
