import Foundation
import XCTest
@testable import MacSWCore

final class SolidWorksResourceMonitorServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private var paths: AppPaths!
    private var service: SolidWorksResourceMonitorService!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-ResourceMonitor-\(UUID().uuidString)")
        paths = AppPaths(appSupportDirectory: root)
        service = SolidWorksResourceMonitorService(fileManager: fileManager)
        try fileManager.createDirectory(at: solidWorksDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
        AppPaths.invalidateInstallationState()
    }

    func testDisableAndRestoreRenameExecutable() throws {
        try Data().write(to: executable)

        XCTAssertEqual(service.state(paths: paths), .enabled)
        try service.setDisabled(true, paths: paths)
        XCTAssertEqual(service.state(paths: paths), .disabled)
        XCTAssertFalse(fileManager.fileExists(atPath: executable.path))
        XCTAssertTrue(fileManager.fileExists(atPath: disabled.path))

        try service.setDisabled(false, paths: paths)
        XCTAssertEqual(service.state(paths: paths), .enabled)
        XCTAssertTrue(fileManager.fileExists(atPath: executable.path))
        XCTAssertFalse(fileManager.fileExists(atPath: disabled.path))
    }

    func testRepeatedRequestIsIdempotent() throws {
        try Data().write(to: executable)

        try service.setDisabled(true, paths: paths)
        XCTAssertNoThrow(try service.setDisabled(true, paths: paths))
        try service.setDisabled(false, paths: paths)
        XCTAssertNoThrow(try service.setDisabled(false, paths: paths))
    }

    func testMissingFilesAreReported() throws {
        XCTAssertEqual(service.state(paths: paths), .unavailable)
        XCTAssertThrowsError(try service.setDisabled(true, paths: paths))
    }

    func testExecutableTakesPriorityAndOverwritesStaleDisabledCopy() throws {
        try Data("current".utf8).write(to: executable)
        try Data("stale".utf8).write(to: disabled)

        XCTAssertEqual(service.state(paths: paths), .enabled)
        try service.setDisabled(true, paths: paths)

        XCTAssertEqual(service.state(paths: paths), .disabled)
        XCTAssertFalse(fileManager.fileExists(atPath: executable.path))
        XCTAssertEqual(try Data(contentsOf: disabled), Data("current".utf8))
    }

    private var solidWorksDirectory: URL {
        paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS")
    }

    private var executable: URL {
        solidWorksDirectory.appendingPathComponent(SolidWorksResourceMonitorService.executableName)
    }

    private var disabled: URL {
        solidWorksDirectory.appendingPathComponent(SolidWorksResourceMonitorService.disabledName)
    }
}
