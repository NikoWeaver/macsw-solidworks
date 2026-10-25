import Foundation
import XCTest
@testable import MacSWCore

final class TeamSetupStoreTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: AppPaths!
    private var suiteName: String!
    private var suite: UserDefaults!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-TeamSetup-\(UUID().uuidString)")
        home = root.appendingPathComponent("home", isDirectory: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        suiteName = "MacSW-TeamSetup-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
        suite.removePersistentDomain(forName: suiteName)
    }

    private var teamFolder: URL { home.appendingPathComponent("Library/CloudStorage/Box-Box/Robotics/MacSW", isDirectory: true) }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The Box layout of docs/team-admin.md, with tiny fake media and its manifest.
    private func makeTeamFolder(language: String = "de", install: [String: Bool] = [:]) throws {
        let media = teamFolder.appendingPathComponent("media/SOLIDWORKS 2026 SP04.1")
        let files = ["setup.exe": Data("MZ".utf8), SilentInstallerPlan.coreMSIRelativePath: Data(repeating: 7, count: 2048),
                     "PreReqs/VBA/vba71.msi": Data("vba".utf8), "PreReqs/VBA/vba71_1033.msi": Data("vba 1033".utf8)]
        var lines: [String] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try write(data, to: media.appendingPathComponent(path))
            lines.append("\(MediaManifest.sha256(data))  ./\(path)")
        }
        let manifest = Data((lines.joined(separator: "\n") + "\n").utf8)
        try write(manifest, to: media.appendingPathComponent(MediaManifest.fileName))
        let config: [String: Any] = [
            "schema": 1, "team": "Robotics team",
            "solidworks": ["release": "2026 SP4.1"],
            "media": ["path": "media/SOLIDWORKS 2026 SP04.1", "manifestSHA256": MediaManifest.sha256(manifest)],
            "vba": ["path": "media/SOLIDWORKS 2026 SP04.1/PreReqs/VBA"],
            "defaults": ["launchSolidWorksAtStart": false, "language": language],
            "install": install
        ]
        try write(try JSONSerialization.data(withJSONObject: config), to: teamFolder.appendingPathComponent(TeamConfig.fileName))
    }

    @MainActor
    private func store(macOS: Int = 27, startInstall: (@MainActor (BootstrapStore) -> Void)? = nil) -> TeamSetupStore {
        TeamSetupStore(
            paths: paths, defaults: suite, home: home,
            facts: {
                PreflightService.Facts(
                    isAppleSilicon: true,
                    macOSVersion: OperatingSystemVersion(majorVersion: macOS, minorVersion: 0, patchVersion: 0),
                    rosettaInstalled: true, freeBytes: 100_000_000_000, physicalMemory: 16 << 30)
            },
            appFolders: [], volumes: [], mayOpen: { _ in true }, freeBytes: { _ in 1 << 50 },
            startInstall: startInstall ?? { _ in XCTFail("the install must not start") }
        )
    }

    /// An obviously fake access key (docs/sharing-plan.md, E6).
    private let fakeKey = "0000 1111 2222 3333 4444 5555"

    /// Every file below the test's folder, and the preferences, without the access key.
    private func assertKeyIsNowhere(file: StaticString = #filePath, line: UInt = #line) throws {
        let forms = [InstallSerials.normalized(fakeKey), fakeKey]
        let files = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in files where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertFalse(forms.contains { text.contains($0) }, url.path, file: file, line: line)
        }
        let preferences = "\(suite.dictionaryRepresentation())"
        XCTAssertFalse(forms.contains { preferences.contains($0) }, file: file, line: line)
    }

    @MainActor
    func testPreflightBlocksOnMacOS28() async {
        let store = store(macOS: 28)
        await store.runPreflight()
        XCTAssertTrue(store.preflightBlocked)
        let good = self.store()
        await good.runPreflight()
        XCTAssertFalse(good.preflightBlocked)
        XCTAssertEqual(good.preflight.count, PreflightService.Item.allCases.count)
    }

    /// Box config -> import -> team media -> checked copy -> install window; the next start needs
    /// neither the team folder nor a new copy.
    @MainActor
    func testWizardCopiesTheTeamMediaAndHandsTheCopyToTheInstaller() async throws {
        try makeTeamFolder()
        let wizard = store()
        await wizard.locateTeamConfig()
        let found = try XCTUnwrap(wizard.teamConfig)
        XCTAssertEqual(found.source, .box)
        XCTAssertEqual(found.config.team, "Robotics team")
        XCTAssertTrue(wizard.importTeamConfig())
        XCTAssertNotNil(suite.object(forKey: AppPreferences.autoLaunchSolidWorksKey))

        await wizard.findMedia()
        XCTAssertEqual(wizard.media?.source, .teamFolder)
        XCTAssertTrue(wizard.needsCopy)
        XCTAssertNil(wizard.installMedia)
        XCTAssertTrue(wizard.mediaSummary?.hasPrefix("Found SOLIDWORKS 2026 SP4.1 in your team folder, ") == true,
                      wizard.mediaSummary ?? "")

        await wizard.copyMedia()
        let copy = MediaCopyService.destination(release: "2026 SP4.1", paths: paths)
        XCTAssertEqual(wizard.copyState, .completed(copy))
        XCTAssertEqual(wizard.installMedia, copy)
        let bootstrap = BootstrapStore(paths: paths)
        XCTAssertTrue(wizard.handOff(to: bootstrap))
        XCTAssertEqual(bootstrap.resolvedMedia?.mediaDirectory.resolvingSymlinksInPath(), copy.resolvingSymlinksInPath())

        // Next start, with Box offline.
        try fileManager.moveItem(at: teamFolder, to: root.appendingPathComponent("offline"))
        let next = store()
        await next.locateTeamConfig()
        XCTAssertEqual(next.teamConfig?.source, .imported)
        await next.findMedia()
        XCTAssertEqual(next.media?.source, .localCopy)
        XCTAssertFalse(next.needsCopy)
        XCTAssertEqual(next.copyState, .completed(copy))
        XCTAssertEqual(next.installMedia, copy)
    }

    /// The team media folder is checked against the team config: another version is not copied.
    @MainActor
    func testTeamMediaOfAnotherVersionFailsTheCopy() async throws {
        try makeTeamFolder()
        let media = teamFolder.appendingPathComponent("media/SOLIDWORKS 2026 SP04.1")
        try Data("\(String(repeating: "c", count: 64))  ./setup.exe\n".utf8)
            .write(to: media.appendingPathComponent(MediaManifest.fileName))
        let wizard = store()
        await wizard.locateTeamConfig()
        await wizard.findMedia()
        await wizard.copyMedia()
        guard case .failed(let message) = wizard.copyState else { return XCTFail("\(wizard.copyState)") }
        XCTAssertTrue(message.contains("does not match the team config"), message)
        XCTAssertNil(wizard.installMedia)
    }

    /// Without a team config, media is used where it is, as before.
    @MainActor
    func testWithoutTeamConfigMediaIsUsedWhereItIs() async throws {
        let media = home.appendingPathComponent("Downloads/SOLIDWORKS 2026 SP04.1")
        try write(Data("MZ".utf8), to: media.appendingPathComponent("setup.exe"))
        try write(Data("msi".utf8), to: media.appendingPathComponent(SilentInstallerPlan.coreMSIRelativePath))
        let wizard = store()
        await wizard.locateTeamConfig()
        XCTAssertNil(wizard.teamConfig)
        XCTAssertNil(wizard.teamConfigProblem)
        await wizard.findMedia()
        XCTAssertEqual(wizard.media?.source, .downloads)
        XCTAssertFalse(wizard.needsCopy)
        XCTAssertEqual(wizard.installMedia?.resolvingSymlinksInPath(), media.resolvingSymlinksInPath())
        XCTAssertEqual(wizard.mediaSummary?.hasPrefix("Found SOLIDWORKS 2026 SP04.1 in your Downloads folder"), true)

        await wizard.useDroppedMedia(root.appendingPathComponent("nothing-here"))
        XCTAssertNil(wizard.media)
        XCTAssertNotNil(wizard.mediaProblem)
    }

    @MainActor
    func testInvalidTeamConfigIsReported() async throws {
        try write(Data("{\"schema\": 9}".utf8), to: home.appendingPathComponent("Downloads/\(TeamConfig.fileName)"))
        let wizard = store()
        await wizard.locateTeamConfig()
        XCTAssertNil(wizard.teamConfig)
        XCTAssertTrue(wizard.teamConfigProblem?.contains("newer MacSW") == true, wizard.teamConfigProblem ?? "")
        XCTAssertFalse(wizard.importTeamConfig())
    }

    /// Check (preflight, privacy text, search) -> access key -> copy -> install; the access key
    /// stays in memory, and the next start goes straight to the access key.
    @MainActor
    func testPagesGoFromTheCheckToTheAccessKeyToTheInstall() async throws {
        try makeTeamFolder()
        var started: [BootstrapStore] = []
        let wizard = store(startInstall: { started.append($0) })
        await wizard.begin()
        XCTAssertEqual(wizard.page, .check)
        XCTAssertFalse(wizard.hasSearched, "nothing imported yet: the privacy text comes before the search")
        XCTAssertNil(wizard.teamConfig)

        await wizard.search()
        XCTAssertEqual(wizard.page, .accessKey)
        XCTAssertTrue(wizard.isReady)

        let bootstrap = BootstrapStore(paths: paths)
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .accessKey, "no access key yet")
        bootstrap.serialSolidWorks = "0000 1111 2222 3333 4444"
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .accessKey, "not six groups of four")
        XCTAssertFalse(fileManager.fileExists(atPath: paths.teamConfig.path))

        bootstrap.serialSolidWorks = fakeKey
        bootstrap.serialMotion = "0000 9999 9999 9999 9999 9999"
        bootstrap.licenseMode = .remoteServer
        await wizard.install(into: bootstrap)
        let copy = MediaCopyService.destination(release: "2026 SP4.1", paths: paths)
        XCTAssertEqual(wizard.page, .install)
        XCTAssertEqual(wizard.copyState, .completed(copy))
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started.first === bootstrap)
        XCTAssertTrue(fileManager.fileExists(atPath: paths.teamConfig.path))
        XCTAssertEqual(bootstrap.resolvedMedia?.mediaDirectory.resolvingSymlinksInPath(), copy.resolvingSymlinksInPath())
        XCTAssertTrue(bootstrap.silentInstall)
        XCTAssertTrue(bootstrap.requiresKnownVBA)
        XCTAssertEqual(bootstrap.teamVBAFolder?.resolvingSymlinksInPath(),
                       teamFolder.appendingPathComponent("media/SOLIDWORKS 2026 SP04.1/PreReqs/VBA").resolvingSymlinksInPath())
        XCTAssertEqual(bootstrap.selectedLanguage?.directoryName, "german")
        XCTAssertEqual(bootstrap.serialMotion, "", "the config does not show the other serial fields")
        XCTAssertEqual(bootstrap.licenseMode, .unconfigured)
        XCTAssertTrue(bootstrap.canStart)
        try assertKeyIsNowhere()

        // A failed install: back to the access key (the key stays), and Install again uses the copy.
        wizard.back()
        XCTAssertEqual(wizard.page, .accessKey)
        XCTAssertEqual(bootstrap.serialSolidWorks, fakeKey)
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .install)
        XCTAssertEqual(started.count, 2)

        // The finished install forgets the key; a reinstall later uses the install window.
        wizard.finish(bootstrap)
        XCTAssertEqual(bootstrap.serialSolidWorks, "")
        XCTAssertFalse(bootstrap.requiresKnownVBA)
        XCTAssertNil(bootstrap.teamVBAFolder)
        XCTAssertEqual(wizard.page, .manual)
        wizard.showTeamSetup()
        XCTAssertEqual(wizard.page, .check)

        // The next start: the imported config needs no new prompt, and the copy is found at once.
        let next = store()
        await next.begin()
        XCTAssertTrue(next.hasSearched)
        XCTAssertEqual(next.page, .accessKey)
        XCTAssertEqual(next.media?.source, .localCopy)
    }

    /// English is the media's own language: no language pack.
    @MainActor
    func testTeamLanguageEnglishNeedsNoLanguagePack() async throws {
        try makeTeamFolder(language: "en")
        let wizard = store(startInstall: { _ in })
        await wizard.begin()
        await wizard.search()
        let bootstrap = BootstrapStore(paths: paths)
        bootstrap.serialSolidWorks = fakeKey
        await wizard.install(into: bootstrap)
        XCTAssertNotNil(bootstrap.resolvedMedia)
        XCTAssertNil(bootstrap.selectedLanguage)
    }

    @MainActor
    func testBlockedPreflightKeepsTheCheckPage() async throws {
        try makeTeamFolder()
        let wizard = store(macOS: 28)
        await wizard.begin()
        await wizard.search()
        XCTAssertNotNil(wizard.teamConfig)
        XCTAssertNotNil(wizard.media)
        XCTAssertFalse(wizard.isReady)
        XCTAssertEqual(wizard.page, .check)
    }

    /// The copy stops (here: media of another version than the config names), so the install does
    /// not start; Back returns to the access key. The install window without the team setup drops
    /// the team options.
    @MainActor
    func testAStoppedCopyDoesNotStartTheInstall() async throws {
        try makeTeamFolder()
        try Data("\(String(repeating: "c", count: 64))  ./setup.exe\n".utf8)
            .write(to: teamFolder.appendingPathComponent("media/SOLIDWORKS 2026 SP04.1/\(MediaManifest.fileName)"))
        let wizard = store()
        await wizard.begin()
        await wizard.search()
        XCTAssertEqual(wizard.page, .accessKey)
        let bootstrap = BootstrapStore(paths: paths)
        bootstrap.serialSolidWorks = "0000-1111-2222-3333-4444-5555"
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .install)
        guard case .failed = wizard.copyState else { return XCTFail("\(wizard.copyState)") }
        XCTAssertNil(bootstrap.resolvedMedia)
        wizard.back()
        XCTAssertEqual(wizard.page, .accessKey)
        wizard.back()
        XCTAssertEqual(wizard.page, .check)
        wizard.continueToAccessKey()
        XCTAssertEqual(wizard.page, .accessKey)

        bootstrap.requiresKnownVBA = true
        wizard.useManualInstall(bootstrap)
        XCTAssertEqual(wizard.page, .manual)
        XCTAssertFalse(bootstrap.requiresKnownVBA)
        wizard.showTeamSetup()
        XCTAssertEqual(wizard.page, .check)
    }

    /// A field that the config shows and that is not valid stops Install before the copy starts.
    @MainActor
    func testShownFieldsAreCheckedBeforeTheCopy() async throws {
        try makeTeamFolder(install: ["showOtherKeys": true, "showLicenseServer": true])
        let wizard = store()
        await wizard.begin()
        await wizard.search()
        let bootstrap = BootstrapStore(paths: paths)
        bootstrap.serialSolidWorks = fakeKey
        bootstrap.serialMotion = "1234"
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .accessKey)
        XCTAssertEqual(wizard.copyState, .idle)
        XCTAssertTrue(wizard.statusMessage.contains("Motion"), wizard.statusMessage)
        XCTAssertFalse(fileManager.fileExists(atPath: paths.teamConfig.path))

        bootstrap.serialMotion = ""
        bootstrap.licenseMode = .remoteServer
        await wizard.install(into: bootstrap)
        XCTAssertEqual(wizard.page, .accessKey, "no server address yet")
        XCTAssertEqual(wizard.copyState, .idle)
    }

    /// No config where MacSW looks: the page stays, and the member chooses the team folder.
    @MainActor
    func testWithoutAConfigTheMemberChoosesTheTeamFolder() async throws {
        try makeTeamFolder()
        let chosen = root.appendingPathComponent("USB/MacSW")
        try fileManager.createDirectory(at: chosen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: teamFolder, to: chosen)
        let wizard = store()
        await wizard.begin()
        await wizard.search()
        XCTAssertTrue(wizard.hasSearched)
        XCTAssertNil(wizard.teamConfig)
        XCTAssertEqual(wizard.page, .check)

        await wizard.chooseTeamFolder(chosen)
        XCTAssertEqual(wizard.teamConfig?.source, .chosen)
        XCTAssertEqual(wizard.media?.source, .teamFolder)
        XCTAssertEqual(wizard.page, .accessKey)
    }
}
