import Combine
import Foundation

@MainActor
public final class RuntimeStore: ObservableObject {
    @Published public private(set) var state: SolidWorksRuntimeState
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var processes: [WineProcess] = []

    /// 正在拉起但还没出现在容器进程里的 Wine 工具名；UI 用它把按钮变灰并转菊花。
    @Published public private(set) var pendingWineTool: String?
    @Published public private(set) var wineRuntimeState: WineRuntimeService.State = .unmanaged
    @Published public private(set) var isMigratingWine = false
    @Published public private(set) var canRollbackWine = false
    private var wineMigrationTask: Task<Void, Never>?
    /// `WineBottleGate.prepare` for a bottle: lists the protected folders its drive letters and
    /// profile links reach (their macOS prompts) and sets aside the links to folders macOS refused.
    /// Runs before each Wine task this store starts; the closure gets a status line while a macOS
    /// prompt is probably on screen.
    private let bottleGate: @Sendable (URL, @escaping @Sendable (String) -> Void) async -> WineBottleGate.Report
    /// Drive letters and profile links for the home and cloud folders (`DriveMapService`); the
    /// closure gets a status line while a macOS prompt is probably on screen.
    private let driveMaps: @Sendable (AppPaths, @escaping @Sendable (String) -> Void) async -> Void

    public func refreshWineRuntime() {
        wineRuntimeState = WineRuntimeService.status(prefix: paths.bottle)
        canRollbackWine = WineRuntimeService.canRollback(prefix: paths.bottle)
    }

    /// Called only after a UI confirmation that explicitly permits stopping SW.
    public func maintainWineRuntime(_ command: String) {
        guard !isMigratingWine, !licenseServer.isOperating, !swcliDaemon.isOperating,
              state != .starting, state != .stopping, !wine.isInstalling(prefix: paths.bottle),
              pendingWineTool == nil, ["baseline", "upgrade", "recover", "rollback"].contains(command) else { return }
        isMigratingWine = true
        licenseServer.runtimeMaintenanceSuspended = true
        fontPreparationSuspended = true
        statusMessage = "Archiving the old App, backing up or restoring the bottle. Do not quit MacSW…"
        wineMigrationTask = Task {
            defer {
                isMigratingWine = false
                licenseServer.runtimeMaintenanceSuspended = false
                fontPreparationSuspended = false
                wineMigrationTask = nil
                refreshWineRuntime()
            }
            if let task = fontPreparation { _ = try? await task.value }
            if let task = swcliTask { _ = try? await task.value }
            fontPreparation = nil
            fontPreparationID = nil
            swcliTask = nil
            swcliTaskID = nil
            // wine_runtime.py checks the links itself before it boots Wine; as MacSW's child it
            // finds the folders MacSW may open granted at once.
            _ = await prepareBottleForWine()
            do {
                let message = try await WineRuntimeService.perform(command, prefix: paths.bottle)
                await maintainDriveMaps()
                statusMessage = message
            } catch { statusMessage = error.localizedDescription }
            AppPaths.invalidateInstallationState()
            await refreshState()
        }
    }

    /// Waits for a running `maintainWineRuntime` to finish; returns at once when none runs.
    public func waitForWineMaintenance() async {
        await wineMigrationTask?.value
    }

    public let paths: AppPaths
    private let wine: WineService
    private let licenseServer: LicenseServerStore
    private let fontLinkRepair: @Sendable (URL) async throws -> Void
    private let swcliPreparation: @Sendable (URL) async throws -> Void
    private let processSnapshot: @Sendable (String, String) async -> [WineProcess]
    private let windowSnapshot: @Sendable ([Int32]) -> [HostWindow]
    private let documentOpener: @Sendable (URL, [URL]) throws -> Void
    /// Starts SLDWORKS.exe once the preflight passed. MacSW runs it as a child process;
    /// SOLIDWORKS.app replaces its own process with it (`WineService.execSolidWorks`).
    public typealias SolidWorksStarter = @MainActor (
        _ executable: URL, _ prefix: URL, _ arguments: [String],
        _ onStarted: @escaping @MainActor @Sendable () -> Void,
        _ completion: @escaping @MainActor @Sendable (Bool, String) -> Void
    ) -> Void
    private let solidWorksStarter: SolidWorksStarter
    /// The bottle's start lock (`StartLock`, F4) around the last check and the start.
    public typealias StartLocker = @Sendable (_ prefix: URL) async -> StartLock.Outcome
    private let startLocker: StartLocker
    private let handOffPollInterval: TimeInterval
    private var handOffTask: Task<Void, Never>?
    private var swcliTask: Task<Void, Error>?
    private var swcliTaskID: UUID?
    private var fontPreparation: Task<Void, Error>?
    private var fontPreparationID: UUID?
    private var fontPreparationSuspended = false
    private var didRunStartup = false
    public let swcliDaemon: SWCLIDaemonStore

    public init(
        paths: AppPaths,
        licenseServer: LicenseServerStore,
        wine: WineService = .shared,
        fontLinkRepair: (@Sendable (URL) async throws -> Void)? = nil,
        swcliPreparation: (@Sendable (URL) async throws -> Void)? = nil,
        swcliDaemon: SWCLIDaemonStore? = nil,
        processSnapshot: (@Sendable (String, String) async -> [WineProcess])? = nil,
        windowSnapshot: (@Sendable ([Int32]) -> [HostWindow])? = nil,
        documentOpener: (@Sendable (URL, [URL]) throws -> Void)? = nil,
        handOffPollInterval: TimeInterval = DocumentHandOff.pollInterval,
        bottleGate: (@Sendable (URL, @escaping @Sendable (String) -> Void) async -> WineBottleGate.Report)? = nil,
        driveMaps: (@Sendable (AppPaths, @escaping @Sendable (String) -> Void) async -> Void)? = nil,
        startLocker: StartLocker? = nil,
        solidWorksStarter: SolidWorksStarter? = nil
    ) {
        self.paths = paths
        self.startLocker = startLocker ?? { prefix in
            await Task.detached(priority: .userInitiated) { StartLock.acquire(prefix: prefix) }.value
        }
        self.solidWorksStarter = solidWorksStarter ?? { executable, prefix, arguments, onStarted, completion in
            wine.launchSolidWorks(executable: executable, prefix: prefix, arguments: arguments,
                                  onStarted: onStarted, completion: completion)
        }
        self.licenseServer = licenseServer
        self.wine = wine
        self.processSnapshot = processSnapshot ?? { bottle, runtime in
            await ProcessInventory.snapshot(bottlePath: bottle, wineRuntimePath: runtime)
        }
        self.windowSnapshot = windowSnapshot ?? { HostWindowInspector.windows(ownedBy: $0) }
        self.documentOpener = documentOpener ?? { prefix, files in
            try wine.openDocumentsInRunningInstance(prefix: prefix, files: files)
        }
        self.handOffPollInterval = handOffPollInterval
        let consentLog = paths.logs.appendingPathComponent("folder-consent.log")
        self.bottleGate = bottleGate ?? { prefix, onWaiting in
            await WineBottleGate.prepare(prefix: prefix,
                                         onWaiting: { onWaiting(FolderConsentService.waitingMessage(for: $0)) },
                                         log: consentLog)
        }
        self.driveMaps = driveMaps ?? { paths, onWaiting in
            _ = await DriveMapService.maintain(paths: paths, onWaiting: onWaiting)
        }
        self.swcliDaemon = swcliDaemon ?? SWCLIDaemonStore(service: SWCLIDaemonService(bundleURL: MacSWBundle.url, paths: paths))
        self.fontLinkRepair = fontLinkRepair ?? { prefix in
            _ = try await RegistryService(wine: wine).repairTahomaFontLinkIfNeeded(prefix: prefix)
        }
        self.swcliPreparation = swcliPreparation ?? { prefix in
            try await Task.detached {
                try PrerequisiteService.prepareSWCLI(bundleURL: MacSWBundle.url, prefix: prefix)
            }.value
        }
        self.state = paths.solidWorksInstalled ? .unknown : .unavailable
    }

    public var isInstalled: Bool { paths.solidWorksInstalled }
    public var isRunning: Bool { if case .running = state { return true }; return false }

    public func startSWCLIDaemon() {
        guard PrerequisiteService.swcliIncluded(bundleURL: MacSWBundle.url) else { return }
        refreshWineRuntime()
        guard isInstalled, !isMigratingWine, !fontPreparationSuspended,
              wineRuntimeState.allowsLaunch, state != .starting, state != .stopping else { return }
        swcliDaemon.start { [self] observed in
            // Deploying over a disconnected but still listening backend is
            // unsafe. Existing startup preparation already deployed its files;
            // the lifecycle wrapper checks/synchronizes again before starting.
            try await ensureFontLinkPrepared()
            if observed == .stopped { try await ensureSWCLIPrepared() }
            await refreshState()
            return ProcessInventory.isSolidWorksRunning(processes)
        }
    }

    /// App 启动时建立唯一的字体准备任务，自动和手动启动都等待它完成。
    public func prepareFontLinkAtAppLaunch() {
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " Open Settings → Maintenance."
            return
        }
        guard !fontPreparationSuspended, fontPreparation == nil,
              paths.bottleExists, paths.solidWorksInstalled else { return }
        let repair = fontLinkRepair
        let gate = bottleGateStep()
        let bottle = paths.bottle
        fontPreparationID = UUID()
        // The font check is the first Wine process after MacSW opens: the bottle gate first.
        fontPreparation = Task {
            await gate()
            try await repair(bottle)
        }
    }

    func ensureFontLinkPrepared() async throws {
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else { throw runtimeError(wineRuntimeState.message) }
        guard !fontPreparationSuspended else {
            throw runtimeError("The bottle is being cleaned up or reinstalled; launch SOLIDWORKS later.")
        }
        prepareFontLinkAtAppLaunch()
        guard let task = fontPreparation, let id = fontPreparationID else { return }
        do {
            try await task.value
        } catch {
            // 失败的任务不能留给下一次手动启动复用；其他等待者可能仍在等同一个任务。
            if fontPreparationID == id {
                fontPreparation = nil
                fontPreparationID = nil
            }
            throw error
        }
    }

    /// 删除容器前先阻止新的字体检查，并等正在读写注册表的 Wine 进程退出。
    public func suspendFontPreparationForBottleDeletion() async {
        if let task = wineMigrationTask { await task.value }
        fontPreparationSuspended = true
        await swcliDaemon.waitForOperation()
        // The filesystem deployment must finish before the installer removes
        // the bottle; cancellation alone cannot stop a synchronous copy safely.
        if let task = swcliTask {
            _ = try? await task.value
            swcliTask = nil
            swcliTaskID = nil
        }
        guard let task = fontPreparation else { return }
        task.cancel()
        _ = try? await task.value
        fontPreparation = nil
        fontPreparationID = nil
    }

    public func resumeFontPreparationAfterBottleDeletion() {
        fontPreparationSuspended = false
    }

    /// 打开 App 不探测进程状态：需要自动启动时才探测，其余情况等用户查看菜单或启动时再说。
    public func startup(autoLaunch: Bool) async {
        guard !didRunStartup else { return }
        didRunStartup = true
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " Open Settings → Maintenance."
            return
        }
        do {
            try await ensureFontLinkPrepared()
        } catch {
            statusMessage = "Checking the PingFang font link failed: \(error.localizedDescription)"
            return
        }
        do {
            try await ensureSWCLIPrepared()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard autoLaunch else { return }
        await refreshState()
        if isInstalled, !isRunning { launch() }
    }

    /// 供面板等待的刷新入口。
    public func refreshNow() async {
        await refreshState()
    }

    /// Documents received (Finder, Dock drop) while SOLIDWORKS was not yet ready.
    private var pendingDocuments: [URL] = []

    /// Opens documents in the running SOLIDWORKS, or starts it with them.
    /// While SOLIDWORKS is starting they stay queued until its main window exists.
    public func open(documents urls: [URL]) {
        let files = SolidWorksDocumentTypes.openableFiles(urls)
        guard !files.isEmpty else { return }
        guard isInstalled else {
            statusMessage = "SOLIDWORKS is not installed yet; cannot open files."
            return
        }
        pendingDocuments.append(contentsOf: files)
        switch state {
        case .running, .starting: scheduleDocumentHandOff()
        default: launch()
        }
    }

    /// Documents for a SOLIDWORKS that runs outside this store (the SOLIDWORKS.app Wine host
    /// passes Finder opens here): wait for its main window, then hand them over. Never starts it.
    public func handOff(documents urls: [URL]) async {
        let files = SolidWorksDocumentTypes.openableFiles(urls)
        guard !files.isEmpty else { return }
        // SOLIDWORKS.app's own process: its folder prompts are its own, so ask them here, natively.
        _ = await prepareBottleForWine()
        pendingDocuments.append(contentsOf: files)
        scheduleDocumentHandOff()
        await handOffTask?.value
    }

    /// Dock icon click while MacSW is already running: start SOLIDWORKS, or bring it forward.
    /// `activate` is best effort (the Wine process may refuse activation); it returns whether it worked.
    public func handleDockReopen(activate: @MainActor (Int32) -> Bool) async {
        guard isInstalled else { return }
        await refreshState()
        switch state {
        case .running:
            let pid = processes.first {
                $0.name.caseInsensitiveCompare(ProcessInventory.primaryProcess) == .orderedSame
            }?.pid
            if let pid, activate(pid) {
                statusMessage = "Brought SOLIDWORKS to the front."
            } else {
                statusMessage = "SOLIDWORKS is already running; switch to its window."
            }
        case .starting:
            statusMessage = "SOLIDWORKS is still starting."
        case .stopping:
            statusMessage = "SOLIDWORKS is shutting down."
        case .unavailable, .unknown, .stopped, .failed:
            launch()
        }
    }

    /// Waits (bounded) for the SOLIDWORKS main window, then hands the queue to the running instance.
    private func scheduleDocumentHandOff() {
        guard handOffTask == nil else { return }
        handOffTask = Task { [weak self] in await self?.waitThenHandOff() }
    }

    private func waitThenHandOff() async {
        defer { handOffTask = nil }
        let began = Date()
        while !pendingDocuments.isEmpty {
            await refreshState()
            let pids = processes.map(\.pid)
            let readiness = DocumentHandOff.readiness(processes: processes, windows: windowSnapshot(pids))
            switch DocumentHandOff.pollDecision(readiness: readiness, waited: Date().timeIntervalSince(began)) {
            case .handOff:
                await handOffPendingDocuments()
                return
            case .abandon:
                pendingDocuments = []
                statusMessage = "SOLIDWORKS did not start; the queued files were not opened."
                return
            case .keepWaiting:
                try? await Task.sleep(nanoseconds: UInt64(handOffPollInterval * 1_000_000_000))
            }
        }
    }

    /// Passes queued documents to the running instance through `wine start /unix`, off the main
    /// actor: the bottle gate before the Wine start can wait (a new link's macOS prompt).
    private func handOffPendingDocuments() async {
        let files = pendingDocuments
        pendingDocuments = []
        guard !files.isEmpty else { return }
        let opener = documentOpener
        let bottle = paths.bottle
        do {
            try await Task.detached { try opener(bottle, files) }.value
        } catch {
            statusMessage = "Could not open the files: \(error.localizedDescription)"
        }
    }

    private func takePendingWindowsPaths() -> [String] {
        let drives = WineDocumentPath.drives(in: paths.bottle)
        let links = WineDocumentPath.folderLinks(in: paths.bottle)
        let urls = pendingDocuments
        pendingDocuments = []
        return urls.compactMap { WineDocumentPath.windowsPath(for: $0, drives: drives, folderLinks: links) }
    }

    public func launch() {
        guard !swcliDaemon.isOperating else { return }
        guard isInstalled else {
            state = .unavailable
            statusMessage = "SOLIDWORKS installation is not finished."
            return
        }
        switch state {
        case .starting, .running, .stopping: return
        case .unavailable, .unknown, .stopped, .failed: break
        }
        state = .starting
        statusMessage = "Preparing to launch SOLIDWORKS…"
        Task {
            do {
                // stopped 也可能只是旧观测：daemon 可在两次菜单刷新之间启动隐藏实例。
                await refreshState()
                if isRunning {
                    statusMessage = "SOLIDWORKS is already running."
                    if !pendingDocuments.isEmpty { scheduleDocumentHandOff() }
                    return
                }
                // H:, B:, I: and the other cloud drive letters first; a cloud folder gets a new
                // letter or link only after MacSW itself could open it. The bottle gate below then
                // lists every protected folder the bottle links to. Not while the bottle is being
                // migrated or deleted (the preparation below refuses the launch then anyway).
                if !isMigratingWine, !fontPreparationSuspended {
                    // SOLIDWORKS does not run (checked above); the font-link check started when the
                    // app opened, and the wineserver it leaves for a few seconds, would otherwise
                    // make both steps below skip the cloud folders.
                    if let task = fontPreparation { _ = try? await task.value }
                    let bottle = paths.bottle
                    _ = await Task.detached { WineBottleGate.waitForIdleSessionEnd(prefix: bottle) }.value
                    await maintainDriveMaps()
                }
                // A Wine access to ~/Documents, Box etc. would freeze wineserver on the macOS
                // consent prompt, so the native app asks first and sets aside what macOS refused.
                let folderNotice = WineBottleGate.notice(await prepareBottleForWine())
                try await ensureFontLinkPrepared()
                try await ensureSWCLIPrepared()
                // F4: the last check and the start under the bottle's start lock, so MacSW and
                // SOLIDWORKS.app (or two SOLIDWORKS.app launches) cannot both start a host.
                let startLock: StartLock?
                switch await startLocker(paths.bottle) {
                case .acquired(let lock): startLock = lock
                case .unavailable: startLock = nil
                case .busy:
                    // Another start holds it (forward mode): it owns this launch, and queued
                    // files go to its SOLIDWORKS once the main window is up.
                    await refreshState()
                    if isRunning {
                        statusMessage = "SOLIDWORKS is already running."
                    } else {
                        state = .failed(StartLock.busyMessage)
                        statusMessage = StartLock.busyMessage
                    }
                    if !pendingDocuments.isEmpty { scheduleDocumentHandOff() }
                    return
                }
                // 准备需要等待，真正启动前再确认一次，不能沿用旧的 stopped。
                await refreshState()
                if isRunning {
                    startLock?.release()
                    statusMessage = "SOLIDWORKS is already running."
                    if !pendingDocuments.isEmpty { scheduleDocumentHandOff() }
                    return
                }
                guard FileManager.default.isExecutableFile(atPath: wine.wineBinary.path) else {
                    startLock?.release()
                    throw runtimeError("The App's bundled Wine runtime is missing; repackage the App.")
                }
                statusMessage = "Launching SOLIDWORKS (Wine \(BuildInfo.wineVersion))…" + (folderNotice.map { " " + $0 } ?? "")
                let documentArguments = takePendingWindowsPaths()
                solidWorksStarter(
                    paths.solidWorksExecutable,
                    paths.bottle,
                    documentArguments,
                    { [weak self] in
                        // MacSW: after Process.run() returned. SOLIDWORKS.app: its exec released it.
                        startLock?.release()
                        guard let self else { return }
                        self.state = .running
                        // Files that arrived while the launch was in flight wait for the main window.
                        if !self.pendingDocuments.isEmpty { self.scheduleDocumentHandOff() }
                        self.statusMessage = "SOLIDWORKS is running." + (folderNotice.map { " " + $0 } ?? "")
                    },
                    { [weak self] success, message in
                        startLock?.release()
                        guard let self else { return }
                        self.state = success
                            ? (self.paths.solidWorksInstalled ? .stopped : .unavailable)
                            : .failed(message)
                        self.statusMessage = message
                    }
                )
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Keeps the drive letters and profile links of `DriveMapService` (unless Settings turned them off).
    func maintainDriveMaps() async {
        await driveMaps(paths) { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
    }

    /// `WineBottleGate.prepare` for the bottle (see `bottleGate`).
    func prepareBottleForWine() async -> WineBottleGate.Report {
        await bottleGate(paths.bottle) { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
    }

    /// `prepareBottleForWine` as the first step of a Wine task (font link, SWCLI).
    private func bottleGateStep() -> @Sendable () async -> Void {
        let gate = bottleGate
        let bottle = paths.bottle
        let status: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.statusMessage = message }
        }
        return { _ = await gate(bottle, status) }
    }

    func ensureSWCLIPrepared() async throws {
        guard !fontPreparationSuspended else {
            throw runtimeError("The bottle is being cleaned up or reinstalled; sync SWCLI later.")
        }
        guard paths.bottleExists, paths.solidWorksInstalled else { return }
        if swcliTask == nil {
            let prepare = swcliPreparation
            let gate = bottleGateStep()
            let bottle = paths.bottle
            swcliTaskID = UUID()
            swcliTask = Task {
                await gate()
                try await prepare(bottle)
            }
        }
        guard let task = swcliTask, let id = swcliTaskID else { return }
        do {
            try await task.value
        } catch {
            if swcliTaskID == id {
                swcliTask = nil
                swcliTaskID = nil
            }
            throw error
        }
    }

    public func requestQuit() {
        guard isRunning, !swcliDaemon.isOperating else { return }
        state = .stopping
        Task {
            let code = (try? await wine.requestSolidWorksQuit(prefix: paths.bottle)) ?? -1
            if code == 0 {
                statusMessage = "SOLIDWORKS was asked to quit normally."
            } else {
                state = .failed("SOLIDWORKS did not respond to the quit request.")
                statusMessage = "Could not quit normally; you can force quit in Settings."
            }
        }
    }

    public func forceStop() {
        guard !isMigratingWine, !swcliDaemon.isOperating else { return }
        Task {
            refreshWineRuntime()
            if !wineRuntimeState.allowsLaunch {
                do {
                    _ = try await WineRuntimeService.perform("stop", prefix: paths.bottle)
                    statusMessage = "Stopped the bottle with the archived runtime; the new Wine was not started."
                    await refreshState()
                } catch { statusMessage = error.localizedDescription }
                return
            }
            let code = (try? await wine.forceStopSolidWorks(prefix: paths.bottle)) ?? -1
            // wineserver 不是 Windows 进程，taskkill 打不掉它，需要单独收尾。
            if await wine.waitWineserver(prefix: paths.bottle, seconds: 10) {
                statusMessage = code == 0 ? "All bottle processes were force quit." : "Bottle processes cleaned up (taskkill returned \(code))."
            } else if (try? await wine.stopWineServerForCleanup(prefix: paths.bottle)) == true {
                statusMessage = "All bottle processes were force quit."
            } else {
                statusMessage = "Some processes could not be stopped; see solidworks-stop.log."
            }
            state = paths.solidWorksInstalled ? .stopped : .unavailable
            await refreshState()
        }
    }

    /// 托盘退出时只收尾当前容器；先停托管许可证进程，再结束 wineserver 和其余 Wine 客户进程。
    /// 未能确认进程全部退出时由调用方留在 App 中显示错误，避免假装已经清理完毕。
    public func stopContainerForAppQuit() async throws {
        guard !swcliDaemon.isOperating else { throw runtimeError("SWCLI is starting; quit after it finishes.") }
        guard !isMigratingWine else { throw runtimeError("A Wine migration is in progress; quit after it finishes.") }
        refreshWineRuntime()
        if !wineRuntimeState.allowsLaunch {
            _ = try await WineRuntimeService.perform("stop", prefix: paths.bottle)
            return
        }
        let snapshot = await ProcessInventory.snapshot(
            bottlePath: paths.bottle.path,
            wineRuntimePath: wine.runtimeURL.path
        )
        guard !snapshot.isEmpty else { return }
        guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
            throw runtimeError("Could not stop the Wine bottle; MacSW will keep running.")
        }
        for attempt in 0..<5 {
            let remaining = await ProcessInventory.snapshot(
                bottlePath: paths.bottle.path,
                wineRuntimePath: wine.runtimeURL.path
            )
            if remaining.isEmpty { return }
            if attempt < 4 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        throw runtimeError("The Wine bottle still has processes; MacSW will keep running. Check the Maintenance page.")
    }

    /// 重启容器：终止全部 Windows 进程并结束 wineserver；原本在跑 SOLIDWORKS 的话再拉起来。
    public func restartContainer() {
        guard !isMigratingWine, !swcliDaemon.isOperating else { return }
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " Open Settings → Maintenance."
            return
        }
        let wasRunning = isRunning
        if wasRunning { state = .stopping }
        Task {
            _ = try? await wine.forceStopSolidWorks(prefix: paths.bottle)
            let settled = await wine.waitWineserver(prefix: paths.bottle, seconds: 15)
            if !settled {
                _ = try? await wine.stopWineServerForCleanup(prefix: paths.bottle)
            }
            await refreshState()
            if wasRunning {
                statusMessage = "Bottle restarted; relaunching SOLIDWORKS."
                launch()
            } else {
                statusMessage = "Bottle fully stopped; the next launch will be a cold start."
            }
        }
    }

    /// Wine 的窗口不是瞬间弹出的：点下去立刻变灰转菊花，撑过这段空窗就收回，
    /// 不去猜进程有没有起来（猜错会一直转）。真实证据是下面 1 秒刷新的容器进程表。
    public func openWineTool(_ name: String) {
        guard !isMigratingWine, pendingWineTool == nil else { return }
        pendingWineTool = name
        if name == "cmd" {
            statusMessage = "Opening macOS Terminal and starting CMD…"
            Task {
                do {
                    try await wine.launchCommandPromptInTerminal(prefix: paths.bottle)
                    statusMessage = "CMD opened in macOS Terminal."
                } catch {
                    statusMessage = error.localizedDescription
                }
                pendingWineTool = nil
            }
            return
        }
        statusMessage = "Launching \(name)… a Wine cold start takes a few seconds."
        let tool = name
        let wine = wine
        let bottle = paths.bottle
        Task {
            // Off the main actor: the bottle gate before the Wine start can wait.
            do {
                try await Task.detached { try wine.launchTool(tool, prefix: bottle) }.value
            } catch {
                pendingWineTool = nil
                statusMessage = error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard pendingWineTool == tool else { return }
            pendingWineTool = nil
            statusMessage = "\(tool) was handed to Wine; if no window appears yet, wait a second or two and check the bottle process table below."
        }
    }

    private func refreshState() async {
        let snapshot = await processSnapshot(paths.bottle.path, wine.runtimeURL.path)
        if snapshot != processes { processes = snapshot }
        apply(observingRunning: ProcessInventory.isSolidWorksRunning(snapshot))
    }

    /// 进程表是唯一证据，但 `starting/stopping/failed` 是用户刚点出来的意图，
    /// 合并规则在 `SolidWorksRuntimeState.applying` 里。
    private func apply(observingRunning running: Bool) {
        let next = state.applying(observedRunning: running, installed: paths.solidWorksInstalled)
        if next != state { state = next }
    }

    private func runtimeError(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.RuntimeStore")
    }
}
