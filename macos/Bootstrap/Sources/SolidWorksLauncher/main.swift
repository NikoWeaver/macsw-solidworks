import AppKit
import Darwin
import MacSWCore

// SOLIDWORKS.app's executable is universal: this arm64 launcher plus the Wine loader as the
// x86_64 slice. The launcher runs MacSW's launch preflight, then replaces itself with the
// loader slice (`WineService.execSolidWorks`), so the Wine host is this app's own process:
// one Dock tile, the bundle's name and icon, and LaunchServices sends it the app's Apple
// events (patch 0025 hands opened documents back to this executable with --open-documents).
// The launcher never checks in with AppKit before the exec; LaunchServices keeps the launch
// events for the Wine host, which checks in as this app.

let environment = ProcessInfo.processInfo.environment
let appExecutable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

func showAlert(_ header: String, _ message: String, offerMacSW host: URL?) {
    var response: CFOptionFlags = 0
    CFUserNotificationDisplayAlert(0, kCFUserNotificationStopAlertLevel, nil, nil, nil,
                                   header as CFString, message as CFString, "OK" as CFString,
                                   host == nil ? nil : "Open MacSW" as CFString, nil, &response)
    if let host, response == kCFUserNotificationAlternateResponse {
        NSWorkspace.shared.open(host)
    }
}

guard let host = AppBundleLaunch.locateMacSW(appBundle: Bundle.main.bundleURL,
                                             info: Bundle.main.infoDictionary ?? [:],
                                             environment: environment) else {
    showAlert("SOLIDWORKS cannot start",
              "MacSW.app was not found. Install it in the Applications folder, next to SOLIDWORKS.app.",
              offerMacSW: nil)
    exit(1)
}
MacSWBundle.url = host
// The Wine locale and other MacSW settings live in MacSW's defaults domain.
UserDefaults.standard.addSuite(named: AppBundleLaunch.macSWDefaultsDomain)
let paths = AppBundleLaunch.appPaths(environment: environment)
let wine = WineService.shared

func log(_ line: String) {
    let text = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(line)\n"
    guard let handle = try? wine.logHandle(for: paths.logs.appendingPathComponent("solidworks-app.log")) else { return }
    try? handle.write(contentsOf: Data(text.utf8))
    try? handle.close()
}

let bottlePath = paths.bottle.path
let runtimePath = wine.runtimeURL.path

func runningSolidWorksPID(bottlePath: String, runtimePath: String) async -> Int32? {
    let snapshot = await ProcessInventory.snapshot(bottlePath: bottlePath, wineRuntimePath: runtimePath)
    return snapshot.first { $0.name.caseInsensitiveCompare(ProcessInventory.primaryProcess) == .orderedSame }?.pid
}

/// Before AppKit or any task runs: the main thread waits on a detached task that touches no
/// main-actor state (top-level variables of this file are main-actor isolated).
func blockingRunningSolidWorksPID() -> Int32? {
    final class Result: @unchecked Sendable { var pid: Int32? }
    let result = Result()
    let done = DispatchSemaphore(value: 0)
    Task.detached { [bottlePath, runtimePath] in
        result.pid = await runningSolidWorksPID(bottlePath: bottlePath, runtimePath: runtimePath)
        done.signal()
    }
    done.wait()
    return result.pid
}

/// F4: the bottle's start lock. The wait goes to the log before the exec (a launch alone should not wait).
final class StartLockNote: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ value: String) { lock.lock(); line = value; lock.unlock() }
    /// The note once, then nil.
    func take() -> String? { lock.lock(); defer { line = nil; lock.unlock() }; return line }
}
let startLockNote = StartLockNote()
let loggedStartLock: RuntimeStore.StartLocker = { [startLockNote] prefix in
    let began = Date()
    let outcome = await Task.detached(priority: .userInitiated) { StartLock.acquire(prefix: prefix) }.value
    let waited = String(format: "%.2f", Date().timeIntervalSince(began))
    switch outcome {
    case .acquired: startLockNote.set("start lock: acquired after \(waited) s")
    case .busy: startLockNote.set("start lock: busy after \(waited) s")
    case .unavailable(let reason): startLockNote.set("start lock: not available (\(reason)); starting without it")
    }
    return outcome
}

@MainActor
func makeRuntime(fontLinkRepair: (@Sendable (URL) async throws -> Void)? = nil,
                 starter: @escaping RuntimeStore.SolidWorksStarter) -> RuntimeStore {
    RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths), fontLinkRepair: fontLinkRepair,
                 startLocker: loggedStartLock, solidWorksStarter: starter)
}

/// Document hand-off and forwarding must never start a second SLDWORKS.exe.
let noLaunch: RuntimeStore.SolidWorksStarter = { _, _, _, _, completion in
    completion(false, "SOLIDWORKS is not running.")
}

@MainActor
func bringToFront(_ pid: Int32?) {
    // Best effort: macOS 14+ activates another app only when the active app yields to it.
    guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
    let activated: Bool
    if #available(macOS 14.0, *) {
        NSApp?.yieldActivation(to: app)
        activated = app.activate(from: .current, options: [.activateAllWindows])
    } else {
        activated = app.activate(options: [.activateAllWindows])
    }
    log("bring SOLIDWORKS (pid \(pid)) to the front: \(activated ? "done" : "refused by macOS")")
}

/// SOLIDWORKS already runs in the bottle, but as another process (MacSW started it): receive
/// LaunchServices' documents as an accessory app, pass them on, bring SOLIDWORKS forward, quit.
final class ForwardDelegate: NSObject, NSApplicationDelegate {
    private var documents: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        documents.append(contentsOf: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let documents = self.documents
        Task { @MainActor in
            log("forward: \(documents.count) document(s) to the running SOLIDWORKS")
            let runtime = makeRuntime(starter: noLaunch)
            await runtime.handOff(documents: documents)
            if !runtime.statusMessage.isEmpty { log("forward: \(runtime.statusMessage)") }
            bringToFront(await runningSolidWorksPID(bottlePath: bottlePath, runtimePath: runtimePath))
            exit(0)
        }
    }
}

switch AppBundleLaunch.mode(arguments: CommandLine.arguments, solidWorksRunning: { blockingRunningSolidWorksPID() != nil }) {
case .openDocuments(let documents):
    Task { @MainActor in
        log("open-documents: \(documents.count) document(s)")
        let runtime = makeRuntime(starter: noLaunch)
        await runtime.handOff(documents: documents)
        // Failures would otherwise only reach a status line nobody sees.
        if !runtime.statusMessage.isEmpty { log("open-documents: \(runtime.statusMessage)") }
        exit(0)
    }
    dispatchMain()

case .forward:
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = ForwardDelegate()
    application.delegate = delegate
    application.run()

case .launch:
    Task { @MainActor in
        let started = Date()
        log("launch: MacSW at \(host.path), bottle \(paths.bottle.path)")
        // Test switch for the LaunchServices validation (docs/solidworks-app.md): a late exec.
        if let delay = Double(environment[AppBundleLaunch.launchDelayKey] ?? ""), delay > 0 {
            log("launch: waiting \(delay) s (\(AppBundleLaunch.launchDelayKey))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        // The x86_64 slice is a copy of MacSW.app's loader; a stale copy must not run MacSW's ntdll.so.
        if environment[AppBundleLaunch.skipLoaderCheckKey] != "1" {
            switch AppBundleLaunch.loaderSliceMatches(appExecutable: appExecutable, macSW: host) {
            case false?:
                log("launch refused: the Wine loader in this app differs from MacSW's (\(host.path))")
                showAlert("SOLIDWORKS.app is out of date",
                          "MacSW.app was updated. Open MacSW: it updates SOLIDWORKS.app (Settings → Maintenance → SOLIDWORKS App). Then start SOLIDWORKS again.",
                          offerMacSW: host)
                exit(1)
            case nil:
                log("launch: could not compare the Wine loader with MacSW's; starting anyway")
            case true?:
                break
            }
        }
        // MacSW checks the font link once per MacSW session; here once per bottle and runtime.
        let fontLinkRepair = environment[AppBundleLaunch.fullPreflightKey] == "1" ? nil
            : AppBundleLaunch.stampedFontLinkRepair(stamp: AppBundleLaunch.fontLinkStamp(paths: paths), macSW: host) {
                _ = try await RegistryService(wine: .shared).repairTahomaFontLinkIfNeeded(prefix: $0)
            }
        let quitClosesWindows = UserDefaults.standard.bool(forKey: AppBundleLaunch.quitClosesWindowsPreference)
        let runtime = makeRuntime(fontLinkRepair: fontLinkRepair) { executable, prefix, arguments, _, completion in
            if let note = startLockNote.take() { log(note) }
            log("exec: Wine host after \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
                + (quitClosesWindows ? ", Quit closes windows" : ""))
            do {
                try wine.execSolidWorks(executable: executable, prefix: prefix, arguments: arguments,
                                        appExecutable: appExecutable, quitClosesWindows: quitClosesWindows)
            } catch {
                completion(false, error.localizedDescription)
            }
        }
        runtime.launch()
        while runtime.state == .starting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let note = startLockNote.take() { log(note) }
        log("launch ended without exec: \(runtime.state) \(runtime.statusMessage)")
        if AppBundleLaunch.endsInForwardMode(runtime.state) {
            // It started in the meantime (MacSW, a second click, or the start that held the start
            // lock): bring it forward instead.
            log("forward: no second start; bring the running SOLIDWORKS forward")
            bringToFront(await runningSolidWorksPID(bottlePath: bottlePath, runtimePath: runtimePath))
        } else {
            showAlert("SOLIDWORKS could not start",
                      runtime.statusMessage.isEmpty ? "MacSW is busy; try again in a moment." : runtime.statusMessage,
                      offerMacSW: host)
        }
        exit(0)
    }
    dispatchMain()
}
