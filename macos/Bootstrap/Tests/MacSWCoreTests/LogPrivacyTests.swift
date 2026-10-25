import Foundation
import XCTest
@testable import MacSWCore

/// Logs directory 0700, log files 0600, and no serial number left in the verbose MSI log
/// (security audit 2026-10-24, finding 4). The serial below is a made-up fixture.
final class LogPrivacyTests: XCTestCase {
    private static let fakeSerial = "ABCD1234EFGH5678JKLM9012"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-LogPrivacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value?.intValue ?? -1
    }

    func testLogHandleCreatesAPrivateDirectoryAndFile() throws {
        let log = root.appendingPathComponent("support/logs/sw_launch.log")
        let handle = try XCTUnwrap(try WineService.shared.logHandle(for: log))
        try handle.write(contentsOf: Data("line\n".utf8))
        try handle.close()
        XCTAssertEqual(try mode(log.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(log), 0o600)
    }

    func testExistingWorldReadableLogsAreTightened() throws {
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let log = logs.appendingPathComponent("sw_open.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: Data("old\n".utf8),
                                                     attributes: [.posixPermissions: 0o644]))
        try WineService.shared.logHandle(for: log)?.close()
        XCTAssertEqual(try mode(logs), 0o700)
        XCTAssertEqual(try mode(log), 0o600)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old\n", "an existing log is appended to")

        let consent = logs.appendingPathComponent("folder-consent.log")
        FolderConsentService.appendLog([], to: consent)
        XCTAssertEqual(try mode(consent), 0o600)

        let written = logs.appendingPathComponent("managed-com-registration.log")
        try LogFiles.write(Data("x\n".utf8), to: written)
        XCTAssertEqual(try mode(written), 0o600)
    }

    private var msiLogText: String {
        [
            "=== Verbose logging started: 10/24/2026  12:00:00  Build type: SHIP UNICODE 5.00.10011.00 ===",
            "MSI (c) (1C:2C) [12:00:00:000]: Command Line: SOLIDWORKSSERIALNUMBER=\(Self.fakeSerial) ADDLOCAL=SolidWorks INSTALLLEVEL=100",
            "MSI (s) (4C:50) [12:00:01:000]: PROPERTY CHANGE: Adding SOLIDWORKSSERIALNUMBER property. Its value is '\(Self.fakeSerial)'.",
            "MSI (s) (4C:50) [12:00:01:100]: PROPERTY CHANGE: Adding SERVERLIST property. Its value is '25734@licsrv'.",
            "CustomAction swCheckSN returned actual error code 0: serial ABCD-1234-EFGH-5678-JKLM-9012 accepted",
            "Info: key abcd 1234 efgh 5678 jklm 9012 stored",
            "Action ended 12:00:02: InstallFinalize. Return value 1.",
            "Property(S): SOLIDWORKSSERIALNUMBER = \(Self.fakeSerial)",
            "MSI (s) (4C:50) [12:00:03:000]: MainEngineThread is returning 0",
            "=== Verbose logging stopped: 10/24/2026  12:00:03 ==="
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func assertRedacted(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let upper = text.uppercased()
        for form in [Self.fakeSerial, "ABCD-1234-EFGH-5678-JKLM-9012", "ABCD 1234 EFGH 5678 JKLM 9012"] {
            XCTAssertFalse(upper.contains(form), form, file: file, line: line)
        }
        XCTAssertFalse(upper.contains("SERIALNUMBER"), file: file, line: line)
        XCTAssertFalse(upper.contains("SERVERLIST"), file: file, line: line)
        XCTAssertTrue(text.contains("Return value 1."), file: file, line: line)
        XCTAssertFalse(text.contains("ADDLOCAL"), "the command line goes with its serial", file: file, line: line)
        XCTAssertEqual(InstallerDiagnostics.msiReturnCode(text), 0, file: file, line: line)
    }

    func testSilentInstallLogLosesEveryFormOfTheSerialInItsOwnEncoding() throws {
        let serials = InstallSerials(values: [.solidWorks: "abcd-1234-efgh-5678-jklm-9012"])
        for (name, encoding, bom) in [("utf16.log", String.Encoding.utf16LittleEndian, Data([0xFF, 0xFE])),
                                      ("utf8.log", String.Encoding.utf8, Data())] {
            let log = root.appendingPathComponent("logs/" + name)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (bom + XCTUnwrap(msiLogText.data(using: encoding))).write(to: log)
            XCTAssertTrue(InstallLogRedaction.redact(log: log, serials: serials))
            let data = try Data(contentsOf: log)
            XCTAssertTrue(data.starts(with: bom), name)
            let text = try XCTUnwrap(PlainTextDecoder.decode(data))
            assertRedacted(text)
            XCTAssertTrue(text.contains("\r\n"), "line ends are kept")
            XCTAssertEqual(try mode(log), 0o600)
        }
    }

    func testWizardInstallWithoutKnownSerialStillDropsThePropertyLines() {
        let text = InstallLogRedaction.redact(msiLogText, serials: InstallSerials())
        XCTAssertFalse(text.uppercased().contains("SERIALNUMBER"))
        XCTAssertFalse(text.uppercased().contains("SERVERLIST"))
        XCTAssertEqual(InstallerDiagnostics.msiReturnCode(text), 0)
    }

    func testMissingLogIsNotCreated() {
        let log = root.appendingPathComponent("logs/install_msi.log")
        XCTAssertFalse(InstallLogRedaction.redact(log: log, serials: InstallSerials()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
}
