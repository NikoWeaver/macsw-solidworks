import Foundation
import XCTest
@testable import MacSWCore

final class InstallationMediaDiscoveryTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-MediaDiscovery-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, bytes: Int = 4) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x4d, count: bytes).write(to: url)
        return url
    }

    /// setup.exe with the core MSI: what real SOLIDWORKS media has.
    @discardableResult
    private func media(_ folder: String) throws -> URL {
        try write("\(folder)/setup.exe", bytes: 100)
        try write("\(folder)/\(SilentInstallerPlan.coreMSIRelativePath)", bytes: 900)
        return root.appendingPathComponent(folder)
    }

    func testTeamFolderComesFirstThenDownloadsThenVolumes() throws {
        let team = try media("team/SW2026")
        let downloads = root.appendingPathComponent("Downloads")
        try media("Downloads/SOLIDWORKS 2026 SP04.1")
        let volume = try media("Volumes/SW2026")

        let fromTeam = try XCTUnwrap(InstallationMediaResolver.discover(teamMedia: team, downloads: downloads, volumes: [volume]))
        XCTAssertEqual(fromTeam.source, .teamFolder)
        XCTAssertEqual(fromTeam.media.mediaDirectory.resolvingSymlinksInPath(), team.resolvingSymlinksInPath())
        XCTAssertFalse(fromTeam.media.isIso)
        XCTAssertEqual(fromTeam.sizeBytes, 1000)

        let fromDownloads = InstallationMediaResolver.discover(teamMedia: nil, downloads: downloads, volumes: [volume])
        XCTAssertEqual(fromDownloads?.source, .downloads)
        XCTAssertEqual(fromDownloads?.media.mediaDirectory.lastPathComponent, "SOLIDWORKS 2026 SP04.1")

        XCTAssertEqual(InstallationMediaResolver.discover(teamMedia: nil, downloads: nil, volumes: [volume])?.source, .volume)
        XCTAssertNil(InstallationMediaResolver.discover(teamMedia: nil, downloads: nil, volumes: []))
    }

    /// A finished local copy comes before the team folder, which may be offline.
    func testFinishedLocalCopyComesFirst() throws {
        let copy = try media("support/media/2026 SP4.1")
        let team = try media("team/SW2026")
        let found = InstallationMediaResolver.discover(localCopy: copy, teamMedia: team, downloads: nil, volumes: [])
        XCTAssertEqual(found?.source, .localCopy)
        XCTAssertEqual(found?.root, copy.standardizedFileURL)
    }

    /// Downloads holds other programs' installers and disk images: only SOLIDWORKS media counts.
    func testOutsideTheTeamFolderOnlySolidWorksMediaCounts() throws {
        let downloads = root.appendingPathComponent("Downloads")
        try write("Downloads/OtherApp/setup.exe")
        try write("Downloads/Windows11.iso")
        XCTAssertNil(InstallationMediaResolver.discover(teamMedia: nil, downloads: downloads, volumes: []))

        try write("Downloads/SW2026-SP04.1.iso", bytes: 50)
        let iso = InstallationMediaResolver.discover(teamMedia: nil, downloads: downloads, volumes: [])
        XCTAssertEqual(iso?.media.displayURL.lastPathComponent, "SW2026-SP04.1.iso")
        XCTAssertEqual(iso?.sizeBytes, 50)
        XCTAssertEqual(iso?.root, downloads.standardizedFileURL)

        // A media folder wins over an ISO.
        try media("Downloads/Media")
        XCTAssertEqual(InstallationMediaResolver.discover(teamMedia: nil, downloads: downloads, volumes: [])?.media.isIso, false)

        XCTAssertTrue(InstallationMediaResolver.isSolidWorksImageName("SOLIDWORKS 2026 SP04.1.ISO"))
        XCTAssertTrue(InstallationMediaResolver.isSolidWorksImageName("sw2026_sp4.iso"))
        XCTAssertFalse(InstallationMediaResolver.isSolidWorksImageName("swift-6.iso"))
    }

    /// One level below Downloads, as `resolve` does for a dropped folder.
    func testDownloadsIsSearchedOneLevelDeep() throws {
        let downloads = root.appendingPathComponent("Downloads")
        try media("Downloads/unzipped/SW2026")
        XCTAssertNil(InstallationMediaResolver.discover(teamMedia: nil, downloads: downloads, volumes: []))
    }

    func testSizeCountsVisibleRegularFilesAndManifestIsNoticed() throws {
        let folder = try media("team/SW2026")
        try write("team/SW2026/.DS_Store", bytes: 1000)
        let without = try XCTUnwrap(InstallationMediaResolver.discover(teamMedia: folder, downloads: nil, volumes: []))
        XCTAssertEqual(without.sizeBytes, 1000)
        XCTAssertFalse(without.hasManifest)
        try write("team/SW2026/\(MediaManifest.fileName)", bytes: 24)
        let with = try XCTUnwrap(InstallationMediaResolver.discover(teamMedia: folder, downloads: nil, volumes: []))
        XCTAssertTrue(with.hasManifest)
        XCTAssertEqual(with.sizeBytes, 1024)
        XCTAssertTrue(with.sizeText.contains("KB"), with.sizeText)
    }

    func testDroppedMediaKeepsTheOldRules() throws {
        let iso = try write("anything.iso", bytes: 10)
        XCTAssertEqual(InstallationMediaResolver.dropped(iso)?.source, .dropped)
        XCTAssertEqual(InstallationMediaResolver.dropped(iso)?.media, .iso(iso.standardizedFileURL))
        XCTAssertNil(InstallationMediaResolver.dropped(root.appendingPathComponent("missing")))
    }

    func testMountedVolumesLeaveOutTheStartupDisk() {
        XCTAssertFalse(InstallationMediaResolver.mountedVolumes().contains { $0.path == "/" })
    }
}
