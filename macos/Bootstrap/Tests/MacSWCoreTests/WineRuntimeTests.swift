import Darwin
import Foundation
import XCTest
@testable import MacSWCore

final class WineRuntimeTests: XCTestCase {
    private func fixture() throws -> (URL, URL, [String: String]) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-upgrade-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }
        let prefix = temporary.appendingPathComponent("bottle")
        let bundle = temporary.appendingPathComponent("MacSW.app")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var identity = ["WineVersion": "11.16", "MonoVersion": "11.3.0"]
        for name in ["WineMacModuleSHA256", "WineInputModuleSHA256", "WineCOMBaseModuleSHA256",
                     "WineComctl32V6ModuleSHA256", "WineNtdllModuleSHA256", "WineLoaderSHA256",
                     "MonoPatchSHA256", "MonoMscorlibSHA256", "MonoRegAsmX86SHA256", "MonoRegAsmX64SHA256"] {
            identity[name] = String(repeating: "0", count: 64)
        }
        var manifest = identity
        manifest["SWCLISourceCommit"] = "not-part-of-wine-identity"
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("BuildManifest.plist"))
        return (prefix, bundle, identity)
    }

    private func record(prefix: URL, identity: [String: String]) throws {
        try "prefix-id".write(to: prefix.appendingPathComponent(".macsw-wine-prefix-id"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["format": 1, "prefix_id": "prefix-id", "identity": identity])
            .write(to: WineRuntimeService.root(prefix: prefix).appendingPathComponent("receipt.json"))
    }

    func testNoRecordRequiresExplicitBaseline() throws {
        let (prefix, bundle, _) = try fixture()
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .baseline)
        XCTAssertThrowsError(try WineRuntimeService.withLaunchLock(prefix: prefix) { XCTFail("must not launch") })
    }

    func testIdentityIgnoresBackendVersionButIncludesPatchChanges() throws {
        let (prefix, bundle, values) = try fixture()
        XCTAssertEqual(try WineRuntimeService.identity(contents: bundle.appendingPathComponent("Contents")), values)
        try record(prefix: prefix, identity: values)
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .ready)
        var old = values
        old["WineMacModuleSHA256"] = "different-patch-same-Wine-version"
        try record(prefix: prefix, identity: old)
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .upgrade)
    }

    func testIncompleteMigrationBlocksEvenMatchingIdentity() throws {
        let (prefix, bundle, values) = try fixture()
        try record(prefix: prefix, identity: values)
        try Data("{}".utf8).write(to: WineRuntimeService.root(prefix: prefix).appendingPathComponent("pending.json"))
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .recovery)
    }

    func testToolboxManifestRequiresAllNewModuleHashes() throws {
        let (_, bundle, values) = try fixture()
        let manifestURL = bundle.appendingPathComponent("Contents/Resources/BuildManifest.plist")
        var manifest = values
        manifest["MonoCCWModuleSHA256"] = String(repeating: "1", count: 64)
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: manifestURL)
        XCTAssertThrowsError(try WineRuntimeService.identity(contents: bundle.appendingPathComponent("Contents")))
        manifest["MonoBTLSModuleSHA256"] = String(repeating: "2", count: 64)
        manifest["WineMSXML3ModuleSHA256"] = String(repeating: "3", count: 64)
        manifest["WineMSXMLSchemaPatchSHA256"] = String(repeating: "4", count: 64)
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: manifestURL)
        XCTAssertEqual(try WineRuntimeService.identity(contents: bundle.appendingPathComponent("Contents")), manifest)
    }

    func testMSXMLManifestDoesNotRequireMonoOverlay() throws {
        let (prefix, bundle, values) = try fixture()
        try record(prefix: prefix, identity: values)
        let url = bundle.appendingPathComponent("Contents/Resources/BuildManifest.plist")
        var manifest = values
        manifest["WineMSXML3ModuleSHA256"] = String(repeating: "1", count: 64)
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: url)
        XCTAssertThrowsError(try WineRuntimeService.identity(contents: bundle.appendingPathComponent("Contents")))
        manifest["WineMSXMLSchemaPatchSHA256"] = String(repeating: "2", count: 64)
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: url)
        XCTAssertEqual(try WineRuntimeService.identity(contents: bundle.appendingPathComponent("Contents")), manifest)
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .upgrade)
    }

    func testMalformedReceiptFailsClosed() throws {
        let (prefix, bundle, _) = try fixture()
        try Data("invalid".utf8).write(to: WineRuntimeService.root(prefix: prefix).appendingPathComponent("receipt.json"))
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .invalid)
    }

    func testReplacedPrefixCannotReuseReceipt() throws {
        let (prefix, bundle, values) = try fixture()
        try record(prefix: prefix, identity: values)
        try FileManager.default.removeItem(at: prefix.appendingPathComponent(".macsw-wine-prefix-id"))
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .baseline)
    }

    func testRelocatingAppRequiresRebindingDespiteUnchangedIdentity() throws {
        let (prefix, bundle, values) = try fixture()
        try record(prefix: prefix, identity: values)
        let receipt = WineRuntimeService.root(prefix: prefix).appendingPathComponent("receipt.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        value["active_app"] = "/different-volume/MacSW.app"
        try JSONSerialization.data(withJSONObject: value).write(to: receipt)
        XCTAssertEqual(WineRuntimeService.status(prefix: prefix, bundle: bundle), .upgrade)
    }

    func testMigrationLockAlsoBlocksServerCleanup() throws {
        let (prefix, _, _) = try fixture()
        let fd = open(WineRuntimeService.root(prefix: prefix).appendingPathComponent("launch.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try WineRuntimeService.withLaunchLock(prefix: prefix, checkIdentity: false) {
            XCTFail("must not start cleanup while migrating")
        })
    }

    func testResidentWineProcessesAlsoPassThroughPreflight() throws {
        let (prefix, _, _) = try fixture()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.environment = ["WINEPREFIX": prefix.path]
        XCTAssertThrowsError(try WineService.shared.start(process))
        XCTAssertFalse(process.isRunning)
    }

    @MainActor
    func testLicenseMaintenanceCannotMutateFilesDuringMigration() throws {
        let (prefix, _, _) = try fixture()
        let licensing = LicenseServerStore(paths: AppPaths(appSupportDirectory: prefix.deletingLastPathComponent()))
        licensing.runtimeMaintenanceSuspended = true
        XCTAssertFalse(licensing.startOperationIfIdle())
        XCTAssertFalse(licensing.isOperating)
        XCTAssertTrue(licensing.statusMessage.contains("migration"))
    }

    @MainActor
    func testPreflightBlocksFontAndBackendBeforeAnyWineAction() async throws {
        let (prefix, _, _) = try fixture()
        let paths = AppPaths(appSupportDirectory: prefix.deletingLastPathComponent())
        let executable = prefix.appendingPathComponent("drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        AppPaths.invalidateInstallationState()
        let runtime = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
                                   fontLinkRepair: { _ in XCTFail("must not touch fonts") },
                                   swcliPreparation: { _ in XCTFail("must not probe Wine backend") })
        runtime.prepareFontLinkAtAppLaunch()
        await runtime.startup(autoLaunch: true)
        XCTAssertEqual(runtime.wineRuntimeState, .baseline)
        XCTAssertTrue(runtime.statusMessage.contains("version"))
    }
}
