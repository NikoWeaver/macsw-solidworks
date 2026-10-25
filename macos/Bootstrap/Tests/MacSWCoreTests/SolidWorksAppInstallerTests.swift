import Foundation
import XCTest
@testable import MacSWCore

// Every test works in a temporary folder: no /Applications, no LaunchServices, no Trash.

private typealias Installer = SolidWorksAppInstaller

private func temporaryDirectory(_ test: XCTestCase) throws -> URL {
    // TMPDIR when set (the test runs keep everything in their own build folder).
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let url = base.appendingPathComponent("MacSW-appinstall-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// A SOLIDWORKS.app layout: Info.plist (identifier, document types) and an executable.
@discardableResult
private func makeApp(at app: URL, identifier: String = AppBundleLaunch.solidWorksBundleIdentifier,
                     executable: String = "build-1", requirement: String? = nil) throws -> URL {
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let types: [[String: Any]] = [
        ["LSHandlerRank": "Owner", "LSItemContentTypes": ["com.dassault.solidworks.part"]],
        ["LSHandlerRank": "Owner", "LSItemContentTypes": ["com.dassault.solidworks.assembly"]],
        ["LSHandlerRank": "Alternate", "LSItemContentTypes": ["org.iso.step"]],
    ]
    try (["CFBundleIdentifier": identifier, "CFBundleDocumentTypes": types] as NSDictionary)
        .write(to: contents.appendingPathComponent("Info.plist"))
    FileManager.default.createFile(atPath: contents.appendingPathComponent("MacOS/SOLIDWORKS").path,
                                   contents: Data(executable.utf8), attributes: [.posixPermissions: 0o755])
    if let requirement { try requirement.write(to: contents.appendingPathComponent("requirement"), atomically: true, encoding: .utf8) }
    return app
}

private func ditto(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}

/// A MacSW.app with SOLIDWORKS.app inside, as `package_solidworks_app.sh --embed` lays it out.
private func makeMacSW(in directory: URL, carrying app: URL?, hash: String? = nil) throws -> URL {
    let macSW = directory.appendingPathComponent("MacSW.app")
    let resources = macSW.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    guard let app else { return macSW }
    try ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, resources.appendingPathComponent(Installer.payloadName).path])
    try ([
        "CFBundleShortVersionString": "1.2",
        "CFBundleVersion": "34",
        Installer.executableSHA256Key: hash ?? Installer.executableSHA256(of: app)!,
    ] as NSDictionary).write(to: resources.appendingPathComponent(Installer.payloadInfoName))
    return macSW
}

private func executable(_ app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/SOLIDWORKS"), encoding: .utf8)
}

private func leftovers(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".SOLIDWORKS-install-") }
}

/// Records the system calls; the running processes can change from one check to the next.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var runningChecks = 0
    var running: (Int) -> [Installer.RunningExecutable] = { _ in [] }
    let trashFolder: URL

    init(trashFolder: URL) { self.trashFolder = trashFolder }

    func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    func nextRunning() -> [Installer.RunningExecutable] {
        lock.lock(); runningChecks += 1; let check = runningChecks; lock.unlock()
        return running(check)
    }

    var effects: Installer.Effects {
        Installer.Effects(
            extract: Installer.liveEffects.extract,
            verifySignature: { [self] in record("verify \($0.lastPathComponent)") },
            designatedRequirement: { try? String(contentsOf: $0.appendingPathComponent("Contents/requirement"), encoding: .utf8) },
            runningExecutables: { [self] in nextRunning() },
            register: { [self] in record("register \($0.path)") },
            unregister: { [self] in record("unregister \($0.path)") },
            trash: { [self] item in
                record("trash \(item.path)")
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item, to: trashFolder.appendingPathComponent(item.lastPathComponent))
            }
        )
    }
}

final class SolidWorksAppInstallerTests: XCTestCase {
    // MARK: Payload and staleness

    func testPayloadIsTheZipWithItsPlist() throws {
        let root = try temporaryDirectory(self)
        let app = try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"))
        XCTAssertNil(Installer.payload(in: try makeMacSW(in: root.appendingPathComponent("shell"), carrying: nil)))
        let macSW = try makeMacSW(in: root, carrying: app)
        let payload = try XCTUnwrap(Installer.payload(in: macSW))
        XCTAssertEqual(payload.archive.lastPathComponent, "SOLIDWORKS.app.zip")
        XCTAssertEqual(payload.version, "1.2")
        XCTAssertEqual(payload.build, "34")
        XCTAssertEqual(payload.executableSHA256, Installer.executableSHA256(of: app))
        XCTAssertEqual(payload.executableSHA256.count, 64)
        // A plist without a usable hash means no payload.
        try (["CFBundleVersion": "34", Installer.executableSHA256Key: "abc"] as NSDictionary)
            .write(to: macSW.appendingPathComponent("Contents/Resources/\(Installer.payloadInfoName)"))
        XCTAssertNil(Installer.payload(in: macSW))
    }

    func testStatusComparesTheInstalledExecutableWithThePayload() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))))
        let system = root.appendingPathComponent("Applications/SOLIDWORKS.app")
        let user = root.appendingPathComponent("home/Applications/SOLIDWORKS.app")
        let candidates = [system, user]

        XCTAssertEqual(Installer.installedCopy(candidates: candidates), .none)
        XCTAssertEqual(Installer.status(payload: payload, installed: .none), .notInstalled)

        try makeApp(at: user, executable: "new")
        XCTAssertEqual(Installer.status(payload: payload, installed: Installer.installedCopy(candidates: candidates)), .current(user))
        try makeApp(at: user, executable: "old")
        XCTAssertEqual(Installer.status(payload: payload, installed: Installer.installedCopy(candidates: candidates)), .stale(user))
        XCTAssertEqual(Installer.status(payload: nil, installed: .ours(user)), .unknown(user))

        // Another app named SOLIDWORKS.app comes first, but our copy in a later place still wins.
        try makeApp(at: system, identifier: "org.macsw.fallback.solidworks")
        XCTAssertEqual(Installer.installedCopy(candidates: candidates), .ours(user))
        try FileManager.default.removeItem(at: user)
        XCTAssertEqual(Installer.status(payload: payload, installed: Installer.installedCopy(candidates: candidates)), .foreign(system))
    }

    func testCandidatesAreTheApplicationsFolders() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(Installer.candidateLocations(home: home).map(\.path),
                       ["/Applications/SOLIDWORKS.app", "/Users/me/Applications/SOLIDWORKS.app"])
    }

    // MARK: Atomic install

    func testInstallUnpacksTheCopyIntoPlaceAndRegistersIt() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))))
        let target = root.appendingPathComponent("Applications/SOLIDWORKS.app")  // the folder does not exist yet
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))

        let result = try Installer.install(payload, to: target, effects: recorder.effects)

        XCTAssertEqual(result, Installer.InstallResult(app: target, replaced: false, requirementChanged: false))
        XCTAssertEqual(executable(target), "new")
        XCTAssertEqual(Installer.executableSHA256(of: target), payload.executableSHA256)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["SOLIDWORKS.app"])
        XCTAssertEqual(recorder.log, ["verify SOLIDWORKS.app", "register \(target.path)"])
    }

    func testInstallSwapsAnExistingCopyAndRemovesTheOldOne() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"),
                                            executable: "new", requirement: "certificate leaf = H\"6164\""))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                                 executable: "old", requirement: "certificate leaf = H\"6164\"")
        FileManager.default.createFile(atPath: target.appendingPathComponent("Contents/old-only").path, contents: Data())
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))

        let result = try Installer.install(payload, to: target, effects: recorder.effects)

        XCTAssertEqual(result, Installer.InstallResult(app: target, replaced: true, requirementChanged: false))
        XCTAssertEqual(executable(target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/old-only").path))
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [], "the superseded copy is removed")
        XCTAssertFalse(recorder.log.contains { $0.hasPrefix("trash") }, "an update does not fill the Trash")
        XCTAssertEqual(recorder.log.last, "register \(target.path)")
    }

    func testInstallReportsAChangedSignatureRequirement() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"),
                                            executable: "new", requirement: "certificate leaf = H\"6164\""))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                                 executable: "old", requirement: "cdhash H\"92a1\"")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        // An ad hoc copy has no lasting permissions to keep: replaced without asking.
        let result = try Installer.install(payload, to: target, effects: recorder.effects)
        XCTAssertTrue(result.requirementChanged)
        XCTAssertEqual(executable(target), "new")
        XCTAssertEqual(executable(root.appendingPathComponent("Trash/SOLIDWORKS.app")), "old", "the old copy is in the Trash")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
    }

    func testCertificateSignedCopyIsNotReplacedWithAnotherRequirementUnlessAllowed() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"),
                                            executable: "adhoc", requirement: "cdhash H\"92a1\""))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                                 executable: "signed", requirement: "identifier \"x\" and certificate leaf = H\"6164\"")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))

        XCTAssertThrowsError(try Installer.install(payload, to: target, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .requirementWouldChange(target))
        }
        XCTAssertEqual(executable(target), "signed")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [], "the unpacked copy is cleaned up")
        XCTAssertEqual(recorder.log, ["verify SOLIDWORKS.app"], "not registered, nothing in the Trash")

        // The user confirmed: replaced, and the signed copy goes to the Trash, not deleted.
        let result = try Installer.install(payload, to: target, effects: recorder.effects, allowRequirementChange: true)
        XCTAssertEqual(result, Installer.InstallResult(app: target, replaced: true, requirementChanged: true))
        XCTAssertEqual(executable(target), "adhoc")
        XCTAssertEqual(executable(root.appendingPathComponent("Trash/SOLIDWORKS.app")), "signed")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
        XCTAssertTrue(recorder.log.contains("register \(target.path)"))
        XCTAssertTrue(recorder.log.contains { $0.hasPrefix("unregister ") && $0.contains("/.SOLIDWORKS-install-") },
                      "the old copy is unregistered before it goes to the Trash")

        // The same identity: an update needs no consent.
        let sameIdentity = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root.appendingPathComponent("next"), carrying: try makeApp(at: root.appendingPathComponent("build2/SOLIDWORKS.app"),
                executable: "signed-2", requirement: "identifier \"x\" and certificate leaf = H\"6164\""))))
        try FileManager.default.removeItem(at: target)
        try makeApp(at: target, executable: "signed-1", requirement: "identifier \"x\" and certificate leaf = H\"6164\"")
        XCTAssertFalse(try Installer.install(sameIdentity, to: target, effects: recorder.effects).requirementChanged)
        XCTAssertEqual(executable(target), "signed-2")
    }

    func testRequirementKinds() {
        XCTAssertTrue(Installer.isIdentityRequirement("identifier \"com.yjbeetle.macsw.solidworks\" and certificate leaf = H\"6164\""))
        XCTAssertTrue(Installer.isIdentityRequirement("identifier \"a\" and anchor apple generic and certificate leaf[subject.OU] = T"))
        XCTAssertFalse(Installer.isIdentityRequirement("cdhash H\"92a1\" or cdhash H\"77b0\""))
        XCTAssertFalse(Installer.isIdentityRequirement(nil))
    }

    func testInstalledCopyHasNoQuarantineFromADownloadedMacSW() throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app")))
        let zip = macSW.appendingPathComponent("Contents/Resources/\(Installer.payloadName)").path
        let quarantine = "0083;6720f000;Safari;"
        XCTAssertEqual(setxattr(zip, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0), 0)
        let payload = try XCTUnwrap(Installer.payload(in: macSW))
        let target = root.appendingPathComponent("Applications/SOLIDWORKS.app")

        _ = try Installer.install(payload, to: target, effects: Recorder(trashFolder: root.appendingPathComponent("Trash")).effects)

        for path in [target.path, target.appendingPathComponent("Contents/MacOS/SOLIDWORKS").path] {
            XCTAssertLessThan(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0, path)
        }
    }

    func testInstallRefusesWhileTheInstalledCopyRuns() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "old")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let host = Installer.RunningExecutable(pid: 4242, path: target.appendingPathComponent("Contents/MacOS/SOLIDWORKS").path)
        recorder.running = { _ in [host] }

        XCTAssertThrowsError(try Installer.install(payload, to: target, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .running(target))
        }
        XCTAssertEqual(executable(target), "old")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
        XCTAssertEqual(recorder.log, [], "nothing unpacked, verified or registered")
    }

    func testInstallChecksAgainRightBeforeTheSwitch() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "old")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        // Not running at the first check; the launcher started while the copy was unpacked.
        let launcher = Installer.RunningExecutable(pid: 77, path: target.path + "/Contents/MacOS/SOLIDWORKS")
        recorder.running = { check in check == 1 ? [] : [launcher] }

        XCTAssertThrowsError(try Installer.install(payload, to: target, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .running(target))
        }
        XCTAssertEqual(executable(target), "old")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [], "the unpacked copy is cleaned up")
        XCTAssertFalse(recorder.log.contains { $0.hasPrefix("register") })
    }

    func testInstallNeverReplacesAnotherAppWithTheSameName() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                                 identifier: "org.macsw.fallback.solidworks", executable: "applescript")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        XCTAssertThrowsError(try Installer.install(payload, to: target, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .foreignApp(target))
        }
        XCTAssertEqual(executable(target), "applescript")
        XCTAssertEqual(recorder.log, [])
    }

    func testDamagedPayloadLeavesTheInstalledCopyAlone() throws {
        let root = try temporaryDirectory(self)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(
            in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"),
            hash: String(repeating: "0", count: 64))))
        let target = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "old")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        XCTAssertThrowsError(try Installer.install(payload, to: target, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .damagedPayload)
        }
        XCTAssertEqual(executable(target), "old")
        XCTAssertEqual(leftovers(in: target.deletingLastPathComponent()), [])
        XCTAssertEqual(recorder.log, [])
    }

    // MARK: Uninstall

    func testUninstallUnregistersAndMovesTheCopyToTheTrash() throws {
        let root = try temporaryDirectory(self)
        let app = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"))
        let trash = root.appendingPathComponent("Trash")
        let recorder = Recorder(trashFolder: trash)

        try Installer.uninstall(app, effects: recorder.effects)

        XCTAssertEqual(recorder.log, ["unregister \(app.path)", "trash \(app.path)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertEqual(executable(trash.appendingPathComponent("SOLIDWORKS.app")), "build-1", "moved, not deleted")
    }

    func testUninstallRefusesWhileRunningAndForOtherApps() throws {
        let root = try temporaryDirectory(self)
        let app = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"))
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        recorder.running = { _ in [Installer.RunningExecutable(pid: 9, path: app.path + "/Contents/MacOS/SOLIDWORKS")] }
        XCTAssertThrowsError(try Installer.uninstall(app, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .running(app))
        }
        let other = try makeApp(at: root.appendingPathComponent("Other/SOLIDWORKS.app"), identifier: "com.example.other")
        XCTAssertThrowsError(try Installer.uninstall(other, effects: recorder.effects)) {
            XCTAssertEqual($0 as? Installer.InstallError, .foreignApp(other))
        }
        XCTAssertEqual(recorder.log, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Running guard

    func testProcessesInsideMatchTheWholeBundlePath() {
        let app = URL(fileURLWithPath: "/Applications/SOLIDWORKS.app")
        let running = [
            Installer.RunningExecutable(pid: 1, path: "/Applications/SOLIDWORKS.app/Contents/MacOS/SOLIDWORKS"),
            Installer.RunningExecutable(pid: 2, path: "/Applications/SOLIDWORKS.app2/Contents/MacOS/SOLIDWORKS"),
            Installer.RunningExecutable(pid: 3, path: "/Applications/MacSW.app/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW"),
            Installer.RunningExecutable(pid: 4, path: "/applications/solidworks.app/Contents/MacOS/SOLIDWORKS"),
            Installer.RunningExecutable(pid: 5, path: "/Applications/SOLIDWORKS.app"),
        ]
        XCTAssertEqual(Installer.processes(inside: app, in: running), [1, 4])
    }

    func testLiveProcessListIncludesThisProcess() {
        let own = Installer.liveRunningExecutables().first { $0.pid == getpid() }
        XCTAssertNotNil(own)
        XCTAssertEqual(own.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
                       Bundle.main.executableURL?.resolvingSymlinksInPath().path)
    }

    // MARK: Default handler and pairing

    func testOwnedContentTypesAreTheOwnerRankedOnes() throws {
        let app = try makeApp(at: try temporaryDirectory(self).appendingPathComponent("SOLIDWORKS.app"))
        XCTAssertEqual(Installer.ownedContentTypes(of: app), ["com.dassault.solidworks.part", "com.dassault.solidworks.assembly"])
    }

    func testHandlerChangesKeepAnotherAppsChoice() {
        let current: [String: String] = ["part": AppBundleLaunch.macSWBundleIdentifier, "drawing": "com.example.viewer"]
        XCTAssertEqual(Installer.handlerChanges(types: ["part", "assembly", "drawing"], current: { current[$0] },
                                                replacing: AppBundleLaunch.macSWBundleIdentifier),
                       ["part", "assembly"])
    }

    func testOnlyTheMacSWThatTheCopyWouldUsePairsWithIt() throws {
        let root = try temporaryDirectory(self)
        let this = root.appendingPathComponent("Applications/MacSW.app")
        try FileManager.default.createDirectory(at: this, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Applications"))
        let target = root.appendingPathComponent("Applications/SOLIDWORKS.app")
        XCTAssertEqual(Installer.pairing(target: target, thisMacSW: this, locate: { _ in this }), .thisMacSW)
        XCTAssertEqual(Installer.pairing(target: target, thisMacSW: link.appendingPathComponent("MacSW.app"),
                                         locate: { _ in this }), .thisMacSW)
        let other = URL(fileURLWithPath: "/Applications/MacSW.app")
        XCTAssertEqual(Installer.pairing(target: target, thisMacSW: root.appendingPathComponent("build/MacSW.app"),
                                         locate: { _ in other }), .other(other))
        XCTAssertEqual(Installer.pairing(target: target, thisMacSW: this, locate: { _ in nil }), .none)
        // The launcher's own search: next to the copy first.
        try FileManager.default.createDirectory(at: this.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix"),
                                                withIntermediateDirectories: true)
        try (["CFBundleIdentifier": AppBundleLaunch.macSWBundleIdentifier] as NSDictionary)
            .write(to: this.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: this.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW").path,
                                       contents: Data("loader".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(Installer.pairing(target: target, thisMacSW: this, locate: Installer.liveLocate), .thisMacSW)
    }

    /// With a signed SOLIDWORKS.app (MACSW_TEST_SIGNED_SOLIDWORKS_APP): the installed copy keeps the
    /// signature and designated requirement, so macOS privacy grants survive an update.
    func testSignedCopyKeepsItsDesignatedRequirement() throws {
        guard let path = ProcessInfo.processInfo.environment["MACSW_TEST_SIGNED_SOLIDWORKS_APP"] else { return }
        let root = try temporaryDirectory(self)
        let source = URL(fileURLWithPath: path)
        let payload = try XCTUnwrap(Installer.payload(in: try makeMacSW(in: root, carrying: source)))
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let live = Installer.liveEffects
        var effects = recorder.effects
        effects.verifySignature = live.verifySignature
        effects.designatedRequirement = live.designatedRequirement
        let target = root.appendingPathComponent("Applications/SOLIDWORKS.app")

        _ = try Installer.install(payload, to: target, effects: effects)
        let update = try Installer.install(payload, to: target, effects: effects)

        XCTAssertNoThrow(try live.verifySignature(target))
        let requirement = try XCTUnwrap(live.designatedRequirement(source))
        XCTAssertEqual(live.designatedRequirement(target), requirement)
        XCTAssertFalse(update.requirementChanged)
        XCTAssertEqual(Installer.executableSHA256(of: target), Installer.executableSHA256(of: source))
        print("  signed copy: \(requirement)")
    }
}

/// Status as text with plain paths: a URL made for an existing folder can end in "/".
private func describe(_ status: Installer.Status) -> String {
    switch status {
    case .notInstalled: return "notInstalled"
    case .current(let url): return "current " + url.path
    case .stale(let url): return "stale " + url.path
    case .unknown(let url): return "unknown " + url.path
    case .foreign(let url): return "foreign " + url.path
    }
}

@MainActor
final class SolidWorksAppStoreTests: XCTestCase {
    private final class Handlers: @unchecked Sendable {
        var current: [String: String] = [:]
        var set: [String] = []
    }

    private func makeStore(root: URL, macSW: URL, recorder: Recorder, handlers: Handlers,
                           host: URL? = nil, defaults: UserDefaults) -> SolidWorksAppStore {
        let pairedHost = host ?? macSW
        return SolidWorksAppStore(
            paths: AppPaths(appSupportDirectory: root.appendingPathComponent("Support")),
            macSW: macSW,
            defaults: defaults,
            candidates: [root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                         root.appendingPathComponent("home/Applications/SOLIDWORKS.app")],
            effects: recorder.effects,
            handlers: SolidWorksAppStore.DefaultHandlers(
                current: { handlers.current[$0] },
                set: { app, type in handlers.set.append("\(type) -> \(app.lastPathComponent)") }),
            locate: { _ in pairedHost },
            observeTermination: false)
    }

    private func defaults() -> UserDefaults {
        let name = "MacSW.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testStaleCopyIsUpdatedAtStartAndMacSWsTypesFollowIt() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))
        let installed = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "old")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let handlers = Handlers()
        handlers.current = ["com.dassault.solidworks.part": AppBundleLaunch.macSWBundleIdentifier,
                            "com.dassault.solidworks.assembly": "com.example.viewer"]
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: handlers, defaults: defaults())
        XCTAssertEqual(describe(store.status), "stale " + installed.path)

        await store.updateIfStale()

        XCTAssertEqual(describe(store.status), "current " + installed.path)
        XCTAssertEqual(executable(installed), "new")
        XCTAssertEqual(handlers.set, ["com.dassault.solidworks.part -> SOLIDWORKS.app"], "another app's choice is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Support/logs/solidworks-app.log").path))
    }

    func testAnotherMacSWBuildNeverTouchesTheInstalledCopy() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "dev"))
        let installed = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "release")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: Handlers(),
                              host: URL(fileURLWithPath: "/Applications/MacSW.app"), defaults: defaults())

        await store.updateIfStale()
        await store.install()

        XCTAssertEqual(executable(installed), "release")
        XCTAssertEqual(recorder.log, [])
        XCTAssertFalse(store.canInstall)
        XCTAssertNotNil(store.pairingProblem)
        XCTAssertEqual(store.statusMessage, store.pairingProblem)
    }

    func testAnotherMacSWBuildNeverUninstallsTheInstalledCopy() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root.appendingPathComponent("devbuild"),
                                  carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "dev"))
        let installed = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "release")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let handlers = Handlers()
        handlers.current = ["com.dassault.solidworks.part": AppBundleLaunch.solidWorksBundleIdentifier]
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: handlers,
                              host: URL(fileURLWithPath: "/Applications/MacSW.app"), defaults: defaults())
        XCTAssertFalse(store.canUninstall)

        await store.uninstall()

        XCTAssertEqual(executable(installed), "release")
        XCTAssertEqual(recorder.log, [])
        XCTAssertEqual(handlers.set, [], "the document types stay with the installed copy")
        XCTAssertEqual(store.statusMessage, store.pairingProblem)

        // Also a MacSW build without SOLIDWORKS.app explains why.
        let shell = try makeMacSW(in: root.appendingPathComponent("shell"), carrying: nil)
        let shellStore = makeStore(root: root, macSW: shell, recorder: recorder, handlers: handlers,
                                   host: URL(fileURLWithPath: "/Applications/MacSW.app"), defaults: defaults())
        XCTAssertFalse(shellStore.canUninstall)
        XCTAssertNotNil(shellStore.pairingProblem)
    }

    func testAutomaticUpdateNeverChangesTheRequirementOfASignedCopy() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"),
                                                                 executable: "adhoc", requirement: "cdhash H\"92\""))
        let installed = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"),
                                    executable: "signed", requirement: "certificate leaf = H\"6164\"")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: Handlers(), defaults: defaults())

        await store.updateIfStale()

        XCTAssertEqual(executable(installed), "signed")
        XCTAssertEqual(describe(store.status), "stale " + installed.path)
        XCTAssertTrue(store.requirementChangeNeedsConsent)
        XCTAssertFalse(store.updatePending, "no retry and no update when SOLIDWORKS.app quits")
        XCTAssertTrue(store.statusMessage.contains("did not replace it"))
        XCTAssertFalse(recorder.log.contains { $0.hasPrefix("register") || $0.hasPrefix("trash") })

        // The user confirmed in Settings.
        await store.install(allowRequirementChange: true)

        XCTAssertEqual(describe(store.status), "current " + installed.path)
        XCTAssertFalse(store.requirementChangeNeedsConsent)
        XCTAssertEqual(executable(installed), "adhoc")
        XCTAssertEqual(executable(root.appendingPathComponent("Trash/SOLIDWORKS.app")), "signed")
        XCTAssertTrue(store.statusMessage.contains("previous copy is in the Trash"))
    }

    func testRunningCopyIsPostponedNotReplaced() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "new"))
        let installed = try makeApp(at: root.appendingPathComponent("Applications/SOLIDWORKS.app"), executable: "old")
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        final class Launcher: @unchecked Sendable { var running = true }
        let launcher = Launcher()
        let process = Installer.RunningExecutable(pid: 5, path: installed.path + "/Contents/MacOS/SOLIDWORKS")
        recorder.running = { _ in launcher.running ? [process] : [] }
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: Handlers(), defaults: defaults())

        await store.updateIfStale()

        XCTAssertTrue(store.updatePending)
        XCTAssertEqual(describe(store.status), "stale " + installed.path)
        XCTAssertEqual(executable(installed), "old")
        XCTAssertTrue(store.summary.contains("updated when SOLIDWORKS.app quits"))

        // The launcher of the "out of date" alert exits right after it opened MacSW: one retry follows.
        launcher.running = false
        for _ in 0..<150 where store.updatePending { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(store.updatePending)
        XCTAssertEqual(describe(store.status), "current " + installed.path)
        XCTAssertEqual(executable(installed), "new")
    }

    func testUninstallGivesTheTypesBackToMacSW() async throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app")))
        let installed = try makeApp(at: root.appendingPathComponent("home/Applications/SOLIDWORKS.app"))
        let recorder = Recorder(trashFolder: root.appendingPathComponent("Trash"))
        let handlers = Handlers()
        handlers.current = ["com.dassault.solidworks.part": AppBundleLaunch.solidWorksBundleIdentifier,
                            "com.dassault.solidworks.assembly": "com.example.viewer"]
        let store = makeStore(root: root, macSW: macSW, recorder: recorder, handlers: handlers, defaults: defaults())
        XCTAssertEqual(describe(store.status), "current " + installed.path)

        await store.uninstall()

        XCTAssertEqual(describe(store.status), "notInstalled")
        XCTAssertEqual(recorder.log, ["unregister \(installed.path)", "trash \(installed.path)"])
        XCTAssertEqual(handlers.set, ["com.dassault.solidworks.part -> MacSW.app"])
    }

    func testSuggestionIsOfferedOncePerBuild() throws {
        let root = try temporaryDirectory(self)
        let macSW = try makeMacSW(in: root, carrying: try makeApp(at: root.appendingPathComponent("build/SOLIDWORKS.app"), executable: "one"))
        let settings = defaults()
        let store = makeStore(root: root, macSW: macSW, recorder: Recorder(trashFolder: root), handlers: Handlers(), defaults: settings)
        XCTAssertTrue(store.suggestsInstall)
        store.dismissSuggestion()
        XCTAssertFalse(store.suggestsInstall)
        XCTAssertFalse(makeStore(root: root, macSW: macSW, recorder: Recorder(trashFolder: root), handlers: Handlers(),
                                 defaults: settings).suggestsInstall)

        // The next MacSW build carries another SOLIDWORKS.app: offered again.
        let next = try makeMacSW(in: root.appendingPathComponent("next"),
                                 carrying: try makeApp(at: root.appendingPathComponent("build2/SOLIDWORKS.app"), executable: "two"))
        XCTAssertTrue(makeStore(root: root, macSW: next, recorder: Recorder(trashFolder: root), handlers: Handlers(),
                                defaults: settings).suggestsInstall)
        // Never offered by a build without SOLIDWORKS.app.
        let shell = try makeMacSW(in: root.appendingPathComponent("shell"), carrying: nil)
        let shellStore = makeStore(root: root, macSW: shell, recorder: Recorder(trashFolder: root), handlers: Handlers(), defaults: settings)
        XCTAssertFalse(shellStore.suggestsInstall)
        XCTAssertFalse(shellStore.canInstall)
    }
}
