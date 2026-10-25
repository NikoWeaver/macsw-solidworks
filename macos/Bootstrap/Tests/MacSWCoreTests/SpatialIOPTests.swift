import Foundation
import XCTest
@testable import MacSWCore

final class SpatialIOPTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("MacSW-spatialiop-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: directory)
    }

    private func write(_ text: String, _ relative: String, under root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A media tree like the 2026 one: a read-only core MSI next to its cabinets, and folders around it.
    private func makeMedia(swwi: String = "swwi", data: String = "data", msi: String = "solidworks.msi") throws -> URL {
        let media = directory.appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
        try write("setup", "setup.exe", under: media)
        try write("vba", "PreReqs/VBA/vba71.msi", under: media)
        try write("lang", "\(swwi)/lang/german/german.msi", under: media)
        try write("cab", "\(swwi)/\(data)/BOData.cab", under: media)
        try write("zip", "\(swwi)/\(data)/spatialiop.zip", under: media)
        try write("package", "\(swwi)/\(data)/\(msi)", under: media)
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: media.appendingPathComponent("\(swwi)/\(data)/\(msi)").path)
        return media
    }

    private func linkDestination(_ url: URL) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: url.path)
    }

    func testStageMirrorsTheMediaWithLinksAndHoldsOneWritableCopy() throws {
        let media = try makeMedia()
        let stage = directory.appendingPathComponent("bottle/drive_c/MacSW/InstallMedia")
        let copy = try SpatialIOP.stageCorePackage(media: media, stage: stage)

        XCTAssertEqual(copy.path, stage.appendingPathComponent("swwi/data/solidworks.msi").path)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "package")
        XCTAssertNil(linkDestination(copy))
        XCTAssertEqual((try fileManager.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual((try fileManager.attributesOfItem(atPath: media.appendingPathComponent("swwi/data/solidworks.msi").path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        for relative in ["setup.exe", "PreReqs", "swwi/lang", "swwi/data/BOData.cab", "swwi/data/spatialiop.zip"] {
            XCTAssertEqual(linkDestination(stage.appendingPathComponent(relative)), media.appendingPathComponent(relative).path, relative)
        }
        for relative in ["swwi", "swwi/data"] {
            XCTAssertNil(linkDestination(stage.appendingPathComponent(relative)), relative)
        }
        // The cabinets resolve through the links, as msiexec reads them.
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("swwi/data/BOData.cab"), encoding: .utf8), "cab")
    }

    func testRebuildingAndRemovingTheStageNeverTouchesTheMedia() throws {
        let media = try makeMedia()
        let stage = directory.appendingPathComponent("stage")
        _ = try SpatialIOP.stageCorePackage(media: media, stage: stage)
        _ = try SpatialIOP.stageCorePackage(media: media, stage: stage)
        try SpatialIOP.removeStage(stage)
        XCTAssertFalse(fileManager.fileExists(atPath: stage.path))
        for relative in ["setup.exe", "PreReqs/VBA/vba71.msi", "swwi/lang/german/german.msi", "swwi/data/BOData.cab",
                         "swwi/data/spatialiop.zip", "swwi/data/solidworks.msi"] {
            XCTAssertTrue(fileManager.fileExists(atPath: media.appendingPathComponent(relative).path), relative)
        }
        XCTAssertNoThrow(try SpatialIOP.removeStage(stage))
    }

    func testStageKeepsTheMediaSpellingAndRefusesMediaWithoutTheCoreMSI() throws {
        let media = try makeMedia(swwi: "SWWI", data: "Data", msi: "SolidWorks.msi")
        let copy = try SpatialIOP.stageCorePackage(media: media, stage: directory.appendingPathComponent("stage"))
        XCTAssertTrue(copy.path.hasSuffix("/SWWI/Data/SolidWorks.msi"))

        let empty = directory.appendingPathComponent("empty")
        try write("setup", "setup.exe", under: empty)
        XCTAssertThrowsError(try SpatialIOP.stageCorePackage(media: empty, stage: directory.appendingPathComponent("stage2")))
    }

    func testWindowsPathIsTheBottlesCDrive() {
        let prefix = URL(fileURLWithPath: "/tmp/MacSW/bottle")
        XCTAssertEqual(SpatialIOP.windowsPath(of: prefix.appendingPathComponent("drive_c/MacSW/InstallMedia/swwi/data/solidworks.msi"), prefix: prefix),
                       #"C:\MacSW\InstallMedia\swwi\data\solidworks.msi"#)
        XCTAssertNil(SpatialIOP.windowsPath(of: URL(fileURLWithPath: "/Volumes/SW/swwi/data/solidworks.msi"), prefix: prefix))
        XCTAssertNil(SpatialIOP.windowsPath(of: prefix.appendingPathComponent("drive_c"), prefix: prefix))
    }

    func testHelperExitCodes() {
        XCTAssertEqual(try SpatialIOP.packageEdit(exitCode: 0), .disabled)
        XCTAssertEqual(try SpatialIOP.packageEdit(exitCode: 3), .notNeeded)
        for code: Int32 in [4, 5, 6] {
            XCTAssertThrowsError(try SpatialIOP.packageEdit(exitCode: code)) { error in
                XCTAssertTrue(error.localizedDescription.contains("does not know this SOLIDWORKS installer"))
                XCTAssertTrue(error.localizedDescription.contains("media was not changed"))
            }
        }
        for code: Int32 in [1, 2, 7, 8, 67] {
            XCTAssertThrowsError(try SpatialIOP.packageEdit(exitCode: code)) { error in
                XCTAssertTrue(error.localizedDescription.contains("exit code \(code)"))
            }
        }
    }

    private let listing = """
    Path = code
    Folder = +
    Size = 0
    Packed Size = 0
    Attributes = D drwxrwxrwx
    Method = Store

    Path = code/bin
    Folder = +
    Size = 0
    Attributes = D drwxrwxrwx

    Path = code/bin/7z.dll
    Folder = -
    Size = 1634304
    Packed Size = 799793
    Attributes =  -rw-rw-rw-

    Path = code/bin/SPAXChecker.exe
    Folder = -
    Size = 12
    Attributes =  -rwxrwxrwx

    """

    func testPayloadEntriesComeFromTheListing() throws {
        let entries = try SpatialIOP.payloadEntries(fromListing: listing)
        XCTAssertEqual(entries, [
            SpatialIOP.PayloadEntry(path: "code", size: 0, isFolder: true),
            SpatialIOP.PayloadEntry(path: "code/bin", size: 0, isFolder: true),
            SpatialIOP.PayloadEntry(path: "code/bin/7z.dll", size: 1_634_304, isFolder: false),
            SpatialIOP.PayloadEntry(path: "code/bin/SPAXChecker.exe", size: 12, isFolder: false)
        ])
    }

    func testPayloadListingRefusesMembersOutsideTheDestination() {
        for path in ["../escape.dll", "/abs/file.dll", "code/../../x.dll", #"code\bin\x.dll"#, ""] {
            XCTAssertThrowsError(try SpatialIOP.payloadEntries(fromListing: "Path = \(path)\nFolder = -\nSize = 1\n"), path)
        }
        XCTAssertThrowsError(try SpatialIOP.payloadEntries(fromListing: "Path = code/link\nFolder = -\nSize = 4\nAttributes =  lrwxrwxrwx\n"))
        XCTAssertThrowsError(try SpatialIOP.payloadEntries(fromListing: "Path = code\nFolder = +\nSize = 0\n"))
        XCTAssertThrowsError(try SpatialIOP.payloadEntries(fromListing: ""))
    }

    func testPayloadProblemsCompareAgainstTheListing() throws {
        let entries = try SpatialIOP.payloadEntries(fromListing: listing)
        let destination = directory.appendingPathComponent("spiop/files")
        XCTAssertEqual(SpatialIOP.payloadProblems(entries, destination: destination).count, entries.count)

        try fileManager.createDirectory(at: destination.appendingPathComponent("code/bin"), withIntermediateDirectories: true)
        try Data(count: 1_634_304).write(to: destination.appendingPathComponent("code/bin/7z.dll"))
        try Data(count: 11).write(to: destination.appendingPathComponent("code/bin/SPAXChecker.exe"))
        XCTAssertEqual(SpatialIOP.payloadProblems(entries, destination: destination),
                       ["size 11 instead of 12: code/bin/SPAXChecker.exe"])

        try Data(count: 12).write(to: destination.appendingPathComponent("code/bin/SPAXChecker.exe"))
        XCTAssertEqual(SpatialIOP.payloadProblems(entries, destination: destination), [])

        try fileManager.removeItem(at: destination.appendingPathComponent("code/bin/7z.dll"))
        try fileManager.createDirectory(at: destination.appendingPathComponent("code/bin/7z.dll"), withIntermediateDirectories: true)
        XCTAssertEqual(SpatialIOP.payloadProblems(entries, destination: destination), ["not a file: code/bin/7z.dll"])
    }

    func testInstallDirectoryReadsOnlyTheSetupKeyAndPrefersTheNewest64BitOne() {
        let registry = """
        WINE REGISTRY Version 2

        [Software\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Licenses] 1730000000
        #time=1db26f3a1f2c3d4
        "SolidWorks Folder"="C:\\\\Wrong\\\\Licenses\\\\"
        "Serial Number"="not-a-serial"

        [Software\\\\SolidWorks\\\\SOLIDWORKS 2025\\\\Setup] 1730000000
        "SolidWorks Folder"="C:\\\\Program Files\\\\SOLIDWORKS 2025\\\\"

        [Software\\\\Wow6432Node\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Setup] 1730000000
        "SolidWorks Folder"="C:\\\\Program Files\\\\Wow\\\\"

        [Software\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Setup] 1730000000
        "Other"="x"
        "SolidWorks Folder"="C:\\\\Program Files\\\\SOLIDWORKS Corp\\\\SOLIDWORKS\\\\"

        [Software\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Setup\\\\Sub] 1730000000
        "SolidWorks Folder"="C:\\\\Wrong\\\\Sub\\\\"
        """
        XCTAssertEqual(SpatialIOP.installDirectory(systemRegistry: registry), #"C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\"#)
    }

    func testInstallDirectoryIgnoresEveryKeyButSetup() {
        let registry = """
        [Software\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Licenses] 1730000000
        "SolidWorks Folder"="C:\\\\Wrong\\\\"
        [Software\\\\SolidWorks\\\\SOLIDWORKS 2026] 1730000000
        "SolidWorks Folder"="C:\\\\Wrong\\\\"
        """
        XCTAssertNil(SpatialIOP.installDirectory(systemRegistry: registry))
        XCTAssertEqual(SpatialIOP.installDirectory(systemRegistry: """
        [Software\\\\Wow6432Node\\\\SolidWorks\\\\SOLIDWORKS 2026\\\\Setup] 1730000000
        "SolidWorks Folder"="C:\\\\Program Files\\\\SW\\\\"
        """), #"C:\Program Files\SW\"#)
    }

    func testPayloadDestinationIsSpiopFilesInTheBottle() {
        let prefix = URL(fileURLWithPath: "/tmp/MacSW/bottle")
        XCTAssertEqual(SpatialIOP.payloadDestination(installDirectory: #"C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\"#, prefix: prefix)?.path,
                       "/tmp/MacSW/bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/spiop/files")
        XCTAssertEqual(SpatialIOP.payloadDestination(installDirectory: #"c:\SW"#, prefix: prefix)?.path,
                       "/tmp/MacSW/bottle/drive_c/SW/spiop/files")
        for folder in [#"D:\SOLIDWORKS\"#, #"C:\"#, #"C:\Program Files\..\..\x"#, "SOLIDWORKS", ""] {
            XCTAssertNil(SpatialIOP.payloadDestination(installDirectory: folder, prefix: prefix), folder)
        }
    }

    func testSpatialInteropStepRunsRightAfterTheCoreInstall() {
        XCTAssertEqual(InstallationStep.spatialInterop.rawValue, InstallationStep.installer.rawValue + 1)
        XCTAssertLessThan(InstallationStep.spatialInterop.rawValue, InstallationStep.language.rawValue)
        XCTAssertTrue(InstallationStep.spatialInterop.title.contains("SpatialIOP"))
    }
}

final class CoreInstallRetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bottle"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOnlyAFailedCoreInstallInANeverStartedBottleGetsAFreshBottle() {
        XCTAssertEqual(CoreInstallRetry.decision(bottleExists: true, receiptExists: false, coreInstallIncomplete: true,
                                                 solidWorksNeverStarted: true), .freshBottle)
        for (bottle, receipt, incomplete, neverStarted) in [
            (false, false, true, true),   // nothing to replace
            (true, true, true, true),     // MacSW finished an install with this bottle
            (true, false, false, true),   // the core install succeeded, or never ran
            (true, false, true, false)    // SOLIDWORKS started (or the bottle is older than the rule)
        ] {
            XCTAssertEqual(CoreInstallRetry.decision(bottleExists: bottle, receiptExists: receipt,
                                                     coreInstallIncomplete: incomplete, solidWorksNeverStarted: neverStarted),
                           .keepBottle, "\(bottle) \(receipt) \(incomplete) \(neverStarted)")
        }
    }

    func testMarkersFollowTheInstallAndTheFirstStart() throws {
        let bottle = directory.appendingPathComponent("bottle")
        func decision(receipt: Bool = false) -> CoreInstallRetry.Decision {
            CoreInstallRetry.decision(prefix: bottle, receiptExists: receipt)
        }
        // A bottle from before the rule: a failed core install there keeps the bottle.
        try CoreInstallRetry.markCoreInstallStarted(prefix: bottle)
        XCTAssertEqual(decision(), .keepBottle)
        CoreInstallRetry.markCoreInstallSucceeded(prefix: bottle)

        try CoreInstallRetry.markNewBottle(prefix: bottle)
        XCTAssertEqual(decision(), .keepBottle)
        try CoreInstallRetry.markCoreInstallStarted(prefix: bottle)
        XCTAssertEqual(decision(), .freshBottle)
        XCTAssertEqual(decision(receipt: true), .keepBottle)
        CoreInstallRetry.markCoreInstallSucceeded(prefix: bottle)
        XCTAssertEqual(decision(), .keepBottle)

        try CoreInstallRetry.markCoreInstallStarted(prefix: bottle)
        CoreInstallRetry.noteSolidWorksMayStart(prefix: bottle)
        XCTAssertEqual(decision(), .keepBottle)
        CoreInstallRetry.noteSolidWorksMayStart(prefix: bottle)

        XCTAssertEqual(CoreInstallRetry.decision(prefix: directory.appendingPathComponent("missing"), receiptExists: false), .keepBottle)
    }

    @MainActor
    func testStoreShowsTheRuleOnlyWhenItApplies() throws {
        let paths = AppPaths(appSupportDirectory: directory)
        let store = BootstrapStore(paths: paths)
        XCTAssertFalse(store.replacesFailedBottle)
        try CoreInstallRetry.markNewBottle(prefix: paths.bottle)
        try CoreInstallRetry.markCoreInstallStarted(prefix: paths.bottle)
        XCTAssertTrue(store.replacesFailedBottle)
        store.cleanInstall = true
        XCTAssertFalse(store.replacesFailedBottle)
        store.cleanInstall = false
        try Data("{}".utf8).write(to: directory.appendingPathComponent("installation-complete.json"))
        XCTAssertFalse(store.replacesFailedBottle)
    }
}
