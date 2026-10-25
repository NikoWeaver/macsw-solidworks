import Foundation
import XCTest
@testable import MacSWCore

/// Everything runs on a fake home and a fake bottle in a temporary directory, with a fake `list`
/// standing in for macOS and a fresh consent session per test: no real home, cloud folder,
/// Wine or macOS prompt is involved.
final class WineBottleGateTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var prefix: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("MacSW-Gate-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        prefix = root.appendingPathComponent("support/bottle", isDirectory: true)
        for dir in ["home/Documents", "home/Downloads", "home/Library/CloudStorage/Box-Box/Project",
                    "home/Library/CloudStorage/OneDrive-Personal", "elsewhere",
                    "support/bottle/dosdevices", "support/bottle/drive_c/users/me"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try link("support/bottle/dosdevices/c:", "../drive_c")
        try link("support/bottle/dosdevices/z:", "/")
        try link("support/bottle/dosdevices/h:", home.path)
        try link("support/bottle/dosdevices/b:", cloud("Box-Box"))
        try link("support/bottle/dosdevices/y:", cloud("OneDrive-Personal"))
        // The user's own letter and profile link to a project folder: never touched.
        try link("support/bottle/dosdevices/q:", root.appendingPathComponent("elsewhere").path)
        try link("support/bottle/drive_c/users/me/Projects", root.appendingPathComponent("elsewhere").path)
        try link("support/bottle/drive_c/users/me/Box", cloud("Box-Box"))
        try link("support/bottle/drive_c/users/me/Documents", home.appendingPathComponent("Documents").path)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func link(_ path: String, _ destination: String) throws {
        try fm.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
    }
    private func destination(_ path: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent(path).path)
    }
    private func held(_ item: String) -> String? { destination("support/bottle/.macsw-held/" + item) }
    private func cloud(_ name: String) -> String { home.appendingPathComponent("Library/CloudStorage/\(name)").path }
    private var allBottleLinks: [String: String] {
        var links: [String: String] = [:]
        for item in ["dosdevices/c:", "dosdevices/z:", "dosdevices/h:", "dosdevices/b:", "dosdevices/y:", "dosdevices/q:",
                     "drive_c/users/me/Projects", "drive_c/users/me/Box", "drive_c/users/me/Documents"] {
            links[item] = destination("support/bottle/" + item)
        }
        return links
    }

    /// macOS stand-in: grants, refuses (EPERM) or never answers by folder name; records the listings.
    final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var listed: [String] = []
        let deny: Set<String>, hang: Set<String>
        init(deny: Set<String> = [], hang: Set<String> = []) { self.deny = deny; self.hang = hang }
        func list(_ url: URL) throws {
            lock.lock(); listed.append(url.lastPathComponent); lock.unlock()
            if deny.contains(url.lastPathComponent) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
            if hang.contains(url.lastPathComponent) { Thread.sleep(forTimeInterval: 1.5) }
        }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return listed }
    }

    private func prepare(_ access: Access, session: FolderConsentService.Session, running: Bool = false,
                         timeout: TimeInterval = 2) async -> WineBottleGate.Report {
        await WineBottleGate.prepare(prefix: prefix, home: home, timeout: timeout, session: session,
                                     isRunning: { _ in running }, list: { try access.list($0) })
    }

    /// A helper's idle wineserver that ends within the wait is not a session; one that stays is.
    func testWaitForIdleSessionEndWaitsForAHelperServerToEnd() {
        let checks = Counter()
        XCTAssertFalse(WineBottleGate.waitForIdleSessionEnd(prefix: prefix, timeout: 5) { _ in
            checks.increment() < 3
        })
        XCTAssertEqual(checks.value, 4)
        XCTAssertTrue(WineBottleGate.waitForIdleSessionEnd(prefix: prefix, timeout: 0.6) { _ in true })
        XCTAssertFalse(WineBottleGate.waitForIdleSessionEnd(prefix: prefix, timeout: 0) { _ in false })
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        /// Returns the count before this call.
        func increment() -> Int { defer { value += 1 }; return value }
    }

    func testLinksReachProtectedFoldersThroughSymbolicLinks() throws {
        // Box Drive's ~/Box is a link to the CloudStorage folder; a letter to it reaches Box.
        try link("home/Box", cloud("Box-Box"))
        try link("support/bottle/dosdevices/x:", home.appendingPathComponent("Box/Project").path)
        // A link to a cloud folder that is gone is judged by its path.
        try link("support/bottle/dosdevices/g:", cloud("GoogleDrive-me@example.com"))
        let links = WineBottleGate.links(prefix: prefix, home: home)
        XCTAssertEqual(links.map(\.item), ["drive_c/users/me/Box", "drive_c/users/me/Documents",
                                           "dosdevices/b:", "dosdevices/g:", "dosdevices/x:", "dosdevices/y:"])
        XCTAssertEqual(links.map { $0.folder?.name ?? "-" }, ["Box", "Documents", "Box", "GoogleDrive", "Box", "OneDrive"])
        XCTAssertEqual(links.first { $0.item == "dosdevices/x:" }?.folder?.url.path, cloud("Box-Box"))
        XCTAssertEqual(links.filter(\.isGated).map(\.item), ["drive_c/users/me/Box", "dosdevices/b:", "dosdevices/g:",
                                                             "dosdevices/x:", "dosdevices/y:"], "only cloud links are gated")
        XCTAssertEqual(FolderConsentService.protectedFolders(prefix: prefix, home: home).map(\.name),
                       ["Box", "Documents", "GoogleDrive", "OneDrive"])
    }

    /// The blocking case: nothing confirmed yet in this process (a new build, SOLIDWORKS.app).
    func testUnconfirmedLinksAreSetAsideUnchangedAndOthersStay() throws {
        let before = allBottleLinks
        let report = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertEqual(report.setAside.map(\.item), ["drive_c/users/me/Box", "dosdevices/b:", "dosdevices/y:"])
        XCTAssertTrue(report.failed.isEmpty)
        for item in ["dosdevices/b:", "dosdevices/y:", "drive_c/users/me/Box"] {
            XCTAssertNil(destination("support/bottle/" + item), item)
            XCTAssertEqual(held(item), before[item], "\(item) is kept unchanged")
        }
        for item in ["dosdevices/c:", "dosdevices/z:", "dosdevices/h:", "dosdevices/q:", "drive_c/users/me/Projects",
                     "drive_c/users/me/Documents"] {
            XCTAssertEqual(destination("support/bottle/" + item), before[item], "\(item) is not touched")
        }
        XCTAssertEqual(WineBottleGate.links(prefix: prefix, home: home).filter(\.isGated), [], "no cloud link is left for Wine")
        XCTAssertEqual(FolderConsentService.protectedFolders(prefix: prefix, home: home).map(\.name), ["Documents"])
    }

    func testPrepareKeepsWhatMacOSAllowsAndSetsAsideTheRest() async throws {
        let access = Access(deny: ["OneDrive-Personal"], hang: ["Documents"])
        let session = FolderConsentService.Session()
        let started = Date()
        let report = await prepare(access, session: session, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.4, "an unanswered prompt is waited for at most the timeout")
        XCTAssertEqual(Set(access.names), ["Box-Box", "Documents", "OneDrive-Personal"], "Documents is still asked natively first")
        XCTAssertEqual(report.checks.map(\.folder.name), ["Box", "Documents", "OneDrive"])
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Box"), cloud("Box-Box"))
        XCTAssertNil(destination("support/bottle/dosdevices/y:"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Documents"), home.appendingPathComponent("Documents").path,
                       "a shell folder link stays whatever macOS answered")
        XCTAssertEqual(report.stillHeld.map(\.item), ["dosdevices/y:"])
        let notice = WineBottleGate.notice(report) ?? ""
        XCTAssertTrue(notice.contains("Documents, OneDrive") && notice.contains("Y: is unavailable"), notice)
        // A second run in the same process lists nothing it was allowed to open again, and does
        // not wait again for Documents, whose prompt is still on screen.
        let second = Access(deny: ["OneDrive-Personal"])
        let again = await prepare(second, session: session)
        XCTAssertEqual(again.checks.map(\.folder.name), ["Documents", "OneDrive"])
        XCTAssertEqual(again.checks.first?.access, .noAnswer)
        XCTAssertEqual(second.names, ["OneDrive-Personal"])
        XCTAssertTrue(again.setAside.isEmpty && again.restored.isEmpty)
        // The late answer (Allow) counts: Documents is not asked again.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let third = Access(deny: ["OneDrive-Personal"])
        let late = await prepare(third, session: session)
        XCTAssertEqual(late.checks.map(\.folder.name), ["OneDrive"])
        XCTAssertEqual(third.names, ["OneDrive-Personal"])
    }

    func testHeldLinksComeBackUnchangedOnceAllowed() async throws {
        let before = allBottleLinks
        let session = FolderConsentService.Session()
        _ = await prepare(Access(deny: ["Box-Box", "Documents", "OneDrive-Personal"]), session: session)
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        let report = await prepare(Access(), session: session)
        XCTAssertEqual(Set(report.restored.map(\.item)), ["dosdevices/b:", "dosdevices/y:", "drive_c/users/me/Box"])
        XCTAssertEqual(allBottleLinks, before)
        XCTAssertTrue(report.stillHeld.isEmpty)
    }

    /// While a session runs, no link moves either way: taking B: away would break `B:\...` in the
    /// running SOLIDWORKS, and bringing it back would let a session that another app started (one
    /// macOS refused Box) reach Box.
    func testNoLinkMovesWhileAWineSessionRuns() async throws {
        let session = FolderConsentService.Session()
        _ = await prepare(Access(deny: ["Box-Box"]), session: session)
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        // Another process (allowed into Box, refused OneDrive) while that session runs.
        let other = FolderConsentService.Session()
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        try link("support/bottle/dosdevices/v:", cloud("OneDrive-Personal"))
        let running = await prepare(Access(deny: ["OneDrive-Personal"]), session: other, running: true)
        XCTAssertTrue(running.sessionRunning)
        XCTAssertTrue(running.setAside.isEmpty && running.restored.isEmpty, "\(running)")
        XCTAssertNil(destination("support/bottle/dosdevices/b:"), "not moved back into the running session")
        XCTAssertEqual(destination("support/bottle/dosdevices/y:"), cloud("OneDrive-Personal"))
        XCTAssertEqual(destination("support/bottle/dosdevices/v:"), cloud("OneDrive-Personal"))
        XCTAssertEqual(Set(running.stillHeld.map(\.item)), ["drive_c/users/me/Box", "dosdevices/b:"])
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: other, isRunning: { _ in true },
                                          list: { _ in })
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        // The session ended: the next start in that process sets aside and moves back.
        let next = await prepare(Access(deny: ["OneDrive-Personal"]), session: other)
        XCTAssertEqual(Set(next.restored.map(\.item)), ["drive_c/users/me/Box", "dosdevices/b:"])
        XCTAssertEqual(Set(next.setAside.map(\.item)), ["dosdevices/v:", "dosdevices/y:"])
    }

    func testNamesTakenWhileHeldBlockOrMakeRoom() async throws {
        let session = FolderConsentService.Session()
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: session, sessionRunning: false)
        let profile = prefix.appendingPathComponent("drive_c/users/me")
        // While the links were away someone made a real "Box" folder with a file in it, and an
        // empty folder stands at y:.
        try fm.createDirectory(at: profile.appendingPathComponent("Box"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: profile.appendingPathComponent("Box/mine.txt"))
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices/y:"), withIntermediateDirectories: true)
        _ = await FolderConsentService.check(
            ["Library/CloudStorage/Box-Box", "Library/CloudStorage/OneDrive-Personal"].map {
                FolderConsentService.ProtectedFolder(name: $0, url: home.appendingPathComponent($0, isDirectory: true))
            }, list: { _ in }, session: session, onWaiting: { _ in })
        let report = WineBottleGate.apply(prefix: prefix, home: home, session: session, sessionRunning: false)
        XCTAssertEqual(destination("support/bottle/dosdevices/y:"), cloud("OneDrive-Personal"), "an empty folder makes room")
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))
        XCTAssertEqual(report.blocked.map(\.item), ["drive_c/users/me/Box"], "a folder of the user's own stays")
        XCTAssertEqual(held("drive_c/users/me/Box"), cloud("Box-Box"))
        XCTAssertTrue(fm.fileExists(atPath: profile.appendingPathComponent("Box/mine.txt").path))
    }

    func testTheSameLinkMadeAgainIsMergedAndANewerLinkTakesTheName() throws {
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        // The owner makes the Box link again by hand and points B: somewhere else in Box.
        try link("support/bottle/drive_c/users/me/Box", cloud("Box-Box"))
        try link("support/bottle/dosdevices/b:", cloud("Box-Box") + "/Project")
        let report = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertEqual(Set(report.setAside.map(\.item)), ["drive_c/users/me/Box", "dosdevices/b:"])
        XCTAssertEqual(held("drive_c/users/me/Box"), cloud("Box-Box"))
        XCTAssertEqual(held("dosdevices/b:"), cloud("Box-Box") + "/Project", "the newer link wins")
        // Allowed now, with the same link present again: the held copy is dropped, nothing doubles.
        try link("support/bottle/drive_c/users/me/Box", cloud("Box-Box"))
        let session = FolderConsentService.Session()
        _ = FolderConsentService.checkBlocking([FolderConsentService.ProtectedFolder(
            name: "Box", url: home.appendingPathComponent("Library/CloudStorage/Box-Box", isDirectory: true))],
            timeout: 1, list: { _ in }, session: session)
        let merged = WineBottleGate.apply(prefix: prefix, home: home, session: session, sessionRunning: false)
        XCTAssertEqual(Set(merged.restored.map(\.item)), ["drive_c/users/me/Box", "dosdevices/b:"])
        XCTAssertNil(held("drive_c/users/me/Box"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Box"), cloud("Box-Box"))
    }

    /// Wine links a missing Desktop, Documents, Downloads, Music, Pictures or Videos to
    /// `$HOME/<folder>` again in the session (shell32 `SHGetFolderPath` with `CSIDL_FLAG_CREATE`
    /// -> mountmgr `set_shell_folder`, also `wineboot -u`), so the gate never empties those names,
    /// not even one that a user pointed into a cloud folder.
    func testShellFolderLinksAreNeverMovedSoWineHasNothingToMakeAgain() throws {
        let profile = "support/bottle/drive_c/users/me/"
        try fm.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try link(profile + "Desktop", home.appendingPathComponent("Desktop").path)
        try link(profile + "Pictures", cloud("Box-Box") + "/Pictures")  // redirected into Box by its owner
        let shellFolders = ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"]
        func entries() -> [String: String] {
            var found: [String: String] = [:]
            for name in shellFolders { found[name] = destination(profile + name) }
            return found
        }
        let before = entries()
        // Wine's step, as unixlib.c set_shell_folder does it: a link to $HOME/<folder> where
        // nothing is at the name (only for folders that exist in the home).
        func wineMakesShellFolders() throws -> [String] {
            var made: [String] = []
            for name in shellFolders {
                var info = stat()
                let target = home.appendingPathComponent(name).path
                guard lstat(root.appendingPathComponent(profile + name).path, &info) != 0,
                      fm.fileExists(atPath: target) else { continue }
                try link(profile + name, target)
                made.append(name)
            }
            return made
        }
        let refusing = Access(deny: ["Box-Box", "OneDrive-Personal", "Documents", "Desktop"])
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(), isRunning: { _ in false },
                                          list: { try refusing.list($0) })
        XCTAssertNil(destination(profile + "Box"), "the cloud link is set aside")
        XCTAssertEqual(entries(), before, "no shell folder link is moved")
        XCTAssertFalse(fm.fileExists(atPath: prefix.appendingPathComponent(".macsw-held/drive_c/users/me/Documents").path))
        XCTAssertEqual(try wineMakesShellFolders(), ["Downloads"], "Wine finds only what was never there")
        // The next starts (no session, then one in a session) leave Wine's link alone.
        let afterWine = entries()
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(), isRunning: { _ in false },
                                          list: { try refusing.list($0) })
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(), isRunning: { _ in true },
                                          list: { try refusing.list($0) })
        XCTAssertEqual(entries(), afterWine)
        XCTAssertEqual(try wineMakesShellFolders(), [])
        XCTAssertFalse(refusing.names.contains("Documents") || refusing.names.contains("Desktop"),
                       "the backstop lists only cloud folders: \(refusing.names)")
    }

    /// The re-review's probe: setting aside left nothing at Documents, so Wine linked ~/Documents
    /// again in-session. Documents is not set aside now.
    func testProbeSetAsideShellFolderLeavesAPlaceholder() throws {
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertNil(held("drive_c/users/me/Documents"))
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Documents"), home.appendingPathComponent("Documents").path)
    }

    /// The re-review's probe: SOLIDWORKS.app (its own TCC identity) started the session with Box
    /// set aside; MacSW, allowed into Box, then runs a Wine task: b: stays away.
    func testProbeNoMoveBackIntoAnotherIdentitysRunningSession() async throws {
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        let solidWorksApp = FolderConsentService.Session()
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: solidWorksApp, isRunning: { _ in false },
                                          list: { try Access(deny: ["Box-Box", "Documents"]).list($0) })
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        let macSW = FolderConsentService.Session()
        let report = await WineBottleGate.prepare(prefix: prefix, home: home, timeout: 1, session: macSW,
                                                  isRunning: { _ in true }, list: { try Access().list($0) })
        XCTAssertEqual(report.restored, [])
        XCTAssertNil(destination("support/bottle/dosdevices/b:"), "b: reaches Box, which the running session's app was never let into")
    }

    /// The re-review's probe, under the cloud-only gate: APFS ignores case and Unicode form, so a
    /// letter to ~/documents is Documents (asked natively first, left in place) and one to
    /// ~/library/cloudstorage/box-box is Box (set aside); one consent covers every spelling.
    func testProbeCaseVariantLinksAreRecognised() async throws {
        let variant = home.appendingPathComponent("documents").path
        guard fm.fileExists(atPath: variant + "/.") else { print("  (case-sensitive volume; skipped)"); return }
        try link("support/bottle/dosdevices/d:", variant)
        try link("support/bottle/dosdevices/e:", home.appendingPathComponent("library/cloudstorage/box-box").path)
        // "Café" stored precomposed (NFC), linked decomposed (NFD).
        try fm.createDirectory(atPath: cloud("Caf\u{E9}-Drive"), withIntermediateDirectories: true)
        try link("support/bottle/dosdevices/f:", home.appendingPathComponent("LIBRARY/CloudStorage/Cafe\u{301}-Drive").path)
        let links = Dictionary(uniqueKeysWithValues: WineBottleGate.links(prefix: prefix, home: home).map { ($0.item, $0) })
        XCTAssertEqual(links["dosdevices/d:"]?.folder?.url.path, home.appendingPathComponent("Documents").path)
        XCTAssertEqual(links["dosdevices/d:"]?.isGated, false)
        XCTAssertEqual(links["dosdevices/e:"]?.folder?.name, "box")
        XCTAssertEqual(links["dosdevices/e:"]?.isGated, true)
        XCTAssertEqual(links["dosdevices/f:"]?.folder?.name, "Cafe\u{301}")
        XCTAssertEqual(links["dosdevices/f:"]?.isGated, true)
        let access = Access(deny: ["Box-Box", "box-box", "Cafe\u{301}-Drive", "Documents", "OneDrive-Personal"])
        let report = await prepare(access, session: .init())
        XCTAssertNil(destination("support/bottle/dosdevices/e:"), "e: -> ~/library/cloudstorage/box-box reaches Box")
        XCTAssertNil(destination("support/bottle/dosdevices/f:"))
        XCTAssertEqual(destination("support/bottle/dosdevices/d:"), variant, "Documents is asked, not set aside")
        XCTAssertTrue(report.checks.contains { $0.folder.name == "Documents" })
        XCTAssertEqual(access.names.filter { $0.lowercased() == "box-box" }.count, 1, "one listing per folder: \(access.names)")
        // Allowed under its own spelling: every spelling's link comes back.
        let session = FolderConsentService.Session()
        _ = FolderConsentService.checkBlocking([FolderConsentService.ProtectedFolder(
            name: "Box", url: URL(fileURLWithPath: cloud("Box-Box"), isDirectory: true))], timeout: 1, list: { _ in }, session: session)
        XCTAssertTrue(session.isConfirmed(home.appendingPathComponent("library/cloudstorage/box-box")))
        let back = WineBottleGate.apply(prefix: prefix, home: home, session: session, sessionRunning: false)
        XCTAssertTrue(Set(back.restored.map(\.item)).isSuperset(of: ["dosdevices/b:", "dosdevices/e:"]), "\(back.restored)")
    }

    /// The re-review's probe: the Data volume's name for the home folder (a firmlink).
    func testProbeFirmlinkPathsAreRecognised() throws {
        // From the real path: /var/folders is /private/var/folders on the Data volume.
        let data = "/System/Volumes/Data" + (home.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? home.path)
        guard fm.fileExists(atPath: data + "/Documents/.") else { print("  (no Data firmlink path here; skipped)"); return }
        try link("support/bottle/dosdevices/d:", data + "/Documents")
        try link("support/bottle/dosdevices/e:", data + "/Library/CloudStorage/Box-Box")
        let links = Dictionary(uniqueKeysWithValues: WineBottleGate.links(prefix: prefix, home: home).map { ($0.item, $0) })
        XCTAssertEqual(links["dosdevices/d:"]?.folder?.url.path, home.appendingPathComponent("Documents").path)
        XCTAssertEqual(links["dosdevices/e:"]?.folder?.url.path, cloud("Box-Box"))
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertEqual(destination("support/bottle/dosdevices/d:"), data + "/Documents", "Documents: asked, left in place")
        XCTAssertNil(destination("support/bottle/dosdevices/e:"), "e: -> /System/Volumes/Data<home>/Library/CloudStorage/Box-Box reaches Box")
    }

    /// DriveMapService must not hand a held letter or profile name to another folder, nor make a
    /// second B: for Box while B: is away.
    func testHeldLettersAndNamesStayTakenForDriveMaps() throws {
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Dropbox"), withIntermediateDirectories: true)
        var letters = ["cloud:OneDrive-Personal": "Y"]
        let changes = DriveMapService.apply(DriveMapService.folders(home: home), prefix: prefix, userName: "me", letters: &letters)
        let outcome = changes.map { "\($0.item) \($0.folder) \($0.outcome.rawValue)" }
        XCTAssertTrue(outcome.contains("B: Box present"), outcome.joined(separator: ", "))
        XCTAssertTrue(outcome.contains("Y: OneDrive present"), outcome.joined(separator: ", "))
        XCTAssertTrue(outcome.contains("X: Dropbox created"), outcome.joined(separator: ", "))
        XCTAssertTrue(outcome.contains("profile/Box Box present"), outcome.joined(separator: ", "))
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        XCTAssertNil(destination("support/bottle/drive_c/users/me/Box"))
    }

    /// Finder hand-off (ac96ef9): with Box's letter and link set aside, a Box file has no B: or
    /// C:\users\me\Box path and falls back to H:; Documents keeps its profile path; once Box is
    /// allowed and moved back, the profile path comes first again.
    func testHandOffPathsWhileALetterIsAwayAndAfterwards() async throws {
        let box = home.appendingPathComponent("Library/CloudStorage/Box-Box/Project/a.sldprt")
        let doc = home.appendingPathComponent("Documents/p.sldprt")
        let session = FolderConsentService.Session()
        _ = await prepare(Access(deny: ["Box-Box"]), session: session)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: box, prefix: prefix, userName: "me"),
                       #"H:\Library\CloudStorage\Box-Box\Project\a.sldprt"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: doc, prefix: prefix, userName: "me"), #"C:\users\me\Documents\p.sldprt"#)
        XCTAssertEqual(DocumentHandOff.startArguments(for: [box], prefix: prefix, userName: "me"), [["start", "/unix", box.path]])
        _ = await prepare(Access(), session: session)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: box, prefix: prefix, userName: "me"), #"C:\users\me\Box\Project\a.sldprt"#)
        XCTAssertEqual(DocumentHandOff.startArguments(for: [box], prefix: prefix, userName: "me"),
                       [["start", #"C:\users\me\Box\Project\a.sldprt"#]])
    }

    func testBackstopRunsOnlyForManagedBottlesAndDoesNotWaitForHeldFolders() throws {
        let session = FolderConsentService.Session()
        let refusing = Access(deny: ["Box-Box", "OneDrive-Personal", "Documents"])
        // A bottle MacSW does not manage (no upgrade state next to it): left alone.
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: session, isRunning: { _ in false },
                                          list: { try refusing.list($0) })
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"))
        XCTAssertTrue(refusing.names.isEmpty)
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: session, isRunning: { _ in false },
                                          list: { try refusing.list($0) })
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        XCTAssertEqual(held("dosdevices/b:"), cloud("Box-Box"))
        let listed = refusing.names.count
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: session, isRunning: { _ in false },
                                          list: { try refusing.list($0) })
        XCTAssertEqual(refusing.names.count, listed, "held folders are not listed again before each Wine process")
        XCTAssertFalse(refusing.names.contains("Documents"), "the backstop lists only cloud folders")
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Documents"), home.appendingPathComponent("Documents").path)
        // A link that cannot be set aside stops Wine.
        try link("support/bottle/dosdevices/v:", cloud("OneDrive-Personal"))
        try fm.removeItem(at: prefix.appendingPathComponent(".macsw-held"))
        fm.createFile(atPath: prefix.appendingPathComponent(".macsw-held").path, contents: Data())
        XCTAssertThrowsError(try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: session,
                                                               isRunning: { _ in false }, list: { try refusing.list($0) }))
    }

    /// The real `WineService.start`: the letter is gone before the Wine process runs; wineserver
    /// (no drives) is not held up; a failed hold starts nothing.
    func testWineServiceStartRunsTheGateFirst() throws {
        // Fresh managed bottle (no drive_c yet), so the launch lock lets it start.
        let fresh = root.appendingPathComponent("fresh/bottle", isDirectory: true)
        try fm.createDirectory(at: fresh.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: WineRuntimeService.root(prefix: fresh), withIntermediateDirectories: true)
        let letter = fresh.appendingPathComponent("dosdevices/b:")
        try fm.createSymbolicLink(atPath: letter.path, withDestinationPath: cloud("Box-Box"))
        let session = FolderConsentService.Session()
        let home = self.home!
        let wine = WineService(prepareBottle: { prefix in
            try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: session, isRunning: { _ in false },
                                              list: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) })
        })
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: tools.appendingPathComponent("wineserver").path, withDestinationPath: "/bin/sh")
        func run(_ executable: URL, _ name: String) throws -> String {
            let out = root.appendingPathComponent(name)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-c", #"if [ -L "$1" ]; then echo present; else echo absent; fi > "$2""#, "sh", letter.path, out.path]
            process.environment = ["WINEPREFIX": fresh.path, "PATH": "/usr/bin:/bin"]
            XCTAssertEqual(try wine.run(process), 0)
            return try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try run(tools.appendingPathComponent("wineserver"), "server.out"), "present")
        XCTAssertEqual(try run(URL(fileURLWithPath: "/bin/sh"), "loader.out"), "absent")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: fresh.appendingPathComponent(".macsw-held/dosdevices/b:").path),
                       cloud("Box-Box"))
        try fm.createSymbolicLink(atPath: letter.path, withDestinationPath: cloud("OneDrive-Personal"))
        try fm.removeItem(at: fresh.appendingPathComponent(".macsw-held"))
        fm.createFile(atPath: fresh.appendingPathComponent(".macsw-held").path, contents: Data())
        let never = root.appendingPathComponent("never.out")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [never.path]
        process.environment = ["WINEPREFIX": fresh.path]
        XCTAssertThrowsError(try wine.run(process))
        XCTAssertFalse(fm.fileExists(atPath: never.path), "Wine is not started when a link cannot be set aside")
    }

    /// wineserver holds a write lock on /tmp/.wine-<uid>/server-<dev>-<inode>/lock while it lives
    /// and takes clients on `socket` next to it. A held lock is a running session (no link moves);
    /// one whose socket does not answer is waited for, and only a cleared lock means no session.
    func testSessionRunsWhileTheWineserverLockIsHeld() throws {
        // A socket path must fit in sockaddr_un (104 bytes): work relative to the test folder.
        let previous = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(root.path))
        addTeardownBlock { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        let serverRoot = "wine-tmp"
        var info = stat()
        XCTAssertEqual(stat(prefix.path, &info), 0)
        let directory = "\(serverRoot)/server-\(String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16))-\(String(UInt64(info.st_ino), radix: 16))"
        func running(_ wait: TimeInterval) -> (Bool, TimeInterval) {
            let started = Date()
            let result = WineBottleGate.sessionRunning(prefix: prefix, serverRoot: serverRoot, endWait: wait)
            return (result, Date().timeIntervalSince(started))
        }
        XCTAssertFalse(running(5).0, "no server directory")
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        fm.createFile(atPath: directory + "/lock", contents: Data())
        XCTAssertLessThan(running(5).1, 1, "a leftover lock file: not running, no wait")
        // A stand-in wineserver: takes the write lock the way wineserver does (fcntl F_SETLK, first
        // byte), then listens on, closes or releases on command.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.currentDirectoryURL = root
        holder.arguments = ["-c", """
            import fcntl, os, socket, sys, time
            fd = os.open(sys.argv[1], os.O_RDWR); fcntl.lockf(fd, fcntl.LOCK_EX, 1); server = None
            print("locked", flush=True)
            for line in sys.stdin:
                command = line.strip()
                if command.endswith("-later"): time.sleep(0.3)
                if command.startswith("listen"):
                    server = socket.socket(socket.AF_UNIX); server.bind(sys.argv[2]); server.listen(5)
                elif command == "close": server.close()  # wineserver keeps the socket file until it exits
                elif command.startswith("unlock"): fcntl.lockf(fd, fcntl.LOCK_UN, 1)
                print("done", flush=True)
            """, directory + "/lock", directory + "/socket"]
        let output = Pipe(), input = Pipe()
        holder.standardOutput = output
        holder.standardInput = input
        try holder.run()
        addTeardownBlock { if holder.isRunning { holder.terminate() } }
        func line() -> String { String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        func send(_ command: String) { input.fileHandleForWriting.write(Data((command + "\n").utf8)) }
        XCTAssertEqual(line(), "locked")
        // Lock held, nobody listening (just starting, or shutting down slowly): waited for, and
        // still running when the lock does not clear.
        let (stopping, waited) = running(0.3)
        XCTAssertTrue(stopping, "a held lock is a running session")
        XCTAssertTrue(waited >= 0.3, "\(waited)")
        // A server that was just starting answers within the wait: running.
        send("listen-later")
        XCTAssertTrue(running(5).0)
        XCTAssertEqual(line(), "done")
        XCTAssertTrue(running(0).0, "lock held and socket answering")
        // It stops taking clients but keeps the lock: still running; it exits within the wait:
        // not running.
        send("close")
        XCTAssertEqual(line(), "done")
        XCTAssertTrue(running(0.3).0)
        send("unlock-later")
        let (ended, took) = running(5)
        XCTAssertFalse(ended)
        XCTAssertLessThan(took, 2, "returns once the lock is gone")
        XCTAssertEqual(line(), "done")
        holder.terminate()
        holder.waitUntilExit()
        XCTAssertFalse(running(5).0)
    }

    // MARK: - The third review's probes

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A stand-in wineserver frozen on a macOS prompt: holds the write lock, listens with Wine's
    /// backlog (`listen(5)`, server/request.c) and never accepts. Returns the server root for
    /// `sessionRunning`, relative to the test folder (a socket path must fit in sockaddr_un).
    private func startFrozenServer() throws -> String {
        let previous = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(root.path))
        addTeardownBlock { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        var info = stat()
        XCTAssertEqual(stat(prefix.path, &info), 0)
        let serverRoot = "wine-tmp"
        let directory = "\(serverRoot)/server-\(String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16))-\(String(UInt64(info.st_ino), radix: 16))"
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        fm.createFile(atPath: directory + "/lock", contents: Data())
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.currentDirectoryURL = root
        holder.arguments = ["-I", "-c", """
            import fcntl, os, socket, sys
            fd = os.open(sys.argv[1], os.O_RDWR); fcntl.lockf(fd, fcntl.LOCK_EX, 1)
            server = socket.socket(socket.AF_UNIX); server.bind(sys.argv[2]); server.listen(5)
            print("frozen", flush=True)
            sys.stdin.read()
            """, directory + "/lock", directory + "/socket"]
        let output = Pipe(), input = Pipe()
        holder.standardOutput = output
        holder.standardInput = input
        try holder.run()
        // No waitUntilExit here: in a teardown block on the main actor it can wait forever.
        addTeardownBlock { if holder.isRunning { holder.terminate() } }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), "frozen")
        return serverRoot
    }

    /// A frozen wineserver refuses connections once its listen backlog is full (a closed test
    /// client does not free its slot), but its lock is held: the session still runs and nothing
    /// moves back into it for a process that may open Box.
    func testFrozenWineserverWithAFullBacklogStillCountsAsRunning() async throws {
        let serverRoot = try startFrozenServer()
        let answers = (0..<7).map { _ in WineBottleGate.sessionRunning(prefix: prefix, serverRoot: serverRoot, endWait: 0.3) }
        XCTAssertEqual(answers, Array(repeating: true, count: 7))
        // Held by an earlier gate of another identity (SOLIDWORKS.app refused).
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        let report = await WineBottleGate.prepare(prefix: prefix, home: home, timeout: 1, session: .init(),
                                                  isRunning: { WineBottleGate.sessionRunning(prefix: $0, serverRoot: serverRoot, endWait: 0.3) },
                                                  list: { try Access().list($0) })
        XCTAssertTrue(report.sessionRunning)
        XCTAssertEqual(report.restored, [], "nothing moves back into a live (frozen) session")
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
    }

    /// The other direction: a letter this process may not open is not taken away from the frozen
    /// session's SOLIDWORKS (its `B:\` paths would break when it wakes up).
    func testFrozenWineserverWithAFullBacklogKeepsItsLetters() throws {
        let serverRoot = try startFrozenServer()
        for _ in 0..<5 { XCTAssertTrue(WineBottleGate.sessionRunning(prefix: prefix, serverRoot: serverRoot, endWait: 0)) }
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(),
                                          isRunning: { WineBottleGate.sessionRunning(prefix: $0, serverRoot: serverRoot, endWait: 0.3) },
                                          list: { try Access(deny: ["Box-Box"]).list($0) })
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"), "b: stays in the live session")
    }

    /// Another app starts a session while the gate waits on a macOS prompt: `guardWineStart` and
    /// `prepare` ask for the session after their native checks, so nothing moves either way.
    func testASessionThatStartsDuringTheNativeCheckIsNotChanged() async throws {
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        let started = Flag()
        try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(), isRunning: { _ in started.isSet },
                                          list: { _ in started.set(); throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) })
        XCTAssertTrue(started.isSet)
        XCTAssertEqual(destination("support/bottle/dosdevices/b:"), cloud("Box-Box"), "not taken away")
        // Held by an earlier gate; this process may open Box, but a session starts meanwhile.
        _ = WineBottleGate.apply(prefix: prefix, home: home, session: .init(), sessionRunning: false)
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
        let later = Flag()
        let report = await WineBottleGate.prepare(prefix: prefix, home: home, timeout: 1, session: .init(),
                                                  isRunning: { _ in later.isSet }, list: { _ in later.set() })
        XCTAssertTrue(later.isSet)
        XCTAssertEqual(report.restored, [], "not moved back")
        XCTAssertNil(destination("support/bottle/dosdevices/b:"))
    }

    /// After every gate (all refused; no session, a session, none), Wine's own step
    /// (unixlib.c set_shell_folder: a link to `$HOME/<folder>` where nothing is, Videos ->
    /// Movies) finds nothing to make, no gated link is left and none is held under a shell name.
    func testWineFindsNothingToMakeAgainAfterAnyGate() throws {
        let profile = "support/bottle/drive_c/users/me/"
        for folder in ["Desktop", "Downloads", "Music", "Pictures", "Movies"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let targets = ["Desktop": "Desktop", "Documents": "Documents", "Downloads": "Downloads",
                       "Music": "Music", "Pictures": "Pictures", "Videos": "Movies"]
        func wineStep() throws -> [String] {
            var made: [String] = []
            for (name, folder) in targets.sorted(by: { $0.key < $1.key }) {
                var info = stat()
                guard lstat(root.appendingPathComponent(profile + name).path, &info) != 0,
                      fm.fileExists(atPath: home.appendingPathComponent(folder).path) else { continue }
                try link(profile + name, home.appendingPathComponent(folder).path)
                made.append(name)
            }
            return made
        }
        _ = try wineStep()  // wineboot's profile
        try link(profile + "OneDrive", cloud("OneDrive-Personal"))
        try fm.createDirectory(at: WineRuntimeService.root(prefix: prefix), withIntermediateDirectories: true)
        let refusing = Access(deny: ["Box-Box", "OneDrive-Personal", "Documents", "Desktop", "Downloads"])
        for running in [false, true, false] {
            try WineBottleGate.guardWineStart(prefix: prefix, home: home, session: .init(), isRunning: { _ in running },
                                              list: { try refusing.list($0) })
            XCTAssertEqual(try wineStep(), [], "Wine made a shell folder again")
        }
        XCTAssertEqual(WineBottleGate.links(prefix: prefix, home: home).filter(\.isGated).map(\.item), [])
        XCTAssertEqual(WineBottleGate.heldLinks(prefix: prefix, home: home).map(\.item),
                       ["drive_c/users/me/Box", "drive_c/users/me/OneDrive", "dosdevices/b:", "dosdevices/y:"])
    }

    /// Other spellings of a cloud folder reach it and are gated: ".." after a symbolic link (taken
    /// the kernel's way: ~/BoxAlias/.. is ~/Library/CloudStorage), a relative target, double and
    /// trailing slashes, "." and "..", a link outside the home, the boot volume alias and the
    /// Data volume in capitals.
    func testOtherSpellingsOfACloudFolderAreGated() throws {
        try link("home/BoxAlias", cloud("Box-Box"))  // like Box Drive's ~/Box
        try link("elsewhere/x", cloud("Box-Box"))
        var cases: [(letter: String, target: String, folder: String)] = [
            ("f", home.appendingPathComponent("BoxAlias").path + "/../OneDrive-Personal", cloud("OneDrive-Personal")),
            ("g", "../../../home/Library/CloudStorage/Box-Box", cloud("Box-Box")),
            ("j", home.path + "//Library//CloudStorage/Box-Box/", cloud("Box-Box")),
            ("k", home.path + "/./Library/CloudStorage/../CloudStorage/Box-Box/Project", cloud("Box-Box")),
            ("l", root.appendingPathComponent("elsewhere/x/Project").path, cloud("Box-Box")),
            ("o", home.appendingPathComponent("Documents").path + "/../Library/CloudStorage/Box-Box", cloud("Box-Box")),
        ]
        if (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/Macintosh HD")) == "/" {
            cases.append(("e", "/Volumes/Macintosh HD" + cloud("Box-Box"), cloud("Box-Box")))
        }
        if let real = realpath(home.path, nil) {
            let upper = ("/System/Volumes/Data" + String(cString: real) + "/Library/CloudStorage/Box-Box").uppercased()
            free(real)
            if fm.fileExists(atPath: upper + "/.") { cases.append(("m", upper, cloud("Box-Box"))) }
        }
        for item in cases { try link("support/bottle/dosdevices/\(item.letter):", item.target) }
        let links = Dictionary(uniqueKeysWithValues: WineBottleGate.links(prefix: prefix, home: home).map { ($0.item, $0) })
        for item in cases {
            let found = links["dosdevices/\(item.letter):"]
            XCTAssertEqual(found?.folder?.url.path.lowercased(), item.folder.lowercased(), "\(item.letter): -> \(item.target)")
            XCTAssertEqual(found?.isGated, true, "\(item.letter): -> \(item.target)")
        }
    }

    /// A home folder with a non-ASCII name, stored NFC, linked NFD (and the reverse).
    func testANonASCIIHomeIsRecognisedInEitherUnicodeForm() throws {
        let nfcHome = root.appendingPathComponent("Jos\u{E9}", isDirectory: true)
        try fm.createDirectory(at: nfcHome.appendingPathComponent("Library/CloudStorage/Box-Box"), withIntermediateDirectories: true)
        try link("support/bottle/dosdevices/n:", root.path + "/Jose\u{301}/Library/CloudStorage/Box-Box")
        XCTAssertEqual(WineBottleGate.links(prefix: prefix, home: nfcHome).first { $0.item == "dosdevices/n:" }?.isGated, true)
        XCTAssertEqual(WineBottleGate.links(prefix: prefix, home: URL(fileURLWithPath: root.path + "/Jose\u{301}"))
            .first { $0.item == "dosdevices/n:" }?.isGated, true)
    }

    /// Desktop and Documents, and drive letters into them, are listed natively first (once each)
    /// and never moved; a refusal is reported with the consent preflight's text.
    func testShellFoldersAreAskedNativelyAndLeftInPlace() async throws {
        try fm.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try link("support/bottle/drive_c/users/me/Desktop", home.appendingPathComponent("Desktop").path)
        try link("support/bottle/dosdevices/d:", home.appendingPathComponent("Documents/Work").path)
        let access = Access(deny: ["Documents"])
        let report = await prepare(access, session: .init(), timeout: 1)
        XCTAssertTrue(access.names.contains("Documents") && access.names.contains("Desktop"), "\(access.names)")
        XCTAssertEqual(access.names.filter { $0 == "Documents" }.count, 1)
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Documents"), home.appendingPathComponent("Documents").path)
        XCTAssertEqual(destination("support/bottle/drive_c/users/me/Desktop"), home.appendingPathComponent("Desktop").path)
        XCTAssertEqual(destination("support/bottle/dosdevices/d:"), home.appendingPathComponent("Documents/Work").path)
        let refused = FolderConsentService.unavailableSummary([.init(
            folder: .init(name: "Documents", url: home.appendingPathComponent("Documents")), access: .denied("x"))]) ?? "?"
        XCTAssertTrue(WineBottleGate.notice(report)?.hasPrefix(refused) == true, WineBottleGate.notice(report) ?? "-")
    }
}

/// MacSW opens: the font-link check (`wine reg query`) and the SWCLI sync are Wine starts, so the
/// bottle gate comes first (the blocking finding of the drive-maps review).
@MainActor
final class WineBottleGateStartupTests: XCTestCase {
    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func installedPaths() throws -> AppPaths {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-GateStartup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        let paths = AppPaths(appSupportDirectory: support)
        try FileManager.default.createDirectory(at: paths.solidWorksExecutable.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: paths.solidWorksExecutable)
        AppPaths.invalidateInstallationState()
        return paths
    }

    func testAppStartRunsTheGateBeforeAnyWineProcess() async throws {
        let paths = try installedPaths()
        let order = Order()
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            fontLinkRepair: { _ in order.add("font (wine reg query)") }, swcliPreparation: { _ in order.add("swcli") },
            processSnapshot: { _, _ in [] },
            bottleGate: { prefix, _ in
                XCTAssertEqual(prefix, paths.bottle)
                order.add("gate")
                return .init()
            },
            driveMaps: { _, _ in order.add("drives") },
            solidWorksStarter: { _, _, _, _, completion in completion(false, "not started (test)") })
        // MacSWApp.init: prepareFontLinkAtAppLaunch(), then startup(autoLaunch:).
        store.prepareFontLinkAtAppLaunch()
        await store.startup(autoLaunch: false)
        XCTAssertEqual(order.all, ["gate", "font (wine reg query)", "gate", "swcli"])
    }

    /// SOLIDWORKS.app's open-documents and forward modes ask their own folder prompts first.
    func testHandOffRunsTheGateBeforeTheDocumentsGoToWine() async throws {
        let paths = try installedPaths()
        let order = Order()
        let part = paths.appSupportDirectory.appendingPathComponent("a.sldprt")
        try Data("x".utf8).write(to: part)
        let store = RuntimeStore(
            paths: paths, licenseServer: LicenseServerStore(paths: paths),
            processSnapshot: { _, _ in [WineProcess(name: "SLDWORKS.exe", pid: 42, residentKB: 1, elapsed: "00:05")] },
            windowSnapshot: { _ in [HostWindow(ownerPID: 42, layer: 0, width: 1600, height: 900)] },
            documentOpener: { _, _ in order.add("wine start") },
            handOffPollInterval: 0.02,
            bottleGate: { _, _ in order.add("gate"); return .init() },
            solidWorksStarter: { _, _, _, _, _ in XCTFail("a document hand-off must not start SOLIDWORKS") })
        await store.handOff(documents: [part])
        XCTAssertEqual(order.all, ["gate", "wine start"])
    }
}
