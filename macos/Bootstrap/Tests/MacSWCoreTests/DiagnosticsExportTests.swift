import Foundation
import XCTest
@testable import MacSWCore

/// The diagnostics zip (sharing plan, C4): the fixed file list, the never-include rules, and no
/// planted value left in what is written. All values are made up.
final class DiagnosticsExportTests: XCTestCase {
    private static let fakeSerial = "ABCD-1234-EFGH-5678-JKLM-9012"
    private var root: URL!
    private var paths: AppPaths!
    private var bundle: URL!
    private let scrubber = DiagnosticsScrubber(context: .init(
        homePath: "/Users/fakeuser", userName: "fakeuser", fullName: "Fake Person",
        hostNames: ["Fake-MacBook-Pro"], cloudFolderNames: ["GoogleDrive-member@example.com"]))
    private let facts = DiagnosticsExport.Facts(
        systemReport: "macOS: 27.0\nMac model: Mac15,9\n", folderReport: "dosdevices/b: -> Box (/Users/fakeuser/Library/CloudStorage/Box-Box): allowed\n",
        processReport: "SLDWORKS.exe\nwineserver\n")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-Diagnostics-\(UUID().uuidString)")
        paths = AppPaths(appSupportDirectory: root.appendingPathComponent("MacSW"))
        bundle = root.appendingPathComponent("MacSW.app")
        try write("Contents/Resources/BuildManifest.plist", in: bundle,
                  "<?xml version=\"1.0\"?><plist><dict><key>GitCommit</key><string>3873d67</string></dict></plist>\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, in base: URL, _ text: String) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The top folder of the unpacked zip and its files (no folders), sorted.
    private func unpack(_ zip: URL) throws -> (URL, [String]) {
        let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        let top = unpacked.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: top.path)?.allObjects as? [String])
            .filter { !$0.hasSuffix("logs") && !$0.hasSuffix("runtime") }.sorted()
        return (top, files)
    }

    private func plantLogs() throws {
        let support = paths.appSupportDirectory
        try write("logs/sw_launch.log", in: support, "launch /Users/fakeuser/Library/Application Support/MacSW/bottle\nkey \(Self.fakeSerial)\n")
        try write("logs/install_msi.log", in: support,
                  "Command Line: SOLIDWORKSSERIALNUMBER=\(Self.fakeSerial) ADDLOCAL=SolidWorks\r\nemail member@example.edu\r\nMainEngineThread is returning 1603\r\n")
        try write("logs/folder-consent.log", in: support, "Desktop: granted\n")
        try write("logs/spatialiop.log", in: support, "msi_spatialiop.exe: changed 3 of 3\n")
        try write(".bottle.wine-runtime/receipt.json", in: support, #"{"format": 1, "active_app": "/Users/fakeuser/Applications/MacSW.app"}"#)
        // Not on the list: never in the zip, whatever they hold.
        try write("logs/drive-maps.log", in: support, "B: Box-Box\n")
        try write("bottle/system.reg", in: support, "WINE REGISTRY Version 2\n")
        try write("bottle/drive_c/ProgramData/FLEXnet/data.dat", in: support, "x\n")
    }

    func testPlanIsTheFixedListOfFilesThatExistPlusTheReports() throws {
        try plantLogs()
        let names = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts).map(\.name)
        XCTAssertEqual(names, ["README.txt", "logs/sw_launch.log", "logs/folder-consent.log", "logs/install_msi.log",
                               "logs/spatialiop.log", "runtime/receipt.json", "BuildManifest.plist", "system.txt", "folder-access.txt", "processes.txt"])
    }

    func testNeverIncludePathsAreRefused() {
        let bottle = "/Users/fakeuser/Library/Application Support/MacSW/bottle"
        for path in ["\(bottle)/system.reg", "\(bottle)/user.reg", "\(bottle)/userdef.reg", "/tmp/export.reg",
                     "\(bottle)/drive_c/ProgramData/FLEXnet/x.data", "/tmp/flexnet/state",
                     "\(bottle)/drive_c/users/fakeuser/AppData/Local/Microsoft/Windows/INetCache/a.xml",
                     "/tmp/CXPA/dump.dmp", "/Users/fakeuser/Documents/SWActivateRequest_fixture.xml",
                     "/tmp/sw.lic", "/tmp/license.TSF", "/Users/fakeuser/Desktop/Bracket.SLDPRT",
                     "/Users/fakeuser/Desktop/Assembly.sldasm", "/tmp/part.step", "/tmp/macro.swp",
                     "\(bottle)/drive_c/windows/temp/any.log"] {
            XCTAssertNotNil(DiagnosticsExport.refusal(URL(fileURLWithPath: path)), path)
        }
        for path in ["/Users/fakeuser/Library/Application Support/MacSW/logs/sw_launch.log",
                     "/Users/fakeuser/Library/Application Support/MacSW/.bottle.wine-runtime/receipt.json",
                     "/Applications/MacSW.app/Contents/Resources/BuildManifest.plist"] {
            XCTAssertNil(DiagnosticsExport.refusal(URL(fileURLWithPath: path)), path)
        }
    }

    func testStagingRefusesTheWholeExportForOneNeverIncludeFile() throws {
        try plantLogs()
        var items = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts)
        items.append(.init(name: "bottle/system.reg", content: .file(paths.bottle.appendingPathComponent("system.reg"))))
        let work = root.appendingPathComponent("work")
        XCTAssertThrowsError(try DiagnosticsExport.stage(items, scrubber: scrubber, top: "x", in: work)) { error in
            XCTAssertEqual((error as? DiagnosticsExport.Refused)?.reason, "registry")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "nothing is written")

        // A listed log that is a link to a hive.
        let log = paths.logs.appendingPathComponent("sw_open.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: paths.bottle.appendingPathComponent("system.reg"))
        let linked = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts)
        XCTAssertTrue(linked.contains { $0.name == "logs/sw_open.log" })
        XCTAssertThrowsError(try DiagnosticsExport.stage(linked, scrubber: scrubber, top: "x", in: work))
    }

    func testZipHoldsTheScrubbedFilesOnly() throws {
        try plantLogs()
        let items = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts)
        let zip = DiagnosticsExport.destination(in: root, date: Date(timeIntervalSince1970: 1_792_930_000))
        XCTAssertEqual(zip.lastPathComponent, "MacSW-diagnostics-2026-10-25.zip")
        try DiagnosticsExport.write(items, scrubber: scrubber, to: zip)
        XCTAssertEqual(DiagnosticsExport.destination(in: root, date: Date(timeIntervalSince1970: 1_792_930_000)).lastPathComponent,
                       "MacSW-diagnostics-2026-10-25-2.zip", "an existing zip is never replaced")

        let (top, files) = try unpack(zip)
        XCTAssertEqual(files, ["BuildManifest.plist", "README.txt", "folder-access.txt", "logs/folder-consent.log",
                               "logs/install_msi.log", "logs/spatialiop.log", "logs/sw_launch.log", "processes.txt",
                               "runtime/receipt.json", "system.txt"])
        var all = ""
        for file in files { all += try String(contentsOf: top.appendingPathComponent(file), encoding: .utf8) + "\n" }
        for planted in ["ABCD", "SERIALNUMBER", "member@example.edu", "fakeuser", "Box-Box", "WINE REGISTRY"] {
            XCTAssertFalse(all.contains(planted), planted)
        }
        XCTAssertTrue(all.contains("MainEngineThread is returning 1603"))
        XCTAssertTrue(all.contains("<string>3873d67</string>"))
        XCTAssertTrue(all.contains("~/Library/Application Support/MacSW/bottle"))
    }

    func testInstallStepLogsGoIntoTheZip() throws {
        try plantLogs()
        let support = paths.appSupportDirectory
        try write("logs/wineboot.log", in: support, "wine: could not load kernel32.dll, status c0000135\n")
        // msiexec went on after MacSW was force-quit: not redacted by value, so the pattern must catch it.
        try write("logs/installer-wine.log", in: support,
                  "CustomActionData=SN-\(Self.fakeSerial);x=\(Self.fakeSerial.replacingOccurrences(of: "-", with: ""))-1\nexit 1603\n")
        try write("logs/vba71_1033-install.log", in: support, "MainEngineThread is returning 0\n")
        let names = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts).map(\.name)
        XCTAssertEqual(names.filter { $0.hasPrefix("logs/") },
                       ["logs/sw_launch.log", "logs/folder-consent.log", "logs/install_msi.log", "logs/spatialiop.log",
                        "logs/wineboot.log", "logs/vba71_1033-install.log", "logs/installer-wine.log"])

        let zip = root.appendingPathComponent("MacSW-diagnostics-test.zip")
        try DiagnosticsExport.write(DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts), scrubber: scrubber, to: zip)
        let (top, files) = try unpack(zip)
        XCTAssertTrue(files.contains("logs/wineboot.log"))
        XCTAssertTrue(files.contains("logs/installer-wine.log"))
        XCTAssertEqual(try String(contentsOf: top.appendingPathComponent("logs/wineboot.log"), encoding: .utf8),
                       "wine: could not load kernel32.dll, status c0000135\n")
        XCTAssertEqual(try String(contentsOf: top.appendingPathComponent("logs/installer-wine.log"), encoding: .utf8),
                       "CustomActionData=SN-<serial>;x=<serial>-1\nexit 1603\n")
    }

    func testInstallStatusFromTheFailurePage() throws {
        let report = DiagnosticsExport.installStatusReport(
            state: .failed("Wine initialization failed (1)."), message: "Wine initialization failed (1).",
            statuses: [.media: .completed, .environment: .failed],
            details: [.media: "Official MSI and prerequisites are present",
                      .environment: "Wine initialization failed (1).\nsee /Users/fakeuser/Library/Application Support/MacSW/logs key \(Self.fakeSerial)"])
        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(8)), [
            "Install: failed", "Message: Wine initialization failed (1).", "", "Steps:",
            "1. Verify the official install media - Completed: Official MSI and prerequisites are present",
            "2. Prepare the Wine environment and managed COM - Failed: Wine initialization failed (1).",
            "    see /Users/fakeuser/Library/Application Support/MacSW/logs key \(Self.fakeSerial)",
            "3. Install the Microsoft VC++ runtime - Pending"])
        XCTAssertEqual(lines.count, 4 + InstallationStep.allCases.count + 1 + 1, "every step, one more detail line, the final newline")

        XCTAssertFalse(DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts).contains { $0.name == "install-status.txt" },
                       "only the install window passes it")
        let items = DiagnosticsExport.plan(paths: paths, bundle: bundle, facts: facts, installStatus: report)
        XCTAssertEqual(items.last?.name, "install-status.txt")
        guard case .text(let readme) = items[0].content else { return XCTFail("README.txt first") }
        XCTAssertTrue(readme.contains("  install-status.txt"))
        let staged = try DiagnosticsExport.stage(items, scrubber: scrubber, top: "x", in: root.appendingPathComponent("work"))
        let text = try String(contentsOf: staged.appendingPathComponent("install-status.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("    see ~/Library/Application Support/MacSW/logs key <serial>\n"), "scrubbed like every file")
    }

    func testLargeFilesKeepTheirLastPart() throws {
        let log = root.appendingPathComponent("big.log")
        try write("big.log", in: root, (1...2000).map { "line \($0)" }.joined(separator: "\n") + "\n")
        let text = try DiagnosticsExport.readText(log, maximumBytes: 1 << 10)
        XCTAssertTrue(text.hasPrefix("[MacSW: only the last"))
        XCTAssertTrue(text.hasSuffix("line 2000\n"))
        XCTAssertFalse(text.contains("line 1\n"))
        let lines = text.split(separator: "\n").dropFirst()
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("line ") }, "the cut starts at a whole line")

        var utf16 = Data([0xFF, 0xFE])
        utf16.append(((1...2000).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n").data(using: .utf16LittleEndian)!)
        let wide = root.appendingPathComponent("wide.log")
        try utf16.write(to: wide)
        let decoded = try DiagnosticsExport.readText(wide, maximumBytes: 1 << 10)
        XCTAssertTrue(decoded.hasSuffix("row 2000\r\n"), "UTF-16 stays aligned and decodable")
    }
}
