import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class RuntimeFontPreparationTests: XCTestCase {
    private actor Calls {
        var count = 0
        func record() { count += 1 }
    }

    func testAppLaunchSharesOneFontPreparationTask() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-font-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(appSupportDirectory: support)
        let executable = paths.bottle.appendingPathComponent(
            "drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe"
        )
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        let calls = Calls()
        let licensing = LicenseServerStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licensing, fontLinkRepair: { _ in
            await calls.record()
            try await Task.sleep(nanoseconds: 20_000_000)
        })

        runtime.prepareFontLinkAtAppLaunch()
        runtime.prepareFontLinkAtAppLaunch()
        await runtime.startup(autoLaunch: false)
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testAppLaunchDoesNotCreateMissingBottle() async {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-font-missing-\(UUID().uuidString)")
        let paths = AppPaths(appSupportDirectory: support)
        let calls = Calls()
        let runtime = RuntimeStore(
            paths: paths,
            licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in await calls.record() }
        )

        runtime.prepareFontLinkAtAppLaunch()
        await runtime.startup(autoLaunch: false)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(paths.bottleExists)
    }

    func testFailedFontPreparationCanBeRetried() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-font-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(appSupportDirectory: support)
        let executable = paths.bottle.appendingPathComponent(
            "drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe"
        )
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        let calls = Calls()
        let runtime = RuntimeStore(
            paths: paths,
            licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in
                await calls.record()
                if await calls.count == 1 { throw NSError(domain: "MacSW.FontTest", code: 1) }
            }
        )

        await runtime.startup(autoLaunch: false)
        XCTAssertTrue(runtime.statusMessage.contains("Checking the PingFang font link failed"))
        try await runtime.ensureFontLinkPrepared()
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testBottleDeletionCancelsAndWaitsForFontPreparation() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-font-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(appSupportDirectory: support)
        let executable = paths.bottle.appendingPathComponent(
            "drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe"
        )
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        let calls = Calls()
        let runtime = RuntimeStore(
            paths: paths,
            licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in
                await calls.record()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )

        runtime.prepareFontLinkAtAppLaunch()
        await runtime.suspendFontPreparationForBottleDeletion()
        let countAfterCancellation = await calls.count
        XCTAssertEqual(countAfterCancellation, 1)
        do {
            try await runtime.ensureFontLinkPrepared()
            XCTFail("容器删除期间不应再启动字体检查")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("The bottle is being cleaned up"))
        }
        runtime.resumeFontPreparationAfterBottleDeletion()
    }
}
