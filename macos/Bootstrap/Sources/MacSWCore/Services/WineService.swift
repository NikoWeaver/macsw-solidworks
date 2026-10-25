import AppKit
import Darwin
import Foundation

public final class WineService: @unchecked Sendable {
    public static let shared = WineService()
    private let stateLock = NSLock()
    private var activePrefixes = Set<String>()
    private var installingPrefixes = Set<String>()
    /// Runs before every Wine process of a bottle starts, wineserver excepted (it opens no drive):
    /// `WineBottleGate.guardWineStart`, which throws when Wine must not start.
    private let prepareBottle: @Sendable (URL) throws -> Void

    init(prepareBottle: (@Sendable (URL) throws -> Void)? = nil) {
        self.prepareBottle = prepareBottle ?? { prefix in
            try WineBottleGate.guardWineStart(
                prefix: prefix,
                log: prefix.deletingLastPathComponent().appendingPathComponent("logs/folder-consent.log"))
        }
    }

    /// Only the confirmed installer may initialize a fresh/replaced bottle.
    func setInstalling(_ installing: Bool, prefix: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if installing { installingPrefixes.insert(prefix.path) }
        else { installingPrefixes.remove(prefix.path) }
    }

    func isInstalling(prefix: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return installingPrefixes.contains(prefix.path)
    }

    func start(_ process: Process) throws {
        guard let path = process.environment?["WINEPREFIX"] else {
            try process.run()
            return
        }
        if process.executableURL?.lastPathComponent != "wineserver" {
            try prepareBottle(URL(fileURLWithPath: path))
        }
        stateLock.lock()
        let installing = installingPrefixes.contains(path)
        stateLock.unlock()
        if installing { try process.run() }
        else {
            try WineRuntimeService.withLaunchLock(prefix: URL(fileURLWithPath: path),
                checkIdentity: process.executableURL?.lastPathComponent != "wineserver") { try process.run() }
        }
    }

    /// 单个日志文件的大小上限，超过就从头写。
    static let maximumLogBytes: Int64 = 4 * 1024 * 1024
    public static let vcLibraries = [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
        "msvcp140_codecvt_ids", "vcruntime140", "vcruntime140_1", "vcomp140", "mfc140u"
    ]
    /// 裸工具名会先经过 Wine start.exe 的 Shell 解析，在 winemac 下平白加载一遍
    /// user32/shell32（实测约 3.5 秒）。只为已知系统工具补全路径，外部 EXE 原样保留。
    private static let systemToolPaths = [
        "cmd": #"C:\windows\system32\cmd.exe"#,
        "msiexec": #"C:\windows\system32\msiexec.exe"#,
        "reg": #"C:\windows\system32\reg.exe"#,
        "regedit": #"C:\windows\regedit.exe"#,
        "taskkill": #"C:\windows\system32\taskkill.exe"#,
        "wineboot": #"C:\windows\system32\wineboot.exe"#,
        "winecfg": #"C:\windows\system32\winecfg.exe"#,
        "winepath": #"C:\windows\system32\winepath.exe"#
    ]
    /// 停止时必须覆盖整套进程，只杀主程序会留下文件服务。
    /// 名单与"哪些进程算 SOLIDWORKS 自己的"是同一件事，只在 ProcessInventory 里定义一次。
    public static let solidWorksProcessNames = ProcessInventory.solidWorksProcesses
    public var runtimeURL: URL {
        MacSWBundle.url.appendingPathComponent("Contents/Frameworks/wine")
    }

    public var wineBinary: URL {
        runtimeURL.appendingPathComponent("lib/wine/x86_64-unix/MacSW")
    }

    public var wineServerBinary: URL {
        runtimeURL.appendingPathComponent("bin/wineserver")
    }

    public func isRunning(prefix: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activePrefixes.contains(prefix.path)
    }

    /// `Process.terminationStatus` 只有退出码的低 8 位：msiexec 的 1603 到这里是 67，
    /// 3010（需要重启）是 194，1638 是 102。两边都归一到 8 位再比，
    /// 成功码列表里写四位码还是写截断值都不会漏判。
    private static func statusMatches(_ code: Int32, _ accepted: [Int32]) -> Bool {
        accepted.contains { ($0 & 0xFF) == (code & 0xFF) }
    }

    public static func isSuccessfulPrerequisiteStatus(_ code: Int32) -> Bool {
        statusMatches(code, [0, 3010, 194, 1638, 102])
    }

    public static func isSuccessfulInstallerStatus(_ code: Int32) -> Bool {
        statusMatches(code, [0, 3010, 194])
    }

    public static func isCancelledInstallerStatus(_ code: Int32) -> Bool {
        // Windows ERROR_INSTALL_USEREXIT (1602) 截断成 66；被信号打死时是信号号 15。
        statusMatches(code, [1602, 66, 15])
    }

    public static func isSuccessfulCleanupStop(killStatus: Int32, waitStatus: Int32) -> Bool {
        [Int32(0), 1].contains(killStatus) && waitStatus == 0
    }

    static let crossProcessSurfacesKey = "MACSW_CROSS_PROCESS_SURFACES"
    static let startupCacheKeys = ["MACSW_WIC_COMPONENT_CACHE", "MACSW_LOCAL_MODULE_READS"]
    /// Patches 0023/0024 only act when this is "1" or "all". Their MACSW_NATIVE_FILE_DIALOG_TEST*
    /// variables (automation only) and the 0025 switches (`solidWorksExecPlan`) are never inherited.
    static let nativeFileDialogsKey = "MACSW_NATIVE_FILE_DIALOGS"

    /// The only variables a Wine process inherits from MacSW's (or SOLIDWORKS.app's) own
    /// environment, besides LANG and LC_*. Wine copies its Unix environment into every Windows
    /// process, so anything else there (API keys, tokens, SSH_AUTH_SOCK, CLAUDE_*, DYLD_*, WINE*
    /// overrides such as WINEDLLOVERRIDES or WINEDLLPATH) stays out (security audit 2026-10-24,
    /// finding 3).
    static let inheritedEnvironmentKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ", "__CF_USER_TEXT_ENCODING",
        // Tuning switches that the Wine patches and MacSW's helpers read (0007, 0009, 0017, 0030, 0036, wine_runtime.py).
        "WINE_SOLIDWORKS_STARTUP_TIMEOUT", "MACSW_OPENGL_RENDERER", "WINEMSYNC", "WINEMSYNC_QLIMIT",
        "MACSW_WINE_LOCALE", "MACSW_GL_BATCH", "MACSW_GL_MPENGINE"
    ]
    /// Wine needs no user PATH entries; MacSW passes the runtime's paths explicitly.
    static let sanitizedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func inheritedEnvironment(_ parent: [String: String]) -> [String: String] {
        var environment = parent.filter { key, _ in
            inheritedEnvironmentKeys.contains(key) || key == "LANG" || key.hasPrefix("LC_")
        }
        environment["PATH"] = sanitizedPath
        return environment
    }

    public func environment(winePrefix: URL, solidWorks: Bool = false,
                            locale: String = AppPreferences.wineLocale(),
                            macFileDialogs: Bool = AppPreferences.useMacFileDialogs(),
                            macFileDialogsEverywhere: Bool = AppPreferences.macFileDialogsEverywhere(),
                            inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        // An allowlist, not the caller's whole environment (see `inheritedEnvironmentKeys`).
        var environment = Self.inheritedEnvironment(inherited)
        environment["WINEPREFIX"] = winePrefix.path
        environment["WINELOADER"] = wineBinary.path
        environment["WINESERVER"] = wineServerBinary.path
        environment["LANG"] = locale
        environment["LC_ALL"] = locale
        environment["WINEDEBUG"] = "-all"
        environment["WINE_MONO_AOT"] = solidWorks ? "none" : "interp"
        if solidWorks {
            // Patch 0018 only acts when this is set; WebView2 panes need it (docs/webview2-under-wine.md).
            environment[Self.crossProcessSurfacesKey] = "1"
            // Patches 0032/0033 (docs/startup-performance.md): cache the WIC component registry and read the
            // own module list locally. Together they remove about 0.5 M wineserver round trips per start.
            for key in Self.startupCacheKeys { environment[key] = "1" }
            environment["WINEDLLOVERRIDES"] = (["atiadlxx=d"] + Self.vcLibraries.map { "\($0)=n,b" })
                .joined(separator: ";")
            // Settings > "Use macOS file dialogs" (on by default, `all`; docs/native-file-dialogs.md).
            if macFileDialogs { environment[Self.nativeFileDialogsKey] = macFileDialogsEverywhere ? "all" : "1" }
        }
        return environment
    }

    public func logDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent("logs")
    }

    public func makeProcess(arguments: [String], prefix: String, solidWorks: Bool = false) -> Process {
        makeProcess(arguments: arguments, prefix: URL(fileURLWithPath: prefix), solidWorks: solidWorks)
    }

    public func makeProcess(arguments: [String], prefix: URL, solidWorks: Bool = false) -> Process {
        let process = Process()
        process.executableURL = wineBinary
        process.arguments = Self.resolvingSystemTool(in: arguments)
        process.environment = environment(winePrefix: prefix, solidWorks: solidWorks)
        return process
    }

    static func resolvingSystemTool(in arguments: [String]) -> [String] {
        guard let command = arguments.first,
              let explicit = systemToolPaths[command.lowercased()] else { return arguments }
        return [explicit] + arguments.dropFirst()
    }

    /// Installer command-line values are not all translated by Wine. Resolve
    /// through this prefix's actual drive mappings, never assume a Z: drive.
    public func windowsPath(for url: URL, prefix: URL) async throws -> String {
        let result = try await capturePairCancellable(
            makeProcess(arguments: ["winepath", "-w", url.path], prefix: prefix)
        )
        guard result.status == 0, let path = Self.parsedWindowsPath(result.standardOutput) else {
            throw NSError(domain: "MacSW.Wine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not convert the install log path to a Windows path in the current Wine bottle."])
        }
        return path
    }

    static func parsedWindowsPath(_ output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil,
              !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
              !path.contains("\u{FFFD}") else { return nil }
        return path
    }

    @discardableResult
    public func run(_ process: Process, log: URL? = nil) throws -> Int32 {
        let handle = try logHandle(for: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }
        try start(process)
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func runCancellable(_ process: Process, log: URL? = nil) async throws -> Int32 {
        try Task.checkCancellation()
        let handle = try logHandle(for: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }

        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try self.start(process)
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            self.terminateProcess(process)
        })
        try Task.checkCancellation()
        return status
    }

    public func captureCancellable(_ process: Process) async throws -> (Int32, String) {
        let capture = try await capturePairCancellable(process)
        return (capture.status, [capture.standardOutput, capture.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))
    }

    /// 分流捕获：`hdiutil -plist`、`reg query` 这类要把标准输出交给解析器的调用，
    /// 混进 stderr 的告警会让整段解析失败，所以两条流必须分开返回。
    public func capturePairCancellable(_ process: Process) async throws
        -> (status: Int32, standardOutput: String, standardError: String)
    {
        // Wine 的常驻 wineserver 会继承子进程的 stderr。若用 Pipe 并等 EOF，
        // reg.exe 等短命令已经退出后，这里仍会一直等到 wineserver 退出。
        // 临时文件在命令退出后即可读取，不受后代进程持有描述符的影响。
        let outputFile = try CaptureFile()
        defer { outputFile.cleanup() }
        let errorFile = try CaptureFile()
        defer { errorFile.cleanup() }
        process.standardOutput = outputFile.handle
        process.standardError = errorFile.handle
        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try self.start(process)
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            self.terminateProcess(process)
        })
        try Task.checkCancellation()
        try outputFile.handle.close()
        try errorFile.handle.close()
        let output = try Data(contentsOf: outputFile.url)
        let errors = try Data(contentsOf: errorFile.url)
        // Wine 工具在中文 locale 下会输出遗留代码页字节（如 reg 的本地化“默认”），
        // 严格解码会整体失败并丢掉 ASCII 内容，这里按有损 UTF-8 解码。
        return (status, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    private struct CaptureFile {
        let url: URL
        let handle: FileHandle

        init() throws {
            var path = Array(FileManager.default.temporaryDirectory
                .appendingPathComponent("MacSW-capture-XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&path)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            url = URL(fileURLWithPath: String(cString: path))
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func cleanup() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func stopWineServerForCleanup(prefix: URL) async throws -> Bool {
        let log = logDirectory(prefix.path).appendingPathComponent("clean-install-wineserver.log")
        let kill = makeProcess(arguments: ["-k"], prefix: prefix)
        kill.executableURL = wineServerBinary
        let killStatus = try await runCancellable(kill, log: log)
        let wait = makeProcess(arguments: ["-w"], prefix: prefix)
        wait.executableURL = wineServerBinary
        let waitStatus = try await runCancellable(wait, log: log)
        return Self.isSuccessfulCleanupStop(killStatus: killStatus, waitStatus: waitStatus)
    }

    public func runMSIExec(arguments: [String], prefix: URL, log: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: arguments, prefix: prefix),
            log: log
        )
    }

    /// msiexec 返回后 wineserver 可能仍在收尾；官方安装包也会留下更新器
    /// 之类的辅助进程，必须在继续之前让它们沉降或退出。
    public func waitWineserver(prefix: URL, seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let process = self.makeProcess(arguments: ["-w"], prefix: prefix)
                process.executableURL = self.wineServerBinary
                let status = try? await self.runCancellable(
                    process,
                    log: self.logDirectory(prefix.path).appendingPathComponent("wineserver.log")
                )
                return status == 0
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let settled = await group.next() ?? false
            group.cancelAll()
            return settled
        }
    }

    public func launchSolidWorks(
        executable: URL,
        prefix: URL,
        arguments: [String] = [],
        onStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Bool, String) -> Void
    ) {
        stateLock.lock()
        guard !activePrefixes.contains(prefix.path) else {
            stateLock.unlock()
            // 必须回调，否则调用方会永远停在“启动中”；真正退出由已接管该容器的那次启动通知。
            DispatchQueue.main.async { onStarted() }
            return
        }
        activePrefixes.insert(prefix.path)
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            var launchHandle: FileHandle?
            defer {
                try? launchHandle?.close()
                self.stateLock.lock()
                self.activePrefixes.remove(prefix.path)
                self.stateLock.unlock()
            }
            do {
                let solidWorks = self.makeProcess(arguments: [executable.path] + arguments, prefix: prefix, solidWorks: true)
                solidWorks.currentDirectoryURL = executable.deletingLastPathComponent()
                let launchLog = self.logDirectory(prefix.path).appendingPathComponent("sw_launch.log")
                launchHandle = try self.logHandle(for: launchLog)
                solidWorks.standardOutput = launchHandle ?? FileHandle.nullDevice
                solidWorks.standardError = launchHandle ?? FileHandle.nullDevice
                CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
                try self.start(solidWorks)
                DispatchQueue.main.async { onStarted() }
                solidWorks.waitUntilExit()
                let result = solidWorks.terminationStatus
                DispatchQueue.main.async {
                    completion(result == 0, "SOLIDWORKS has exited (\(result)).")
                }
            } catch {
                DispatchQueue.main.async { completion(false, "Launch failed: \(error.localizedDescription)") }
            }
        }
    }

    /// What SOLIDWORKS.app executes: the x86_64 slice of its own executable (the Wine loader) with
    /// SOLIDWORKS as the program, so the Wine host is the app bundle's process.
    struct ExecPlan: Equatable {
        let path: String
        let arguments: [String]
        let environment: [String: String]
        let directory: String
        let log: URL
    }

    func solidWorksExecPlan(executable: URL, prefix: URL, arguments: [String], appExecutable: URL,
                            quitClosesWindows: Bool = false,
                            inherited: [String: String] = ProcessInfo.processInfo.environment) -> ExecPlan {
        // The exec passes exactly this environment: the allowlist of `environment`, not the launcher's.
        var environment = environment(winePrefix: prefix, solidWorks: true, inherited: inherited)
        // winemac compares this with the main bundle of the process (Contents/MacOS/<executable>),
        // so the Wine processes the host starts ignore the inherited variables.
        environment[AppBundleLaunch.appBundleKey] = appExecutable
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        environment[AppBundleLaunch.openDocumentsHelperKey] = appExecutable.path
        if quitClosesWindows { environment[AppBundleLaunch.quitModeKey] = "close" }
        // Patch 0025 starts the open-documents helper with the host's environment. A launch with a
        // data directory or MacSW.app override (a test instance) passes it on, so a Finder open on
        // that instance stays in its bottle and never reaches AppPaths.live() (bughunt F6).
        for key in [AppBundleLaunch.appSupportKey, AppBundleLaunch.hostAppKey] {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        // argv[0] names the runtime's loader: loader/main.c loads the ntdll.so next to argv[0]
        // when there is none next to the executable itself.
        return ExecPlan(path: appExecutable.path,
                        arguments: [wineBinary.path, executable.path] + arguments,
                        environment: environment,
                        directory: executable.deletingLastPathComponent().path,
                        log: logDirectory(prefix.path).appendingPathComponent("sw_launch.log"))
    }

    /// SOLIDWORKS.app only: replaces this process with the Wine loader slice of `appExecutable`,
    /// under the same launch lock and runtime check as `start`. Returns only by throwing.
    /// `replace` is the exec itself (tests inject it).
    public func execSolidWorks(executable: URL, prefix: URL, arguments: [String], appExecutable: URL,
                               quitClosesWindows: Bool = false) throws -> Never {
        try execSolidWorks(executable: executable, prefix: prefix, arguments: arguments, appExecutable: appExecutable,
                           quitClosesWindows: quitClosesWindows, replace: Self.replaceProcess)
    }

    func execSolidWorks(executable: URL, prefix: URL, arguments: [String], appExecutable: URL,
                        quitClosesWindows: Bool, replace: (ExecPlan, Int32?) -> Int32) throws -> Never {
        let plan = solidWorksExecPlan(executable: executable, prefix: prefix, arguments: arguments,
                                      appExecutable: appExecutable, quitClosesWindows: quitClosesWindows)
        try prepareBottle(prefix)
        let handle = try logHandle(for: plan.log)
        CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
        let status = try WineRuntimeService.withLaunchLock(prefix: prefix) {
            replace(plan, handle?.fileDescriptor)
        }
        throw error("Could not start the Wine loader: \(String(cString: strerror(status))).", status)
    }

    /// posix_spawn with POSIX_SPAWN_SETEXEC: on success it does not return.
    private static func replaceProcess(with plan: ExecPlan, output: Int32?) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdin/stdout/stderr survive; the launch lock and other descriptors close.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var x86_64: cpu_type_t = 0x0100_0007  // CPU_TYPE_X86_64: the Wine loader slice
        posix_spawnattr_setbinpref_np(&attributes, 1, &x86_64, nil)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        for target in [Int32(1), 2] {
            if let output { posix_spawn_file_actions_adddup2(&actions, output, target) }
            else { posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0) }
        }
        posix_spawn_file_actions_addchdir_np(&actions, plan.directory)

        let argv = plan.arguments.map { strdup($0) } + [nil]
        let envp = plan.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        return posix_spawn(nil, plan.path, &actions, &attributes, argv, envp)
    }

    /// Cold-start fallback only: a second SLDWORKS.exe with file arguments. Whether it forwards to a
    /// running instance under Wine is unverified, so running instances use `openDocumentsInRunningInstance`.
    public func handOffDocuments(executable: URL, prefix: URL, arguments: [String]) throws {
        let process = makeProcess(arguments: [executable.path] + arguments, prefix: prefix, solidWorks: true)
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        let handle = try logHandle(for: logDirectory(prefix.path).appendingPathComponent("sw_open.log"))
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
        try start(process)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            try? handle?.close()
        }
    }

    /// Passes documents to the running SOLIDWORKS through `wine start /unix <file>` (ShellExecute),
    /// which never launches SLDWORKS.exe by itself unless the registered open verb does.
    public func openDocumentsInRunningInstance(prefix: URL, files: [URL]) throws {
        // Before the Windows paths are worked out: they must name only letters and links that stay.
        try prepareBottle(prefix)
        CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
        let handle = try logHandle(for: logDirectory(prefix.path).appendingPathComponent("sw_open.log"))
        var started: [Process] = []
        defer {
            let group = started
            DispatchQueue.global(qos: .utility).async {
                group.forEach { $0.waitUntilExit() }
                try? handle?.close()
            }
        }
        for arguments in DocumentHandOff.startArguments(for: files, prefix: prefix) {
            let process = makeProcess(arguments: arguments, prefix: prefix, solidWorks: true)
            process.standardOutput = handle ?? FileHandle.nullDevice
            process.standardError = handle ?? FileHandle.nullDevice
            try start(process)
            started.append(process)
        }
    }

    public func requestSolidWorksQuit(prefix: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: Self.taskkillArguments(force: false), prefix: prefix),
            log: logDirectory(prefix.path).appendingPathComponent("solidworks-stop.log")
        )
    }

    public func forceStopSolidWorks(prefix: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: Self.taskkillArguments(force: true), prefix: prefix),
            log: logDirectory(prefix.path).appendingPathComponent("solidworks-stop.log")
        )
    }

    static func taskkillArguments(force: Bool) -> [String] {
        var arguments = ["taskkill"]
        if force { arguments.append("/f") }
        for name in solidWorksProcessNames { arguments.append(contentsOf: ["/im", name]) }
        return arguments
    }

    public func launchTool(_ name: String, prefix: URL) throws {
        let process = makeProcess(arguments: [name], prefix: prefix)
        CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
        try start(process)
    }

    /// CMD 是控制台程序；从图形应用直接启动时没有交互式终端，读到 EOF 就会退出。
    /// 通过 Terminal 的伪终端运行同一份 Wine 和容器，避免依赖当前不可用的 wineconsole 图形后端。
    public func launchCommandPromptInTerminal(prefix: URL) async throws {
        let runtimeState = WineRuntimeService.status(prefix: prefix)
        guard runtimeState.allowsLaunch else {
            throw MacSWError.make(runtimeState.message, domain: "MacSW.WineService")
        }
        let script = """
        on run argv
            tell application "Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, commandPromptTerminalCommand(prefix: prefix)]
        CoreInstallRetry.noteSolidWorksMayStart(prefix: prefix)
        let (status, output) = try await captureCancellable(process)
        guard status == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacSWError.make(
                detail.isEmpty ? "Could not open macOS Terminal (exit code \(status))." : "Could not open macOS Terminal: \(detail)",
                domain: "MacSW.WineService"
            )
        }
    }

    func commandPromptTerminalCommand(prefix: URL) -> String {
        let wineEnvironment = environment(winePrefix: prefix)
        let keys = ["WINEPREFIX", "WINELOADER", "WINESERVER", "LANG", "LC_ALL", "WINEDEBUG", "WINE_MONO_AOT"]
        let assignments = keys.compactMap { key in
            wineEnvironment[key].map { "\(key)=\(Self.shellQuote($0))" }
        }
        let cmd = Self.systemToolPaths["cmd"]!
        let contents = MacSWBundle.url.appendingPathComponent("Contents")
        let python = contents.appendingPathComponent("Resources/SWCLI/runtime/PythonNative/bin/python3")
        let guardScript = contents.appendingPathComponent("Resources/SWCLI/bin/wine_runtime.py")
        // -B: never write bytecode into the signed bundle.
        return (["env"] + assignments + [Self.shellQuote(python.path), "-I", "-B", Self.shellQuote(guardScript.path),
                "launch", "--contents", Self.shellQuote(contents.path), "--prefix", Self.shellQuote(prefix.path),
                "--", Self.shellQuote(wineBinary.path), Self.shellQuote(cmd)]).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(processIdentifier, SIGKILL) }
        }
    }

    /// 打开（必要时创建）一个追加写的日志句柄；调用方负责关闭。
    /// The directory is 0700 and the file 0600 (`LogFiles`).
    public func logHandle(for log: URL?) throws -> FileHandle? {
        guard let log else { return nil }
        let fileManager = FileManager.default
        try LogFiles.prepare(log)
        if let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? NSNumber,
           size.int64Value > Self.maximumLogBytes {
            // wine 的输出每次都往上追加，几 MB 之后查看器只剩卡顿；旧内容已经没价值了。
            if let truncate = try? FileHandle(forWritingTo: log) {
                try? truncate.truncate(atOffset: 0)
                try? truncate.close()
            }
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        return handle
    }

    private func error(_ message: String, _ code: Int32) -> NSError {
        MacSWError.make(message, domain: "MacSW.Wine", code: Int(code))
    }
}
