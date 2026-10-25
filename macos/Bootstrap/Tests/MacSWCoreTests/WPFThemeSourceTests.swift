import Foundation
import XCTest
@testable import MacSWCore

/// Layout detection and member mapping for the WPF theme libraries inside the Microsoft .NET installer
/// (4.8: netfx_Full.mzz; 4.8.1: an x64 KB cab). These are pure functions; no installer is needed.
final class WPFThemeSourceTests: XCTestCase {
    private let kb481Installer = [
        "Windows10.0-KB5011048-x86.cab",
        "x64-Windows10.0-KB5011048-x64.cab",
        "xarm64-Windows10.0-KB5011048-arm64.cab",
        "header.bmp",
        "Graphics/Print.ico",
        "1025/LocalizedData.xml"
    ]

    private let kb481Cab = [
        "amd64_presentationframework.aero2_31bf3856ad364e35_4.0.15840.3_none_864b5cd8618c176c.manifest",
        "amd64_presentationframework.aero2_31bf3856ad364e35_4.0.15840.3_none_864b5cd8618c176c/presentationframework.aero2.dll",
        "amd64_presentationframework.aerolite_31bf3856ad364e35_4.0.15840.3_none_c25ae11b0e327218/presentationframework.aerolite.dll",
        "amd64_presentationframework.aero_31bf3856ad364e35_4.0.15840.3_none_35c8eb7b9c1ed860/presentationframework.aero.dll",
        "amd64_presentationframework.classic_31bf3856ad364e35_4.0.15840.3_none_711fb18c72adf51f/presentationframework.classic.dll",
        "amd64_presentationframework.luna_31bf3856ad364e35_4.0.15840.3_none_35e54ae79c0bf235/presentationframework.luna.dll",
        "amd64_presentationframework.royale_31bf3856ad364e35_4.0.15840.3_none_1d187fc9edb689e7/presentationframework.royale.dll",
        "amd64_presentationframework_31bf3856ad364e35_4.0.15840.3_none_aaaa/presentationframework.dll"
    ]

    private let expectedMembers = [
        ("Luna", "amd64_presentationframework.luna_31bf3856ad364e35_4.0.15840.3_none_35e54ae79c0bf235/presentationframework.luna.dll"),
        ("Aero", "amd64_presentationframework.aero_31bf3856ad364e35_4.0.15840.3_none_35c8eb7b9c1ed860/presentationframework.aero.dll"),
        ("Classic", "amd64_presentationframework.classic_31bf3856ad364e35_4.0.15840.3_none_711fb18c72adf51f/presentationframework.classic.dll"),
        ("Royale", "amd64_presentationframework.royale_31bf3856ad364e35_4.0.15840.3_none_1d187fc9edb689e7/presentationframework.royale.dll"),
        ("AeroLite", "amd64_presentationframework.aerolite_31bf3856ad364e35_4.0.15840.3_none_c25ae11b0e327218/presentationframework.aerolite.dll")
    ]

    func testListingParserKeepsOnlyMemberPaths() {
        let listing = """
        Path = Windows10.0-KB5011048-x86.cab
        Size = 179406268
        Method = BCJ2 LZMA:29:lc8:pb1 LZMA:24 LZMA:24

        Path = Graphics/Print.ico
        Size = 126132
        Attributes = N

        Path = name with spaces.bmp
        """
        XCTAssertEqual(
            PrerequisiteService.memberPaths(fromListing: listing),
            ["Windows10.0-KB5011048-x86.cab", "Graphics/Print.ico", "name with spaces.bmp"]
        )
        XCTAssertEqual(PrerequisiteService.memberPaths(fromListing: ""), [])
        XCTAssertEqual(PrerequisiteService.memberPaths(fromListing: "Path = a.dll\r\nSize = 1\r\nPath = b.dll\r\n"), ["a.dll", "b.dll"])
    }

    func testNetFx48LayoutUsesNetfxFullMzz() {
        let members = ["netfx_Full.mzz", "netfx_Full_x64.msi", "header.bmp"]
        XCTAssertEqual(
            PrerequisiteService.themeArchive(inInstallerMembers: members),
            .netfxFull(member: "netfx_Full.mzz")
        )
        XCTAssertEqual(
            PrerequisiteService.themeArchive(inInstallerMembers: ["NETFX_FULL.MZZ"]),
            .netfxFull(member: "NETFX_FULL.MZZ")
        )
    }

    func testNetfxFullMzzWinsWhenKBCabIsAlsoPresent() {
        XCTAssertEqual(
            PrerequisiteService.themeArchive(inInstallerMembers: kb481Installer + ["netfx_Full.mzz"]),
            .netfxFull(member: "netfx_Full.mzz")
        )
    }

    func testNetFx481LayoutPicksTheX64KBCab() {
        XCTAssertEqual(
            PrerequisiteService.themeArchive(inInstallerMembers: kb481Installer),
            .updateCab(member: "x64-Windows10.0-KB5011048-x64.cab")
        )
    }

    func testKBNumberAndCaseAreNotHardCoded() {
        let members = ["Windows10.0-KB9999999-x86.cab", "X64-Windows10.0-kb9999999-X64.CAB", "xarm64-Windows10.0-KB9999999-arm64.cab"]
        XCTAssertEqual(
            PrerequisiteService.themeArchive(inInstallerMembers: members),
            .updateCab(member: "X64-Windows10.0-kb9999999-X64.CAB")
        )
    }

    func testOnlyAnUpdateCabForAnotherArchitectureIsNotAThemeSource() {
        XCTAssertNil(PrerequisiteService.themeArchive(inInstallerMembers: [
            "Windows10.0-KB5011048-x86.cab",
            "xarm64-Windows10.0-KB5011048-arm64.cab",
            "header.bmp"
        ]))
    }

    func testUnrelatedOrNestedMembersAreIgnored() {
        XCTAssertNil(PrerequisiteService.themeArchive(inInstallerMembers: []))
        XCTAssertNil(PrerequisiteService.themeArchive(inInstallerMembers: [
            "x64-Redist.cab",
            "sub/netfx_Full.mzz",
            "sub/x64-Windows10.0-KB5011048-x64.cab",
            "x64-Windows10.0-KB5011048-x64.cab.txt"
        ]))
    }

    func testThemeMembersMapAllFiveAmd64LibrariesInThemeOrder() throws {
        let mapped = try PrerequisiteService.themeMembers(inCabMembers: kb481Cab)
        XCTAssertEqual(mapped.map(\.theme), PrerequisiteService.themes)
        XCTAssertEqual(mapped.map(\.theme), ["Luna", "Aero", "Classic", "Royale", "AeroLite"])
        for (index, expected) in expectedMembers.enumerated() {
            XCTAssertEqual(mapped[index].theme, expected.0)
            XCTAssertEqual(mapped[index].member, expected.1)
        }
    }

    func testThemeMembersMatchCaseInsensitively() throws {
        let shouting = kb481Cab.map { $0.uppercased() }
        let mapped = try PrerequisiteService.themeMembers(inCabMembers: shouting)
        XCTAssertEqual(mapped.map(\.member), expectedMembers.map { $0.1.uppercased() })
    }

    func testThemeMembersIgnoreOtherArchitecturesDeltasAndManifests() throws {
        let decoys = [
            "wow64_presentationframework.aero_31bf3856ad364e35_4.0.15840.3_none_1/presentationframework.aero.dll",
            "msil_presentationframework.luna_31bf3856ad364e35_4.0.15840.3_none_2/presentationframework.luna.dll",
            "f/amd64_presentationframework.classic_31bf3856ad364e35_4.0.15840.3_none_3/presentationframework.classic.dll",
            "r/amd64_presentationframework.royale_31bf3856ad364e35_4.0.15840.3_none_4/presentationframework.royale.dll",
            "amd64_presentationframework.aerolite_31bf3856ad364e35_4.0.15840.3_none_5.manifest"
        ]
        let mapped = try PrerequisiteService.themeMembers(inCabMembers: decoys + kb481Cab)
        XCTAssertEqual(mapped.map(\.member), expectedMembers.map { $0.1 })
    }

    func testAero2DoesNotStandInForAero() {
        let members = kb481Cab.filter { !$0.contains("presentationframework.aero_") }
        XCTAssertThrowsError(try PrerequisiteService.themeMembers(inCabMembers: members)) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("PresentationFramework.Aero.dll"), message)
            XCTAssertFalse(message.contains("PresentationFramework.AeroLite.dll"), message)
            XCTAssertFalse(message.contains("Luna"), message)
        }
    }

    func testMissingLibrariesAreAllNamedInOneEnglishError() {
        let members = kb481Cab.filter {
            !$0.contains("presentationframework.luna_") && !$0.contains("presentationframework.aerolite_")
        }
        XCTAssertThrowsError(try PrerequisiteService.themeMembers(inCabMembers: members)) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("PresentationFramework.Luna.dll"), message)
            XCTAssertTrue(message.contains("PresentationFramework.AeroLite.dll"), message)
            XCTAssertTrue(message.contains(".NET 4.8.1"), message)
        }
        XCTAssertThrowsError(try PrerequisiteService.themeMembers(inCabMembers: []))
    }
}
