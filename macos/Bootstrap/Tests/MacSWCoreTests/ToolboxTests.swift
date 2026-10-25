import Foundation
import XCTest
@testable import MacSWCore

final class ToolboxTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-Toolbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ value: String, path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    private func mapping(stdout: String, stderr: String = "", status: Int = 0) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Arguments, not interpolated shell syntax: paths may contain quotes or spaces.
        process.arguments = ["-c", #"printf '%s' "$1"; printf '%s' "$2" >&2; exit "$3""#,
                             "toolbox-path-test", stdout, stderr, String(status)]
        process.environment = [:]
        return process
    }

    func testPathMappingIgnoresStderrButRecordsBothStreams() async throws {
        let directory = try root()
        let path = directory.appendingPathComponent("用户 𐌂/Toolbox Data").path
        let warning = "wineserver: sock_get_ntstatus() can't map error: Host is down\n"
        let log = directory.appendingPathComponent("logs/toolbox-path.log")
        let resolved = try await ToolboxService().resolveDataDirectory(
            using: mapping(stdout: path + "\r\n", stderr: warning), log: log)
        XCTAssertEqual(resolved.path, path)
        let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        XCTAssertEqual(diagnostic["exit_code"] as? Int, 0)
        XCTAssertEqual(diagnostic["stdout"] as? String, path + "\r\n")
        XCTAssertEqual(diagnostic["stderr"] as? String, warning)
        XCTAssertNotNil(diagnostic["timestamp"] as? String)
    }

    func testPathMappingRejectsNonzeroExitEvenWithValidStdout() async throws {
        let log = try root().appendingPathComponent("toolbox-path.log")
        do {
            _ = try await ToolboxService().resolveDataDirectory(
                using: mapping(stdout: "/tmp/SWData\n", stderr: "failure", status: 53), log: log)
            XCTFail("A valid-looking path cannot override a failed command")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("53"))
            XCTAssertTrue(error.localizedDescription.contains("toolbox-path.log"))
        }
        let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        XCTAssertEqual(diagnostic["exit_code"] as? Int, 53)
        XCTAssertEqual(diagnostic["stderr"] as? String, "failure")
    }

    func testPathMappingRejectsMissingOrMalformedStdout() async throws {
        let log = try root().appendingPathComponent("toolbox-path.log")
        for output in ["", " \n", #"C:\SWData"#, "/tmp/one\n/tmp/two", "/tmp/one\rtwo", "/tmp/\u{FFFD}"] {
            do {
                _ = try await ToolboxService().resolveDataDirectory(
                    using: mapping(stdout: output, stderr: "/tmp/not-stdout\n"), log: log)
                XCTFail("Invalid stdout was accepted: \(output.debugDescription)")
            } catch {
                XCTAssertEqual((error as NSError).domain, "MacSW.Toolbox")
            }
        }
        // NUL cannot be passed as an argv value; make the child emit the actual byte.
        let process = mapping(stdout: "")
        process.arguments = ["-c", #"printf '/tmp/one\000two\n'"#]
        do {
            _ = try await ToolboxService().resolveDataDirectory(using: process, log: log)
            XCTFail("NUL in a path must be rejected")
        } catch {
            XCTAssertEqual((error as NSError).domain, "MacSW.Toolbox")
        }
    }

    func testOfficialUpdaterUsesDefaultMonoWithoutChangingInstallerEnvironment() {
        let prefix = URL(fileURLWithPath: "/tmp/toolbox-test")
        let process = ToolboxService().makeUpdater(executable: URL(fileURLWithPath: "/sw/sldtoolboxupdater.exe"),
            dataPath: #"C:\SWData"#, archivesPath: #"Z:\media with spaces\Toolbox"#, prefix: prefix)
        XCTAssertEqual(process.arguments, ["/sw/sldtoolboxupdater.exe", #"C:\SWData"#, #"Z:\media with spaces\Toolbox"#, "TRUE"])
        XCTAssertEqual(process.environment?["WINE_MONO_AOT"], "none")
        XCTAssertEqual(WineService.shared.environment(winePrefix: prefix)["WINE_MONO_AOT"], "interp")
        XCTAssertNil(process.environment?["WINEDLLOVERRIDES"])
    }

    func testDataLocationIsVersionIndependentAndOnlyReadsGeneralSettings() {
        let paths = ToolboxService.dataPaths(in: #"""
        [Software\\SolidWorks\\SOLIDWORKS 2027\\General] 123
        "Toolbox Data Location"="D:\\Shared Toolbox"
        [Unrelated]
        "Toolbox Data Location"="C:\\wrong"
        "SolidWorks Folder"="C:\\Program Files\\SOLIDWORKS"
        """#)
        XCTAssertEqual(paths, [#"D:\Shared Toolbox"#])
    }

    func testDataLocationPrefersUserOverrideAndRejectsAmbiguousVersions() throws {
        let prefix = try root()
        let header = #"[Software\\SolidWorks\\SOLIDWORKS 2025\\General]"#
        try write(header + "\n\"Toolbox Data Location\"=\"C:\\\\SWData\"", path: "system.reg", root: prefix)
        XCTAssertEqual(try ToolboxService.configuredDataPath(prefix: prefix), #"C:\SWData"#)
        try write(header + "\n\"Toolbox Data Location\"=\"D:\\\\Custom\"", path: "user.reg", root: prefix)
        XCTAssertEqual(try ToolboxService.configuredDataPath(prefix: prefix), #"D:\Custom"#)
        try write(header + "\n\"Toolbox Data Location\"=\"D:\\\\One\"\n" +
                  #"[Software\\SolidWorks\\SOLIDWORKS 2026\\General]"# + "\n\"Toolbox Data Location\"=\"D:\\\\Two\"",
                  path: "user.reg", root: prefix)
        XCTAssertThrowsError(try ToolboxService.configuredDataPath(prefix: prefix))
    }

    func testOnlySelectedStandardsAreValidated() throws {
        let root = try root()
        try write("<ToolboxStandards><Standard><Name>GB</Name><Source>gb.zip</Source><Install>Yes</Install></Standard>" +
                  "<Standard><Name>ISO</Name><Source>iso.zip</Source><Install>No</Install></Standard></ToolboxStandards>",
                  path: "ToolboxStandards.xml", root: root)
        let selected = try ToolboxService.selectedStandards(in: root)
        XCTAssertEqual(selected, [.init(name: "GB", source: "gb.zip")])
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        try write("part", path: "browser/GB/Bolts/bolt.SLDPRT", root: root)
        XCTAssertEqual(try ToolboxService.validate(root: root, standards: selected), 1)
    }

    func testExitZeroOrDatabaseAloneDoesNotProveToolboxDeployment() throws {
        let root = try root()
        let standards = [ToolboxService.Standard(name: "GB", source: "gb.zip")]
        try write("database", path: "lang/english/swbrowser.sldedb", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: standards))
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: standards))
    }

    func testEachSelectedStandardNeedsModels() throws {
        let root = try root()
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        try write("part", path: "browser/GB/bolt.sldprt", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: [
            .init(name: "GB", source: "gb.zip"), .init(name: "ISO", source: "iso.zip")]))
    }

    func testMalformedAndUnsafeStandardsAreRefused() throws {
        let root = try root()
        for xml in ["<ToolboxStandards>", "<unrelated />",
                    "<ToolboxStandards><Standard><Name>GB</Name><Source>../gb.zip</Source><Install>Yes</Install></Standard></ToolboxStandards>",
                    "<ToolboxStandards><Standard><Name>../GB</Name><Source>gb.zip</Source><Install>Yes</Install></Standard></ToolboxStandards>"] {
            try write(xml, path: "ToolboxStandards.xml", root: root)
            XCTAssertThrowsError(try ToolboxService.selectedStandards(in: root))
        }
    }

    func testToolboxRunsAfterThemesAndBeforeFinalValidation() {
        XCTAssertLessThan(InstallationStep.wpfThemes.rawValue, InstallationStep.toolbox.rawValue)
        XCTAssertLessThan(InstallationStep.toolbox.rawValue, InstallationStep.validation.rawValue)
    }
}
