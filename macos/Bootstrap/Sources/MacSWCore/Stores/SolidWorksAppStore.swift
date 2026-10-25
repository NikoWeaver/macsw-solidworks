import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// MacSW's side of SOLIDWORKS.app (docs/solidworks-app.md, section 4): install, update and
/// uninstall from Settings → Maintenance, the suggestion after an install or a MacSW update, and
/// the automatic update of a copy that an older MacSW build installed.
@MainActor
public final class SolidWorksAppStore: ObservableObject {
    public typealias Installer = SolidWorksAppInstaller

    @Published public private(set) var status: Installer.Status = .notInstalled
    @Published public private(set) var pairing: Installer.Pairing = .none
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusMessage = ""
    /// A stale copy was running when MacSW wanted to update it; retried when SOLIDWORKS.app quits.
    @Published public private(set) var updatePending = false
    /// The installed copy is signed with an identity and this MacSW's copy has another designated
    /// requirement: MacSW does not replace it on its own. Settings asks (`install(allowRequirementChange:)`).
    @Published public private(set) var requirementChangeNeedsConsent = false
    @Published private var suggestionDismissed = false

    /// Default app for a content type (bundle identifier), and setting it.
    public struct DefaultHandlers: Sendable {
        public var current: @Sendable (_ contentType: String) -> String?
        public var set: @Sendable (_ app: URL, _ contentType: String) -> Void

        public init(current: @escaping @Sendable (String) -> String?, set: @escaping @Sendable (URL, String) -> Void) {
            self.current = current
            self.set = set
        }

        public static let live = DefaultHandlers(
            current: { identifier in
                guard let type = UTType(identifier), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else {
                    return nil
                }
                return Bundle(url: app)?.bundleIdentifier
            },
            set: { app, identifier in
                guard let type = UTType(identifier) else { return }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in }
            }
        )
    }

    public let payload: Installer.Payload?
    private let macSW: URL
    private let candidates: [URL]
    private let effects: Installer.Effects
    private let handlers: DefaultHandlers
    private let locate: @Sendable (URL) -> URL?
    private let defaults: UserDefaults
    private let logFile: URL
    private var terminationObserver: NSObjectProtocol?
    /// Postponed updates in a row. The first one is tried again after a few seconds: the launcher's
    /// "out of date" alert opens MacSW just before the launcher exits, and it never checks in as an app.
    private var postponements = 0

    public init(
        paths: AppPaths,
        macSW: URL = MacSWBundle.url,
        defaults: UserDefaults = .standard,
        candidates: [URL] = Installer.candidateLocations(home: FileManager.default.homeDirectoryForCurrentUser),
        effects: Installer.Effects = Installer.liveEffects,
        handlers: DefaultHandlers = .live,
        locate: @escaping @Sendable (URL) -> URL? = { Installer.liveLocate($0) },
        observeTermination: Bool = true
    ) {
        self.macSW = macSW
        self.payload = Installer.payload(in: macSW)
        self.candidates = candidates
        self.effects = effects
        self.handlers = handlers
        self.locate = locate
        self.defaults = defaults
        self.logFile = paths.logs.appendingPathComponent("solidworks-app.log")
        refresh()
        guard observeTermination else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == AppBundleLaunch.solidWorksBundleIdentifier else { return }
            Task { @MainActor in
                guard let self, self.updatePending else { return }
                await self.updateIfStale()
            }
        }
    }

    deinit {
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
    }

    public var installedURL: URL? {
        switch status {
        case .current(let url), .stale(let url), .unknown(let url): return url
        case .notInstalled, .foreign: return nil
        }
    }

    /// The installed copy, or where a new one goes (/Applications).
    public var target: URL { installedURL ?? candidates[0] }

    /// This MacSW may install or update SOLIDWORKS.app: it carries one, and a copy at the target
    /// would use this MacSW.app (`Installer.pairing`).
    public var canInstall: Bool {
        if case .foreign = status { return false }
        return payload != nil && pairing == .thisMacSW && !isWorking
    }

    /// Only the MacSW.app that the installed copy uses removes it and takes its document types back.
    public var canUninstall: Bool { installedURL != nil && pairing == .thisMacSW && !isWorking }

    /// Offered once per SOLIDWORKS.app build (that is, after a MacSW install or update) until
    /// installed or dismissed.
    public var suggestsInstall: Bool { status == .notInstalled && canInstall && !suggestionDismissed }

    public func dismissSuggestion() {
        guard let payload else { return }
        defaults.set(payload.executableSHA256, forKey: AppPreferences.solidWorksAppSuggestionDismissedKey)
        suggestionDismissed = true
    }

    public func refresh() {
        status = Installer.status(payload: payload, installed: Installer.installedCopy(candidates: candidates))
        pairing = Installer.pairing(target: target, thisMacSW: macSW, locate: locate)
        suggestionDismissed = payload.map {
            defaults.string(forKey: AppPreferences.solidWorksAppSuggestionDismissedKey) == $0.executableSHA256
        } ?? true
    }

    /// One line for Settings → Maintenance.
    public var summary: String {
        let version = payload.map { "\($0.version) (\($0.build))" } ?? ""
        switch status {
        case .notInstalled where payload == nil:
            return "This MacSW build does not include SOLIDWORKS.app."
        case .notInstalled:
            return "Not installed. Installs SOLIDWORKS.app \(version) in \(target.deletingLastPathComponent().path): start SOLIDWORKS from Launchpad, Spotlight and the Dock, and open SOLIDWORKS documents with it."
        case .current(let url):
            return "Installed: \(url.path), the same build as this MacSW (\(version))."
        case .stale(let url):
            return updatePending
                ? "Installed: \(url.path), from another MacSW build. It is updated when SOLIDWORKS.app quits."
                : "Installed: \(url.path), from another MacSW build. Update it to \(version)."
        case .unknown(let url):
            return "Installed: \(url.path). This MacSW build does not include SOLIDWORKS.app, so it cannot update it."
        case .foreign(let url):
            return "\(url.path) is another app. Move it away to install MacSW's SOLIDWORKS.app."
        }
    }

    /// Why `canInstall` or `canUninstall` is false although this MacSW carries SOLIDWORKS.app or
    /// one is installed.
    public var pairingProblem: String? {
        guard payload != nil || installedURL != nil else { return nil }
        switch pairing {
        case .thisMacSW: return nil
        case .other(let host):
            return "SOLIDWORKS.app in \(target.deletingLastPathComponent().path) would use the MacSW at \(host.path), not this one. Install it from that MacSW, or move this MacSW.app to /Applications."
        case .none:
            return "SOLIDWORKS.app in \(target.deletingLastPathComponent().path) would not find this MacSW. Move MacSW.app to /Applications first."
        }
    }

    // MARK: Actions

    /// Install, update or reinstall (Settings, the install suggestion). `allowRequirementChange`:
    /// the user confirmed that a copy signed with an identity may get another designated requirement.
    public func install(allowRequirementChange: Bool = false) async {
        refresh()
        guard !isWorking else { return }
        guard let payload else { statusMessage = Installer.InstallError.noPayload.localizedDescription; return }
        if case .foreign(let url) = status {
            statusMessage = Installer.InstallError.foreignApp(url).localizedDescription
            return
        }
        if let problem = pairingProblem { statusMessage = problem; return }
        let target = self.target
        let effects = self.effects
        isWorking = true
        let result = await Task.detached {
            Result { try Installer.install(payload, to: target, effects: effects, allowRequirementChange: allowRequirementChange) }
        }.value
        isWorking = false
        requirementChangeNeedsConsent = false
        switch result {
        case .success(let installed):
            updatePending = false
            postponements = 0
            let changed = updateDefaultHandlers(types: Installer.ownedContentTypes(of: installed.app),
                                                from: AppBundleLaunch.macSWBundleIdentifier, to: installed.app)
            var message = installed.replaced ? "SOLIDWORKS.app was updated in \(target.deletingLastPathComponent().path)."
                                             : "SOLIDWORKS.app was installed in \(target.deletingLastPathComponent().path)."
            if installed.requirementChanged {
                message += " Its code signature changed, so macOS may ask again for access to Desktop, Documents and Downloads."
                    + (installed.replaced ? " The previous copy is in the Trash." : "")
            }
            statusMessage = message
            log("install: \(target.path) (\(installed.replaced ? "replaced" : "new"), build \(payload.version) \(payload.build), "
                + "\(changed.count) document type(s) now open with it\(installed.requirementChanged ? ", signature requirement changed" : ""))")
        case .failure(Installer.InstallError.running(let url)):
            updatePending = true
            postponements += 1
            if postponements == 1 { retryShortly() }
            statusMessage = Installer.InstallError.running(url).localizedDescription
                + " MacSW updates it when SOLIDWORKS.app quits."
            log("install: postponed, \(url.path) is running")
        case .failure(Installer.InstallError.requirementWouldChange(let url)):
            // Not postponed: no retry and no update when SOLIDWORKS.app quits, only the user decides.
            updatePending = false
            postponements = 0
            requirementChangeNeedsConsent = true
            statusMessage = Installer.InstallError.requirementWouldChange(url).localizedDescription
                + " MacSW did not replace it. To replace it anyway, click Update SOLIDWORKS App in Settings → Maintenance."
            log("install: not replaced, \(url.path) would get another signature requirement")
        case .failure(let error):
            statusMessage = error.localizedDescription
            log("install failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Moves the installed copy to the Trash; MacSW opens SOLIDWORKS documents again.
    public func uninstall() async {
        refresh()
        guard let app = installedURL, !isWorking else { return }
        if let problem = pairingProblem { statusMessage = problem; return }
        // Decided before the copy goes away, while LaunchServices still reports it.
        let types = Installer.ownedContentTypes(of: app)
        let current = handlers.current
        let restore = Installer.handlerChanges(types: types, current: current,
                                               replacing: AppBundleLaunch.solidWorksBundleIdentifier)
        let effects = self.effects
        isWorking = true
        let result = await Task.detached { Result { try Installer.uninstall(app, effects: effects) } }.value
        isWorking = false
        switch result {
        case .success:
            for type in restore { handlers.set(macSW, type) }
            updatePending = false
            statusMessage = "SOLIDWORKS.app was moved to the Trash. MacSW opens SOLIDWORKS documents again."
            log("uninstall: \(app.path) moved to the Trash")
        case .failure(let error):
            statusMessage = error.localizedDescription
            log("uninstall failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// At MacSW start, on a Dock click and when SOLIDWORKS.app quits: a copy from another MacSW
    /// build is replaced with this one's, but only when it would use this MacSW.app.
    public func updateIfStale() async {
        refresh()
        guard case .stale = status else { updatePending = false; requirementChangeNeedsConsent = false; return }
        guard canInstall else { return }
        await install()
    }

    private func retryShortly() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.updatePending else { return }
            await self.updateIfStale()
        }
    }

    /// The SOLIDWORKS types follow the app being installed when MacSW (or no app) opens them now.
    @discardableResult
    private func updateDefaultHandlers(types: [String], from bundleIdentifier: String, to app: URL) -> [String] {
        let changes = Installer.handlerChanges(types: types, current: handlers.current, replacing: bundleIdentifier)
        for type in changes { handlers.set(app, type) }
        return changes
    }

    private func log(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] MacSW \(line)\n"
        guard let handle = try? WineService.shared.logHandle(for: logFile) else { return }
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }
}
