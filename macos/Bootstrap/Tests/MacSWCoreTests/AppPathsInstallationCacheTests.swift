import Foundation
import XCTest
@testable import MacSWCore

final class AppPathsInstallationCacheTests: XCTestCase {
    private var bottle: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        bottle = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Paths-\(UUID().uuidString)")
        try fileManager.createDirectory(at: bottle, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AppPaths.invalidateInstallationState()
        try? fileManager.removeItem(at: bottle)
    }

    func testResolutionIsCachedUntilInstallationStateIsInvalidated() throws {
        let cached = AppPaths.resolveSolidWorksExecutable(in: bottle)
        let installed = bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe")
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: installed)

        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), cached, "第二次解析应命中缓存")

        AppPaths.invalidateInstallationState()
        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), installed, "失效后应重新解析到新路径")
    }

    /// 主路径是注册表里的 "SolidWorks Folder"，兜底路径只是"常见位置"。
    func testRegistryValueDecidesTheInstallLocation() throws {
        AppPaths.invalidateInstallationState()
        let installed = bottle.appendingPathComponent("drive_c/Program Files/Custom/SLDWORKS.exe")
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: installed)
        try "#32# Software registry\n[\n\"SolidWorks Folder\"=\"C:\\\\Program Files\\\\Custom\"\n]\n"
            .write(to: bottle.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), installed)
    }

    /// BOM 与转义都要处理：读不出来就会退回"常见位置"，装在非默认目录的 SOLIDWORKS 就找不到了。
    func testRegistryHiveIsReadRegardlessOfEncoding() throws {
        AppPaths.invalidateInstallationState()
        let installed = bottle.appendingPathComponent("drive_c/SWDir/SLDWORKS.exe")
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: installed)
        var bytes = Data([0xFF, 0xFE])
        for unit in "[\n\"SolidWorks Folder\"=\"C:\\\\SWDir\"\n]\n".utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        try bytes.write(to: bottle.appendingPathComponent("system.reg"))
        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), installed)
    }

    /// 注册表指向的目录里没有主程序时不能照着它返回，退回常见位置。
    func testRegistryValueIsIgnoredWhenThatPathHasNoExecutable() throws {
        AppPaths.invalidateInstallationState()
        try "[\n\"SolidWorks Folder\"=\"C:\\\\Nowhere\"\n]\n"
            .write(to: bottle.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let fallback = bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        try fileManager.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: fallback)
        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), fallback)
    }
}
