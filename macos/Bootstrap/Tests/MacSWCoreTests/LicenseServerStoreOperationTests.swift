import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class LicenseServerStoreOperationTests: XCTestCase {
    func testOperationIsClaimedSynchronously() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-license-operation-\(UUID().uuidString)")
        let store = LicenseServerStore(paths: AppPaths(appSupportDirectory: root))

        XCTAssertTrue(store.startOperationIfIdle())
        XCTAssertTrue(store.isOperating)
        XCTAssertFalse(store.startOperationIfIdle(), "第二个动作不能在首个异步 Task 启动前穿过操作锁")
    }
}
