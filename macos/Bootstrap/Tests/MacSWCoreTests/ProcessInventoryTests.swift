import Foundation
import XCTest
@testable import MacSWCore

final class ProcessInventoryTests: XCTestCase {
    private static let bottle = "/Users/dev/Library/Application Support/MacSW/bottle"
    private static let wineRuntime = "/Applications/MacSW.app/Contents/Frameworks/wine"
    private static let sample = """
      PID    RSS ELAPSED COMMAND
      8239 114688   01:23:45 /Applications/MacSW.app/Contents/Frameworks/wine/bin/wineserver -w
      8241 192937984 01:23:40 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe
      8244 200704   01:23:30 C:\\Program Files\\SOLIDWORKS\\sldworks_fs.exe
      8250   13112  00:10:00 C:\\windows\\system32\\notepad.exe \(bottle)/drive_c/users/dev/notes.txt
      8260    4096  00:00:02 \(wineRuntime)/bin/wineloader \(wineRuntime)/bin/wine reg import C:\\windows\\temp\\MacSW-316C1F25.reg
      51708  98304  02:00:00 /Applications/MacSW.app/Contents/MacOS/MacSW
      51709  12345  02:00:00 /usr/sbin/httpserver
      """

    private func parsed() -> [WineProcess] {
        ProcessInventory.parse(Self.sample, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime)
    }

    /// A sibling bottle whose path starts with ours (bottle-t1) is not our container.
    func testSiblingBottleWithSamePrefixIsNotOurs() {
        let sibling = "  9000 100 00:01:00 \(Self.bottle)-t1/drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"
        XCTAssertTrue(ProcessInventory.parse(sibling, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime).isEmpty)
        let ours = "  9001 100 00:01:00 \(Self.bottle)/drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"
        XCTAssertEqual(ProcessInventory.parse(ours, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime).map(\.pid), [9001])
    }

    func testListsEveryContainerProcessIncludingHelpers() {
        XCTAssertEqual(Set(parsed().map(\.name)), [
            "wineserver", "SLDWORKS.exe", "sldworks_fs.exe", "notepad.exe"
        ])
        XCTAssertFalse(parsed().contains { $0.name == "MacSW" })
        XCTAssertFalse(parsed().contains { $0.name == "httpserver" })
        // wine / wineloader 这些宿主侧命令行工具不该出现在容器表里
        XCTAssertFalse(parsed().contains { $0.name.contains("wineloader") || $0.name.contains(".reg") })
    }

    func testFindsOrphanedWineProcessFromAnOlderAppBuildAfterWineserverExit() {
        let output = """
          5212 1024  09:59:13 C:\\windows\\system32\\notepad.exe \(Self.bottle)/drive_c/users/dev/notes.txt
        """
        let processes = ProcessInventory.parse(
            output,
            bottlePath: Self.bottle,
            wineRuntimePath: "/Applications/New-MacSW.app/Contents/Frameworks/wine"
        )
        XCTAssertEqual(processes.map(\.pid), [5212], "An orphaned Wine process must block bottle deletion even without wineserver")
        XCTAssertEqual(processes.first?.name, "notepad.exe")
    }

    func testSortedByResidentMemoryWithSolidWorksFirst() {
        let processes = parsed()
        XCTAssertEqual(processes.first?.name, "SLDWORKS.exe")
        XCTAssertEqual(processes.first?.pid, 8241)
        XCTAssertEqual(processes.map(\.residentMB), processes.map(\.residentMB).sorted(by: >))
    }

    func testTotalsAndRunningState() {
        let processes = parsed()
        XCTAssertTrue(ProcessInventory.isSolidWorksRunning(processes))
        XCTAssertFalse(ProcessInventory.isSolidWorksRunning(
            ProcessInventory.parse("  1 200 00:10:00 C:\\windows\\system32\\notepad.exe", bottlePath: "", wineRuntimePath: "")
        ))
    }

    func testHiddenCOMHostIsDetectedRegardlessOfExecutableCase() {
        for name in ["sldworks.exe", "SldWorks.exe", "SLDWORKS.exe"] {
            let output = "  4452 23232 00:20:36 C:\\Program Files\\SOLIDWORKS\\\(name) -Embedding"
            let candidates = ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime)
            XCTAssertEqual(candidates.map(\.pid), [4452], "候选漏检就无法继续读取 WINEPREFIX")
            XCTAssertEqual(candidates.first?.name, name)
            XCTAssertTrue(ProcessInventory.isSolidWorksRunning(candidates))
            XCTAssertTrue(ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime,
                processPrefixes: [4452: "/private/tmp/other/bottle"]).isEmpty)
        }
    }

    /// 合计必须从 KB 换算：逐行向上取整会把两个 600 KB 报成 2 MB。
    func testTotalRoundsOnceInsteadOfPerRow() {
        let small = [
            WineProcess(name: "a.exe", pid: 1, residentKB: 600, elapsed: "00:00:01"),
            WineProcess(name: "b.exe", pid: 2, residentKB: 600, elapsed: "00:00:01")
        ]
        XCTAssertEqual(small.map(\.residentMB), [1, 1])
        XCTAssertEqual(ProcessInventory.totalResidentMB(small), 1)
    }

    /// 容器与 App 都可能装在带空格的路径里，宿主侧 wine 工具仍要认出来。
    func testHostWineToolsAreFilteredEvenWithSpacesInTheRuntimePath() {
        let runtime = "/Applications/My App/wine"
        let command = "  7 100 00:00:01 \(runtime)/bin/wineloader \(runtime)/bin/wine reg import C:\\windows\\temp\\x.reg"
        XCTAssertTrue(ProcessInventory.parse(command, bottlePath: "", wineRuntimePath: runtime).isEmpty)
        XCTAssertEqual(
            ProcessInventory.parse(
                "  8 100 00:00:01 \(runtime)/bin/wineserver -w", bottlePath: "", wineRuntimePath: runtime
            ).map(\.name),
            ["wineserver"]
        )
    }

    func testDisplayNameSurvivesSpacesInWindowsPaths() {
        XCTAssertEqual(
            ProcessInventory.parse(
                "  1 200 00:10:00 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe",
                bottlePath: "", wineRuntimePath: ""
            ).map(\.name),
            ["SLDWORKS.exe"]
        )
        XCTAssertTrue(ProcessInventory.parse("garbage header", bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime).isEmpty)
    }

    func testActualPrefixSeparatesIdenticalSolidWorksCommands() {
        let output = """
          10 1000 00:00:01 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe
          11 1000 00:00:01 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe
          12 1000 00:00:01 C:\\Program Files\\SOLIDWORKS\\sldworks_fs.exe
        """
        let result = ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime,
            processPrefixes: [10: Self.bottle, 11: "/private/tmp/isolated/bottle", 12: "/private/tmp/isolated/bottle"])
        XCTAssertEqual(result.map(\.pid), [10])
    }

    func testForeignPrefixOverridesSharedRuntimeAndArgumentPathHints() {
        let output = """
          10 1000 00:00:01 \(Self.wineRuntime)/bin/wineserver
          11 1000 00:00:01 C:\\windows\\system32\\notepad.exe \(Self.bottle)/drive_c/shared.txt
        """
        XCTAssertTrue(ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime,
            processPrefixes: [10: "/tmp/other", 11: "/tmp/other"]).isEmpty)
    }

    func testUnreadableEnvironmentKeepsConservativeDeletionGuard() {
        let output = "  10 1000 00:00:01 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe"
        XCTAssertEqual(ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime,
            processPrefixes: [:]).map(\.pid), [10])
    }

    func testPrefixPathAliasesAndTrailingSlashMatch() {
        let output = "  10 1000 00:00:01 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe"
        XCTAssertEqual(ProcessInventory.parse(output, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime,
            processPrefixes: [10: Self.bottle + "/./"]).map(\.pid), [10])
    }

    private func procArguments(argv: [String], environment: [String], argumentPadding: Int = 0) -> Data {
        var argc = Int32(argv.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(contentsOf: Array("/some runtime/wine".utf8) + [0, 0, 0])
        for entry in argv { data.append(contentsOf: Array(entry.utf8) + [0]) }
        data.append(contentsOf: [UInt8](repeating: 0, count: argumentPadding))
        for entry in environment { data.append(contentsOf: Array(entry.utf8) + [0]) }
        data.append(0)
        return data
    }

    func testProcArgumentsSkipsExecutablePaddingAndExactArgumentCount() {
        let data = procArguments(argv: ["SLDWORKS.exe", "", "WINEPREFIX=/argument-not-environment"],
            environment: ["OTHER=WINEPREFIX=/not-a-key", "WINEPREFIX=" + Self.bottle, "SECRET=not-exposed"])
        XCTAssertEqual(ProcessInventory.winePrefix(from: data), Self.bottle)
    }

    func testProcArgumentsRejectsMissingRelativeAndTruncatedPrefixes() {
        XCTAssertNil(ProcessInventory.winePrefix(from: Data([1, 2, 3])))
        for environment in [[], ["OTHER=WINEPREFIX=/not-a-key"], ["WINEPREFIX=relative"], ["WINEPREFIX="]] {
            XCTAssertNil(ProcessInventory.winePrefix(from: procArguments(argv: ["wine"], environment: environment)))
        }
        let truncated = procArguments(argv: ["wine"], environment: ["WINEPREFIX=/tmp/test"]).dropLast(2)
        XCTAssertNil(ProcessInventory.winePrefix(from: Data(truncated)))
        XCTAssertNil(ProcessInventory.winePrefix(pid: -1))
    }

    func testProcArgumentsHandlesWineRewrittenArgumentPadding() {
        let data = procArguments(argv: ["SLDWORKS.exe", ""],
            environment: ["OTHER=ignored", "WINEPREFIX=" + Self.bottle], argumentPadding: 256)
        XCTAssertEqual(ProcessInventory.winePrefix(from: data), Self.bottle)
    }

    func testLiveSnapshotSeparatesSameNamedProcessesWithoutCreatingWineContainers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-process-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("sldworks.exe")
        // Apple 系统程序可能隐藏环境或需要 platform 签名；使用真正的普通客户进程。
        let source = directory.appendingPathComponent("probe.c")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", source.path, "-o", executable.path]
        compiler.standardOutput = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        let own = "/private/tmp/MacSW-process-owner-\(UUID().uuidString)/bottle with spaces"
        let foreign = "/private/tmp/MacSW-process-foreign-\(UUID().uuidString)/bottle"
        func start(_ prefix: String) throws -> Process {
            let process = Process()
            process.executableURL = executable
            process.arguments = []
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        let primary = try start(own)
        defer { if primary.isRunning { primary.terminate() }; primary.waitUntilExit() }
        let other = try start(foreign)
        defer { if other.isRunning { other.terminate() }; other.waitUntilExit() }
        // Process.run 返回时子进程可能尚未就绪，等待真实环境可读。
        for _ in 0..<50 {
            if ProcessInventory.winePrefix(pid: primary.processIdentifier) == own,
               ProcessInventory.winePrefix(pid: other.processIdentifier) == foreign { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ProcessInventory.winePrefix(pid: primary.processIdentifier), own)
        XCTAssertEqual(ProcessInventory.winePrefix(pid: other.processIdentifier), foreign)
        let result = await ProcessInventory.snapshot(bottlePath: own, wineRuntimePath: Self.wineRuntime)
        XCTAssertTrue(result.contains { $0.pid == primary.processIdentifier })
        XCTAssertFalse(result.contains { $0.pid == other.processIdentifier })
    }

    func testElapsedSecondsForTableSorting() {
        func seconds(_ elapsed: String) -> Int {
            WineProcess(name: "x", pid: 1, residentKB: 1, elapsed: elapsed).elapsedSeconds
        }
        XCTAssertEqual(seconds("00:00:45"), 45)
        XCTAssertEqual(seconds("01:23:45"), 5025)
        XCTAssertEqual(seconds("1-02:03:04"), 93_784)
        XCTAssertEqual(seconds("05:23"), 323, "不满一小时 ps 只给 mm:ss")
        XCTAssertEqual(seconds("乱码"), 0)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(ProcessInventory.formatElapsed("01:23:45"), "1h 23m")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:05:00"), "5m")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:00:45"), "<1m")
        XCTAssertEqual(ProcessInventory.formatElapsed("1-02:03:04"), "1d 2h 3m")
        XCTAssertEqual(ProcessInventory.formatElapsed("05:23"), "5m")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:45"), "<1m")
    }
}
