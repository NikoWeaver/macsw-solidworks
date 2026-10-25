import Foundation
import XCTest
@testable import MacSWCore

final class FolderConsentTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Consent-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testProtectedFoldersComeFromBottleSymlinks() throws {
        let home = root.appendingPathComponent("home")
        let account = root.appendingPathComponent("bottle/drive_c/users/me")
        try fileManager.createDirectory(at: account, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: account.appendingPathComponent("Desktop").path,
                                           withDestinationPath: home.appendingPathComponent("Desktop").path)
        try fileManager.createSymbolicLink(atPath: account.appendingPathComponent("My Documents").path,
                                           withDestinationPath: home.path + "/Documents/sub")
        try fileManager.createSymbolicLink(atPath: account.appendingPathComponent("Music").path,
                                           withDestinationPath: home.appendingPathComponent("Music").path)
        // A real directory needs no consent.
        try fileManager.createDirectory(at: account.appendingPathComponent("Downloads"), withIntermediateDirectories: true)

        let folders = FolderConsentService.protectedFolders(
            prefix: root.appendingPathComponent("bottle"), home: home, fileManager: fileManager)
        XCTAssertEqual(folders.map(\.name), ["Desktop", "Documents"])
        XCTAssertEqual(folders.first?.url.path, home.appendingPathComponent("Desktop").standardizedFileURL.path)
    }

    func testSameFolderLinkedFromTwoAccountsIsListedOnce() throws {
        let home = root.appendingPathComponent("home")
        for name in ["a", "b"] {
            let account = root.appendingPathComponent("bottle/drive_c/users/\(name)")
            try fileManager.createDirectory(at: account, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: account.appendingPathComponent("Downloads").path,
                                               withDestinationPath: home.appendingPathComponent("Downloads").path)
        }
        let folders = FolderConsentService.protectedFolders(
            prefix: root.appendingPathComponent("bottle"), home: home, fileManager: fileManager)
        XCTAssertEqual(folders.map(\.name), ["Downloads"])
    }

    func testMissingBottleHasNoFolders() {
        XCTAssertEqual(FolderConsentService.protectedFolders(
            prefix: root.appendingPathComponent("none"), home: root, fileManager: fileManager), [])
    }

    /// Drive letters (dosdevices) count as well as profile links: B: -> Box and I: -> iCloud Drive
    /// are touched natively before Wine starts. H: (home) and Z: (/) only contain protected folders
    /// and do not count, as Z: never did.
    func testCloudFoldersBehindDriveLettersAndProfileLinks() throws {
        let home = root.appendingPathComponent("home")
        let bottle = root.appendingPathComponent("bottle")
        let account = bottle.appendingPathComponent("drive_c/users/me")
        let dos = bottle.appendingPathComponent("dosdevices")
        try fileManager.createDirectory(at: account, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dos, withIntermediateDirectories: true)
        let box = home.appendingPathComponent("Library/CloudStorage/Box-Box")
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        try fileManager.createSymbolicLink(atPath: account.appendingPathComponent("Box").path, withDestinationPath: box.path)
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("b:").path, withDestinationPath: box.path)
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("h:").path, withDestinationPath: home.path)
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("i:").path, withDestinationPath: iCloud.path + "/")
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("y:").path,
                                           withDestinationPath: home.path + "/Library/CloudStorage/OneDrive-Personal/Team")
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("z:").path, withDestinationPath: "/")
        // Not a protected folder: another Library folder.
        try fileManager.createSymbolicLink(atPath: dos.appendingPathComponent("l:").path,
                                           withDestinationPath: home.path + "/Library/Fonts")

        let folders = FolderConsentService.protectedFolders(prefix: bottle, home: home, fileManager: fileManager)
        XCTAssertEqual(folders.map(\.name), ["Box", "iCloud Drive", "OneDrive"])
        XCTAssertEqual(folders.map(\.url.path), [box.standardizedFileURL.path, iCloud.standardizedFileURL.path,
                                                 home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal").standardizedFileURL.path])
        XCTAssertEqual(FolderConsentService.waitingMessage(for: folders[0]),
                       "macOS is asking for permission to access your Box folder — click Allow so SOLIDWORKS can open and save files there.")
    }

    func testBoundedGivesUpAfterTheTimeoutWithoutWaitingForTheWork() async {
        let waiting = Box()
        let started = Date()
        let slow = await FolderConsentService.bounded(timeout: 0.3, announceAfter: 0.05, onWaiting: { waiting.add("waiting") }) { () -> Int in
            Thread.sleep(forTimeInterval: 1.5)
            return 1
        }
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2)
        XCTAssertEqual(waiting.names, ["waiting"])
        let quick = await FolderConsentService.bounded(timeout: 5, announceAfter: 2, onWaiting: { waiting.add("again") }) { 7 }
        XCTAssertEqual(quick, 7)
        XCTAssertEqual(waiting.names, ["waiting"])
    }

    func testCheckReportsGrantedDeniedAndNoAnswer() async {
        let folders = ["Desktop", "Documents", "Downloads"].map {
            FolderConsentService.ProtectedFolder(name: $0, url: root.appendingPathComponent($0))
        }
        let waiting = Box()
        let checks = await FolderConsentService.check(
            folders, timeout: 0.6, announceAfter: 0.1,
            list: { url in
                switch url.lastPathComponent {
                case "Desktop": return
                case "Documents": throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
                default: Thread.sleep(forTimeInterval: 1.5)
                }
            },
            onWaiting: { waiting.add($0.name) }
        )
        XCTAssertEqual(checks.map(\.access), [.granted, .denied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError).localizedDescription), .noAnswer])
        XCTAssertEqual(waiting.names, ["Downloads"])
        let summary = FolderConsentService.unavailableSummary(checks)
        XCTAssertTrue(summary?.contains("Documents, Downloads") == true)
        XCTAssertNil(FolderConsentService.unavailableSummary([checks[0]]))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
