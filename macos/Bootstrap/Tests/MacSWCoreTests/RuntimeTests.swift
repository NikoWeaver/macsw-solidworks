import Foundation
import XCTest
@testable import MacSWCore

final class RuntimeTests: XCTestCase {
    func testEnvironmentIsolationKeepsHostOutOfWineEnvironment() throws {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let env = wine.environment(winePrefix: prefix, solidWorks: true)

        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
        let localeEnv = wine.environment(winePrefix: prefix, locale: "en_US.UTF-8")
        XCTAssertEqual(localeEnv["LANG"], "en_US.UTF-8")
        XCTAssertEqual(localeEnv["LC_ALL"], "en_US.UTF-8")
        let chineseEnv = wine.environment(winePrefix: prefix, locale: "zh_CN.UTF-8")
        XCTAssertEqual(chineseEnv["LANG"], "zh_CN.UTF-8")
        XCTAssertEqual(chineseEnv["LC_ALL"], "zh_CN.UTF-8")
        XCTAssertTrue(env["WINELOADER"]?.hasSuffix("/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW") == true)
        XCTAssertTrue(env["WINESERVER"]?.hasSuffix("/Contents/Frameworks/wine/bin/wineserver") == true)
        for key in [
            "CX_ROOT", "CX_BOTTLE", "WINEDLLPATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
            "MONO_ENV_OPTIONS", "MACSW_WINELOADER", "MACSW_APP_NAME"
        ] {
            XCTAssertNil(env[key], "Inherited environment leaked: \(key)")
        }

        let overrides = try XCTUnwrap(env["WINEDLLOVERRIDES"])
        XCTAssertTrue(overrides.contains("concrt140=n,b"))
        XCTAssertTrue(overrides.contains("atiadlxx=d"))
        XCTAssertFalse(overrides.contains("mscoree"))
        XCTAssertFalse(overrides.contains("d3d11"))
        XCTAssertNil(wine.environment(winePrefix: prefix)["WINEDLLOVERRIDES"])
        XCTAssertEqual(env["MACSW_CROSS_PROCESS_SURFACES"], "1")
        XCTAssertNil(wine.environment(winePrefix: prefix)["MACSW_CROSS_PROCESS_SURFACES"])
        for key in ["MACSW_WIC_COMPONENT_CACHE", "MACSW_LOCAL_MODULE_READS"] {
            XCTAssertEqual(env[key], "1", key)
            XCTAssertNil(wine.environment(winePrefix: prefix)[key], key)
        }
        XCTAssertEqual(PrerequisiteService.themes.count, 5)
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(0))
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(194))
        XCTAssertTrue(WineService.isSuccessfulCleanupStop(killStatus: 1, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 2, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 0, waitStatus: 1))

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/macsw-test")
        XCTAssertThrowsError(try wine.run(missing))
    }

    /// Settings > "Use macOS file dialogs" reaches SOLIDWORKS only, and only through this variable.
    func testMacFileDialogsSettingSetsTheNativeFileDialogGateForSolidWorksOnly() {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let key = "MACSW_NATIVE_FILE_DIALOGS"

        XCTAssertEqual(wine.environment(winePrefix: prefix, solidWorks: true, macFileDialogs: true,
                                        macFileDialogsEverywhere: false)[key], "1")
        XCTAssertEqual(wine.environment(winePrefix: prefix, solidWorks: true, macFileDialogs: true,
                                        macFileDialogsEverywhere: true)[key], "all")
        XCTAssertNil(wine.environment(winePrefix: prefix, solidWorks: true, macFileDialogs: false,
                                      macFileDialogsEverywhere: true)[key])
        // Default (settings never touched): the Mac panel everywhere, File > Open included.
        if UserDefaults.standard.object(forKey: AppPreferences.useMacFileDialogsKey) == nil,
           UserDefaults.standard.object(forKey: AppPreferences.macFileDialogsEverywhereKey) == nil {
            XCTAssertEqual(wine.environment(winePrefix: prefix, solidWorks: true)[key], "all")
        }
        XCTAssertNil(wine.environment(winePrefix: prefix, solidWorks: true, macFileDialogs: false)[key])
        // Installers and tools keep the Wine dialogs.
        XCTAssertNil(wine.environment(winePrefix: prefix, solidWorks: false, macFileDialogs: true)[key])
        // The test hooks never reach a real launch, even if the host shell has them set.
        setenv("MACSW_NATIVE_FILE_DIALOG_TEST", "cancel", 1)
        setenv(key, "1", 1)
        defer {
            unsetenv("MACSW_NATIVE_FILE_DIALOG_TEST")
            unsetenv(key)
        }
        let env = wine.environment(winePrefix: prefix, solidWorks: true, macFileDialogs: false)
        XCTAssertNil(env[key])
        XCTAssertNil(env["MACSW_NATIVE_FILE_DIALOG_TEST"])
        XCTAssertNil(wine.environment(winePrefix: prefix)[key])
    }

    /// Wine copies its Unix environment into every Windows process: only the allowlist of
    /// `WineService.inheritedEnvironmentKeys` (plus LANG/LC_*) comes from the caller.
    func testWineEnvironmentKeepsOnlyAllowlistedVariablesOfAPollutedParent() {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let kept = [
            "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/x/T/",
            "TZ": "Europe/Copenhagen", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0", "LC_CTYPE": "UTF-8",
            "WINEMSYNC": "0", "WINEMSYNC_QLIMIT": "64", "MACSW_OPENGL_RENDERER": "software",
            "WINE_SOLIDWORKS_STARTUP_TIMEOUT": "90", "MACSW_WINE_LOCALE": "en_US.UTF-8", "MACSW_GL_BATCH": "0",
            "MACSW_GL_MPENGINE": "0"
        ]
        let dropped = [
            "OPENROUTER_API_KEY": "sk-or-secret", "ANTHROPIC_API_KEY": "sk-ant-secret",
            "CLAUDE_CODE_MESSAGING_TOKEN": "token-secret", "CLAUDE_CODE_USER_EMAIL": "me@example.com",
            "GITHUB_TOKEN": "ghp_secret", "AWS_SECRET_ACCESS_KEY": "aws-secret", "SSH_AUTH_SOCK": "/private/tmp/agent",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib", "DYLD_LIBRARY_PATH": "/tmp", "WINEDLLPATH": "/tmp/dlls",
            "MONO_ENV_OPTIONS": "--debug", "CX_ROOT": "/tmp/cx", "MACSW_WINELOADER": "/tmp/wine",
            "MACSW_NATIVE_FILE_DIALOG_TEST": "cancel", "MACSW_APP_BUNDLE": "/tmp/x.app",
            "MACSW_OPEN_DOCUMENTS_HELPER": "/tmp/helper", "MACSW_APP_QUIT": "close", "MACSW_HOST_APP": "/tmp/MacSW.app",
            "XPC_SERVICE_NAME": "application.com.example", "TERM_PROGRAM": "iTerm.app", "OLDPWD": "/Users/me/src"
        ]
        let overridden = ["PATH": "/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin:/bin", "LANG": "de_DE.UTF-8",
                          "WINEDEBUG": "+relay", "WINEDLLOVERRIDES": "ntdll=n", "WINEPREFIX": "/tmp/other",
                          "MACSW_NATIVE_FILE_DIALOGS": "1", "MACSW_CROSS_PROCESS_SURFACES": "1",
                          "MACSW_WIC_COMPONENT_CACHE": "1", "MACSW_LOCAL_MODULE_READS": "1"]
        let parent = kept.merging(dropped) { a, _ in a }.merging(overridden) { a, _ in a }
        for solidWorks in [false, true] {
            let env = wine.environment(winePrefix: prefix, solidWorks: solidWorks, locale: "en_US.UTF-8",
                                       macFileDialogs: false, inherited: parent)
            for (key, value) in kept { XCTAssertEqual(env[key], value, key) }
            for key in dropped.keys { XCTAssertNil(env[key], key) }
            XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
            XCTAssertEqual(env["LANG"], "en_US.UTF-8")
            XCTAssertEqual(env["LC_ALL"], "en_US.UTF-8")
            XCTAssertEqual(env["WINEDEBUG"], "-all")
            XCTAssertEqual(env["WINEPREFIX"], prefix.path)
            XCTAssertNil(env["MACSW_NATIVE_FILE_DIALOGS"], "the setting is off in this call")
            XCTAssertNotEqual(env["WINEDLLOVERRIDES"], "ntdll=n")
            XCTAssertEqual(env["MACSW_CROSS_PROCESS_SURFACES"], solidWorks ? "1" : nil)
            // Patches 0032/0033: set by MacSW for SOLIDWORKS only, never inherited from the parent.
            for key in WineService.startupCacheKeys { XCTAssertEqual(env[key], solidWorks ? "1" : nil, key) }
            XCTAssertFalse(env.values.contains { $0.contains("secret") || $0.contains("@example.com") })
            let macSWKeys = Set(["PATH", "LANG", "LC_ALL", "WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDEBUG",
                                 "WINE_MONO_AOT", "MACSW_CROSS_PROCESS_SURFACES", "WINEDLLOVERRIDES"]
                                + WineService.startupCacheKeys)
            let unexpected = Set(env.keys).subtracting(macSWKeys).subtracting(kept.keys)
            XCTAssertTrue(unexpected.isEmpty, "unexpected keys: \(unexpected.sorted())")
        }
        // The default reads the real process environment through the same allowlist.
        setenv("MACSW_TEST_SECRET_TOKEN", "secret", 1)
        defer { unsetenv("MACSW_TEST_SECRET_TOKEN") }
        XCTAssertNil(wine.environment(winePrefix: prefix)["MACSW_TEST_SECRET_TOKEN"])
        XCTAssertEqual(wine.environment(winePrefix: prefix)["PATH"], WineService.sanitizedPath)
    }

    func testCommandPromptTerminalCommandQuotesTheBottlePath() {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let command = wine.commandPromptTerminalCommand(prefix: prefix)

        XCTAssertTrue(command.hasPrefix("env WINEPREFIX='/tmp/MacSW test'\\''s bottle' "))
        XCTAssertTrue(command.contains("WINELOADER='\(wine.wineBinary.path)'"))
        XCTAssertTrue(command.contains("WINESERVER='\(wine.wineServerBinary.path)'"))
        XCTAssertTrue(command.hasSuffix(" 'C:\\windows\\system32\\cmd.exe'"))
        // The bundled Python must not write bytecode into the signed App.
        XCTAssertTrue(command.contains(" -I -B "))
    }

    func testKnownWineToolsUseExplicitWindowsPathsWithoutChangingExternalExecutables() {
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["reg", "query", "HKCU\\Software"]),
            [#"C:\windows\system32\reg.exe"#, "query", "HKCU\\Software"]
        )
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["MSIEXEC", "/i", "installer.msi"]),
            [#"C:\windows\system32\msiexec.exe"#, "/i", "installer.msi"]
        )
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["/media/VC_redist.x64.exe", "/quiet"]),
            ["/media/VC_redist.x64.exe", "/quiet"]
        )
        XCTAssertEqual(WineService.resolvingSystemTool(in: []), [])
    }

    func testCancellableProcessIsTerminatedPromptly() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let task = Task { try await WineService.shared.runCancellable(process) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled process unexpectedly completed successfully")
        } catch is CancellationError {
            XCTAssertFalse(process.isRunning)
        }
    }

    func testInstallerLogPathUsesActualWineMappingAndRejectsAmbiguousOutput() {
        XCTAssertEqual(WineService.parsedWindowsPath("H:\\logs with spaces\\vc.log\r\n"),
                       #"H:\logs with spaces\vc.log"#)
        XCTAssertEqual(WineService.resolvingSystemTool(in: ["winepath", "-w", "/tmp/vc.log"]),
                       [#"C:\windows\system32\winepath.exe"#, "-w", "/tmp/vc.log"])
        for invalid in ["", "/tmp/vc.log", "vc.log", "H:vc.log", "H:\\vc.log\nwarning",
                        "H:\\bad\u{FFFD}.log", "H:\\bad\0.log"] {
            XCTAssertNil(WineService.parsedWindowsPath(invalid))
        }
        XCTAssertFalse(WineService.isSuccessfulPrerequisiteStatus(86), "1622 日志打开失败不能视为成功")
    }

    /// 已取消的任务里再调取消安全包装会直接抛错，所以"取消后收尾"不能就地跑。
    func testCancelledScopeRefusesToStartNewProcesses() async {
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            do {
                _ = try await WineService.shared.runCancellable(Process())
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
    }

    /// `Task.detached` 不继承取消，这就是清理安装进程时用的逃生通道。
    func testDetachedTaskSurvivesParentCancellation() async {
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000)
                return !Task.isCancelled
            }.value
        }
        task.cancel()
        let survived = await task.value
        XCTAssertTrue(survived)
    }

    /// 轮询观测要与用户意图合并，不能反向覆盖。
    func testPollingNeverOverridesUserIntent() {
        let failed = SolidWorksRuntimeState.failed("启动失败")
        XCTAssertEqual(SolidWorksRuntimeState.starting.applying(observedRunning: false, installed: true), .starting)
        XCTAssertEqual(SolidWorksRuntimeState.starting.applying(observedRunning: true, installed: true), .running)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: true, installed: true), .stopping)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: false, installed: true), .stopped)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: false, installed: false), .unavailable)
        XCTAssertEqual(failed.applying(observedRunning: false, installed: true), failed)
        XCTAssertEqual(failed.applying(observedRunning: true, installed: true), .running)
        // 没有意图的状态一律以观测为准。
        XCTAssertEqual(SolidWorksRuntimeState.unknown.applying(observedRunning: false, installed: true), .stopped)
        XCTAssertEqual(SolidWorksRuntimeState.running.applying(observedRunning: false, installed: false), .unavailable)
    }

    /// 进程状态只有退出码的低 8 位：3010 = 0xBC2 → 194，1638 = 0x666 → 102。
    /// 两边都归一之后再比，列表里写四位码还是写截断值都不会漏判。
    func testInstallerStatusesCompareTheLowEightBits() {
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(0))
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(194), "3010 需要重启")
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(102), "1638 另一个安装进行中")
        XCTAssertTrue(WineService.isSuccessfulInstallerStatus(194))
        XCTAssertFalse(WineService.isSuccessfulInstallerStatus(67))
        XCTAssertTrue(WineService.isCancelledInstallerStatus(66), "1602 用户取消")
        XCTAssertTrue(WineService.isCancelledInstallerStatus(15), "SIGTERM")
        XCTAssertFalse(WineService.isCancelledInstallerStatus(16))
    }

    func testMSIReturnCodeComesFromTheVerboseLog() {
        let log = """
        Action ended 22:20:18: InstallFinalPackage. Return value 3.
        MSI (s) (CC:2C) [12:34:56:789]: MainEngineThread is returning 1603
        """
        XCTAssertEqual(InstallerDiagnostics.msiReturnCode(log), 1603)
        XCTAssertNil(InstallerDiagnostics.msiReturnCode("Action ended. Return value 1."))
    }

    /// 日志是追加写的，不设上限就会一直长到几 MB。
    func testOversizedLogIsRestartedBeforeAppending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("wineboot.log")
        try Data(repeating: 0x41, count: Int(WineService.maximumLogBytes) + 1).write(to: log)
        let handle = try XCTUnwrap(WineService.shared.logHandle(for: log))
        XCTAssertEqual(try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, 0)
        try? handle.close()

        let fresh = directory.appendingPathComponent("fresh.log")
        XCTAssertNotNil(try WineService.shared.logHandle(for: fresh))
        XCTAssertNil(try WineService.shared.logHandle(for: nil))
    }

    func testStopCommandsCoverTheWholeProcessFamily() {
        XCTAssertEqual(
            WineService.taskkillArguments(force: false),
            ["taskkill", "/im", "SLDWORKS.exe", "/im", "sldworks_fs.exe"]
        )
        XCTAssertEqual(WineService.taskkillArguments(force: true).prefix(2), ["taskkill", "/f"])
    }

    func testCapturedOutputSurvivesNonUTF8LocaleBytes() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'InprocServer32    REG_SZ    \\304\\253\\277\\275mscoree.dll\\n'"]
        let (status, output) = try await WineService.shared.captureCancellable(process)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains("mscoree.dll"), "实际捕获: \(output.debugDescription)")
    }
}
