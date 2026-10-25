import Foundation
import XCTest
@testable import MacSWCore

final class DocumentHandOffTests: XCTestCase {
    private func process(_ name: String, pid: Int32) -> WineProcess {
        WineProcess(name: name, pid: pid, residentKB: 1024, elapsed: "00:10")
    }

    private func window(pid: Int32, layer: Int = 0, width: Double = 1600, height: Double = 900) -> HostWindow {
        HostWindow(ownerPID: pid, layer: layer, width: width, height: height)
    }

    func testReadinessNotRunningWithoutSolidWorksProcess() {
        XCTAssertEqual(DocumentHandOff.readiness(processes: [], windows: [window(pid: 5)]), .notRunning)
        XCTAssertEqual(DocumentHandOff.readiness(processes: [process("explorer.exe", pid: 5)], windows: [window(pid: 5)]), .notRunning)
    }

    func testReadinessStartingUntilMainSizedWindowOfSolidWorksProcess() {
        let sw = [process("SLDWORKS.exe", pid: 10), process("sldworks_fs.exe", pid: 11)]
        XCTAssertEqual(DocumentHandOff.readiness(processes: sw, windows: []), .starting)
        // Splash-sized, other process, and non-normal layers do not count.
        XCTAssertEqual(DocumentHandOff.readiness(processes: sw, windows: [
            window(pid: 10, width: 560, height: 320), window(pid: 11), window(pid: 99), window(pid: 10, layer: 25)
        ]), .starting)
        XCTAssertEqual(DocumentHandOff.readiness(processes: sw, windows: [window(pid: 10)]), .ready)
    }

    func testReadinessIsCaseInsensitiveOnProcessName() {
        XCTAssertEqual(DocumentHandOff.readiness(processes: [process("sldworks.exe", pid: 3)], windows: [window(pid: 3)]), .ready)
    }

    func testActionDecision() {
        XCTAssertEqual(DocumentHandOff.action(readiness: .notRunning, launchInFlight: false), .coldStart)
        XCTAssertEqual(DocumentHandOff.action(readiness: .notRunning, launchInFlight: true), .waitForReadiness)
        XCTAssertEqual(DocumentHandOff.action(readiness: .starting, launchInFlight: false), .waitForReadiness)
        XCTAssertEqual(DocumentHandOff.action(readiness: .starting, launchInFlight: true), .waitForReadiness)
        XCTAssertEqual(DocumentHandOff.action(readiness: .ready, launchInFlight: false), .handOffToRunning)
    }

    func testPollDecision() {
        XCTAssertEqual(DocumentHandOff.pollDecision(readiness: .ready, waited: 0), .handOff)
        XCTAssertEqual(DocumentHandOff.pollDecision(readiness: .starting, waited: 10), .keepWaiting)
        XCTAssertEqual(DocumentHandOff.pollDecision(readiness: .starting, waited: DocumentHandOff.readinessTimeout), .handOff)
        XCTAssertEqual(DocumentHandOff.pollDecision(readiness: .notRunning, waited: 5), .keepWaiting)
        XCTAssertEqual(DocumentHandOff.pollDecision(readiness: .notRunning, waited: DocumentHandOff.startGrace), .abandon)
    }

    func testStartArgumentsKeepPathAsSingleArgument() {
        let file = URL(fileURLWithPath: "/Users/me/My Parts/底盘.sldprt")
        XCTAssertEqual(DocumentHandOff.startArguments(for: file), ["start", "/unix", "/Users/me/My Parts/底盘.sldprt"])
        XCTAssertEqual(DocumentHandOff.startArguments(for: file, windowsPath: #"C:\users\me\Documents\My Parts\底盘.sldprt"#),
                       ["start", #"C:\users\me\Documents\My Parts\底盘.sldprt"#])
    }

    func testHandOffUsesProfilePathForLinkedFoldersOnly() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dho-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("bottle")
        let documents = root.appendingPathComponent("home/Documents")
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users/me"), withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("drive_c/users/me/Documents").path,
                                  withDestinationPath: documents.path)

        let inDocuments = documents.appendingPathComponent("A B.SLDPRT")
        let elsewhere = root.appendingPathComponent("elsewhere/C.SLDASM")
        XCTAssertEqual(DocumentHandOff.startArguments(for: [inDocuments, elsewhere], prefix: prefix, userName: "me"), [
            ["start", #"C:\users\me\Documents\A B.SLDPRT"#],
            ["start", "/unix", elsewhere.path]
        ])
    }
}

@MainActor
final class RuntimeDocumentHandOffTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _opened: [[URL]] = []
        private var _windows: [HostWindow] = []
        var opened: [[URL]] { lock.lock(); defer { lock.unlock() }; return _opened }
        var windows: [HostWindow] {
            get { lock.lock(); defer { lock.unlock() }; return _windows }
            set { lock.lock(); _windows = newValue; lock.unlock() }
        }
        func record(_ files: [URL]) { lock.lock(); _opened.append(files); lock.unlock() }
    }

    private func makeRuntime(box: Box) throws -> (RuntimeStore, URL, URL) {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-handoff-\(UUID().uuidString)")
        let paths = AppPaths(appSupportDirectory: support)
        let executable = paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        let part = support.appendingPathComponent("a.sldprt")
        try Data("x".utf8).write(to: part)
        let runtime = RuntimeStore(
            paths: paths,
            licenseServer: LicenseServerStore(paths: paths),
            processSnapshot: { _, _ in [WineProcess(name: "SLDWORKS.exe", pid: 42, residentKB: 1, elapsed: "00:05")] },
            windowSnapshot: { _ in box.windows },
            documentOpener: { _, files in box.record(files) },
            handOffPollInterval: 0.02
        )
        return (runtime, support, part)
    }

    func testDocumentWaitsForMainWindowThenGoesToRunningInstance() async throws {
        let box = Box()
        let (runtime, support, part) = try makeRuntime(box: box)
        defer { try? FileManager.default.removeItem(at: support) }
        await runtime.refreshNow()
        XCTAssertTrue(runtime.isRunning)

        runtime.open(documents: [part])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(box.opened.isEmpty, "no main window yet: must stay queued")

        box.windows = [HostWindow(ownerPID: 42, layer: 0, width: 1600, height: 900)]
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.opened.count, 1)
        XCTAssertEqual(box.opened.first?.map { $0.lastPathComponent }, ["a.sldprt"])
    }

    func testDocumentGoesStraightToReadyInstance() async throws {
        let box = Box()
        box.windows = [HostWindow(ownerPID: 42, layer: 0, width: 1600, height: 900)]
        let (runtime, support, part) = try makeRuntime(box: box)
        defer { try? FileManager.default.removeItem(at: support) }
        await runtime.refreshNow()
        runtime.open(documents: [part])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(box.opened.count, 1)
    }
}
