import Combine
import Foundation

public extension Notification.Name {
    static let macSWInstallationCompleted = Notification.Name("MacSWInstallationCompleted")
}

@MainActor
public final class BootstrapStore: ObservableObject {
    @Published public private(set) var selectedMedia: URL?
    @Published public private(set) var resolvedMedia: ResolvedMedia?
    @Published public var cleanInstall = false
    @Published public var silentInstall = true
    /// nil 保持 Wine 默认版本；SOLIDWORKS 2026 需要设为 .windows11。
    @Published public var windowsVersion: WindowsVersion?
    @Published public var serialSolidWorks = ""
    @Published public var serialSimulation = ""
    @Published public var serialMotion = ""
    @Published public var serialMBD = ""
    @Published public var selectedLanguage: SolidWorksLanguage?
    @Published public var licenseMode: BootstrapLicenseMode = .unconfigured
    @Published public var licenseServerAddress = ""
    @Published public private(set) var availableLanguages: [SolidWorksLanguage] = []
    @Published public private(set) var state: InstallationState = .idle
    @Published public private(set) var stepStatuses: [InstallationStep: InstallationStepStatus] = [:]
    @Published public private(set) var stepDetails: [InstallationStep: String] = [:]
    @Published public private(set) var statusMessage = "Choose the official install media to get started."
    /// Replaces the ADDLOCAL list of the silent core install; nil keeps the default feature set.
    public var addLocalOverride: [String]?
    /// Headless installs: crashes must exit instead of waiting on a WineDbg dialog nobody can click,
    /// and a WineDbg left behind after an installer counts as a failed install.
    public var hardenForHeadless = false
    /// Called for every step status change, in addition to the published state.
    public var progressHandler: ((InstallationStep, InstallationStepStatus, String) -> Void)?
    /// The team install (`TeamSetupStore.handOff`): VBA is installed only from the MSIs MacSW
    /// knows (`VBAPrerequisite.knownSHA256`), because every editor of the team folder can change
    /// its files. False: the install without a team config, which installs any VBA it finds.
    public var requiresKnownVBA = false
    /// The team config's `vba.path`, searched after the media's own VBA folders.
    public var teamVBAFolder: URL?

    public let paths: AppPaths
    private let wine: WineService
    private let prerequisites: PrerequisiteService
    private let registry: RegistryService
    private let iso: IsoService
    private let licensing: LicenseServerStore
    private let runtime: RuntimeStore?
    private let spatialIOP: SpatialIOPService
    private var installationTask: Task<Void, Never>?
    var installationGeneration: UUID?

    public init(
        paths: AppPaths,
        wine: WineService = .shared,
        prerequisites: PrerequisiteService = .shared,
        registry: RegistryService? = nil,
        iso: IsoService = .shared,
        licensing: LicenseServerStore? = nil,
        runtime: RuntimeStore? = nil,
        spatialIOP: SpatialIOPService? = nil
    ) {
        self.paths = paths
        self.wine = wine
        self.prerequisites = prerequisites
        self.registry = registry ?? RegistryService(wine: wine)
        self.iso = iso
        self.licensing = licensing ?? LicenseServerStore(paths: paths)
        self.runtime = runtime
        self.spatialIOP = spatialIOP ?? SpatialIOPService(wine: wine)
    }

    public var serials: InstallSerials {
        get {
            InstallSerials(values: [
                .solidWorks: serialSolidWorks,
                .simulation: serialSimulation,
                .motion: serialMotion,
                .mbd: serialMBD
            ])
        }
        set {
            serialSolidWorks = newValue[.solidWorks]
            serialSimulation = newValue[.simulation]
            serialMotion = newValue[.motion]
            serialMBD = newValue[.mbd]
        }
    }

    /// The team setup forgets the access key when its install has finished.
    public func forgetSerials() {
        serials = InstallSerials()
    }

    public var canStart: Bool {
        resolvedMedia != nil
            && !state.isActive
            && serialsReady
            && licenseRequest != nil
    }

    public var startHint: String? {
        let invalid = serials.invalidFields()
        if silentInstall, !invalid.isEmpty { return "\(invalid.map(\.title).joined(separator: ", ")) must be six groups of four characters." }
        if silentInstall, !serials.isComplete { return "Silent install requires at least the SOLIDWORKS serial number." }
        return licenseMissingInput
    }

    /// 交互安装的序列号由官方向导询问，这里不参与校验。
    private var serialsReady: Bool {
        !silentInstall || (serials.isComplete && serials.invalidFields().isEmpty)
    }

    private var licenseMissingInput: String? {
        licenseMode.missingInputMessage(address: licenseServerAddress)
    }

    /// 单选解析出的唯一许可动作；nil 表示当前模式的输入还不可用。
    private var licenseRequest: LicenseRequest? {
        guard licenseMissingInput == nil else { return nil }
        switch licenseMode {
        case .unconfigured: return .skip
        case .remoteServer:
            return .address(licenseServerAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private enum LicenseRequest {
        case skip
        case address(String)
    }

    public var showsCleanInstall: Bool { paths.bottleExists }

    /// The retry rule (`CoreInstallRetry`): this start moves the bottle of a failed core install to the
    /// Trash and installs into a fresh one. A clean install deletes the bottle anyway.
    public var replacesFailedBottle: Bool {
        !cleanInstall && CoreInstallRetry.decision(prefix: paths.bottle, receiptExists: receiptExists) == .freshBottle
    }

    /// Pure path check only: does not mount the ISO, start any process, or read
    /// files next to the media (serials are only ever typed in by the user).
    public func selectMedia(_ url: URL) {
        guard url.isFileURL else {
            statusMessage = "Only an ISO file, setup.exe or a folder on this Mac can be chosen."
            return
        }
        guard let resolved = InstallationMediaResolver.resolve(url) else {
            resolvedMedia = nil
            selectedMedia = nil
            availableLanguages = []
            selectedLanguage = nil
            statusMessage = "Install media not found: it must contain setup.exe or an .iso (directly or in a first-level subfolder of the chosen folder)."
            return
        }
        resolvedMedia = resolved
        selectedMedia = resolved.displayURL
        availableLanguages = LanguageCatalog.official
        if selectedLanguage == nil {
            selectedLanguage = LanguageCatalog.autoSelection(from: LanguageCatalog.official)
        }
        statusMessage = resolved.isIso
            ? "ISO media recognized: \(resolved.displayURL.lastPathComponent)"
            : "Media folder recognized: \(resolved.displayURL.lastPathComponent)"
    }

    public func start() {
        guard canStart,
              installationTask == nil,
              let selectedMedia,
              let resolvedMedia,
              let license = licenseRequest else { return }
        let request = InstallRequest(
            serials: serials,
            language: selectedLanguage,
            silent: silentInstall,
            windowsVersion: windowsVersion,
            license: license,
            addLocal: addLocalOverride,
            hardened: hardenForHeadless,
            // Read now: Settings may have saved a folder since this store was created.
            vbaFolder: AppPreferences.vbaInstallerFolder(),
            teamVBAFolder: teamVBAFolder,
            knownVBA: requiresKnownVBA ? VBAPrerequisite.knownSHA256 : nil
        )
        let generation = UUID()
        installationGeneration = generation
        state = .preparing
        installationTask = Task {
            await runInstallation(
                selectedMedia: selectedMedia,
                resolved: resolvedMedia,
                request: request,
                generation: generation
            )
        }
    }

    /// Starts the install and waits until the pipeline (including its cleanup) has finished.
    /// Returns nil when the current inputs cannot start an install; see `startHint`.
    public func runUntilFinished() async -> InstallationState? {
        guard canStart, installationTask == nil else { return nil }
        start()
        await installationTask?.value
        return state
    }

    public func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        statusMessage = "Stopping this install…"
        installationTask?.cancel()
    }

    public func resetAfterFailure() {
        guard !state.isActive else { return }
        state = .idle
        stepStatuses = [:]
        stepDetails = [:]
        statusMessage = "You can adjust the options and start again."
    }

    /// install-status.txt of Export Diagnostics on the failure page (`DiagnosticsExport`).
    public var installStatusReport: String {
        DiagnosticsExport.installStatusReport(state: state, message: statusMessage, statuses: stepStatuses, details: stepDetails)
    }

    /// 界面入口：清理失败必须当场说出来，按钮点下去没反应比报错更糟。
    public func requestCleanupOfIncompleteInstallation() {
        Task {
            do { try await cleanIncompleteInstallation() }
            catch { statusMessage = "Cleanup failed: \(error.localizedDescription)" }
        }
    }

    public func cleanIncompleteInstallation() async throws {
        guard paths.bottle.standardizedFileURL == paths.appSupportDirectory.appendingPathComponent("bottle").standardizedFileURL else {
            throw bootstrapError("Unexpected bottle path; refusing to clean up.")
        }
        guard !state.isActive else { throw bootstrapError("The install is still running.") }
        await runtime?.suspendFontPreparationForBottleDeletion()
        defer { runtime?.resumeFontPreparationAfterBottleDeletion() }
        try await stopContainerBeforeDeletion()
        if FileManager.default.fileExists(atPath: paths.bottle.path) {
            try FileManager.default.removeItem(at: paths.bottle)
        }
        try? FileManager.default.removeItem(at: installationReceipt)
        AppPaths.invalidateInstallationState()
        statusMessage = "Incomplete install cleaned up."
    }

    /// wineserver 退出不代表所有宿主侧 Wine 客户进程都消失：脱离旧 server 的
    /// Wine 进程仍可能持有待删除容器的路径。删除前以进程表做最后一道检查。
    private func stopContainerBeforeDeletion() async throws {
        guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
            throw bootstrapError("Could not stop the Wine bottle; deletion cancelled.")
        }
        var remaining: [WineProcess] = []
        for attempt in 0..<5 {
            try Task.checkCancellation()
            remaining = await ProcessInventory.snapshot(
                bottlePath: paths.bottle.path,
                wineRuntimePath: wine.runtimeURL.path
            )
            if remaining.isEmpty { return }
            if attempt < 4 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        let examples = remaining.prefix(5).map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
        let suffix = remaining.count > 5 ? " and \(remaining.count - 5) more" : ""
        throw bootstrapError("The bottle still has processes: \(examples)\(suffix). Deletion cancelled; confirm and terminate these processes first.")
    }

    private func runInstallation(
        selectedMedia: URL,
        resolved: ResolvedMedia,
        request: InstallRequest,
        generation: UUID
    ) async {
        let runtimeState = WineRuntimeService.status(prefix: paths.bottle)
        guard runtime?.isMigratingWine != true,
              runtimeState != .recovery, runtimeState != .invalid,
              runtimeState != .upgrade || cleanInstall else {
            statusMessage = "Finish the Wine upgrade or recovery in Settings → Maintenance before installing."
            installationTask = nil
            installationGeneration = nil
            return
        }
        wine.setInstalling(true, prefix: paths.bottle)
        defer { wine.setInstalling(false, prefix: paths.bottle) }
        stepStatuses = [:]
        stepDetails = [:]
        report(.media, .running, "Verifying the official install media…")
        statusMessage = "Verifying the install media…"
        var mountedByApp: MountedMedia?
        var desktopRedirections: [PrerequisiteService.DesktopRedirection] = []
        var suspendedFontPreparation = false
        defer {
            if suspendedFontPreparation { runtime?.resumeFontPreparationAfterBottleDeletion() }
            if !desktopRedirections.isEmpty {
                try? prerequisites.restoreDesktopFolders(prefix: paths.bottle, to: desktopRedirections)
            }
            if let mountedByApp {
                let code = iso.unmount(mountedByApp)
                if code != 0 {
                    statusMessage += " The install image could not be ejected automatically (\(code)); eject \"\(mountedByApp.mountPoint.lastPathComponent)\" in Finder."
                }
            }
            if installationGeneration == generation {
                installationTask = nil
                installationGeneration = nil
            }
        }

        do {
            let media: URL
            switch resolved {
            case .iso(let url):
                let mounted = try await iso.mount(url)
                mountedByApp = mounted
                media = mounted.mountPoint
            case .directory(let url, _):
                media = url
            }
            try Task.checkCancellation()

            let missing = InstallationMedia.missingComponents(in: media, language: request.language)
            guard missing.isEmpty else {
                throw bootstrapError("The media is missing required components: \(missing.map(\.label).joined(separator: ", ")).")
            }
            let hasToolbox = InstallationMedia.hasToolboxPayload(in: media)
            report(.media, .completed, hasToolbox
                ? "Official MSI, prerequisites and Toolbox are all present"
                : "Official MSI and prerequisites are present (the media has no Toolbox; it will be skipped)")

            let replaceFailedBottle = replacesFailedBottle
            if cleanInstall || replaceFailedBottle, paths.bottleExists {
                try validateInputsOutsideBottle([selectedMedia, media])
                suspendedFontPreparation = true
                await runtime?.suspendFontPreparationForBottleDeletion()
                try await stopContainerBeforeDeletion()
                try Task.checkCancellation()
                if replaceFailedBottle { try trashFailedBottle() }
                else { try FileManager.default.removeItem(at: paths.bottle) }
                try? FileManager.default.removeItem(at: installationReceipt)
                AppPaths.invalidateInstallationState()
            }
            try Task.checkCancellation()
            let newBottle = !paths.bottleExists

            state = .installing(.environment)
            report(.environment, .running, "Preparing the Wine bottle and managed COM runtime…")
            let wineboot = wine.makeProcess(arguments: ["wineboot", "-u"], prefix: paths.bottle)
            let bootCode = try await wine.runCancellable(
                wineboot,
                log: paths.logs.appendingPathComponent("wineboot.log")
            )
            guard bootCode == 0 else { throw bootstrapError("Wine initialization failed (\(bootCode)).") }
            if newBottle { try? CoreInstallRetry.markNewBottle(prefix: paths.bottle) }
            try prerequisites.prepareShortNameAliases(prefix: paths.bottle)
            desktopRedirections = try prerequisites.redirectDesktopFolders(prefix: paths.bottle)
            // H:, B:, I: and the other cloud drive letters (DriveMapService) for the new bottle;
            // a cloud folder is mapped only after the native app could open it (its macOS prompt).
            _ = await DriveMapService.maintain(paths: paths, onWaiting: { [weak self] message in
                Task { @MainActor in self?.statusMessage = message }
            })
            // Documents and Downloads stay linked to the real folders; the native app takes the
            // macOS consent prompt now instead of freezing wineserver mid-install, and links to
            // cloud folders macOS refused are set aside while the installers run (WineBottleGate).
            _ = await WineBottleGate.prepare(
                prefix: paths.bottle,
                onWaiting: { [weak self] folder in
                    Task { @MainActor in self?.statusMessage = FolderConsentService.waitingMessage(for: folder) }
                },
                log: paths.logs.appendingPathComponent("folder-consent.log"))
            if request.hardened {
                try await registry.write([Self.disableCrashDialog], prefix: paths.bottle)
            }
            try await prerequisites.configureMono(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMRegistration(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMDependencies(prefix: paths.bottle)
            try prerequisites.prepareSWCLI(prefix: paths.bottle)
            let installationFontStatus = try await registry.configureInstallationEnvironment(prefix: paths.bottle)
            let environmentSummary = "Mono, RegAsm, stdole, SWCLI and SOLIDWORKS compatibility settings are ready"
                + (replaceFailedBottle ? "; the bottle of the failed install is in the Trash" : "")
            switch installationFontStatus {
            case .enabled:
                report(.environment, .completed, environmentSummary)
            case .notDetected:
                report(
                    .environment,
                    .completed,
                    "\(environmentSummary); no usable system PingFang font found, so Chinese text may not display completely"
                )
            case .existingLinksUnreadable:
                report(
                    .environment,
                    .completed,
                    "\(environmentSummary); the existing Tahoma font link could not be read safely, so font settings were left unchanged"
                )
            }

            state = .installing(.vcRuntime)
            report(.vcRuntime, .running, "Silently installing the official VC++ x64 runtime…")
            try await prerequisites.installVC(media: media, prefix: paths.bottle)
            report(.vcRuntime, .completed, "VC++ runtime verified")

            state = .installing(.loginManager)
            report(.loginManager, .running, "Silently installing SOLIDWORKS Login Manager…")
            try await prerequisites.installLoginManager(media: media, prefix: paths.bottle)
            let missingLoginManager = await registry.missingCOMRegistrations(
                at: "HKCR\\CLSID\\\(InstallerDiagnostics.loginManagerCLSID)\\InprocServer32",
                requires: InstallerDiagnostics.loginManagerRequirements,
                prefix: paths.bottle
            )
            guard missingLoginManager.isEmpty else {
                throw bootstrapError("Login Manager managed COM registration is missing \(missingLoginManager.joined(separator: ", ")).")
            }
            report(.loginManager, .completed, "Managed COM registration verified")

            state = .installing(.vba)
            try await installVBAIfAvailable(media: media, request: request)

            state = .installing(.installer)
            if let version = request.windowsVersion {
                report(.installer, .running, "Setting the bottle's Windows version to \(version.rawValue)…")
                let winecfg = wine.makeProcess(
                    arguments: SilentInstallerPlan.windowsVersionArguments(version),
                    prefix: paths.bottle
                )
                let versionCode = try await wine.runCancellable(
                    winecfg,
                    log: paths.logs.appendingPathComponent("winecfg.log")
                )
                guard versionCode == 0 else { throw bootstrapError("Setting the Windows version failed (\(versionCode)).") }
                try Task.checkCancellation()
            }
            report(.installer, .running, "Preparing MacSW's copy of the SOLIDWORKS installer for Wine (SpatialIOP)…")
            let corePackage = try await spatialIOP.prepareCorePackage(media: media, prefix: paths.bottle)
            try Task.checkCancellation()
            let msiLog = paths.logs.appendingPathComponent("install_msi.log")
            let installerWineLog = paths.logs.appendingPathComponent("installer-wine.log")
            // msiexec writes the verbose log itself: created 0600 first, it keeps that mode (LogFiles).
            try LogFiles.prepare(msiLog)
            let installerArguments: [String]
            if request.silent {
                report(.installer, .running, "Silently deploying the SOLIDWORKS core. Do not close this window…")
                installerArguments = SilentInstallerPlan.coreInstallArguments(
                    msi: corePackage.msi, log: msiLog, serials: request.serials, addLocal: request.addLocal
                )
            } else {
                // 组件选择与序列号都由官方向导接管，这里不预写任何注册表。
                report(.installer, .running, "The official installer window is open; complete your choices there…")
                installerArguments = SilentInstallerPlan.interactiveInstallArguments(
                    msi: corePackage.msi, log: msiLog
                )
            }
            let installerCode: Int32
            try? CoreInstallRetry.markCoreInstallStarted(prefix: paths.bottle)
            do {
                installerCode = try await wine.runMSIExec(
                    arguments: installerArguments,
                    prefix: paths.bottle,
                    log: installerWineLog
                )
            } catch {
                await Self.redactInstallLogs([msiLog, installerWineLog], serials: request.serials)
                throw error
            }
            // The verbose MSI log holds the serial numbers: remove them after every install.
            await Self.redactInstallLogs([msiLog, installerWineLog], serials: request.serials)
            if WineService.isCancelledInstallerStatus(installerCode) { throw CancellationError() }
            if request.hardened { try await failIfWineDebuggerRemains() }
            guard WineService.isSuccessfulInstallerStatus(installerCode) else {
                // 失败日志可能有几十 MB，读取与正则在后台做，别把界面钉在主线程上。
                let detail = await Task.detached(priority: .utility) { InstallerDiagnostics.failureDetail(log: msiLog) }.value
                let retry = replacesFailedBottle ? " " + CoreInstallRetry.retryNote : ""
                throw bootstrapError("SOLIDWORKS installation failed (process exit code \(installerCode)).\(detail)\(retry)")
            }
            CoreInstallRetry.markCoreInstallSucceeded(prefix: paths.bottle)
            if await wine.waitWineserver(prefix: paths.bottle, seconds: 30) {
                report(.installer, .completed, request.silent
                    ? "Official MSI finished silently (exit code \(installerCode))"
                    : "Official installer wizard finished (exit code \(installerCode))")
            } else {
                guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
                    throw bootstrapError("Leftover installer processes could not be stopped; the bottle is still locked.")
                }
                report(.installer, .completed, "Official MSI finished; leftover Wine helper processes were cleaned up")
            }
            try Task.checkCancellation()

            AppPaths.invalidateInstallationState()
            guard paths.solidWorksInstalled else {
                throw bootstrapError("The installer exited, but the SOLIDWORKS main program was not found.")
            }

            state = .installing(.spatialInterop)
            if corePackage.needsPayload {
                report(.spatialInterop, .running, "Extracting the media's spatialiop.zip into spiop\\files…")
                let files = try await spatialIOP.installPayload(media: media, prefix: paths.bottle)
                report(.spatialInterop, .completed, "\(files) files, checked against the zip's own listing")
            } else {
                report(.spatialInterop, .skipped, "This media's installer has no SpatialIOP actions; nothing to add")
            }

            state = .installing(.language)
            if let language = request.language {
                report(.language, .running, "Installing \(language.displayName) language resources…")
                try await prerequisites.installLanguage(media: media, language: language, prefix: paths.bottle)
                report(.language, .completed, "\(language.displayName) language resources installed")
            } else {
                report(.language, .skipped, "No language resources selected; using the media's default English interface")
            }

            state = .installing(.wpfThemes)
            report(.wpfThemes, .running, "Extracting the five theme libraries from the Microsoft installer…")
            try await prerequisites.installThemes(
                media: media,
                prefix: paths.bottle,
                target: paths.solidWorksExecutable.deletingLastPathComponent()
            )
            report(.wpfThemes, .completed, "The five WPF theme libraries were added")

            state = .installing(.toolbox)
            if hasToolbox {
                report(.toolbox, .running, "Deploying Toolbox standard parts with the official tool and checking the index…")
                let toolboxParts = try await ToolboxService(wine: wine).install(media: media, paths: paths)
                report(.toolbox, .completed, "Official index and selected standard parts verified (\(toolboxParts) part models)")
            } else {
                // .warning 才会进入安装完成页的“安装提示”；.skipped 只显示在进度列表里。
                report(.toolbox, .warning, InstallationMedia.toolboxSkippedNote)
            }

            state = .installing(.licensing)
            switch request.license {
            case .skip:
                report(.licensing, .skipped, "Skipped per the license option")
            case .address(let address):
                report(.licensing, .running, "Writing the license server address…")
                try await licensing.configureDuringInstallation(address: address)
                report(.licensing, .completed, "License server address written to the bottle")
            }

            state = .installing(.validation)
            report(.validation, .running, "Verifying the main program, COM registration and theme libraries…")
            try await validateInstalledRuntime()
            if request.hardened { try await failIfWineDebuggerRemains() }
            _ = try await WineRuntimeService.perform("baseline", prefix: paths.bottle)
            try writeInstallationReceipt()
            report(.validation, .completed, "Main program, SldWorks.Application COM registration and theme libraries verified")
            state = .completed
            statusMessage = "Installation succeeded. Click Done to close the installer window."
            if suspendedFontPreparation {
                runtime?.resumeFontPreparationAfterBottleDeletion()
                suspendedFontPreparation = false
            }
            NotificationCenter.default.post(name: .macSWInstallationCompleted, object: nil)
        } catch is CancellationError {
            statusMessage = "Terminating install processes in the bottle…"
            let settled = await terminateCancelledInstallation()
            // A cancelled msiexec can go on writing its log until the bottle is empty.
            await Self.redactInstallLogs([paths.logs.appendingPathComponent("install_msi.log"),
                                          paths.logs.appendingPathComponent("installer-wine.log")],
                                         serials: request.serials)
            if let running = stepStatuses.first(where: { $0.value == .running })?.key {
                report(running, .cancelled, "The install was stopped by the user")
            }
            state = .cancelled
            statusMessage = settled
                ? "The install was interrupted; no completion marker was written. You can start again or clean up the incomplete install."
                : "The install was interrupted, but processes are still running in the bottle. Force-quit them on the Maintenance page in Settings, then retry."
        } catch {
            if let running = stepStatuses.first(where: { $0.value == .running })?.key {
                report(running, .failed, error.localizedDescription)
            }
            state = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    /// 取消只能 SIGTERM 到宿主侧的 wine 启动器：容器里的 msiexec 会改挂到 launchd 下继续写盘，
    /// 所以"已取消"必须等容器真的空了才算数。收尾要跑在未被取消的任务里，
    /// 否则 WineService 的取消安全包装会立刻抛错，什么也杀不掉。
    private func terminateCancelledInstallation() async -> Bool {
        let wine = self.wine
        let bottle = paths.bottle
        return await Task.detached(priority: .userInitiated) {
            if await wine.waitWineserver(prefix: bottle, seconds: 10) { return true }
            _ = try? await wine.stopWineServerForCleanup(prefix: bottle)
            return await wine.waitWineserver(prefix: bottle, seconds: 25)
        }.value
    }

    /// Large logs: read and rewritten off the main thread.
    nonisolated private static func redactInstallLogs(_ logs: [URL], serials: InstallSerials) async {
        await Task.detached(priority: .utility) {
            for log in logs { InstallLogRedaction.redact(log: log, serials: serials) }
        }.value
    }

    private struct InstallRequest {
        let serials: InstallSerials
        let language: SolidWorksLanguage?
        let silent: Bool
        let windowsVersion: WindowsVersion?
        let license: LicenseRequest
        let addLocal: [String]?
        let hardened: Bool
        let vbaFolder: URL?
        let teamVBAFolder: URL?
        let knownVBA: [String: String]?
    }

    /// Optional, like Toolbox: SOLIDWORKS installs and runs without VBA, only equations and macros
    /// fail. So a missing or failed VBA install is a warning on the completion page, not a failed
    /// install; a cancellation still stops the install. In the team install, MSIs that MacSW does
    /// not know are refused before msiexec, with the same warning.
    private func installVBAIfAvailable(media: URL, request: InstallRequest) async throws {
        let bottle = paths.bottle
        report(.vba, .running, "Checking for Microsoft VBA 7.1…")
        if await Task.detached(priority: .utility, operation: { VBAPrerequisite.isRegistered(prefix: bottle) }).value {
            report(.vba, .completed, "Already installed (the APC COM class is registered)")
            return
        }
        guard let installers = VBAPrerequisite.installers(media: media, teamFolder: request.teamVBAFolder,
                                                          userFolder: request.vbaFolder) else {
            report(.vba, .warning, VBAPrerequisite.skippedNote)
            return
        }
        report(.vba, .running, "Silently installing Microsoft VBA 7.1 from \(installers[0].deletingLastPathComponent().path)…")
        do {
            try await prerequisites.installVBA(installers: installers, prefix: bottle, knownSHA256: request.knownVBA)
            let missing = await registry.missingCOMRegistrations(
                at: "HKCR\\CLSID\\\(VBAPrerequisite.apcCLSID)\\InprocServer32",
                requires: [VBAPrerequisite.apcLibrary],
                prefix: bottle
            )
            guard missing.isEmpty else {
                throw bootstrapError("the installers exited, but the APC COM class \(VBAPrerequisite.apcCLSID) is not registered.")
            }
            report(.vba, .completed, "VBA 7.1 installed; the APC COM class is registered")
        } catch {
            // A cancelled install stops here (the reg query swallows its own cancellation).
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            report(.vba, .warning, "Not installed: \(error.localizedDescription) SOLIDWORKS equations and macros will not work. \(VBAPrerequisite.repairHint)")
        }
    }

    nonisolated static let disableCrashDialog = RegistryAssignment(
        key: #"HKCU\Software\Wine\WineDbg"#, name: "ShowCrashDialog", dwordValue: 0
    )

    /// With ShowCrashDialog=0 WineDbg prints a backtrace and exits; one that is still there
    /// after a few seconds means a crashed process is stuck, so the result cannot be trusted.
    private func failIfWineDebuggerRemains() async throws {
        for attempt in 0..<5 {
            let processes = await ProcessInventory.snapshot(
                bottlePath: paths.bottle.path,
                wineRuntimePath: wine.runtimeURL.path
            )
            let debuggers = processes.filter { $0.name.lowercased().hasPrefix("winedbg") }
            if debuggers.isEmpty { return }
            if attempt == 4 {
                let pids = debuggers.map { String($0.pid) }.joined(separator: ", ")
                throw bootstrapError("A Wine debugger is still running in the bottle (PID \(pids)); a process crashed during the install.")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func report(_ step: InstallationStep, _ status: InstallationStepStatus, _ detail: String) {
        stepStatuses[step] = status
        stepDetails[step] = detail
        progressHandler?(step, status, detail)
    }

    private func validateInstalledRuntime() async throws {
        guard paths.solidWorksInstalled else { throw bootstrapError("SOLIDWORKS main program not found.") }
        let target = paths.solidWorksExecutable.deletingLastPathComponent()
        for theme in PrerequisiteService.themes {
            guard FileManager.default.fileExists(atPath: target.appendingPathComponent("PresentationFramework.\(theme).dll").path) else {
                throw bootstrapError("Missing WPF theme library PresentationFramework.\(theme).dll.")
            }
        }
        guard let clsid = await registry.solidWorksApplicationCLSID(prefix: paths.bottle) else {
            throw bootstrapError("The official MSI did not register the SldWorks.Application ProgID.")
        }
        let missing = await registry.missingCOMRegistrations(
            at: "HKCR\\CLSID\\\(clsid)",
            requires: InstallerDiagnostics.solidWorksRequirements,
            prefix: paths.bottle
        )
        guard missing.isEmpty else {
            throw bootstrapError("SOLIDWORKS COM registration is missing \(missing.joined(separator: ", ")).")
        }
    }

    private var installationReceipt: URL {
        paths.appSupportDirectory.appendingPathComponent("installation-complete.json")
    }

    private var receiptExists: Bool { FileManager.default.fileExists(atPath: installationReceipt.path) }

    /// The retry rule moves the bottle to the Trash instead of deleting it: nothing in it is lost.
    private func trashFailedBottle() throws {
        guard paths.bottle.standardizedFileURL == paths.appSupportDirectory.appendingPathComponent("bottle").standardizedFileURL else {
            throw bootstrapError("Unexpected bottle path; refusing to move it to the Trash.")
        }
        do {
            try FileManager.default.trashItem(at: paths.bottle, resultingItemURL: nil)
        } catch {
            throw bootstrapError("Could not move the bottle of the failed install to the Trash: \(error.localizedDescription) Turn on Clean install to delete it instead.")
        }
    }

    private func writeInstallationReceipt() throws {
        let object: [String: String] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "solidWorksExecutable": paths.solidWorksExecutable.path,
            "wineVersion": BuildInfo.wineVersion
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: installationReceipt, options: .atomic)
    }

    private func validateInputsOutsideBottle(_ inputs: [URL]) throws {
        let bottle = paths.bottle.resolvingSymlinksInPath().path
        for input in inputs {
            let path = input.resolvingSymlinksInPath().path
            guard path != bottle, !path.hasPrefix(bottle + "/") else {
                throw bootstrapError("The install input is inside the bottle to be deleted; move it outside the bottle first.")
            }
        }
    }

    private func bootstrapError(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.Bootstrap")
    }
}
