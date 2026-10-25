import Foundation
import XCTest
@testable import MacSWCore

final class HeadlessInstallTests: XCTestCase {
    // Synthetic value in the serial format; not a real serial number.
    private let serial = "ABCD1234EFGH5678IJKL9012"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-headless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func serialFile(_ contents: String, mode: Int) throws -> URL {
        let url = directory.appendingPathComponent("serial-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func assertSerialFileRefused(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try HeadlessSerialFile.read(url)
            XCTFail("serial file should have been refused", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(serial), file: file, line: line)
        }
    }

    func testParsesFullArgumentList() throws {
        let options = try HeadlessInstallOptions.parse([
            "MacSW", "--headless-install", "--media", "/Volumes/SW", "--serial-file", "/tmp/s",
            "--license-server", "25734@lic.example", "--windows-version", "win11",
            "--language", "german", "--addlocal", "SolidWorks, ProgramFiles", "--locale", "zh_CN.UTF-8",
            "--log", "/tmp/h.log"
        ])
        XCTAssertEqual(options.media.path, "/Volumes/SW")
        XCTAssertEqual(options.serialFile.path, "/tmp/s")
        XCTAssertEqual(options.license, .server("25734@lic.example"))
        XCTAssertEqual(options.windowsVersion, .windows11)
        XCTAssertEqual(options.language, "german")
        XCTAssertEqual(options.addLocal, ["SolidWorks", "ProgramFiles"])
        XCTAssertEqual(options.locale, "zh_CN.UTF-8")
        XCTAssertEqual(options.log?.path, "/tmp/h.log")
    }

    func testDefaultsKeepGUIDefaults() throws {
        let options = try HeadlessInstallOptions.parse(["MacSW", "--headless-install", "--media", "/m", "--serial-file", "/s"])
        XCTAssertEqual(options.license, .standalone)
        XCTAssertNil(options.windowsVersion)
        XCTAssertNil(options.language)
        XCTAssertNil(options.addLocal)
        XCTAssertEqual(options.locale, "en_US.UTF-8")
        XCTAssertNil(options.log)
    }

    func testRejectsInvalidArguments() {
        let base = ["MacSW", "--headless-install", "--media", "/m", "--serial-file", "/s"]
        let invalid: [[String]] = [
            ["MacSW", "--headless-install", "--serial-file", "/s"],
            ["MacSW", "--headless-install", "--media", "/m"],
            base + ["--license", "standalone", "--license-server", "1@h"],
            base + ["--license-server", "1@h", "--license", "standalone"],
            base + ["--license", "trial"],
            base + ["--license-server", "not an address"],
            base + ["--windows-version", "win7"],
            base + ["--addlocal", "SolidWorks,,ProgramFiles"],
            base + ["--addlocal", "SolidWorks REMOVE=ALL"],
            base + ["--media", "/other"],
            base + ["--serial"],
            base + ["--locale"],
            base + ["--locale", "fr_FR.UTF-8"],
            base + ["--locale", "en_US.UTF-8", "--locale", "zh_CN.UTF-8"],
            base + ["--log"],
            ["MacSW", "--headless-install", "--media", "--serial-file", "/s"]
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try HeadlessInstallOptions.parse(arguments), "\(arguments)")
        }
    }

    func testFlagDetectionIgnoresProgramName() {
        XCTAssertTrue(HeadlessInstallOptions.isRequested(["MacSW", "--headless-install"]))
        XCTAssertFalse(HeadlessInstallOptions.isRequested(["MacSW"]))
        XCTAssertFalse(HeadlessInstallOptions.isRequested(["--headless-install"]))
    }

    func testResolvesLanguages() throws {
        XCTAssertNil(try HeadlessInstallOptions.resolveLanguage("English"))
        XCTAssertEqual(try HeadlessInstallOptions.resolveLanguage("GERMAN")?.directoryName, "german")
        XCTAssertEqual(try HeadlessInstallOptions.resolveLanguage("Deutsch")?.directoryName, "german")
        XCTAssertThrowsError(try HeadlessInstallOptions.resolveLanguage("klingon"))
    }

    func testReadsPrivateSerialFile() throws {
        let hyphenated = "abcd-1234-efgh-5678-ijkl-9012\n"
        XCTAssertEqual(try HeadlessSerialFile.read(serialFile(hyphenated, mode: 0o600)), serial)
        XCTAssertEqual(try HeadlessSerialFile.read(serialFile(serial, mode: 0o400)), serial)
    }

    func testRefusesSerialFileWithLoosePermissions() throws {
        for mode in [0o644, 0o640, 0o604, 0o660, 0o666, 0o700, 0o610] {
            assertSerialFileRefused(try serialFile(serial, mode: mode))
        }
    }

    func testRefusesSerialFileThatIsNotARegularFile() throws {
        let target = try serialFile(serial, mode: 0o600)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        assertSerialFileRefused(link)

        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        assertSerialFileRefused(folder)

        assertSerialFileRefused(directory.appendingPathComponent("missing.txt"))
    }

    func testRefusesMalformedSerialWithoutEchoingIt() throws {
        let short = "ABCD-1234-EFGH"
        do {
            _ = try HeadlessSerialFile.read(serialFile(short, mode: 0o600))
            XCTFail("short serial should be refused")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("ABCD"))
            XCTAssertFalse(error.localizedDescription.contains("1234"))
        }
    }

    func testRedactorScrubsSerialAndMSIProperties() {
        let redactor = HeadlessRedactor(serial: serial)
        let arguments = SilentInstallerPlan.coreInstallArguments(
            msi: URL(fileURLWithPath: "/m/solidworks.msi"),
            log: URL(fileURLWithPath: "/l/install_msi.log"),
            serials: InstallSerials(values: [.solidWorks: serial])
        ).joined(separator: " ")
        let lines = [
            arguments,
            "Property(S): SOLIDWORKSSERIALNUMBER = \(serial)",
            "Property(S): SERVERLIST = 25734@lic.example",
            "MOTIONSERIALNUMBER=WXYZ",
            "typed as abcd-1234-efgh-5678-ijkl-9012 and ABCD 1234 EFGH 5678 IJKL 9012"
        ]
        for line in lines {
            let scrubbed = redactor.scrub(line)
            XCTAssertFalse(scrubbed.contains(serial), scrubbed)
            XCTAssertFalse(scrubbed.uppercased().contains("ABCD-1234"), scrubbed)
            XCTAssertFalse(scrubbed.contains("ABCD 1234"), scrubbed)
            XCTAssertFalse(scrubbed.contains("lic.example"), scrubbed)
            XCTAssertFalse(scrubbed.contains("WXYZ"), scrubbed)
        }
        XCTAssertEqual(redactor.scrub("[5/10] installer: Completed"), "[5/10] installer: Completed")
    }

    @MainActor
    func testSerialNeverAppearsInOutput() async throws {
        let file = try serialFile(serial, mode: 0o600)
        let appSupport = directory.appendingPathComponent("AppSupport", isDirectory: true)
        let log = directory.appendingPathComponent("headless.log")
        var lines: [String] = []
        // Media that does not exist: the run stops before any Wine process starts.
        let code = await HeadlessInstaller.run(
            arguments: [
                "MacSW", "--headless-install", "--media", directory.appendingPathComponent("no-media").path,
                "--serial-file", file.path, "--log", log.path
            ],
            paths: AppPaths(appSupportDirectory: appSupport)
        ) { lines.append($0) }
        XCTAssertNotEqual(code, 0)
        XCTAssertFalse(lines.isEmpty)
        let printed = lines.joined(separator: "\n")
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(logged.isEmpty)
        for text in [printed, logged] {
            XCTAssertFalse(text.contains(serial))
            XCTAssertFalse(text.contains("ABCD"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("bottle").path))
    }

    @MainActor
    func testLoosePermissionsStopBeforeAnyOutputOfTheSerial() async throws {
        let file = try serialFile(serial, mode: 0o644)
        var lines: [String] = []
        let code = await HeadlessInstaller.run(
            arguments: ["MacSW", "--headless-install", "--media", directory.path, "--serial-file", file.path],
            paths: AppPaths(appSupportDirectory: directory.appendingPathComponent("AppSupport"))
        ) { lines.append($0) }
        XCTAssertEqual(code, 66)
        XCTAssertTrue(lines.joined().contains("chmod 600"))
        XCTAssertFalse(lines.joined().contains(serial))
    }

    func testAddLocalOverrideReplacesOnlyADDLOCAL() {
        let properties = SilentInstallerPlan.coreMSIProperties(addLocal: ["SolidWorks", "ProgramFiles"])
        XCTAssertEqual(properties.count, SilentInstallerPlan.defaultMSIProperties.count)
        XCTAssertTrue(properties.contains("ADDLOCAL=SolidWorks,ProgramFiles"))
        XCTAssertEqual(
            properties.filter { !$0.hasPrefix("ADDLOCAL=") },
            SilentInstallerPlan.defaultMSIProperties.filter { !$0.hasPrefix("ADDLOCAL=") }
        )
        XCTAssertEqual(SilentInstallerPlan.coreMSIProperties(addLocal: nil), SilentInstallerPlan.defaultMSIProperties)
    }

    func testCrashDialogAssignmentIsADword() throws {
        let text = try RegistryService.registryFileText([BootstrapStore.disableCrashDialog])
        XCTAssertTrue(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\WineDbg]"))
        XCTAssertTrue(text.contains("\"ShowCrashDialog\"=dword:00000000"))
    }
}
