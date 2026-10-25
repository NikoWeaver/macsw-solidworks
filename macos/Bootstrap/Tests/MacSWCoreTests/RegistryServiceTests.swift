import Foundation
import XCTest
@testable import MacSWCore

final class RegistryServiceTests: XCTestCase {
    func testMacShortcutMappingRequiresAllFourValuesAndDeletesOnlyThoseValues() {
        let output = """
        HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver
            LeftCommandIsCtrl    REG_SZ    Y
            RightCommandIsCtrl    REG_SZ    Y
            LeftOptionIsAlt    REG_SZ    Y
            RightOptionIsAlt    REG_SZ    Y
            RetinaMode    REG_SZ    y
        """
        XCTAssertTrue(RegistryService.macShortcutsEnabled(fromQueryStatus: 0, output: output))
        XCTAssertFalse(RegistryService.macShortcutsEnabled(fromQueryStatus: 1, output: output))
        XCTAssertFalse(RegistryService.macShortcutsEnabled(
            fromQueryStatus: 0,
            output: output.replacingOccurrences(of: "RightOptionIsAlt    REG_SZ    Y", with: "RightOptionIsAlt    REG_SZ    N")
        ))
        let deletion = RegistryService.macShortcutDeletionText()
        XCTAssertTrue(deletion.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]"))
        for name in RegistryService.macShortcutValueNames {
            XCTAssertTrue(deletion.contains("\"\(name)\"=-"))
        }
        XCTAssertFalse(deletion.contains("RetinaMode"))
    }

    func testLicenseServerQueryDistinguishesMissingValueFromFailures() throws {
        XCTAssertTrue(try RegistryService.licenseServers(fromQueryStatus: 1, output: "").endpoints.isEmpty)
        XCTAssertThrowsError(try RegistryService.licenseServers(fromQueryStatus: 2, output: "failed"))
        XCTAssertThrowsError(try RegistryService.licenseServers(fromQueryStatus: 0, output: "unexpected"))
        XCTAssertThrowsError(try RegistryService.licenseServers(
            fromQueryStatus: 0,
            output: "SW_D_LICENSE_FILE    REG_SZ    not-a-server"
        ))
        XCTAssertEqual(
            try RegistryService.licenseServers(
                fromQueryStatus: 0,
                output: "SW_D_LICENSE_FILE    REG_SZ    25734@licenses.example.edu"
            ).canonical,
            "25734@licenses.example.edu"
        )
    }

    func testRegistryFileUsesFullHiveAndGroupsValuesUnderOneKey() throws {
        let text = try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: "25734@licenses.example.edu"),
            RegistryAssignment(key: "HKCU\\Software\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: "25734@licenses.example.edu"),
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SOLIDWORKS_LICENSE_FILE", value: "27000@x")
        ])
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "Windows Registry Editor Version 5.00")
        XCTAssertEqual(text.components(separatedBy: "[HKEY_LOCAL_MACHINE").count - 1, 1)
        XCTAssertTrue(text.contains("[HKEY_LOCAL_MACHINE\\SOFTWARE\\FLEXlm License Manager]"))
        XCTAssertTrue(text.contains("[HKEY_CURRENT_USER\\Software\\FLEXlm License Manager]"))
        XCTAssertTrue(text.contains("\"SOLIDWORKS_LICENSE_FILE\"=\"27000@x\""))
        // 同键下的值按名称排序，写入结果可预期
        let lmSection = text.components(separatedBy: "[HKEY_LOCAL_MACHINE\\SOFTWARE\\FLEXlm License Manager]")[1]
        XCTAssertTrue(lmSection.range(of: "SOLIDWORKS_LICENSE_FILE")!.lowerBound
            < lmSection.range(of: "SW_D_LICENSE_FILE")!.lowerBound)
    }

    func testEscapingKeepsBackslashesAndQuotesInsideOneValue() {
        XCTAssertEqual(RegistryService.escape(#"a\b"c"#), #"a\\b\"c"#)
    }

    func testRegistryFileSerializesDWORDAsEightDigitHex() throws {
        let text = try RegistryService.registryFileText([
            RegistryAssignment(
                key: #"HKCU\Control Panel\Desktop"#,
                name: "FontSmoothingType",
                dwordValue: 2
            )
        ])
        XCTAssertTrue(text.contains(#""FontSmoothingType"=dword:00000002"#))
    }

    /// HKCR/HKCU/HKLM 都要展开成 .reg 认识的完整根名，已经是全名的不重复加工。
    func testFullHiveExpandsShortRootsAndLeavesLongOnesAlone() {
        XCTAssertEqual(RegistryService.fullHive(#"HKCU\Software\X"#), #"HKEY_CURRENT_USER\Software\X"#)
        XCTAssertEqual(RegistryService.fullHive(#"HKLM\SOFTWARE"#), #"HKEY_LOCAL_MACHINE\SOFTWARE"#)
        XCTAssertEqual(RegistryService.fullHive(#"HKEY_CLASSES_ROOT\SldWorks.Application"#), #"HKEY_CLASSES_ROOT\SldWorks.Application"#)
        // 没见过的短写保持原样：.reg 会自己报错，比在这里猜一个根更安全。
        XCTAssertEqual(RegistryService.fullHive(#"HKCU\Software\X"#).hasPrefix("HKEY_"), true)
    }

    /// .reg 的行格式装不下含换行的值：必须在生成阶段拒绝，而不是写坏注册表。
    func testValuesWithNewlinesAreRejectedBeforeBeingWritten() {
        let illegal = [RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: "a\nb")]
        XCTAssertThrowsError(try RegistryService.registryFileText(illegal))
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: "a\tb")
        ]))
        XCTAssertNoThrow(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: #"a\b"c"#)
        ]))
    }

    /// The remote SolidNetWork address covers all six client values and nothing else.
    func testLicenseAssignmentsCoverEveryClientValue() {
        let servers = LicenseServerList(endpoints: [LicenseServerEndpoint(port: 27000, host: "license.example")])
        let expected = Set(RegistryService.licenseValueTargets.map { "\($0.key)|\($0.name)" })
        let assignments = RegistryService.licenseAssignments(servers)
        XCTAssertEqual(Set(assignments.map { "\($0.key)|\($0.name)" }), expected)
        XCTAssertTrue(assignments.allSatisfy { $0.value == servers.canonical })
    }

    /// SOLIDWORKS 的输入捕获、窗口截图、MDI 标题按钮外观和字体平滑是同一批安装期兼容设置，
    /// 必须一次写齐；日常启动不再负责补写或迁移。
    func testSolidWorksCompatibilityAssignmentsCoverInputCaptureAndCaptionAppearance() {
        XCTAssertEqual(RegistryService.solidWorksCompatibilityAssignments, [
            RegistryAssignment(
                key: "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
                name: "sldworks.exe",
                value: "WINE_NOCAPTURERESEND WINE_PRINTWINDOW_SURFACE"
            ),
            RegistryAssignment(
                key: "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ThemeManager",
                name: "ThemeActive",
                value: "0"
            ),
            RegistryAssignment(
                key: "HKCU\\Control Panel\\Desktop",
                name: "FontSmoothingType",
                dwordValue: 2
            ),
            RegistryAssignment(
                key: "HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe",
                name: "Version",
                value: "win7"
            )
        ])
    }

    func testWineFontRegistryQueriesAndAppleAssignments() throws {
        let fontOutput = """
        HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts
            苹方-简 常规体 (TrueType)    REG_SZ    Z:\\System\\Library\\AssetsV2\\PingFang.ttc
        """
        let linksOutput = """
        HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink
            Tahoma    REG_MULTI_SZ    tahoma.ttf\\0meiryo.ttc,Meiryo\\0simsun.ttc,SimSun
        """
        XCTAssertTrue(RegistryService.hasRegisteredPingFang(fromQueryStatus: 0, output: fontOutput))
        // Under en_US the family value name is English; detection keys on the file name only.
        let englishFontOutput = fontOutput.replacingOccurrences(of: "苹方-简 常规体", with: "PingFang SC")
        XCTAssertTrue(RegistryService.hasRegisteredPingFang(fromQueryStatus: 0, output: englishFontOutput))
        XCTAssertFalse(RegistryService.hasRegisteredPingFang(fromQueryStatus: 1, output: fontOutput))
        XCTAssertFalse(RegistryService.hasRegisteredPingFang(
            fromQueryStatus: 0,
            output: fontOutput.replacingOccurrences(of: "PingFang.ttc", with: "PingFangUI.bad")
        ))
        XCTAssertTrue(try RegistryService.hasRegisteredPingFangForStartup(fromQueryStatus: 0, output: fontOutput))
        XCTAssertFalse(try RegistryService.hasRegisteredPingFangForStartup(fromQueryStatus: 0, output: ""))
        XCTAssertThrowsError(try RegistryService.hasRegisteredPingFangForStartup(fromQueryStatus: 2, output: ""))
        let links = try XCTUnwrap(RegistryService.tahomaLinks(fromQueryStatus: 0, output: linksOutput))
        XCTAssertEqual(links, ["tahoma.ttf", "meiryo.ttc,Meiryo", "simsun.ttc,SimSun"])
        let assignments = RegistryService.appleFontAssignments(existingTahomaLinks: links)
        XCTAssertEqual(assignments.first(where: { $0.name == "Tahoma" })?.valueKind, .multiString)
        XCTAssertEqual(assignments.first(where: { $0.name == "Tahoma" })?.value.components(separatedBy: "\0"),
                       ["PingFang.ttc,PingFang SC"] + links)
        XCTAssertEqual(assignments.first(where: { $0.name == "SimSun" })?.value, "Tahoma")
        XCTAssertEqual(assignments.first(where: { $0.name == "Microsoft YaHei" })?.value, "Tahoma")
        XCTAssertFalse(assignments.contains(where: { $0.name == "Tahoma" && $0.valueKind == .string }))
    }

    func testStartupRepairAddsOnlyMissingTahomaFontLinkAndPreservesExistingFallbacks() throws {
        let original = ["MSGOTHIC.TTC,MS UI Gothic", "SIMSUN.TTC,SimSun", "SEGUISYM.TTF,Segoe UI Symbol"]
        let assignment = try XCTUnwrap(RegistryService.missingPingFangLinkAssignment(existingTahomaLinks: original))
        XCTAssertEqual(assignment.name, "Tahoma")
        XCTAssertEqual(assignment.valueKind, .multiString)
        XCTAssertEqual(assignment.value.components(separatedBy: "\0"), ["PingFang.ttc,PingFang SC"] + original)
        XCTAssertEqual(assignment.key, #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#)
        XCTAssertNil(RegistryService.missingPingFangLinkAssignment(
            existingTahomaLinks: ["PingFang.ttc,PingFang SC"] + original
        ))
    }

    func testTahomaLinksRejectIncompleteOrLossyQueries() {
        let header = #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#
        let complete = "\(header)\n    Tahoma    REG_MULTI_SZ    tahoma.ttf\\0meiryo.ttc,Meiryo\\0simsun.ttc,SimSun"
        XCTAssertEqual(RegistryService.tahomaLinks(fromQueryStatus: 0, output: complete)?.count, 3)
        XCTAssertEqual(RegistryService.tahomaLinks(fromQueryStatus: 0, output: complete + "\nQuery complete")?.count, 3)
        XCTAssertNil(RegistryService.tahomaLinks(
            fromQueryStatus: 0,
            output: "\(header)\n    Tahoma Bold    REG_MULTI_SZ    bold.ttf,Example"
        ))
        let wineDefaults = [
            "MSGOTHIC.TTC,MS UI Gothic", "MINGLIU.TTC,PMingLiU", "SIMSUN.TTC,SimSun",
            "GULIM.TTC,Gulim", "YUGOTHM.TTC,Yu Gothic UI", "MSJH.TTC,Microsoft JhengHei UI",
            "MSYH.TTC,Microsoft YaHei UI", "MALGUN.TTF,Malgun Gothic", "SEGUISYM.TTF,Segoe UI Symbol"
        ]
        let realFormat = "\(header)\n    Tahoma    REG_MULTI_SZ    \(wineDefaults.joined(separator: "\\0"))"
        XCTAssertEqual(RegistryService.tahomaLinks(fromQueryStatus: 0, output: realFormat), wineDefaults)
        XCTAssertNil(RegistryService.tahomaLinks(fromQueryStatus: 1, output: complete))
        XCTAssertNil(RegistryService.tahomaLinks(
            fromQueryStatus: 0,
            output: "\(header)\n    Tahoma    REG_MULTI_SZ    tahoma.ttf\\0meiryo.ttc,Meiryo\n        simsun.ttc,SimSun"
        ))
        XCTAssertNil(RegistryService.tahomaLinks(
            fromQueryStatus: 0,
            output: "\(header)\n    Tahoma    REG_MULTI_SZ    tahoma.ttf\\0字体�.ttc,示例"
        ))
        XCTAssertNil(RegistryService.tahomaLinks(
            fromQueryStatus: 0,
            output: "\(header)\n    Tahoma    REG_MULTI_SZ    tahoma.ttf\\0字体.ttc,示例"
        ))
        XCTAssertNil(RegistryService.tahomaLinks(
            fromQueryStatus: 0,
            output: "\(header)\n    Tahoma    REG_MULTI_SZ    tahoma.ttf\\0\\0simsun.ttc,SimSun"
        ))
    }

    func testRegistryFileUsesUTF16LEForChineseNamesAndMultiStringValues() throws {
        let text = try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma",
                               multiStringValues: ["PingFang.ttc,PingFang SC", "tahoma.ttf"])
        ])
        XCTAssertTrue(text.contains(#""Tahoma"=hex(7):50,00,69,00,6e,00,67,00"#))
        XCTAssertTrue(text.contains("74,00,61,00,68,00,6f,00,6d,00,61,00,2e,00,74,00,74,00,66,00,00,00,00,00"))
        let data = try RegistryService.registryFileData([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "宋体", value: "Tahoma")
        ])
        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xfe])
        XCTAssertTrue(String(data: data.dropFirst(2), encoding: .utf16LittleEndian)?
            .contains(#""宋体"="Tahoma""#) == true)
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma", multiStringValues: [""])
        ]))
        XCTAssertNoThrow(try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma", multiStringValues: ["苹方-简"])
        ]))
    }
}
