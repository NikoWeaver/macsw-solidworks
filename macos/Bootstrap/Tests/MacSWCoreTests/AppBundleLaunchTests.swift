import Foundation
import XCTest
@testable import MacSWCore

/// A MacSW.app layout good enough for `AppBundleLaunch.isMacSW` and `WineService.wineBinary`.
private func makeFakeMacSW(in directory: URL, identifier: String = AppBundleLaunch.macSWBundleIdentifier,
                           loader: Bool = true) throws -> URL {
    let app = directory.appendingPathComponent("MacSW.app")
    let unix = app.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix")
    try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
    try (["CFBundleIdentifier": identifier] as NSDictionary)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    if loader {
        let path = unix.appendingPathComponent("MacSW").path
        FileManager.default.createFile(atPath: path, contents: Data("loader".utf8), attributes: [.posixPermissions: 0o755])
    }
    return app
}

/// BuildManifest.plist with every key `WineRuntimeService.identity` requires.
private func writeBuildManifest(into app: URL, loaderHash: String = "loader-1") throws {
    var identity: [String: String] = [:]
    for key in ["WineVersion", "MonoVersion", "WineMacModuleSHA256", "WineInputModuleSHA256",
                "WineCOMBaseModuleSHA256", "WineComctl32V6ModuleSHA256", "WineNtdllModuleSHA256",
                "MonoPatchSHA256", "MonoMscorlibSHA256", "MonoRegAsmX86SHA256", "MonoRegAsmX64SHA256"] {
        identity[key] = key.lowercased()
    }
    identity["WineLoaderSHA256"] = loaderHash
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try (identity as NSDictionary).write(to: resources.appendingPathComponent("BuildManifest.plist"))
}

private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
private func be64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

/// A 64-bit Mach-O header with a segment command and, when given, an LC_UUID.
private func thinMachO(cpuType: Int32, uuid: UUID?) -> Data {
    var commands = le32(0x19) + le32(72) + Data(count: 64)
    var count: UInt32 = 1
    if let uuid {
        commands += le32(0x1b) + le32(24) + withUnsafeBytes(of: uuid.uuid) { Data($0) }
        count += 1
    }
    return le32(0xfeed_facf) + le32(UInt32(bitPattern: cpuType)) + le32(3) + le32(2) + le32(count)
        + le32(UInt32(commands.count)) + le32(0) + le32(0) + commands
}

/// A universal file (fat_arch or fat_arch_64 entries) with the slices at 4 KiB boundaries.
private func fatMachO(_ slices: [(cpuType: Int32, data: Data)], wide: Bool = false) -> Data {
    var header = be32(wide ? 0xcafe_babf : 0xcafe_babe) + be32(UInt32(slices.count))
    var body = Data()
    var offset = 4096
    for slice in slices {
        header += be32(UInt32(bitPattern: slice.cpuType)) + be32(3)
        header += wide ? be64(UInt64(offset)) + be64(UInt64(slice.data.count)) : be32(UInt32(offset)) + be32(UInt32(slice.data.count))
        header += be32(12) + (wide ? be32(0) : Data())
        body += Data(count: offset - 4096 - body.count) + slice.data
        offset = 4096 + ((body.count + 4095) / 4096) * 4096
    }
    return header + Data(count: 4096 - header.count) + body
}

private let arm64: Int32 = 0x0100_000c

private func temporaryDirectory(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-bundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

final class AppBundleLaunchTests: XCTestCase {
    func testOpenDocumentsModeComesFromWinemacArguments() {
        var probed = false
        let mode = AppBundleLaunch.mode(arguments: ["/A/SOLIDWORKS", "--open-documents", "/Users/me/My Parts/a.sldprt", "/b.SLDASM"]) {
            probed = true
            return true
        }
        XCTAssertEqual(mode, .openDocuments([URL(fileURLWithPath: "/Users/me/My Parts/a.sldprt"),
                                             URL(fileURLWithPath: "/b.SLDASM")]))
        XCTAssertFalse(probed, "the helper never decides between launching and forwarding")
    }

    func testAppStartForwardsOnlyWhenSolidWorksAlreadyRuns() {
        XCTAssertEqual(AppBundleLaunch.mode(arguments: ["/A/SOLIDWORKS"]) { true }, .forward)
        XCTAssertEqual(AppBundleLaunch.mode(arguments: ["/A/SOLIDWORKS"]) { false }, .launch)
        XCTAssertEqual(AppBundleLaunch.mode(arguments: ["/A/SOLIDWORKS", "-psn_0_12345"]) { false }, .launch)
    }

    func testMacSWIsFoundByOverrideThenInfoPlistThenNextToTheAppThenApplications() {
        let app = URL(fileURLWithPath: "/Volumes/X/Apps/SOLIDWORKS.app")
        let applications = URL(fileURLWithPath: "/Applications")
        var valid: Set<String> = ["/Env/MacSW.app", "/Info/MacSW.app", "/Volumes/X/Apps/MacSW.app", "/Applications/MacSW.app"]
        func locate() -> String? {
            AppBundleLaunch.locateMacSW(appBundle: app, info: [AppBundleLaunch.hostAppInfoKey: "/Info/MacSW.app"],
                                        environment: [AppBundleLaunch.hostAppKey: "/Env/MacSW.app"],
                                        applications: applications,
                                        registered: { [URL(fileURLWithPath: "/Users/me/Applications/MacSW.app")] },
                                        isMacSW: { valid.contains($0.path) })?.path
        }
        XCTAssertEqual(locate(), "/Env/MacSW.app")
        valid.remove("/Env/MacSW.app")
        XCTAssertEqual(locate(), "/Info/MacSW.app")
        valid.remove("/Info/MacSW.app")
        XCTAssertEqual(locate(), "/Volumes/X/Apps/MacSW.app")
        valid.remove("/Volumes/X/Apps/MacSW.app")
        XCTAssertEqual(locate(), "/Applications/MacSW.app")
        valid = ["/Users/me/Applications/MacSW.app"]
        XCTAssertEqual(locate(), "/Users/me/Applications/MacSW.app", "a copy LaunchServices knows comes last")
        valid.removeAll()
        XCTAssertNil(locate())
    }

    func testOnlyAMacSWBundleWithAWineLoaderCounts() throws {
        let root = try temporaryDirectory(self)
        XCTAssertTrue(AppBundleLaunch.isMacSW(try makeFakeMacSW(in: root.appendingPathComponent("ok"))))
        XCTAssertFalse(AppBundleLaunch.isMacSW(try makeFakeMacSW(in: root.appendingPathComponent("other"), identifier: "com.example.other")))
        XCTAssertFalse(AppBundleLaunch.isMacSW(try makeFakeMacSW(in: root.appendingPathComponent("shell"), loader: false)))
        XCTAssertFalse(AppBundleLaunch.isMacSW(root.appendingPathComponent("missing/MacSW.app")))
    }

    func testDataDirectoryOverride() {
        XCTAssertEqual(AppBundleLaunch.appPaths(environment: [AppBundleLaunch.appSupportKey: "/tmp/macsw-demo"]).bottle.path,
                       "/tmp/macsw-demo/bottle")
    }

    func testRuntimePathsFollowTheMacSWBundle() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        XCTAssertEqual(original, Bundle.main.bundleURL)
        let app = try makeFakeMacSW(in: try temporaryDirectory(self))
        MacSWBundle.url = app
        XCTAssertEqual(WineService.shared.wineBinary.path,
                       app.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW").path)
        XCTAssertEqual(WineService.shared.environment(winePrefix: URL(fileURLWithPath: "/tmp/b"))["WINELOADER"],
                       WineService.shared.wineBinary.path)
    }

    func testExecPlanRunsTheLoaderSliceOfTheAppAsTheWineHost() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/Users/me/Library/Application Support/MacSW/bottle")
        let exe = prefix.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        let app = URL(fileURLWithPath: "/Applications/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS")
        let plan = wine.solidWorksExecPlan(executable: exe, prefix: prefix, arguments: [#"Z:\a.sldprt"#], appExecutable: app)

        XCTAssertEqual(plan.path, app.path, "the app's own (universal) executable is replaced by its x86_64 slice")
        XCTAssertEqual(plan.arguments, [wine.wineBinary.path, exe.path, #"Z:\a.sldprt"#],
                       "argv[0] names the runtime loader so the loader finds ntdll.so next to it")
        XCTAssertEqual(plan.directory, exe.deletingLastPathComponent().path)
        XCTAssertEqual(plan.log.path, "/Users/me/Library/Application Support/MacSW/logs/sw_launch.log")
        XCTAssertEqual(plan.environment[AppBundleLaunch.appBundleKey], "/Applications/SOLIDWORKS.app",
                       "winemac honours the switches only in the process whose main bundle is this path")
        XCTAssertEqual(plan.environment[AppBundleLaunch.openDocumentsHelperKey], app.path)
        XCTAssertNil(plan.environment[AppBundleLaunch.quitModeKey], "Quit keeps Wine's session end by default")
        let closing = wine.solidWorksExecPlan(executable: exe, prefix: prefix, arguments: [], appExecutable: app,
                                              quitClosesWindows: true)
        XCTAssertEqual(closing.environment[AppBundleLaunch.quitModeKey], "close")
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.path)
        // Same SOLIDWORKS environment as a MacSW launch.
        let launched = wine.environment(winePrefix: prefix, solidWorks: true)
        for key in ["WINELOADER", "WINESERVER", "WINEDLLOVERRIDES", "LANG", "WINE_MONO_AOT", "MACSW_CROSS_PROCESS_SURFACES"] {
            XCTAssertEqual(plan.environment[key], launched[key], key)
        }
    }

    /// The exec replaces SOLIDWORKS.app's process with exactly the plan's environment: the
    /// launcher's own environment (for example a shell's API keys) must not reach Wine.
    func testExecPlanDoesNotCopyTheLaunchersEnvironmentIntoWine() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let prefix = URL(fileURLWithPath: "/Users/me/Library/Application Support/MacSW/bottle")
        let exe = prefix.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        let app = URL(fileURLWithPath: "/Applications/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS")
        let parent = [
            "HOME": "/Users/me", "USER": "me", "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "OPENROUTER_API_KEY": "sk-or-secret", "CLAUDE_CODE_MESSAGING_TOKEN": "token-secret",
            "SSH_AUTH_SOCK": "/private/tmp/agent", "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            AppBundleLaunch.hostAppKey: "/Elsewhere/MacSW.app", AppBundleLaunch.appSupportKey: "/tmp/demo",
            AppBundleLaunch.launchDelayKey: "60", AppBundleLaunch.appBundleKey: "/Evil.app",
            AppBundleLaunch.quitModeKey: "close"
        ]
        let plan = WineService.shared.solidWorksExecPlan(executable: exe, prefix: prefix, arguments: [],
                                                         appExecutable: app, inherited: parent)
        XCTAssertEqual(plan.environment["HOME"], "/Users/me")
        XCTAssertEqual(plan.environment["USER"], "me")
        XCTAssertEqual(plan.environment["PATH"], WineService.sanitizedPath)
        for key in ["OPENROUTER_API_KEY", "CLAUDE_CODE_MESSAGING_TOKEN", "SSH_AUTH_SOCK", "DYLD_INSERT_LIBRARIES",
                    AppBundleLaunch.launchDelayKey] {
            XCTAssertNil(plan.environment[key], key)
        }
        // F6: the overrides reach the host, so its open-documents helper uses the same instance.
        XCTAssertEqual(plan.environment[AppBundleLaunch.hostAppKey], "/Elsewhere/MacSW.app")
        XCTAssertEqual(plan.environment[AppBundleLaunch.appSupportKey], "/tmp/demo")
        // The 0025 switches come from the plan only.
        XCTAssertEqual(plan.environment[AppBundleLaunch.appBundleKey], "/Applications/SOLIDWORKS.app")
        XCTAssertNil(plan.environment[AppBundleLaunch.quitModeKey])
        XCTAssertFalse(plan.environment.values.contains { $0.contains("secret") })
        // Without an explicit parent, the launcher's real environment goes through the same allowlist.
        setenv("MACSW_TEST_SECRET_TOKEN", "secret", 1)
        defer { unsetenv("MACSW_TEST_SECRET_TOKEN") }
        let live = WineService.shared.solidWorksExecPlan(executable: exe, prefix: prefix, arguments: [], appExecutable: app)
        XCTAssertNil(live.environment["MACSW_TEST_SECRET_TOKEN"])
        XCTAssertEqual(live.environment["PATH"], WineService.sanitizedPath)
    }

    /// Bughunt F6: patch 0025 starts the open-documents helper with the host's environment. Set
    /// overrides go to the host (the helper then uses the test instance's bottle); unset or empty
    /// ones stay absent (the owner's launch: the helper uses AppPaths.live()). The overrides never
    /// reach ordinary Wine processes.
    func testExecPlanPassesSetInstanceOverridesOnlyToTheHost() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let prefix = URL(fileURLWithPath: "/tmp/test-as/bottle")
        let exe = prefix.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        let app = URL(fileURLWithPath: "/tmp/test-app/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS")
        let keys = [AppBundleLaunch.appSupportKey, AppBundleLaunch.hostAppKey]
        let set = WineService.shared.solidWorksExecPlan(
            executable: exe, prefix: prefix, arguments: [], appExecutable: app,
            inherited: ["HOME": "/Users/me", AppBundleLaunch.appSupportKey: "/tmp/test-as",
                        AppBundleLaunch.hostAppKey: "/tmp/test-app/MacSW.app"])
        XCTAssertEqual(set.environment[AppBundleLaunch.appSupportKey], "/tmp/test-as")
        XCTAssertEqual(set.environment[AppBundleLaunch.hostAppKey], "/tmp/test-app/MacSW.app")
        for inherited in [["HOME": "/Users/me"], ["HOME": "/Users/me", AppBundleLaunch.appSupportKey: "",
                                                  AppBundleLaunch.hostAppKey: ""]] {
            let unset = WineService.shared.solidWorksExecPlan(executable: exe, prefix: prefix, arguments: [],
                                                              appExecutable: app, inherited: inherited)
            for key in keys { XCTAssertNil(unset.environment[key], key) }
        }
        for solidWorks in [false, true] {
            let env = WineService.shared.environment(
                winePrefix: prefix, solidWorks: solidWorks,
                inherited: [AppBundleLaunch.appSupportKey: "/tmp/test-as", AppBundleLaunch.hostAppKey: "/tmp/x.app"])
            for key in keys { XCTAssertNil(env[key], key) }
        }
    }

    func testBundleSwitchesNeverLeakIntoOrdinaryWineProcesses() {
        let keys = [AppBundleLaunch.appBundleKey, AppBundleLaunch.openDocumentsHelperKey, AppBundleLaunch.quitModeKey]
        for key in keys { setenv(key, "/tmp/x", 1) }
        defer { for key in keys { unsetenv(key) } }
        for solidWorks in [false, true] {
            let env = WineService.shared.environment(winePrefix: URL(fileURLWithPath: "/tmp/b"), solidWorks: solidWorks)
            for key in keys { XCTAssertNil(env[key], key) }
        }
    }

    /// The retry rule (`CoreInstallRetry`): SOLIDWORKS.app's first start ends a bottle's never-started
    /// state, before the exec and also when the exec then fails.
    func testExecEndsTheNeverStartedStateOfTheBottle() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        let root = try temporaryDirectory(self)
        let macSW = try makeFakeMacSW(in: root)
        try writeBuildManifest(into: macSW)
        MacSWBundle.url = macSW
        let bottle = root.appendingPathComponent("support/bottle")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        try CoreInstallRetry.markNewBottle(prefix: bottle)
        try CoreInstallRetry.markCoreInstallStarted(prefix: bottle)
        XCTAssertEqual(CoreInstallRetry.decision(prefix: bottle, receiptExists: false), .freshBottle)
        XCTAssertThrowsError(try WineService.shared.execSolidWorks(
            executable: bottle.appendingPathComponent("drive_c/SLDWORKS.exe"), prefix: bottle, arguments: [],
            appExecutable: URL(fileURLWithPath: "/Applications/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS"),
            quitClosesWindows: false) { _, _ in ENOENT })
        XCTAssertEqual(CoreInstallRetry.decision(prefix: bottle, receiptExists: false), .keepBottle)
    }

    func testExecIsRefusedAndNeverRunsForABottleInRecoveryOrUpgradeState() throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        let root = try temporaryDirectory(self)
        let macSW = try makeFakeMacSW(in: root)
        try writeBuildManifest(into: macSW)
        MacSWBundle.url = macSW
        let app = URL(fileURLWithPath: "/Applications/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS")
        var execs: [String] = []
        func exec(_ prefix: URL) throws -> Never {
            try WineService.shared.execSolidWorks(
                executable: prefix.appendingPathComponent("drive_c/SLDWORKS.exe"), prefix: prefix, arguments: [],
                appExecutable: app, quitClosesWindows: false) { plan, _ in
                    execs.append(plan.environment["WINEPREFIX"] ?? "")
                    return ENOENT
                }
        }
        let fm = FileManager.default

        // An unfinished migration (pending.json).
        let recovery = root.appendingPathComponent("recovery/bottle")
        try fm.createDirectory(at: WineRuntimeService.root(prefix: recovery), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: WineRuntimeService.root(prefix: recovery).appendingPathComponent("pending.json"))
        XCTAssertEqual(WineRuntimeService.status(prefix: recovery), .recovery)
        XCTAssertThrowsError(try exec(recovery))

        // A bottle recorded with another runtime identity.
        let upgrade = root.appendingPathComponent("upgrade/bottle")
        try fm.createDirectory(at: upgrade.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: WineRuntimeService.root(prefix: upgrade), withIntermediateDirectories: true)
        try Data("prefix-1\n".utf8).write(to: upgrade.appendingPathComponent(".macsw-wine-prefix-id"))
        let receipt: [String: Any] = ["format": 1, "prefix_id": "prefix-1", "identity": ["WineVersion": "older"]]
        try JSONSerialization.data(withJSONObject: receipt)
            .write(to: WineRuntimeService.root(prefix: upgrade).appendingPathComponent("receipt.json"))
        XCTAssertEqual(WineRuntimeService.status(prefix: upgrade), .upgrade)
        XCTAssertThrowsError(try exec(upgrade))
        XCTAssertEqual(execs, [], "the runtime gate runs before the exec")

        // A bottle MacSW does not manage starts; a failed exec is reported.
        let unmanaged = root.appendingPathComponent("unmanaged/bottle")
        XCTAssertEqual(WineRuntimeService.status(prefix: unmanaged), .unmanaged)
        XCTAssertThrowsError(try exec(unmanaged))
        XCTAssertEqual(execs, [unmanaged.path])
    }

    func testMachOUUIDOfTheRequestedSlice() {
        let a = UUID(), b = UUID()
        let loader = thinMachO(cpuType: AppBundleLaunch.cpuTypeX86_64, uuid: a)
        XCTAssertEqual(AppBundleLaunch.machOUUID(loader, cpuType: AppBundleLaunch.cpuTypeX86_64), a)
        XCTAssertNil(AppBundleLaunch.machOUUID(loader, cpuType: arm64), "a thin file of another architecture")
        for wide in [false, true] {
            let universal = fatMachO([(arm64, thinMachO(cpuType: arm64, uuid: b)),
                                      (AppBundleLaunch.cpuTypeX86_64, loader)], wide: wide)
            XCTAssertEqual(AppBundleLaunch.machOUUID(universal, cpuType: AppBundleLaunch.cpuTypeX86_64), a)
            XCTAssertEqual(AppBundleLaunch.machOUUID(universal, cpuType: arm64), b)
        }
        XCTAssertNil(AppBundleLaunch.machOUUID(fatMachO([(arm64, thinMachO(cpuType: arm64, uuid: b))]),
                                               cpuType: AppBundleLaunch.cpuTypeX86_64))
        XCTAssertNil(AppBundleLaunch.machOUUID(thinMachO(cpuType: AppBundleLaunch.cpuTypeX86_64, uuid: nil),
                                               cpuType: AppBundleLaunch.cpuTypeX86_64))
        XCTAssertNil(AppBundleLaunch.machOUUID(Data("#!/bin/sh\n".utf8), cpuType: AppBundleLaunch.cpuTypeX86_64))
        XCTAssertNil(AppBundleLaunch.machOUUID(loader.prefix(40), cpuType: AppBundleLaunch.cpuTypeX86_64))
    }

    func testAStaleLoaderSliceIsDetected() throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeFakeMacSW(in: root)
        let current = UUID()
        try thinMachO(cpuType: AppBundleLaunch.cpuTypeX86_64, uuid: current)
            .write(to: macSW.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW"))
        let app = root.appendingPathComponent("SOLIDWORKS")
        func build(_ uuid: UUID) throws {
            try fatMachO([(arm64, thinMachO(cpuType: arm64, uuid: UUID())),
                          (AppBundleLaunch.cpuTypeX86_64, thinMachO(cpuType: AppBundleLaunch.cpuTypeX86_64, uuid: uuid))])
                .write(to: app)
        }
        try build(current)
        XCTAssertEqual(AppBundleLaunch.loaderSliceMatches(appExecutable: app, macSW: macSW), true)
        try build(UUID())
        XCTAssertEqual(AppBundleLaunch.loaderSliceMatches(appExecutable: app, macSW: macSW), false)
        XCTAssertNil(AppBundleLaunch.loaderSliceMatches(appExecutable: root.appendingPathComponent("missing"), macSW: macSW))
    }

    func testFontLinkCheckRunsOncePerBottleAndRuntime() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeFakeMacSW(in: root)
        try writeBuildManifest(into: macSW)
        let prefix = root.appendingPathComponent("bottle")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let stamp = root.appendingPathComponent(".solidworks-app-fontlink")
        final class Count: @unchecked Sendable { var value = 0 }
        let runs = Count()
        let repair = AppBundleLaunch.stampedFontLinkRepair(stamp: stamp, macSW: macSW) { _ in runs.value += 1 }

        try await repair(prefix)
        try await repair(prefix)
        XCTAssertEqual(runs.value, 1, "checked once, then skipped while the stamp is current")
        try writeBuildManifest(into: macSW, loaderHash: "loader-2")
        try await repair(prefix)
        XCTAssertEqual(runs.value, 2, "a new runtime identity checks again")
        try Data("prefix-2".utf8).write(to: prefix.appendingPathComponent(".macsw-wine-prefix-id"))
        try await repair(prefix)
        XCTAssertEqual(runs.value, 3, "a new bottle checks again")

        let failing = AppBundleLaunch.stampedFontLinkRepair(stamp: stamp, macSW: macSW) { _ in
            runs.value += 1
            throw CocoaError(.fileWriteUnknown)
        }
        try writeBuildManifest(into: macSW, loaderHash: "loader-3")
        do { try await failing(prefix); XCTFail("the error reaches the launch") } catch {}
        try await repair(prefix)
        XCTAssertEqual(runs.value, 5, "a failed check leaves no stamp")

        let unstamped = AppBundleLaunch.stampedFontLinkRepair(stamp: stamp, macSW: root.appendingPathComponent("none")) { _ in
            runs.value += 1
        }
        try await unstamped(prefix)
        try await unstamped(prefix)
        XCTAssertEqual(runs.value, 7, "without a build identity the check always runs")
    }

    /// F4: a launch that ended without the exec because SOLIDWORKS runs, or because another start
    /// kept the start lock for the whole wait, goes to forward mode. Other ends show an alert.
    func testLauncherGoesToForwardModeWhenSolidWorksRunsOrTheStartLockStaysBusy() {
        XCTAssertTrue(AppBundleLaunch.endsInForwardMode(.running))
        XCTAssertTrue(AppBundleLaunch.endsInForwardMode(.failed(StartLock.busyMessage)))
        XCTAssertFalse(AppBundleLaunch.endsInForwardMode(.failed("exec failed (test)")))
        XCTAssertFalse(AppBundleLaunch.endsInForwardMode(.stopped))
        XCTAssertFalse(AppBundleLaunch.endsInForwardMode(.unavailable))
    }

    func testQuittingMacSWLeavesSolidWorksAppSessionsRunning() {
        let sw = WineProcess(name: "SLDWORKS.exe", pid: 42, residentKB: 1, elapsed: "00:05")
        let other = WineProcess(name: "sldworks_fs.exe", pid: 43, residentKB: 1, elapsed: "00:05")
        let app: (Int32) -> String? = { $0 == 42 ? AppBundleLaunch.solidWorksBundleIdentifier : nil }
        XCTAssertEqual(AppBundleLaunch.macSWQuitPlan(snapshot: [], bundleIdentifier: app), .stopBottleAndQuit)
        XCTAssertEqual(AppBundleLaunch.macSWQuitPlan(snapshot: [other], bundleIdentifier: app), .stopBottleAndQuit)
        XCTAssertEqual(AppBundleLaunch.macSWQuitPlan(snapshot: [sw, other], bundleIdentifier: app), .quitLeavingSolidWorks)
        XCTAssertEqual(AppBundleLaunch.macSWQuitPlan(snapshot: [sw, other], bundleIdentifier: { _ in nil }),
                       .confirmEndingSolidWorks, "SOLIDWORKS that MacSW started (no bundle record)")
        XCTAssertEqual(AppBundleLaunch.macSWQuitPlan(snapshot: [sw], bundleIdentifier: { _ in "com.yjbeetle.macsw.solidworks-demo" }),
                       .confirmEndingSolidWorks)
    }
}

@MainActor
final class RuntimeStarterTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _starts: [(URL, URL, [String])] = []
        private var _opened: [[URL]] = []
        var starts: [(URL, URL, [String])] { lock.lock(); defer { lock.unlock() }; return _starts }
        var opened: [[URL]] { lock.lock(); defer { lock.unlock() }; return _opened }
        func start(_ value: (URL, URL, [String])) { lock.lock(); _starts.append(value); lock.unlock() }
        func open(_ files: [URL]) { lock.lock(); _opened.append(files); lock.unlock() }
    }

    private func installedPaths() throws -> AppPaths {
        let paths = AppPaths(appSupportDirectory: try temporaryDirectory(self).appendingPathComponent("support"))
        let executable = paths.solidWorksExecutable
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        AppPaths.invalidateInstallationState()
        return paths
    }

    func testLaunchHandsTheStartToTheInjectedStarterAfterThePreflight() async throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let paths = try installedPaths()
        let box = Box()
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [] },
            bottleGate: { _, _ in .init() },
            driveMaps: { _, _ in },
            solidWorksStarter: { executable, prefix, arguments, _, completion in
                box.start((executable, prefix, arguments))
                completion(false, "exec failed (test)")
            })
        store.launch()
        for _ in 0..<300 where store.state == .starting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(box.starts.count, 1)
        XCTAssertEqual(box.starts.first?.0, paths.solidWorksExecutable)
        XCTAssertEqual(box.starts.first?.1, paths.bottle)
        XCTAssertEqual(box.starts.first?.2, [])
        XCTAssertEqual(store.state, .failed("exec failed (test)"))
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
        func set() { lock.lock(); _value = true; lock.unlock() }
    }

    private func isHeld(_ prefix: URL) -> Bool {
        switch StartLock.acquire(prefix: prefix, timeout: 0) {
        case .acquired(let lock): lock.release(); return false
        case .busy: return true
        case .unavailable(let reason): XCTFail("start lock unavailable: \(reason)"); return false
        }
    }

    /// F4: the bottle's start lock is held from the last process check through the start, and
    /// released once the starter reports the host process (MacSW: after Process.run()).
    func testLaunchHoldsTheStartLockUntilTheHostProcessExists() async throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let paths = try installedPaths()
        let box = Box()
        var heldDuringStart: Bool?
        var heldAfterStart: Bool?
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [] },
            bottleGate: { _, _ in .init() },
            driveMaps: { _, _ in },
            solidWorksStarter: { executable, prefix, arguments, onStarted, completion in
                box.start((executable, prefix, arguments))
                heldDuringStart = self.isHeld(prefix)
                onStarted()
                heldAfterStart = self.isHeld(prefix)
                completion(false, "exited (test)")
            })
        store.launch()
        for _ in 0..<300 where store.state == .starting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(box.starts.count, 1)
        XCTAssertEqual(heldDuringStart, true, "a second launcher waits while this one starts")
        XCTAssertEqual(heldAfterStart, false, "released once the host process exists")
        XCTAssertFalse(isHeld(paths.bottle))
    }

    /// F4: another start keeps the lock for the whole wait: no start, forward mode.
    func testLaunchWithABusyStartLockNeverStarts() async throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let paths = try installedPaths()
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [] },
            bottleGate: { _, _ in .init() },
            driveMaps: { _, _ in },
            startLocker: { _ in .busy },
            solidWorksStarter: { _, _, _, _, _ in XCTFail("a busy start lock must not start SOLIDWORKS") })
        store.launch()
        for _ in 0..<300 where store.state == .starting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.state, .failed(StartLock.busyMessage))
        XCTAssertTrue(AppBundleLaunch.endsInForwardMode(store.state))
    }

    /// F4: the start that held the lock before made SOLIDWORKS run; the check under the lock sees
    /// it, nothing starts, and the lock is free again.
    func testLaunchSeesTheHostThatStartedBeforeItGotTheStartLock() async throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        MacSWBundle.url = try makeFakeMacSW(in: try temporaryDirectory(self))
        let paths = try installedPaths()
        let locked = Flag()
        let host = WineProcess(name: "SLDWORKS.exe", pid: 4242, residentKB: 1, elapsed: "00:01")
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in locked.value ? [host] : [] },
            bottleGate: { _, _ in .init() },
            driveMaps: { _, _ in },
            startLocker: { prefix in
                let outcome = StartLock.acquire(prefix: prefix, timeout: 1)
                locked.set()
                return outcome
            },
            solidWorksStarter: { _, _, _, _, _ in XCTFail("SOLIDWORKS already runs: no second start") })
        store.launch()
        for _ in 0..<300 where store.state == .starting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.state, .running)
        XCTAssertTrue(AppBundleLaunch.endsInForwardMode(store.state))
        XCTAssertFalse(isHeld(paths.bottle))
    }

    /// After SOLIDWORKS crashed (its process exited non-zero and is gone), a Dock click or
    /// `open -a MacSW` starts it again: no "running"/"starting" state, launch lock or
    /// `WineService` active-prefix entry is left behind. Runs the real `launchSolidWorks`
    /// with a stand-in loader that exits like the crashed SLDWORKS.exe.
    func testDockReopenAfterACrashStartsSolidWorksAgain() async throws {
        let original = MacSWBundle.url
        defer { MacSWBundle.url = original }
        let root = try temporaryDirectory(self)
        MacSWBundle.url = try makeFakeMacSW(in: root)
        let runs = root.appendingPathComponent("runs.log")
        try "#!/bin/sh\necho run >> '\(runs.path)'\nexit 5\n"
            .write(to: WineService.shared.wineBinary, atomically: true, encoding: .utf8)
        let paths = try installedPaths()
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [] },
            bottleGate: { _, _ in .init() },
            driveMaps: { _, _ in })
        func runCount() -> Int {
            ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
        func waitForExit(_ count: Int) async throws {
            for _ in 0..<500 where runCount() < count || store.state == .starting || store.state == .running {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        store.launch()
        try await waitForExit(1)
        XCTAssertEqual(runCount(), 1)
        XCTAssertEqual(store.state, .failed("SOLIDWORKS has exited (5)."))
        XCTAssertFalse(WineService.shared.isRunning(prefix: paths.bottle), "the active-prefix entry is cleared")

        await store.handleDockReopen { _ in XCTFail("nothing is running to bring forward"); return false }
        try await waitForExit(2)
        XCTAssertEqual(runCount(), 2, "the reopen started SOLIDWORKS again")
        XCTAssertEqual(store.state, .failed("SOLIDWORKS has exited (5)."))
    }

    func testHandOffGoesToTheRunningInstanceAndNeverStartsSolidWorks() async throws {
        let paths = try installedPaths()
        let box = Box()
        let part = paths.appSupportDirectory.appendingPathComponent("a.sldprt")
        try Data("x".utf8).write(to: part)
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            processSnapshot: { _, _ in [WineProcess(name: "SLDWORKS.exe", pid: 42, residentKB: 1, elapsed: "00:05")] },
            windowSnapshot: { _ in [HostWindow(ownerPID: 42, layer: 0, width: 1600, height: 900)] },
            documentOpener: { _, files in box.open(files) },
            handOffPollInterval: 0.02,
            solidWorksStarter: { _, _, _, _, _ in XCTFail("a document hand-off must not start SOLIDWORKS") })
        await store.handOff(documents: [part, paths.appSupportDirectory.appendingPathComponent("notes.txt")])
        XCTAssertEqual(box.opened.map { $0.map(\.lastPathComponent) }, [["a.sldprt"]])
        await store.handOff(documents: [paths.appSupportDirectory.appendingPathComponent("notes.txt")])
        XCTAssertEqual(box.opened.count, 1, "nothing SOLIDWORKS can open: nothing to hand over")
        XCTAssertTrue(box.starts.isEmpty)
    }
}
