import Foundation
import XCTest
@testable import MacSWCore

/// Everything runs on a fake home and a fake prefix in a temporary directory: no real home,
/// CloudStorage, iCloud Drive or bottle is looked at.
final class DriveMapServiceTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var prefix: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("MacSW-DriveMaps-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        prefix = root.appendingPathComponent("support/bottle", isDirectory: true)
        for dir in ["home/Documents", "home/Library/CloudStorage/Box-Box/Project", "home/Library/CloudStorage/OneDrive-Personal",
                    "home/Library/CloudStorage/GoogleDrive-me@example.com", "home/Library/CloudStorage/.hidden",
                    "home/Library/Mobile Documents/com~apple~CloudDocs",
                    "support/bottle/dosdevices", "support/bottle/drive_c/users/me", "elsewhere"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: home.appendingPathComponent("Library/CloudStorage/notes.txt").path, contents: Data())
        try link("support/bottle/dosdevices/c:", "../drive_c")
        try link("support/bottle/dosdevices/z:", "/")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func link(_ path: String, _ destination: String) throws {
        try fm.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
    }

    private func destination(_ path: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(path).path)
    }

    /// Whether anything (also a dangling link) exists at `path`.
    private func exists(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)) != nil
    }

    /// Stands in for macOS when `maintain` lists a cloud folder natively: records the folder and
    /// refuses (EPERM) or never answers (blocks until released) for the given folder names;
    /// `onList` runs while a listing is pending (the macOS prompt on screen).
    /// Touches no disk, so it can outlive the temporary directory.
    private final class FakeAccess: @unchecked Sendable {
        private let lock = NSLock()
        private var listed: [String] = []
        private let denied: Set<String>
        private let unanswered: Set<String>
        private let onList: @Sendable (String) -> Void
        let release = DispatchSemaphore(value: 0)

        init(denied: Set<String> = [], unanswered: Set<String> = [], onList: @escaping @Sendable (String) -> Void = { _ in }) {
            self.denied = denied
            self.unanswered = unanswered
            self.onList = onList
        }

        func list(_ url: URL) throws {
            lock.lock(); listed.append(url.lastPathComponent); lock.unlock()
            onList(url.lastPathComponent)
            if denied.contains(url.lastPathComponent) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            if unanswered.contains(url.lastPathComponent) { _ = release.wait(timeout: .now() + 10) }
        }

        var names: [String] { lock.lock(); defer { lock.unlock() }; return listed }
    }

    private func cloud(_ name: String) -> String { home.appendingPathComponent("Library/CloudStorage/\(name)").path }
    private var iCloud: String { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path }

    private func apply(_ letters: inout [String: String], userName: String = "me") -> [DriveMapService.Change] {
        DriveMapService.apply(DriveMapService.folders(home: home), prefix: prefix, userName: userName, letters: &letters)
    }

    private func outcomes(_ changes: [DriveMapService.Change]) -> [String] {
        changes.map { "\($0.item) \($0.folder) \($0.outcome.rawValue)" }
    }

    func testProviderNames() {
        XCTAssertEqual(DriveMapService.providerName("Box-Box"), "Box")
        XCTAssertEqual(DriveMapService.providerName("OneDrive-Personal"), "OneDrive")
        XCTAssertEqual(DriveMapService.providerName("GoogleDrive-me@example.com"), "GoogleDrive")
        XCTAssertEqual(DriveMapService.providerName("Dropbox"), "Dropbox")
        XCTAssertEqual(DriveMapService.providerName("-odd"), "-odd")
    }

    func testFoldersAreHomeCloudStorageAndICloudDrive() throws {
        let folders = DriveMapService.folders(home: home)
        XCTAssertEqual(folders.map(\.key), ["home", "cloud:Box-Box", "cloud:GoogleDrive-me@example.com",
                                            "cloud:OneDrive-Personal", "icloud"])
        XCTAssertEqual(folders.map(\.name), ["Home", "Box", "GoogleDrive", "OneDrive", "iCloud Drive"])
        XCTAssertEqual(folders.map { $0.fixedLetter.map { String($0) } ?? "-" }, ["H", "B", "-", "-", "I"])
        XCTAssertEqual(folders[0].profileNames, [], "no profile link for the home folder (it holds the bottle)")
        XCTAssertEqual(folders[1].profileNames, ["Box", "Box-Box"])
        XCTAssertEqual(folders[4].profileNames, ["iCloud Drive"])
        XCTAssertEqual(folders[1].url.path, cloud("Box-Box"))

        // iCloud Drive only when it exists.
        try fm.removeItem(at: URL(fileURLWithPath: iCloud))
        XCTAssertEqual(DriveMapService.folders(home: home).last?.key, "cloud:OneDrive-Personal")
        // No CloudStorage at all: just the home folder.
        XCTAssertEqual(DriveMapService.folders(home: root.appendingPathComponent("nobody")).map(\.key), ["home"])
    }

    func testFreshPrefixGetsLettersAndProfileLinksAndASecondRunChangesNothing() throws {
        var letters: [String: String] = [:]
        let first = apply(&letters)
        XCTAssertEqual(outcomes(first), [
            "H: Home created", "B: Box created", "Y: GoogleDrive created", "X: OneDrive created", "I: iCloud Drive created",
            "profile/Box Box created", "profile/GoogleDrive GoogleDrive created", "profile/OneDrive OneDrive created",
            "profile/iCloud Drive iCloud Drive created"
        ])
        XCTAssertEqual(destination("support/bottle/dosdevices/h:"), home.path)
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))
        XCTAssertEqual(destination("support/bottle/dosdevices/i:"), iCloud)
        XCTAssertEqual(destination("support/bottle/dosdevices/y:"), cloud("GoogleDrive-me@example.com"))
        XCTAssertEqual(destination("support/bottle/dosdevices/x:"), cloud("OneDrive-Personal"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Box"), cloud("Box-Box"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/iCloud Drive"), iCloud)
        XCTAssertEqual(destination("support/bottle/dosdevices/c:"), "../drive_c")
        XCTAssertEqual(destination("support/bottle/dosdevices/z:"), "/")
        XCTAssertEqual(letters, ["home": "H", "cloud:Box-Box": "B", "cloud:GoogleDrive-me@example.com": "Y",
                                 "cloud:OneDrive-Personal": "X", "icloud": "I"])

        let entries = try fm.contentsOfDirectory(atPath: prefix.appendingPathComponent("dosdevices").path).sorted()
        let before = letters
        let second = apply(&letters)
        XCTAssertTrue(second.allSatisfy { $0.outcome == .present }, outcomes(second).joined(separator: ", "))
        XCTAssertEqual(second.count, first.count)
        XCTAssertEqual(letters, before)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: prefix.appendingPathComponent("dosdevices").path).sorted(), entries)
    }

    /// The owner's hand-made setup: b: -> Box-Box, h: -> ~ (trailing slash) and users/<user>/Box.
    func testHandMadeMappingsAreAdoptedNotDuplicated() throws {
        try link("support/bottle/dosdevices/b:", cloud("Box-Box"))
        try link("support/bottle/dosdevices/h:", home.path + "/")
        try link("support/bottle/drive_c/users/me/Box", cloud("Box-Box"))
        var letters: [String: String] = [:]
        let changes = apply(&letters)
        XCTAssertEqual(Array(outcomes(changes).prefix(2)), ["H: Home present", "B: Box present"])
        XCTAssertTrue(outcomes(changes).contains("profile/Box Box present"))
        XCTAssertEqual(destination("support/bottle/dosdevices/h:"), home.path + "/", "left exactly as it was")
        XCTAssertEqual(letters["cloud:Box-Box"], "B")

        // A cloud folder already under another letter or profile name keeps it (no second pool
        // letter, no second link); the documented H:, B: and I: are still made when free.
        let other = root.appendingPathComponent("other/bottle")
        try fm.createDirectory(at: other.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other.appendingPathComponent("drive_c/users/me"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: other.appendingPathComponent("dosdevices/p:").path, withDestinationPath: cloud("OneDrive-Personal"))
        try fm.createSymbolicLink(atPath: other.appendingPathComponent("dosdevices/y:").path, withDestinationPath: home.path)
        try fm.createSymbolicLink(atPath: other.appendingPathComponent("drive_c/users/me/My Box").path, withDestinationPath: cloud("Box-Box"))
        var otherLetters: [String: String] = [:]
        let otherChanges = outcomes(DriveMapService.apply(DriveMapService.folders(home: home), prefix: other, userName: "me", letters: &otherLetters))
        XCTAssertTrue(otherChanges.contains("P: OneDrive present"), otherChanges.joined(separator: ", "))
        XCTAssertTrue(otherChanges.contains("H: Home created"))
        XCTAssertTrue(otherChanges.contains("X: GoogleDrive created"), "Y: is taken by the hand-made home link")
        XCTAssertTrue(otherChanges.contains("profile/My Box Box present"))
        XCTAssertEqual(otherLetters["cloud:OneDrive-Personal"], "P")
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: other.appendingPathComponent("dosdevices/y:").path), home.path)
        XCTAssertFalse(fm.fileExists(atPath: other.appendingPathComponent("drive_c/users/me/Box").path))
    }

    func testExistingLettersAndNamesThatPointElsewhereAreNeverTouched() throws {
        try link("support/bottle/dosdevices/h:", root.appendingPathComponent("elsewhere").path)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices/b:"), withIntermediateDirectories: true)
        try link("support/bottle/dosdevices/i:", "/does/not/exist")
        try link("support/bottle/dosdevices/y::", "/dev/disk9")
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users/me/box"), withIntermediateDirectories: true)
        try link("support/bottle/drive_c/users/me/iCloud Drive", root.appendingPathComponent("elsewhere").path)
        var letters: [String: String] = [:]
        let changes = outcomes(apply(&letters))
        XCTAssertEqual(Array(changes.prefix(5)), [
            "H: Home conflict", "B: Box conflict", "X: GoogleDrive created", "W: OneDrive created", "I: iCloud Drive conflict"
        ])
        XCTAssertTrue(changes.contains("profile/Box-Box Box created"), "\"box\" (any case) is taken: the full name is used")
        XCTAssertTrue(changes.contains("profile/iCloud Drive iCloud Drive conflict"))
        XCTAssertEqual(destination("support/bottle/dosdevices/h:"), root.appendingPathComponent("elsewhere").path)
        XCTAssertEqual(destination("support/bottle/dosdevices/i:"), "/does/not/exist", "a dangling link is not replaced")
        XCTAssertNil(destination("support/bottle/dosdevices/b:"), "a real directory stays a directory")
        XCTAssertNil(destination("support/bottle/dosdevices/y:"), "y:: (device) takes Y:")
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/iCloud Drive"), root.appendingPathComponent("elsewhere").path)
        XCTAssertNil(letters["home"])
        XCTAssertNil(letters["cloud:Box-Box"])
    }

    func testStoredLettersAreKeptAndReservedForMissingFolders() throws {
        // Dropbox had Y: before and is gone for now; OneDrive had W:.
        var letters = ["cloud:Dropbox": "Y", "cloud:OneDrive-Personal": "W"]
        let changes = outcomes(apply(&letters))
        XCTAssertTrue(changes.contains("W: OneDrive created"))
        XCTAssertTrue(changes.contains("X: GoogleDrive created"), "Y: stays reserved for Dropbox")
        XCTAssertEqual(letters["cloud:Dropbox"], "Y")
        XCTAssertNil(destination("support/bottle/dosdevices/y:"))

        // A stored letter that something else took meanwhile is reported, not moved.
        let other = root.appendingPathComponent("other/bottle")
        try fm.createDirectory(at: other.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: other.appendingPathComponent("dosdevices/w:").path, withDestinationPath: "/Volumes/USB")
        var stored = ["cloud:OneDrive-Personal": "W"]
        let otherChanges = outcomes(DriveMapService.apply(DriveMapService.folders(home: home), prefix: other, userName: "me", letters: &stored))
        XCTAssertTrue(otherChanges.contains("W: OneDrive conflict"))
        XCTAssertEqual(stored["cloud:OneDrive-Personal"], "W")
        // A stored letter outside the pool (a damaged table) is not used.
        var damaged = ["cloud:GoogleDrive-me@example.com": "C"]
        let third = root.appendingPathComponent("third/bottle")
        try fm.createDirectory(at: third.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        let thirdChanges = outcomes(DriveMapService.apply(DriveMapService.folders(home: home), prefix: third, userName: "me", letters: &damaged))
        XCTAssertTrue(thirdChanges.contains("Y: GoogleDrive created"))
        XCTAssertEqual(damaged["cloud:GoogleDrive-me@example.com"], "Y")
    }

    func testRunningOutOfLettersIsReported() throws {
        for letter in DriveMapService.poolLetters {
            try link("support/bottle/dosdevices/\(letter.lowercased()):", "/Volumes/V\(letter)")
        }
        var letters: [String: String] = [:]
        let changes = outcomes(apply(&letters))
        XCTAssertTrue(changes.contains("- GoogleDrive noFreeLetter"))
        XCTAssertTrue(changes.contains("- OneDrive noFreeLetter"))
        XCTAssertTrue(changes.contains("B: Box created"), "B:, H: and I: are not in the pool")
    }

    func testNothingHappensWithoutAnInitializedPrefix() throws {
        let fresh = root.appendingPathComponent("fresh/bottle")
        var letters: [String: String] = [:]
        XCTAssertEqual(DriveMapService.apply(DriveMapService.folders(home: home), prefix: fresh, userName: "me", letters: &letters), [])
        XCTAssertFalse(fm.fileExists(atPath: fresh.path))
        XCTAssertEqual(letters, [:])

        // dosdevices but no profile folder for this user: letters only, no profile folder is made.
        let changes = apply(&letters, userName: "nobody")
        XCTAssertFalse(changes.contains { $0.item.hasPrefix("profile/") })
        XCTAssertFalse(fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/users/nobody").path))
        XCTAssertEqual(apply(&letters, userName: "../me").filter { $0.item.hasPrefix("profile/") }, [])
    }

    func testMaintainHonoursTheSettingKeepsTheTableAndLogs() async throws {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        let table = paths.appSupportDirectory.appendingPathComponent(DriveMapService.lettersFileName)
        let log = paths.logs.appendingPathComponent(DriveMapService.logName)

        let untouched = FakeAccess()
        let off = await DriveMapService.maintain(paths: paths, enabled: false, home: home, userName: "me",
                                                 list: { try untouched.list($0) })
        XCTAssertNil(off)
        XCTAssertEqual(untouched.names, [], "off: no cloud folder is opened")
        XCTAssertNil(destination("support/bottle/dosdevices/h:"))
        XCTAssertTrue(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("off in Settings"))

        let on = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me")
        XCTAssertEqual(on?.filter { $0.outcome == .created }.count, 9)
        XCTAssertEqual(DriveMapService.loadLetters(from: table)["cloud:Box-Box"], "B")
        XCTAssertEqual(DriveMapService.loadLetters(from: table)["cloud:OneDrive-Personal"], "X")
        XCTAssertEqual((try fm.attributesOfItem(atPath: table.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("B: Box=created"), text)
        let mode = (try fm.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)

        // The bottle was reinstalled: the stored letters come back.
        try fm.removeItem(at: paths.bottle)
        try fm.createDirectory(at: paths.bottle.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.removeItem(at: URL(fileURLWithPath: cloud("GoogleDrive-me@example.com")))
        let again = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me")
        XCTAssertTrue(again?.contains(DriveMapService.Change(item: "X:", folder: "OneDrive", outcome: .created)) == true)
        XCTAssertEqual(DriveMapService.loadLetters(from: table)["cloud:GoogleDrive-me@example.com"], "Y")

        // No bottle (not created yet): nothing is read, written or logged.
        let empty = AppPaths(appSupportDirectory: root.appendingPathComponent("empty"))
        let none = await DriveMapService.maintain(paths: empty, enabled: true, home: home, userName: "me")
        XCTAssertNil(none)
        XCTAssertFalse(fm.fileExists(atPath: empty.appSupportDirectory.path))
    }

    /// A new letter makes Wine open the folder at every start (mountmgr reads each drive root), so
    /// a cloud folder that macOS does not let MacSW open gets no new letter or profile link.
    func testMaintainMapsOnlyCloudFoldersMacOSLetsMacSWOpen() async throws {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        let table = paths.appSupportDirectory.appendingPathComponent(DriveMapService.lettersFileName)
        let log = paths.logs.appendingPathComponent(DriveMapService.logName)
        // Box: "Don't Allow"; iCloud Drive: nobody answers the prompt.
        let refusing = FakeAccess(denied: ["Box-Box"], unanswered: ["com~apple~CloudDocs"])
        addTeardownBlock { refusing.release.signal() }
        let first = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me", timeout: 1,
                                                   list: { try refusing.list($0) })
        refusing.release.signal()
        XCTAssertEqual(refusing.names, ["Box-Box", "GoogleDrive-me@example.com", "OneDrive-Personal", "com~apple~CloudDocs"])
        XCTAssertEqual(outcomes(first ?? []), [
            "H: Home created", "Y: GoogleDrive created", "X: OneDrive created",
            "profile/GoogleDrive GoogleDrive created", "profile/OneDrive OneDrive created",
            "- Box noAccess", "- iCloud Drive noAccess"
        ])
        for path in ["dosdevices/b:", "dosdevices/i:", "drive_c/users/me/Box", "drive_c/users/me/Box-Box",
                     "drive_c/users/me/iCloud Drive"] {
            XCTAssertFalse(exists("support/bottle/\(path)"), path)
        }
        XCTAssertEqual(DriveMapService.loadLetters(from: table),
                       ["home": "H", "cloud:GoogleDrive-me@example.com": "Y", "cloud:OneDrive-Personal": "X"])
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("- Box=noAccess") && text.contains("- iCloud Drive=noAccess"), text)

        // Allowed later: the next run maps them, and lists only the folders that get something new.
        let allowing = FakeAccess()
        let second = outcomes(await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me",
                                                             timeout: 1, list: { try allowing.list($0) }) ?? [])
        XCTAssertEqual(allowing.names, ["Box-Box", "com~apple~CloudDocs"])
        for change in ["B: Box created", "I: iCloud Drive created", "profile/Box Box created",
                       "profile/iCloud Drive iCloud Drive created", "Y: GoogleDrive present"] {
            XCTAssertTrue(second.contains(change), change + " in " + second.joined(separator: ", "))
        }
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))

        // Everything mapped: no folder is listed (the launch's consent check takes them).
        let idle = FakeAccess(denied: ["Box-Box", "com~apple~CloudDocs"])
        let third = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me",
                                                   timeout: 1, list: { try idle.list($0) })
        XCTAssertEqual(idle.names, [])
        XCTAssertTrue(third?.allSatisfy { $0.outcome == .present } == true, outcomes(third ?? []).joined(separator: ", "))
    }

    func testHandMadeLinksToARefusedCloudFolderStayAsTheyAre() async throws {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        try link("support/bottle/dosdevices/b:", cloud("Box-Box"))
        let refusing = FakeAccess(denied: ["Box-Box"])
        let changes = outcomes(await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me",
                                                              timeout: 5, list: { try refusing.list($0) }) ?? [])
        XCTAssertTrue(changes.contains("- Box noAccess"), changes.joined(separator: ", "))
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"), "never removed")
        XCTAssertFalse(exists("support/bottle/drive_c/users/me/Box"), "no new profile link for a refused folder")

        // The owner's hand-made b: and users/<user>/Box: nothing new for Box, so it is not listed
        // here (the consent check right after touches it) and both links are reported as present.
        try link("support/bottle/drive_c/users/me/Box", cloud("Box-Box"))
        let watching = FakeAccess(denied: ["Box-Box"])
        let again = outcomes(await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me",
                                                            timeout: 5, list: { try watching.list($0) }) ?? [])
        XCTAssertFalse(watching.names.contains("Box-Box"), watching.names.joined(separator: ", "))
        XCTAssertTrue(again.contains("B: Box present") && again.contains("profile/Box Box present"), again.joined(separator: ", "))
    }

    /// While a Wine session of the bottle runs (maybe started by another app that macOS refused a
    /// cloud folder), no cloud letter or link is added; the next run without a session adds them.
    /// The folders are still listed natively (the prompts belong to MacSW, not Wine).
    func testMaintainAddsNoCloudLinkWhileAWineSessionRuns() async throws {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        let log = paths.logs.appendingPathComponent(DriveMapService.logName)
        let access = FakeAccess()
        let during = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me", timeout: 1,
                                                    list: { try access.list($0) }, isRunning: { _ in true })
        XCTAssertEqual(outcomes(during ?? []), ["H: Home created"])
        XCTAssertEqual(access.names, ["Box-Box", "GoogleDrive-me@example.com", "OneDrive-Personal", "com~apple~CloudDocs"])
        for path in ["dosdevices/b:", "dosdevices/i:", "dosdevices/x:", "dosdevices/y:", "drive_c/users/me/Box"] {
            XCTAssertFalse(exists("support/bottle/\(path)"), path)
        }
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Wine session running"))
        let after = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me", timeout: 1,
                                                   list: { try access.list($0) }, isRunning: { _ in false })
        XCTAssertTrue(outcomes(after ?? []).contains("B: Box created"), outcomes(after ?? []).joined(separator: ", "))
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The third review's probe: another app starts a Wine session while MacSW's native check
    /// waits on a macOS prompt. The session is asked after the checks, so it gets no new cloud
    /// letter or link when the owner clicks Allow.
    func testMaintainAddsNoCloudLinkToASessionThatStartsDuringTheNativeCheck() async throws {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        let started = Flag()
        let access = FakeAccess(onList: { _ in started.set() })
        let changes = await DriveMapService.maintain(paths: paths, enabled: true, home: home, userName: "me", timeout: 2,
                                                     list: { try access.list($0) }, isRunning: { _ in started.isSet })
        XCTAssertTrue(started.isSet)
        XCTAssertFalse(access.names.isEmpty, "the cloud folders were listed natively")
        XCTAssertEqual(outcomes(changes ?? []), ["H: Home created"])
        for path in ["dosdevices/b:", "dosdevices/i:", "dosdevices/x:", "dosdevices/y:", "drive_c/users/me/Box",
                     "drive_c/users/me/OneDrive"] {
            XCTAssertFalse(exists("support/bottle/\(path)"), path)
        }
    }

    /// The third review's probe: a CloudStorage folder whose provider part is a shell folder name
    /// ("Pictures-Acme") gets its profile link under its full name, which the bottle gate can set
    /// aside (it never moves Desktop, Documents, Downloads, Music, Pictures or Videos).
    func testProfileLinksNeverTakeAShellFolderName() throws {
        try fm.createDirectory(atPath: cloud("Pictures-Acme"), withIntermediateDirectories: true)
        var letters: [String: String] = [:]
        let changes = outcomes(apply(&letters))
        XCTAssertTrue(changes.contains("profile/Pictures-Acme Pictures created"), changes.joined(separator: ", "))
        XCTAssertFalse(exists("support/bottle/drive_c/users/me/Pictures"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Pictures-Acme"), cloud("Pictures-Acme"))
        let link = WineBottleGate.links(prefix: prefix, home: home).first { $0.item == "drive_c/users/me/Pictures-Acme" }
        XCTAssertEqual(link?.isGated, true)
    }

    func testLetterTableToleratesDamage() throws {
        let file = root.appendingPathComponent("support/\(DriveMapService.lettersFileName)")
        XCTAssertEqual(DriveMapService.loadLetters(from: file), [:])
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(DriveMapService.loadLetters(from: file), [:])
        try Data(#"{"a":"Y","b":"yy","c":"x","d":"Ö"}"#.utf8).write(to: file)
        XCTAssertEqual(DriveMapService.loadLetters(from: file), ["a": "Y"])
        DriveMapService.saveLetters(["cloud:Box-Box": "B"], to: file)
        XCTAssertEqual(DriveMapService.loadLetters(from: file), ["cloud:Box-Box": "B"])
    }
}

/// The launch preflight keeps the drive letters before it touches the folders they open up.
@MainActor
final class DriveMapLaunchOrderTests: XCTestCase {
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testLaunchMapsDrivesBeforeTheConsentCheck() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-DriveOrder-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(appSupportDirectory: support)
        let executable = paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        AppPaths.invalidateInstallationState()
        let order = Order()
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in order.add("font") }, swcliPreparation: { _ in },
            processSnapshot: { _, _ in [] },
            bottleGate: { prefix, _ in
                XCTAssertEqual(prefix, paths.bottle)
                order.add("consent")
                return .init()
            },
            driveMaps: { mapped, _ in
                XCTAssertEqual(mapped.bottle, paths.bottle)
                order.add("drives")
            },
            solidWorksStarter: { _, _, _, _, completion in completion(false, "not started (test)") })
        store.launch()
        for _ in 0..<300 where store.state == .starting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The font check runs the bottle gate again itself (nothing left to ask by then).
        XCTAssertEqual(Array(order.all.prefix(4)), ["drives", "consent", "consent", "font"])
    }
}
