import Darwin
import Foundation
import XCTest
@testable import MacSWCore

final class DownloadQuarantineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsw-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The value macOS writes for a download (flags;time;agent;UUID).
    private func quarantine(_ url: URL) {
        let value = "0083;6718a000;Safari;00000000-0000-0000-0000-000000000000"
        XCTAssertEqual(setxattr(url.path, DownloadQuarantine.attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0,
                       url.path)
    }

    /// A small bundle with a nested helper, a relative link inside it and a link to a file outside it.
    private func makeBundle(outside: URL) throws -> (app: URL, items: [URL]) {
        let app = directory.appendingPathComponent("MacSW.app", isDirectory: true)
        let unix = app.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        let loader = unix.appendingPathComponent("MacSW")
        try Data("loader".utf8).write(to: loader)
        let info = app.appendingPathComponent("Contents/Info.plist")
        try Data("plist".utf8).write(to: info)
        let wine = unix.appendingPathComponent("wine")
        try FileManager.default.createSymbolicLink(atPath: wine.path, withDestinationPath: "MacSW")
        let external = app.appendingPathComponent("Contents/external")
        try FileManager.default.createSymbolicLink(at: external, withDestinationURL: outside)
        let items = [app, app.appendingPathComponent("Contents"), unix, loader, info, wine, external]
        items.forEach(quarantine)
        return (app, items)
    }

    func testDecisionAsksOnlyForAFlaggedBundleThatCanBeChanged() {
        let app = URL(fileURLWithPath: "/Applications/MacSW.app")
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false) { _ in false }, .nothing)
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: true) { _ in false }, .nothing)
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false) { _ in true }, .ask)
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: true) { _ in true }, .suppressed)
        let translocated = URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/1234-ABCD/d/MacSW.app")
        XCTAssertEqual(DownloadQuarantine.decision(bundle: translocated, suppressed: false) { _ in true }, .translocated)
        XCTAssertEqual(DownloadQuarantine.decision(bundle: translocated, suppressed: true) { _ in true }, .translocated,
                       "the move hint is not a question, so suppression does not hide it")
        XCTAssertEqual(DownloadQuarantine.decision(bundle: translocated, suppressed: false) { _ in false }, .nothing)
    }

    func testTheCheckLooksAtTheBundleFolderItself() throws {
        let app = directory.appendingPathComponent("MacSW.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false), .nothing)
        quarantine(app)
        XCTAssertTrue(DownloadQuarantine.hasAttribute(app))
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false), .ask)
    }

    func testRemoveClearsTheWholeBundleAndNothingOutsideIt() throws {
        let outside = directory.appendingPathComponent("Box folder file.sldprt")
        try Data("model".utf8).write(to: outside)
        quarantine(outside)
        let sibling = directory.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        quarantine(sibling)
        let (app, items) = try makeBundle(outside: outside)

        XCTAssertEqual(try DownloadQuarantine.remove(from: app), items.count)
        for item in items {
            XCTAssertFalse(DownloadQuarantine.hasAttribute(item), item.path)
        }
        XCTAssertTrue(DownloadQuarantine.hasAttribute(outside), "a link is changed itself, its target is not")
        XCTAssertTrue(DownloadQuarantine.hasAttribute(sibling))
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false), .nothing)
        XCTAssertEqual(try DownloadQuarantine.remove(from: app), 0, "a second run finds nothing to do")
    }

    func testRemoveRefusesAnythingButAnAppFolder() throws {
        let folder = directory.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        quarantine(folder)
        XCTAssertThrowsError(try DownloadQuarantine.remove(from: folder))
        XCTAssertTrue(DownloadQuarantine.hasAttribute(folder))

        let target = directory.appendingPathComponent("Real.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        quarantine(target)
        let link = directory.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try DownloadQuarantine.remove(from: link))
        XCTAssertTrue(DownloadQuarantine.hasAttribute(target))
    }

    func testAFailureLeavesTheBundleFlaggedSoTheNextLaunchAsksAgain() throws {
        let (app, _) = try makeBundle(outside: directory.appendingPathComponent("missing"))
        // APFS refuses to change the attributes of a read-only file (EACCES), even for its owner.
        let blocked = app.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW")
        XCTAssertEqual(chmod(blocked.path, 0o444), 0)
        defer { _ = chmod(blocked.path, 0o644) }
        XCTAssertThrowsError(try DownloadQuarantine.remove(from: app))
        XCTAssertTrue(DownloadQuarantine.hasAttribute(blocked))
        XCTAssertTrue(DownloadQuarantine.hasAttribute(app))
        XCTAssertEqual(DownloadQuarantine.decision(bundle: app, suppressed: false), .ask)
    }

    func testTheQuestionIsThePlansText() {
        XCTAssertEqual(DownloadQuarantine.consentText,
                       "MacSW will remove the download flag from its own files so that macOS does not block its Wine helpers.")
    }
}
