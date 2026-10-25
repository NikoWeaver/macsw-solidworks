import Foundation
import XCTest
@testable import MacSWCore

/// A valid macsw-team.json, changed per test with `json(_:)`.
private let validConfig: [String: Any] = [
    "schema": 1,
    "team": "Robotics team",
    "solidworks": ["release": "2026 SP4.1", "build": "34.4.1.1011"],
    "media": ["path": "media/SW2026", "manifestSHA256": String(repeating: "AB", count: 32)],
    "vba": ["path": "media/SW2026/PreReqs/VBA"],
    "defaults": ["language": "en", "toolbox": false, "driveLetters": true, "macFileDialogs": "all",
                 "launchSolidWorksAtStart": false],
    "updates": ["feed": "releases/latest.json"],
    "support": ["contact": "Ask in the team CAD channel", "guide": "Start here.pdf"]
]

private func json(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object = validConfig
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

final class TeamConfigTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-TeamConfig-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func invalid(_ data: Data) -> TeamConfigError? {
        do {
            _ = try TeamConfig.parse(data)
            return nil
        } catch {
            return error as? TeamConfigError
        }
    }

    // MARK: Parsing

    /// team/macsw-team.example.json is the admin's starting point: it must stay valid.
    func testExampleConfigParses() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../team/macsw-team.example.json").standardizedFileURL
        let config = try TeamConfig.load(example)
        XCTAssertEqual(config.team, "Robotics team")
        XCTAssertEqual(config.solidWorks.release, "2026 SP4.1")
        XCTAssertEqual(config.solidWorks.build, "34.4.1.1011")
        XCTAssertEqual(config.media.path, "media/SOLIDWORKS 2026 SP04.1")
        XCTAssertEqual(config.vbaPath, "media/SOLIDWORKS 2026 SP04.1/PreReqs/VBA")
        XCTAssertEqual(config.defaults.macFileDialogs, "all")
        XCTAssertEqual(config.defaults.toolbox, false)
        XCTAssertEqual(config.install, TeamConfig.Install.none)
        XCTAssertEqual(config.updatesFeed, "releases/latest.json")
        XCTAssertEqual(config.supportGuide, "Start here.pdf")
    }

    func testHashIsLowercasedAndOptionalPartsMayBeMissing() throws {
        let config = try TeamConfig.parse(json {
            $0["vba"] = nil
            $0["defaults"] = nil
            $0["updates"] = nil
            $0["support"] = nil
            $0["solidworks"] = ["release": " 2026 SP4.1 "]
        })
        XCTAssertEqual(config.media.manifestSHA256, String(repeating: "ab", count: 32))
        XCTAssertEqual(config.solidWorks.release, "2026 SP4.1")
        XCTAssertNil(config.solidWorks.build)
        XCTAssertNil(config.vbaPath)
        XCTAssertNil(config.defaults.driveLetters)
        XCTAssertNil(config.supportContact)
    }

    /// The config is shared and editable: a serial in it is never read or kept.
    func testUnknownKeysAreIgnoredAndASerialIsNotKept() throws {
        let config = try TeamConfig.parse(json {
            $0["serial"] = "PLANTED-KEY-FOR-TEST"
            $0["future"] = ["anything": [1, 2, 3]]
            $0["media"] = ["path": "media/SW2026", "manifestSHA256": String(repeating: "ab", count: 32),
                           "serialNumber": "PLANTED-KEY-FOR-TEST"]
        })
        XCTAssertEqual(config.team, "Robotics team")
        XCTAssertFalse(String(describing: config).contains("PLANTED-KEY"))
        XCTAssertFalse(String(reflecting: config).lowercased().contains("serial"))
    }

    /// The access key step shows one field unless the config turns the others on.
    func testOtherSerialsAndLicenceServerAreHiddenUnlessShown() throws {
        XCTAssertEqual(try TeamConfig.parse(try json()).install, TeamConfig.Install.none)
        let shown = try TeamConfig.parse(try json { $0["install"] = ["showOtherKeys": true, "showLicenseServer": true] })
        XCTAssertTrue(shown.install.showOtherKeys)
        XCTAssertTrue(shown.install.showLicenseServer)
        let one = try TeamConfig.parse(try json { $0["install"] = ["showLicenseServer": true] })
        XCTAssertFalse(one.install.showOtherKeys)
        XCTAssertEqual(invalid(try json { $0["install"] = ["showOtherKeys": "yes"] }),
                       .invalid("install.showOtherKeys has the wrong type"))
    }

    func testNewerSchemaGivesAClearMessageWhateverElseChanged() throws {
        let newer = try JSONSerialization.data(withJSONObject: ["schema": 2, "layout": "new"])
        XCTAssertEqual(invalid(newer), .newerSchema(2))
        XCTAssertTrue((invalid(newer)?.errorDescription ?? "").contains("newer MacSW"))
        XCTAssertEqual(invalid(try json { $0["schema"] = 0 }), .invalid("schema must be 1"))
        XCTAssertEqual(invalid(try json { $0["schema"] = nil }), .invalid("schema is missing"))
        XCTAssertEqual(invalid(try json { $0["schema"] = "1" }), .invalid("schema has the wrong type"))
    }

    func testMissingOrWrongFieldsAreNamed() throws {
        XCTAssertEqual(invalid(Data("not json".utf8)), .notJSON)
        XCTAssertEqual(invalid(Data("[1]".utf8)), .notJSON)
        XCTAssertEqual(invalid(try json { $0["team"] = nil }), .invalid("team is missing"))
        XCTAssertEqual(invalid(try json { $0["team"] = "  " }), .invalid("team is empty"))
        XCTAssertEqual(invalid(try json { $0["media"] = ["path": "media/SW2026"] }), .invalid("media.manifestSHA256 is missing"))
        XCTAssertEqual(invalid(try json { $0["defaults"] = ["toolbox": "no"] }), .invalid("defaults.toolbox has the wrong type"))
        // The plan's placeholder is not a hash.
        guard case .invalid(let reason)? = invalid(try json {
            $0["media"] = ["path": "media/SW2026", "manifestSHA256": "<sha256 of media-manifest.sha256>"]
        }) else { return XCTFail("placeholder hash accepted") }
        XCTAssertTrue(reason.contains("manifestSHA256"), reason)
        guard case .invalid(let mode)? = invalid(try json { $0["defaults"] = ["macFileDialogs": "sometimes"] }) else {
            return XCTFail("unknown file dialog mode accepted")
        }
        XCTAssertTrue(mode.contains("macFileDialogs"), mode)
    }

    /// The release names the local copy's folder in Application Support.
    func testReleaseMustBeAPlainFolderName() throws {
        for release in ["", "../escape", "2026/SP4", "a:b", ".hidden", "a\\b", String(repeating: "x", count: 65)] {
            XCTAssertNotNil(invalid(try json { $0["solidworks"] = ["release": release] }), release)
        }
        XCTAssertNil(invalid(try json { $0["solidworks"] = ["release": "2026 SP4.1 (team)"] }))
    }

    func testAbsoluteAndParentPathsAreRefused() throws {
        let cases: [(String, String)] = [
            ("/Users/someone/media", "it must be relative to the team folder"),
            ("~/media", "it must be relative to the team folder"),
            ("media/../../outside", "it must not contain .."),
            ("..", "it must not contain .."),
            ("media\\SW2026", "use / between folder names")
        ]
        for (path, reason) in cases {
            XCTAssertEqual(invalid(try json { $0["media"] = ["path": path, "manifestSHA256": String(repeating: "a", count: 64)] }),
                           .unsafePath(field: "media.path", path: path, reason: reason))
        }
        XCTAssertEqual(invalid(try json { $0["vba"] = ["path": "../VBA"] }),
                       .unsafePath(field: "vba.path", path: "../VBA", reason: "it must not contain .."))
        XCTAssertEqual(invalid(try json { $0["support"] = ["guide": "/etc/passwd"] }),
                       .unsafePath(field: "support.guide", path: "/etc/passwd", reason: "it must be relative to the team folder"))
    }

    // MARK: Paths in the team folder

    func testPathsResolveOnlyInsideTheTeamFolder() throws {
        let team = root.appendingPathComponent("MacSW", isDirectory: true)
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: team.appendingPathComponent("media/SW2026/PreReqs/VBA"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let config = try TeamConfig.parse(json())

        XCTAssertEqual(try config.mediaFolder(in: team).lastPathComponent, "SW2026")
        XCTAssertEqual(try config.vbaFolder(in: team)?.lastPathComponent, "VBA")
        // A link inside the team folder may point inside it, never out of it.
        try fileManager.createSymbolicLink(at: team.appendingPathComponent("inside"), withDestinationURL: team.appendingPathComponent("media"))
        try fileManager.createSymbolicLink(at: team.appendingPathComponent("media/out"), withDestinationURL: outside)
        XCTAssertNoThrow(try TeamConfig.resolve("inside/SW2026", field: "media.path", in: team))
        XCTAssertThrowsError(try TeamConfig.resolve("media/out", field: "media.path", in: team)) {
            XCTAssertEqual($0 as? TeamConfigError,
                           .unsafePath(field: "media.path", path: "media/out", reason: "it leads out of the team folder"))
        }
        XCTAssertThrowsError(try TeamConfig.resolve("media/missing", field: "media.path", in: team)) {
            XCTAssertEqual($0 as? TeamConfigError, .notFound(field: "media.path", path: "media/missing"))
        }
        // The media path names a folder, not a file.
        try Data("x".utf8).write(to: team.appendingPathComponent("media/file.iso"))
        let fileConfig = try TeamConfig.parse(json {
            $0["media"] = ["path": "media/file.iso", "manifestSHA256": String(repeating: "a", count: 64)]
        })
        XCTAssertThrowsError(try fileConfig.mediaFolder(in: team))
    }

    // MARK: Defaults

    func testDefaultsNeverReplaceTheMembersChoice() throws {
        let suiteName = "MacSW-TeamDefaults-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(false, forKey: AppPreferences.mapMacFoldersKey)

        let config = try TeamConfig.parse(json {
            $0["defaults"] = ["driveLetters": true, "macFileDialogs": "1", "launchSolidWorksAtStart": true, "toolbox": true]
        })
        let written = config.applyDefaults(to: suite)

        XCTAssertEqual(written, [AppPreferences.autoLaunchSolidWorksKey, AppPreferences.useMacFileDialogsKey,
                                 AppPreferences.macFileDialogsEverywhereKey])
        XCTAssertFalse(AppPreferences.mapMacFolders(defaults: suite))
        XCTAssertTrue(AppPreferences.autoLaunchSolidWorks(defaults: suite))
        XCTAssertTrue(AppPreferences.useMacFileDialogs(defaults: suite))
        XCTAssertFalse(AppPreferences.macFileDialogsEverywhere(defaults: suite))
        // A second import writes nothing: every value is set now.
        XCTAssertEqual(config.applyDefaults(to: suite), [])

        let off = try TeamConfig.parse(json { $0["defaults"] = ["macFileDialogs": "off"] })
        let fresh = try XCTUnwrap(UserDefaults(suiteName: suiteName + "-off"))
        defer { fresh.removePersistentDomain(forName: suiteName + "-off") }
        XCTAssertEqual(off.applyDefaults(to: fresh), [AppPreferences.useMacFileDialogsKey])
        XCTAssertFalse(AppPreferences.useMacFileDialogs(defaults: fresh))
    }
}

final class TeamConfigLocatorTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: AppPaths!
    private var suiteName: String!
    private var suite: UserDefaults!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-TeamLocator-\(UUID().uuidString)")
        home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("Library/CloudStorage"), withIntermediateDirectories: true)
        paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        suiteName = "MacSW-TeamLocator-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
        suite.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    private func config(in folder: URL, team: String, valid: Bool = true) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(TeamConfig.fileName)
        try (valid ? json { $0["team"] = team } : Data("{\"schema\": 1}".utf8)).write(to: file)
        return file
    }

    private var box: URL { home.appendingPathComponent("Library/CloudStorage/Box-Box", isDirectory: true) }

    private func locate(appFolders: [URL] = [], mayOpen: @escaping (URL) async -> Bool = { _ in true }) async -> TeamConfigLocator.Outcome {
        await TeamConfigLocator.locate(paths: paths, defaults: suite, appFolders: appFolders, home: home, mayOpen: mayOpen)
    }

    private func found(_ outcome: TeamConfigLocator.Outcome) -> TeamConfigLocator.Found? {
        if case .found(let found) = outcome { return found }
        return nil
    }

    func testSearchOrderIsImportedAppFolderDownloadsThenBox() async throws {
        let app = root.appendingPathComponent("Volumes/MacSW 0.2.0", isDirectory: true)
        try config(in: box.appendingPathComponent("Robotics/MacSW"), team: "box")
        let downloads = try config(in: home.appendingPathComponent("Downloads"), team: "downloads")
        let next = try config(in: app, team: "app")

        var outcome = await locate(appFolders: [app])
        XCTAssertEqual(found(outcome)?.config.team, "app")
        XCTAssertEqual(found(outcome)?.source, .appFolder)
        try fileManager.removeItem(at: next)
        outcome = await locate(appFolders: [app])
        XCTAssertEqual(found(outcome)?.source, .downloads)
        try fileManager.removeItem(at: downloads)
        outcome = await locate(appFolders: [app])
        let fromBox = try XCTUnwrap(found(outcome))
        XCTAssertEqual(fromBox.source, .box)
        XCTAssertEqual(fromBox.teamFolder.lastPathComponent, "MacSW")

        // Imported: found first, with the paths still relative to the Box folder.
        try TeamConfigLocator.importConfig(fromBox, paths: paths, defaults: suite)
        try config(in: app, team: "app")
        let again = await locate(appFolders: [app])
        let imported = try XCTUnwrap(found(again))
        XCTAssertEqual(imported.source, .imported)
        XCTAssertEqual(imported.config.team, "box")
        XCTAssertEqual(imported.file, paths.teamConfig)
        XCTAssertEqual(imported.teamFolder, fromBox.teamFolder)
        XCTAssertEqual(AppPreferences.teamFolder(defaults: suite), fromBox.teamFolder)
        XCTAssertTrue(AppPreferences.mapMacFolders(defaults: suite))
        XCTAssertNotNil(suite.object(forKey: AppPreferences.mapMacFoldersKey))
    }

    /// `Box-*/MacSW` and `Box-*/<top-level folder>/MacSW`, nothing deeper.
    func testBoxIsSearchedTwoLevelsDeepByNameOnly() async throws {
        try config(in: box.appendingPathComponent("Team/Robotics/MacSW"), team: "too deep")
        let deep = await locate()
        XCTAssertEqual(deep, .notFound)
        try config(in: home.appendingPathComponent("Library/CloudStorage/Box-Work/MacSW"), team: "top level")
        let top = await locate()
        XCTAssertEqual(found(top)?.config.team, "top level")
        // Other providers are not searched.
        try config(in: home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/MacSW"), team: "onedrive")
        XCTAssertEqual(TeamConfigLocator.boxRoots(home: home).map(\.lastPathComponent), ["Box-Box", "Box-Work"])
    }

    /// Downloads and Box are opened only through `mayOpen` (the macOS prompt); a refusal skips them.
    func testProtectedFoldersAreOpenedOnlyAfterMayOpen() async throws {
        try config(in: home.appendingPathComponent("Downloads"), team: "downloads")
        try config(in: box.appendingPathComponent("MacSW"), team: "box")
        let asked = Recorder()
        let outcome = await locate(mayOpen: { folder in
            asked.add(folder.lastPathComponent)
            return folder.lastPathComponent != "Downloads"
        })
        XCTAssertEqual(found(outcome)?.config.team, "box")
        XCTAssertEqual(asked.values, ["Downloads", "Box-Box"])
        let refused = await locate(mayOpen: { _ in false })
        XCTAssertEqual(refused, .notFound)
    }

    func testFirstValidConfigWinsAndAnInvalidOneIsReportedOtherwise() async throws {
        let app = root.appendingPathComponent("app", isDirectory: true)
        let broken = try config(in: app, team: "", valid: false)
        try config(in: home.appendingPathComponent("Downloads"), team: "downloads")
        let valid = await locate(appFolders: [app])
        XCTAssertEqual(found(valid)?.config.team, "downloads")
        try fileManager.removeItem(at: home.appendingPathComponent("Downloads/\(TeamConfig.fileName)"))
        guard case .invalid(let file, let message) = await locate(appFolders: [app]) else {
            return XCTFail("the invalid config was not reported")
        }
        XCTAssertEqual(file, broken)
        XCTAssertTrue(message.contains("team is missing"), message)
    }

    func testChosenFolderOrFile() throws {
        let team = root.appendingPathComponent("Chosen/MacSW", isDirectory: true)
        let file = try config(in: team, team: "chosen")
        XCTAssertEqual(found(TeamConfigLocator.examineChosen(team))?.source, .chosen)
        XCTAssertEqual(found(TeamConfigLocator.examineChosen(file))?.teamFolder, team.standardizedFileURL)
        guard case .invalid(_, let message) = TeamConfigLocator.examineChosen(root) else {
            return XCTFail("a folder without a config was accepted")
        }
        XCTAssertTrue(message.contains(TeamConfig.fileName), message)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
