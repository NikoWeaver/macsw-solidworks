import Combine
import Foundation

/// VBA 7.1 in the bottle (`VBAPrerequisite`): the launch-time warning and the
/// Settings → Maintenance repair action "Install VBA (equations and macros)".
@MainActor
public final class VBAStore: ObservableObject {
    /// nil until checked, or while an install of SOLIDWORKS may have changed it.
    @Published public private(set) var isRegistered: Bool?
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusMessage = ""

    public let paths: AppPaths
    private let defaults: UserDefaults
    private let wine: WineService
    private let fileCheck: @Sendable (URL) -> Bool
    private let liveCheck: @Sendable (URL) async -> Bool
    private let installer: @Sendable ([URL], URL) async throws -> Void
    /// Result of a `reg query` in this MacSW session. It wins over the registry files,
    /// which wineserver writes up to 30 s after a change.
    private var liveResult: Bool?

    public init(
        paths: AppPaths,
        defaults: UserDefaults = .standard,
        wine: WineService = .shared,
        fileCheck: (@Sendable (URL) -> Bool)? = nil,
        liveCheck: (@Sendable (URL) async -> Bool)? = nil,
        installer: (@Sendable ([URL], URL) async throws -> Void)? = nil
    ) {
        self.paths = paths
        self.defaults = defaults
        self.wine = wine
        self.fileCheck = fileCheck ?? { VBAPrerequisite.isRegistered(prefix: $0) }
        self.liveCheck = liveCheck ?? { prefix in
            await RegistryService(wine: wine).missingCOMRegistrations(
                at: "HKCR\\CLSID\\\(VBAPrerequisite.apcCLSID)\\InprocServer32",
                requires: [VBAPrerequisite.apcLibrary],
                prefix: prefix
            ).isEmpty
        }
        self.installer = installer ?? { installers, prefix in
            try await PrerequisiteService(wine: wine).installVBA(installers: installers, prefix: prefix)
        }
    }

    /// The launch-time warning: SOLIDWORKS is installed, but VBA 7.1 is not.
    public var missingWarning: String? {
        paths.solidWorksInstalled && isRegistered == false ? VBAPrerequisite.missingWarning : nil
    }

    public var installerFolder: URL? { AppPreferences.vbaInstallerFolder(defaults: defaults) }

    public var warningSuppressed: Bool {
        get { defaults.bool(forKey: AppPreferences.vbaWarningSuppressedKey) }
        set { defaults.set(newValue, forKey: AppPreferences.vbaWarningSuppressedKey) }
    }

    /// Reads the registry files (no Wine process); used at app launch and when Settings opens.
    public func refresh() async {
        if let liveResult {
            isRegistered = liveResult
            return
        }
        guard paths.bottleExists else {
            isRegistered = nil
            return
        }
        let bottle = paths.bottle
        let check = fileCheck
        isRegistered = await Task.detached(priority: .utility) { check(bottle) }.value
    }

    /// After an install of SOLIDWORKS (which installs VBA when it finds the MSIs): asks the
    /// running wineserver, because the registry files may not have the new keys yet.
    public func installationCompleted() async {
        liveResult = nil
        isRegistered = nil
        guard paths.bottleExists else { return }
        await verify()
    }

    /// Installs both MSIs from `folder` into the bottle and remembers the folder for later installs.
    public func install(from folder: URL) async {
        guard !isWorking else { return }
        guard let installers = VBAPrerequisite.installers(inFolder: folder) else {
            statusMessage = "\(folder.lastPathComponent) must contain vba71.msi and vba71_1033.msi (PreReqs\\VBA of the SOLIDWORKS media)."
            return
        }
        guard paths.bottleExists else {
            statusMessage = "Install SOLIDWORKS first; MacSW has no bottle yet."
            return
        }
        guard !wine.isInstalling(prefix: paths.bottle) else {
            statusMessage = "An installation is running; install VBA after it finishes."
            return
        }
        isWorking = true
        defer { isWorking = false }
        AppPreferences.setVBAInstallerFolder(folder, defaults: defaults)
        statusMessage = "Installing Microsoft VBA 7.1… a Wine cold start takes a few seconds."
        do {
            try await installer(installers, paths.bottle)
            await verify()
            statusMessage = isRegistered == true
                ? "VBA 7.1 is installed. Restart SOLIDWORKS to use equations and macros."
                : "The VBA installers finished, but the APC COM class \(VBAPrerequisite.apcCLSID) is not registered; see vba71-install.log in the logs folder."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func verify() async {
        let registered = await liveCheck(paths.bottle)
        liveResult = registered
        isRegistered = registered
    }
}
