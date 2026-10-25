import Foundation
import XCTest
@testable import MacSWCore

final class VBAPrerequisiteTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var suite: UserDefaults!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-VBA-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MacSW-VBA-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
        suite.removePersistentDomain(forName: suiteName)
    }

    @discardableResult
    private func write(_ relativePath: String, contents: String = "payload") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func names(_ urls: [URL]?) -> [String] {
        (urls ?? []).map(\.lastPathComponent)
    }

    // MARK: Finding the installers

    /// sldim.xml: `PreReqs\VBA\vba71.msi` and `vba71_1033.msi`; the core product goes first.
    func testOfficialLayoutGivesBothInstallersInInstallOrder() throws {
        try write("media/PreReqs/VBA/vba71_1033.msi")
        try write("media/PreReqs/VBA/vba71.msi")
        let found = VBAPrerequisite.installers(media: root.appendingPathComponent("media"), userFolder: nil)
        XCTAssertEqual(names(found), ["vba71.msi", "vba71_1033.msi"])
        XCTAssertEqual(found?.first?.deletingLastPathComponent().lastPathComponent, "VBA")
    }

    func testFolderAndFileNamesMatchWithoutCase() throws {
        try write("media/PREREQS/vba/VBA71.MSI")
        try write("media/PREREQS/vba/Vba71_1033.Msi")
        let found = VBAPrerequisite.installers(media: root.appendingPathComponent("media"), userFolder: nil)
        XCTAssertEqual(names(found), ["VBA71.MSI", "Vba71_1033.Msi"])
    }

    func testOtherMediaLayoutsAreSearched() throws {
        try write("media/PreReqs/Microsoft_VBA/vba71.msi")
        try write("media/PreReqs/Microsoft_VBA/vba71_1033.msi")
        XCTAssertEqual(
            names(VBAPrerequisite.installers(media: root.appendingPathComponent("media"), userFolder: nil)),
            ["vba71.msi", "vba71_1033.msi"]
        )
    }

    /// The English resource MSI alone, or an empty or directory "MSI", is not an installable VBA.
    func testBothNonEmptyInstallersAreRequired() throws {
        let folder = root.appendingPathComponent("vba")
        try write("vba/vba71.msi")
        XCTAssertNil(VBAPrerequisite.installers(inFolder: folder))
        try write("vba/vba71_1033.msi", contents: "")
        XCTAssertNil(VBAPrerequisite.installers(inFolder: folder))
        try write("vba/vba71_1033.msi")
        XCTAssertEqual(names(VBAPrerequisite.installers(inFolder: folder)), ["vba71.msi", "vba71_1033.msi"])
        try fileManager.removeItem(at: folder.appendingPathComponent("vba71.msi"))
        try fileManager.createDirectory(at: folder.appendingPathComponent("vba71.msi"), withIntermediateDirectories: true)
        XCTAssertNil(VBAPrerequisite.installers(inFolder: folder))
        XCTAssertNil(VBAPrerequisite.installers(inFolder: root.appendingPathComponent("missing")))
    }

    /// The media's own MSIs match the SOLIDWORKS version being installed, so they win over the
    /// folder remembered in Settings; that folder is used when the media has none.
    func testMediaComesBeforeTheUserFolder() throws {
        try write("user/vba71.msi")
        try write("user/vba71_1033.msi")
        try fileManager.createDirectory(at: root.appendingPathComponent("media/swwi"), withIntermediateDirectories: true)
        let media = root.appendingPathComponent("media")
        let user = root.appendingPathComponent("user")
        XCTAssertEqual(VBAPrerequisite.installers(media: media, userFolder: user)?.first?.deletingLastPathComponent().lastPathComponent, "user")
        XCTAssertNil(VBAPrerequisite.installers(media: media, userFolder: nil))

        try write("media/PreReqs/VBA/vba71.msi")
        try write("media/PreReqs/VBA/vba71_1033.msi")
        XCTAssertEqual(VBAPrerequisite.installers(media: media, userFolder: user)?.first?.deletingLastPathComponent().lastPathComponent, "VBA")
    }

    /// The team install: the media copy's PreReqs/VBA, then the team config's vba.path, then Settings.
    func testTeamFolderComesAfterTheMediaAndBeforeTheUserFolder() throws {
        for folder in ["team", "user"] {
            try write("\(folder)/vba71.msi")
            try write("\(folder)/vba71_1033.msi")
        }
        let media = root.appendingPathComponent("media")
        let team = root.appendingPathComponent("team")
        let user = root.appendingPathComponent("user")
        func folder(_ found: [URL]?) -> String? { found?.first?.deletingLastPathComponent().lastPathComponent }
        XCTAssertEqual(folder(VBAPrerequisite.installers(media: media, teamFolder: team, userFolder: user)), "team")
        XCTAssertEqual(folder(VBAPrerequisite.installers(media: media, teamFolder: root.appendingPathComponent("missing"),
                                                         userFolder: user)), "user")
        try write("media/PreReqs/VBA/vba71.msi")
        try write("media/PreReqs/VBA/vba71_1033.msi")
        XCTAssertEqual(folder(VBAPrerequisite.installers(media: media, teamFolder: team, userFolder: user)), "VBA")
    }

    // MARK: Known SHA-256 (the team install)

    /// docs/vba-equations.md, section 1: the owner's Microsoft-signed 7.1.11.28 MSIs, hashed again
    /// for this check (build.nosync/vba and the Box copies are byte-identical).
    func testKnownHashesAreTheTwoMicrosoftMSIs() {
        XCTAssertEqual(Set(VBAPrerequisite.knownSHA256.keys), Set(VBAPrerequisite.installerNames))
        XCTAssertEqual(VBAPrerequisite.knownSHA256["vba71.msi"], "08069ec9dfa56d1cdac335ec297451573e1ca8742ecbb358e20ae5be6e9feeee")
        XCTAssertEqual(VBAPrerequisite.knownSHA256["vba71_1033.msi"], "7029661494d24a8b0cba0a176ceab0c18fa02c004288672f21c1f0cfc7a07955")
    }

    func testHashCheckAcceptsOnlyTheKnownFiles() throws {
        let base = try write("vba/vba71.msi", contents: "base")
        let english = try write("vba/VBA71_1033.MSI", contents: "english")
        let known = ["vba71.msi": MediaManifest.sha256(Data("base".utf8)),
                     "vba71_1033.msi": MediaManifest.sha256(Data("english".utf8))]
        XCTAssertNoThrow(try VBAPrerequisite.checkKnownHashes([base, english], known: known))

        try write("vba/VBA71_1033.MSI", contents: "changed")
        XCTAssertThrowsError(try VBAPrerequisite.checkKnownHashes([base, english], known: known)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("vba71_1033.msi is not the Microsoft file MacSW knows"),
                          error.localizedDescription)
        }
        XCTAssertThrowsError(try VBAPrerequisite.checkKnownHashes([try write("vba/other.msi")], known: known))
        XCTAssertThrowsError(try VBAPrerequisite.checkKnownHashes([root.appendingPathComponent("vba/missing.msi")], known: known))
        XCTAssertThrowsError(try VBAPrerequisite.checkKnownHashes([base]), "a fake file is not the real MSI")
    }

    /// The staged copies (the files msiexec reads) are all checked first: one unknown MSI stops
    /// the install before Wine starts, also for the other MSI, and the staging folder is removed.
    func testInstallRefusesAnUnknownMSIBeforeWineStarts() async throws {
        let calls = Calls()
        let wine = WineService(prepareBottle: { _ in
            calls.add("wine")
            throw MacSWError.make("Wine does not start in this test.", domain: "test")
        })
        let bottle = root.appendingPathComponent("support/bottle")
        let temp = bottle.appendingPathComponent("drive_c/windows/temp")
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        let installers = [try write("vba/vba71.msi", contents: "base"), try write("vba/vba71_1033.msi", contents: "english")]
        let base = MediaManifest.sha256(Data("base".utf8))
        let english = MediaManifest.sha256(Data("english".utf8))

        do {
            try await PrerequisiteService(wine: wine).installVBA(
                installers: installers, prefix: bottle,
                knownSHA256: ["vba71.msi": base, "vba71_1033.msi": String(repeating: "0", count: 64)])
            XCTFail("an unknown MSI was installed")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("vba71_1033.msi is not"), error.localizedDescription)
        }
        XCTAssertEqual(calls.all, [])
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: temp.path), [])

        do {
            try await PrerequisiteService(wine: wine).installVBA(
                installers: installers, prefix: bottle, knownSHA256: ["vba71.msi": base, "vba71_1033.msi": english])
            XCTFail("Wine was not asked to start")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wine does not start in this test.")
        }
        XCTAssertEqual(calls.all, ["wine"])
    }

    /// VBA is optional for the install, like Toolbox: media without it is still complete.
    func testVBAIsNotARequiredMediaComponent() {
        XCTAssertFalse(InstallationMedia.requiredComponents.contains { $0.relativePath.lowercased().contains("vba") })
        XCTAssertFalse(InstallationMedia.dotNetComponent.relativePath.lowercased().contains("vba"))
    }

    // MARK: Install plan

    func testVBAArgumentsInstallSilentlyWithAVerboseLog() {
        let arguments = SilentInstallerPlan.vbaInstallArguments(
            msi: URL(fileURLWithPath: "/bottle/drive_c/windows/temp/MacSW-VBA-1/vba71.msi"),
            log: URL(fileURLWithPath: "/logs/vba71-install.log")
        )
        XCTAssertEqual(arguments, [
            "msiexec", "/i", "/bottle/drive_c/windows/temp/MacSW-VBA-1/vba71.msi", "/qn", "/norestart",
            "DISABLEROLLBACK=1", "/l*v", "/logs/vba71-install.log"
        ])
    }

    /// After the other prerequisites (VC++, Login Manager) and before the SOLIDWORKS core MSI,
    /// as the official Installation Manager orders them.
    func testVBAStepRunsAfterThePrerequisitesAndBeforeTheCore() {
        XCTAssertLessThan(InstallationStep.vcRuntime.rawValue, InstallationStep.vba.rawValue)
        XCTAssertLessThan(InstallationStep.loginManager.rawValue, InstallationStep.vba.rawValue)
        XCTAssertLessThan(InstallationStep.vba.rawValue, InstallationStep.installer.rawValue)
        XCTAssertTrue(InstallationStep.vba.title.contains("VBA"))
    }

    func testMessagesSayWhatFailsAndWhereToFixIt() {
        for message in [VBAPrerequisite.missingWarning, VBAPrerequisite.skippedNote] {
            XCTAssertTrue(message.contains("equations and macros will not work"))
        }
        XCTAssertTrue(VBAPrerequisite.skippedNote.contains("Install VBA (equations and macros)"))
        XCTAssertTrue(VBAPrerequisite.skippedNote.contains("PreReqs/VBA"))
    }

    // MARK: Registration in the registry files

    private static let registered = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\Machine

    #arch=win64

    [Software\\Classes\\CLSID\\{CFE9F29B-E1B6-4240-AED7-360846769314}] 1792774003
    #time=1dd630e15c46b24
    @="Microsoft APC 7.1 Object Library"

    [Software\\Classes\\CLSID\\{CFE9F29B-E1B6-4240-AED7-360846769314}\\InprocServer32] 1792774003
    #time=1dd630e15c46b24
    @="C:\\Program Files\\Common Files\\Microsoft Shared\\VBA\\VBA7.1\\apc71.dll"

    [Software\\Classes\\MSAPC.Apc\\CLSID] 1792774003
    @="{CFE9F29B-E1B6-4240-AED7-360846769314}"
    """#

    func testRegisteredInprocServerCounts() {
        XCTAssertTrue(VBAPrerequisite.isRegistered(inHive: Self.registered))
        XCTAssertTrue(VBAPrerequisite.isRegistered(inHive: Self.registered.lowercased()))
    }

    /// The ProgID's CLSID value, the class key without InprocServer32, an empty default value
    /// and the 32-bit view do not make the 64-bit SLDWORKS.exe able to create the class.
    func testIncompleteOr32BitRegistrationDoesNotCount() {
        let progIDOnly = #"""
        [Software\\Classes\\MSAPC.Apc\\CLSID] 1792774003
        @="{CFE9F29B-E1B6-4240-AED7-360846769314}"
        """#
        let classOnly = #"""
        [Software\\Classes\\CLSID\\{CFE9F29B-E1B6-4240-AED7-360846769314}] 1792774003
        @="Microsoft APC 7.1 Object Library"
        """#
        let emptyValue = #"""
        [Software\\Classes\\CLSID\\{CFE9F29B-E1B6-4240-AED7-360846769314}\\InprocServer32] 1792774003
        @=""
        "ThreadingModel"="Apartment"
        """#
        let wow64 = #"""
        [Software\\Classes\\Wow6432Node\\CLSID\\{CFE9F29B-E1B6-4240-AED7-360846769314}\\InprocServer32] 1792774003
        @="C:\\Program Files (x86)\\Common Files\\Microsoft Shared\\VBA\\VBA7.1\\apc71.dll"
        """#
        for hive in [progIDOnly, classOnly, emptyValue, wow64, ""] {
            XCTAssertFalse(VBAPrerequisite.isRegistered(inHive: hive))
        }
    }

    func testBottleCheckReadsSystemAndUserHives() throws {
        let bottle = root.appendingPathComponent("bottle")
        try fileManager.createDirectory(at: bottle, withIntermediateDirectories: true)
        XCTAssertFalse(VBAPrerequisite.isRegistered(prefix: bottle))
        try write("bottle/system.reg", contents: "WINE REGISTRY Version 2\n")
        XCTAssertFalse(VBAPrerequisite.isRegistered(prefix: bottle))
        try write("bottle/user.reg", contents: Self.registered)
        XCTAssertTrue(VBAPrerequisite.isRegistered(prefix: bottle))
        try fileManager.removeItem(at: bottle.appendingPathComponent("user.reg"))
        try write("bottle/system.reg", contents: Self.registered)
        XCTAssertTrue(VBAPrerequisite.isRegistered(prefix: bottle))
    }

    // MARK: Folder setting

    func testInstallerFolderSettingRoundTripsAndRejectsRelativePaths() {
        XCTAssertNil(AppPreferences.vbaInstallerFolder(defaults: suite))
        AppPreferences.setVBAInstallerFolder(URL(fileURLWithPath: "/Users/me/VBA/"), defaults: suite)
        XCTAssertEqual(AppPreferences.vbaInstallerFolder(defaults: suite)?.path, "/Users/me/VBA")
        suite.set("VBA", forKey: AppPreferences.vbaInstallerFolderKey)
        XCTAssertNil(AppPreferences.vbaInstallerFolder(defaults: suite))
    }
}

@MainActor
final class VBAStoreTests: XCTestCase {
    /// One temporary MacSW support folder and defaults suite per test, removed afterwards.
    @MainActor
    private struct Sandbox {
        let root: URL
        let suite: UserDefaults
        var paths: AppPaths { AppPaths(appSupportDirectory: root.appendingPathComponent("support")) }

        func makeBottle(solidWorks: Bool) throws {
            let executable = paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            if solidWorks { try Data("MZ".utf8).write(to: executable) }
            AppPaths.invalidateInstallationState()
        }

        func installerFolder(complete: Bool = true) throws -> URL {
            let folder = root.appendingPathComponent("Team Folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("msi".utf8).write(to: folder.appendingPathComponent("vba71.msi"))
            if complete { try Data("msi".utf8).write(to: folder.appendingPathComponent("vba71_1033.msi")) }
            return folder
        }

        func store(file: Bool = false, live: Flag = Flag(false), calls: Calls = Calls(), failure: Error? = nil) -> VBAStore {
            VBAStore(
                paths: paths,
                defaults: suite,
                fileCheck: { _ in calls.add("file"); return file },
                liveCheck: { _ in calls.add("live"); return live.value },
                installer: { installers, prefix in
                    calls.add("install " + installers.map(\.lastPathComponent).joined(separator: ",") + " -> " + prefix.lastPathComponent)
                    if let failure { throw failure }
                }
            )
        }
    }

    private func sandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-VBAStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "MacSW.tests.\(UUID().uuidString)"
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: name)
            AppPaths.invalidateInstallationState()
        }
        return Sandbox(root: root, suite: UserDefaults(suiteName: name)!)
    }

    func testWarnsOnlyWhenSolidWorksIsInstalledAndVBAIsMissing() async throws {
        let box = try sandbox()
        let calls = Calls()
        let missing = box.store(file: false, calls: calls)
        await missing.refresh()
        XCTAssertNil(missing.isRegistered)
        XCTAssertEqual(calls.all, [], "no bottle, nothing to read")

        try box.makeBottle(solidWorks: false)
        await missing.refresh()
        XCTAssertEqual(missing.isRegistered, false)
        XCTAssertNil(missing.missingWarning)

        try box.makeBottle(solidWorks: true)
        XCTAssertEqual(missing.missingWarning, VBAPrerequisite.missingWarning)

        let present = box.store(file: true, calls: calls)
        await present.refresh()
        XCTAssertNil(present.missingWarning)
        XCTAssertEqual(calls.all, ["file", "file"])
    }

    func testFolderWithoutBothInstallersIsRefusedBeforeWineRuns() async throws {
        let box = try sandbox()
        try box.makeBottle(solidWorks: true)
        let calls = Calls()
        let vba = box.store(calls: calls)
        await vba.install(from: try box.installerFolder(complete: false))
        XCTAssertEqual(calls.all, [])
        XCTAssertTrue(vba.statusMessage.contains("vba71_1033.msi"))
        XCTAssertNil(AppPreferences.vbaInstallerFolder(defaults: box.suite))
    }

    func testInstallWithoutBottleDoesNotCreateOne() async throws {
        let box = try sandbox()
        let calls = Calls()
        let vba = box.store(calls: calls)
        await vba.install(from: try box.installerFolder())
        XCTAssertEqual(calls.all, [])
        XCTAssertFalse(box.paths.bottleExists)
    }

    /// The registry files lag up to 30 s behind wineserver, so the reg query result after an
    /// install stays in charge, and the folder is remembered for the next SOLIDWORKS install.
    func testInstallVerifiesWithWineserverAndRemembersTheFolder() async throws {
        let box = try sandbox()
        try box.makeBottle(solidWorks: true)
        let calls = Calls()
        let vba = box.store(file: false, live: Flag(true), calls: calls)
        await vba.refresh()
        XCTAssertEqual(vba.isRegistered, false)

        let folder = try box.installerFolder()
        await vba.install(from: folder)
        XCTAssertEqual(calls.all, ["file", "install vba71.msi,vba71_1033.msi -> bottle", "live"])
        XCTAssertEqual(vba.isRegistered, true)
        XCTAssertNil(vba.missingWarning)
        XCTAssertTrue(vba.statusMessage.contains("Restart SOLIDWORKS"))
        XCTAssertEqual(AppPreferences.vbaInstallerFolder(defaults: box.suite)?.path, folder.standardizedFileURL.path)
        XCTAssertFalse(vba.isWorking)

        await vba.refresh()
        XCTAssertEqual(vba.isRegistered, true, "a stale system.reg does not bring the warning back")
    }

    func testFailedOrUnverifiedInstallKeepsTheWarning() async throws {
        let box = try sandbox()
        try box.makeBottle(solidWorks: true)
        let failing = box.store(failure: MacSWError.make("vba71.msi installation failed (67); see vba71-install.log.", domain: "test"))
        await failing.refresh()
        await failing.install(from: try box.installerFolder())
        XCTAssertEqual(failing.isRegistered, false)
        XCTAssertEqual(failing.statusMessage, "vba71.msi installation failed (67); see vba71-install.log.")
        XCTAssertNotNil(failing.missingWarning)

        let unverified = box.store(live: Flag(false))
        await unverified.install(from: try box.installerFolder())
        XCTAssertEqual(unverified.isRegistered, false)
        XCTAssertTrue(unverified.statusMessage.contains(VBAPrerequisite.apcCLSID))
    }

    /// A finished SOLIDWORKS install (maybe a clean one) replaces what this session knew.
    func testInstallationCompletedAsksWineserverAgain() async throws {
        let box = try sandbox()
        try box.makeBottle(solidWorks: true)
        let live = Flag(true)
        let vba = box.store(live: live)
        await vba.install(from: try box.installerFolder())
        XCTAssertEqual(vba.isRegistered, true)

        live.value = false
        await vba.installationCompleted()
        XCTAssertEqual(vba.isRegistered, false)
        XCTAssertNotNil(vba.missingWarning)
    }

    func testWarningSuppressionIsStored() throws {
        let box = try sandbox()
        let vba = box.store()
        XCTAssertFalse(vba.warningSuppressed)
        vba.warningSuppressed = true
        XCTAssertTrue(box.suite.bool(forKey: AppPreferences.vbaWarningSuppressedKey))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock(); items.append(item); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
