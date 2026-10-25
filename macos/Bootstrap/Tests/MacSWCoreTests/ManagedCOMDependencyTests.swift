import CryptoKit
import Foundation
import XCTest
@testable import MacSWCore

final class ManagedCOMDependencyTests: XCTestCase {
    func testStdoleIsVerifiedAndProvisionedAtomically() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-stdole-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let source = bundle.appendingPathComponent("Contents/Resources/managed/stdole.dll")
        let prefix = root.appendingPathComponent("bottle")
        let data = Data("validated stdole".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: source)

        try PrerequisiteService.prepareManagedCOMDependencies(
            bundleURL: bundle, prefix: prefix, expectedSHA256: hash)
        let target = prefix.appendingPathComponent(PrerequisiteService.stdoleDestination)
        XCTAssertEqual(try Data(contentsOf: target), data)

        try Data("stale stdole".utf8).write(to: target)
        try PrerequisiteService.prepareManagedCOMDependencies(
            bundleURL: bundle, prefix: prefix, expectedSHA256: hash)
        XCTAssertEqual(try Data(contentsOf: target), data)

        XCTAssertThrowsError(try PrerequisiteService.prepareManagedCOMDependencies(
            bundleURL: bundle, prefix: prefix, expectedSHA256: String(repeating: "0", count: 64)))

        try fm.removeItem(at: source)
        XCTAssertThrowsError(try PrerequisiteService.prepareManagedCOMDependencies(
            bundleURL: bundle, prefix: prefix, expectedSHA256: hash))
    }
}
