import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class BootstrapStoreLifecycleTests: XCTestCase {
    private var sandbox: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        sandbox = fileManager.temporaryDirectory.appendingPathComponent("MacSW-bootstrap-lifecycle-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: sandbox)
    }

    private func media(named name: String, serial: String? = nil) throws -> URL {
        let directory = sandbox.appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: directory.appendingPathComponent("setup.exe"))
        if let serial {
            try "SolidWorks \(serial)\n".write(
                to: directory.appendingPathComponent("serials.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    /// Serials are only ever typed in by the user: files next to the media are never read.
    func testSerialFilesNextToMediaAreIgnored() throws {
        let directory = try media(named: "with-serial-file", serial: "0000 1111 1111 1111 1111 1111")
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))

        store.selectMedia(directory)

        XCTAssertNotNil(store.resolvedMedia)
        XCTAssertTrue(store.serials.isEmpty)
        XCTAssertEqual(store.licenseMode, .unconfigured)
    }

    func testInvalidSelectionClearsMedia() throws {
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))
        store.selectMedia(try media(named: "valid"))
        store.selectMedia(sandbox.appendingPathComponent("missing"))

        XCTAssertNil(store.resolvedMedia)
        XCTAssertNil(store.selectedMedia)
    }

    func testStartClaimsInstallationBeforeSchedulingTask() async throws {
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))
        store.silentInstall = false
        store.selectMedia(try media(named: "install"))
        XCTAssertTrue(store.canStart)

        store.start()
        let firstGeneration = try XCTUnwrap(store.installationGeneration)
        XCTAssertEqual(store.state, .preparing)

        store.start()
        XCTAssertEqual(store.installationGeneration, firstGeneration)
        store.cancel()
    }
}
