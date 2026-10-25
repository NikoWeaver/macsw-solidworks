import Foundation
import XCTest
@testable import MacSWCore

final class BottleLayoutTests: XCTestCase {
    private var prefix: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        prefix = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Layout-\(UUID().uuidString)")
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: prefix)
    }

    func testDesktopLinkIsRedirectedForTheInstallAndRestoredAfterwards() throws {
        let realDesktop = prefix.appendingPathComponent("outside-desktop")
        try fileManager.createDirectory(at: realDesktop, withIntermediateDirectories: true)
        let desktop = prefix.appendingPathComponent("drive_c/users/YJBeetle/Desktop")
        try fileManager.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: desktop.path, withDestinationPath: realDesktop.path)

        let redirected = try PrerequisiteService.redirectDesktopFolders(prefix: prefix, fileManager: fileManager)
        XCTAssertEqual(redirected.map(\.account), ["YJBeetle"])
        XCTAssertEqual(redirected.first?.originalDestination, realDesktop.path)
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: desktop.path))

        // 安装器把快捷方式写进容器内，真实 macOS 桌面不受影响。
        try Data("lnk".utf8).write(to: desktop.appendingPathComponent("SOLIDWORKS 2025.lnk"))
        XCTAssertTrue(fileManager.fileExists(atPath: realDesktop.path))
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: realDesktop.path).count, 0)

        try PrerequisiteService.restoreDesktopFolders(prefix: prefix, to: redirected, fileManager: fileManager)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: desktop.path), realDesktop.path)
        XCTAssertFalse(fileManager.fileExists(atPath: desktop.appendingPathComponent("SOLIDWORKS 2025.lnk").path))

        // 重复恢复不应破坏已就位的链接。
        try PrerequisiteService.restoreDesktopFolders(prefix: prefix, to: redirected, fileManager: fileManager)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: desktop.path), realDesktop.path)
    }

    func testRealDesktopFolderIsLeftAloneOnRestore() throws {
        let existing = prefix.appendingPathComponent("drive_c/users/Public/Desktop")
        try fileManager.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("lnk".utf8).write(to: existing.appendingPathComponent("keep.lnk"))

        let redirected = try PrerequisiteService.redirectDesktopFolders(prefix: prefix, fileManager: fileManager)
        XCTAssertEqual(redirected.first?.originalDestination, "")
        try PrerequisiteService.restoreDesktopFolders(prefix: prefix, to: redirected, fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: existing.appendingPathComponent("keep.lnk").path))
    }

    func testShortNameAliasesAreCreatedWithoutTouchingRealDirectories() throws {
        let programFiles = prefix.appendingPathComponent("drive_c/Program Files")
        try fileManager.createDirectory(at: programFiles, withIntermediateDirectories: true)
        // 已存在但指向别处的链接会被纠正。
        let alias = prefix.appendingPathComponent("drive_c/PROGRA~1")
        try fileManager.createSymbolicLink(atPath: alias.path, withDestinationPath: "Somewhere Else")

        try PrerequisiteService.prepareShortNameAliases(prefix: prefix, fileManager: fileManager)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: alias.path), "Program Files")

        let second = prefix.appendingPathComponent("drive_c/PROGRA~2")
        try fileManager.createDirectory(at: second, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: prefix.appendingPathComponent("drive_c/Program Files (x86)"),
            withIntermediateDirectories: true
        )
        try PrerequisiteService.prepareShortNameAliases(prefix: prefix, fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: second.appendingPathComponent("").path))
        XCTAssertNil(try? fileManager.destinationOfSymbolicLink(atPath: second.path))
    }
}
