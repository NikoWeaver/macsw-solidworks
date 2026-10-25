import Foundation
import XCTest
@testable import MacSWCore

final class InstallSerialsTests: XCTestCase {
    func testNormalizationStripsSeparatorsAndUppercases() {
        XCTAssertEqual(
            InstallSerials.normalized("abcd-efgh 1234 ijkl mnop qrst"),
            "ABCDEFGH1234IJKLMNOPQRST"
        )
    }

    /// 全角、西里尔、重音字符在 Unicode 里都算"字母数字"，绝不能被当成 24 位留下来。
    func testNormalizationDropsEverythingOutsideASCIIAlphanumeric() {
        XCTAssertEqual(InstallSerials.normalized("　-／"), "")
        XCTAssertEqual(InstallSerials.normalized("\u{00E9}"), "")      // 预组合 é：单个非 ASCII 标量
        XCTAssertEqual(InstallSerials.normalized("e\u{0301}"), "E")    // 分解形式：组合记号被丢，ASCII 字母留下
        XCTAssertEqual(InstallSerials.normalized("ß"), "")
        XCTAssertEqual(InstallSerials.normalized("ＡＢＣＤ"), "")
        XCTAssertEqual(InstallSerials.normalized("ВВВВ"), "")
        XCTAssertEqual(InstallSerials.normalized("В1"), "1")
        XCTAssertEqual(InstallSerials.normalized("１２３４"), "")
        XCTAssertEqual(InstallSerials.normalized("١٢٣٤"), "")
    }

    func testNonASCIISerialIsRejectedAsMalformed() {
        var serials = InstallSerials()
        // 24 个全角数字：字形簇刚好 24，但一个 ASCII 字符都不是。
        serials[.solidWorks] = "１２３４１２３４１２３４１２３４１２３４１２３４"
        XCTAssertEqual(serials.invalidFields(), [.solidWorks])
        XCTAssertFalse(serials.isComplete)
        XCTAssertTrue(serials.msiProperties.isEmpty)
    }

    func testMSIPropertiesAreDeterministicAndSkipEmptyFields() {
        var serials = InstallSerials()
        serials[.mbd] = "AAAA BBBB CCCC DDDD EEEE FFFF"
        serials[.solidWorks] = "0000-2222-3333-4444-5555-6666"
        serials[.motion] = "   "
        XCTAssertEqual(serials.msiProperties, [
            "MBDSERIALNUMBER=AAAABBBBCCCCDDDDEEEEFFFF",
            "SOLIDWORKSSERIALNUMBER=000022223333444455556666"
        ])
        XCTAssertFalse(serials.isEmpty)
        XCTAssertTrue(serials.isComplete)
    }

    func testInvalidFieldsOnlyReportFilledMalformedValues() {
        var serials = InstallSerials()
        serials[.simulation] = "12345"
        XCTAssertEqual(serials.invalidFields(), [.simulation])
        serials[.simulation] = ""
        XCTAssertTrue(serials.invalidFields().isEmpty)
    }
}

final class LanguageCatalogTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Languages-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func makeLanguageDirectory(_ name: String, msiName: String? = nil) throws {
        let directory = root.appendingPathComponent(LanguageCatalog.relativeDirectory).appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("msi".utf8).write(to: directory.appendingPathComponent(msiName ?? "\(name).msi"))
        try Data("cab".utf8).write(to: directory.appendingPathComponent("payload.cab"))
    }

    func testDiscoveryOnlyKeepsDirectoriesWithAnMSI() throws {
        try makeLanguageDirectory("chinese-simplified")
        try makeLanguageDirectory("german", msiName: "german.msi")
        let empty = root.appendingPathComponent(LanguageCatalog.relativeDirectory).appendingPathComponent("korean")
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)

        let languages = LanguageCatalog.discover(in: root, fileManager: fileManager)
        XCTAssertEqual(languages.count, 2)
        XCTAssertEqual(
            Set(languages),
            Set([
                SolidWorksLanguage(
                    directoryName: "chinese-simplified",
                    msiFileName: "chinese-simplified.msi",
                    displayName: "简体中文"
                ),
                SolidWorksLanguage(directoryName: "german", msiFileName: "german.msi", displayName: "Deutsch")
            ])
        )
    }

    func testDiscoveryAcceptsMismatchedMSIBasename() throws {
        try makeLanguageDirectory("turkish", msiName: "Turkish.msi")
        let languages = LanguageCatalog.discover(in: root, fileManager: fileManager)
        XCTAssertEqual(languages.first?.msiFileName, "Turkish.msi")
        XCTAssertEqual(
            LanguageCatalog.relativeMSIPath(languages[0]),
            "swwi/lang/turkish/Turkish.msi"
        )
    }

    func testDiscoveryReturnsEmptyWithoutMedia() {
        XCTAssertTrue(LanguageCatalog.discover(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testSystemLanguageIdentifiersMapToMediaDirectories() {
        XCTAssertEqual(LanguageCatalog.match(for: "en-US"), .baseLanguage)
        XCTAssertEqual(LanguageCatalog.match(for: "zh-Hans-CN"), .directory("chinese-simplified"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-CN"), .directory("chinese-simplified"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-Hant"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-TW"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-HK"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "de-DE"), .directory("german"))
        XCTAssertEqual(LanguageCatalog.match(for: "pt"), .directory("portuguese-brazilian"))
        XCTAssertEqual(LanguageCatalog.match(for: "nl-NL"), .unknown)
        XCTAssertEqual(LanguageCatalog.match(for: ""), .unknown)
    }

    func testAutoSelectionFollowsSystemPreferenceOrder() {
        let media = ["chinese-simplified", "japanese", "korean"].map {
            SolidWorksLanguage(directoryName: $0, msiFileName: "\($0).msi", displayName: $0)
        }
        XCTAssertEqual(
            LanguageCatalog.autoSelection(from: media, preferredLanguages: ["zh-Hans-CN", "en-US"])?.directoryName,
            "chinese-simplified"
        )
        // 无法识别的首选语言继续向后查找。
        XCTAssertEqual(
            LanguageCatalog.autoSelection(from: media, preferredLanguages: ["nl-NL", "ja"])?.directoryName,
            "japanese"
        )
        // 介质没有对应语言资源时不猜，保持介质默认。
        XCTAssertNil(LanguageCatalog.autoSelection(from: media, preferredLanguages: ["de-DE", "fr"]))
        XCTAssertNil(LanguageCatalog.autoSelection(from: media, preferredLanguages: ["en-GB"]))
        XCTAssertNil(LanguageCatalog.autoSelection(from: [], preferredLanguages: ["zh-Hans-CN"]))
    }
}

/// The one-field access key of the team wizard. Every key here is an obvious fake.
final class AccessKeyTests: XCTestCase {
    func testSixGroupsOfFourWithOrWithoutSeparators() {
        for key in ["0000 1111 2222 3333 4444 5555", "0000-1111-2222-3333-4444-5555", "000011112222333344445555",
                    "abcd efgh ijkl mnop qrst uvwx", "  0000 1111 2222 3333 4444 5555\n", "0000 1111\t2222 3333 4444 5555"] {
            XCTAssertEqual(AccessKey.check(key), .valid, key)
        }
    }

    func testEmptyAndWrongLengthKeys() {
        XCTAssertEqual(AccessKey.check(""), .empty)
        XCTAssertEqual(AccessKey.check(" -\n"), .empty)
        XCTAssertEqual(AccessKey.check("0000 1111 2222 3333 4444"), .wrongLength(20))
        XCTAssertEqual(AccessKey.check("0000 1111 2222 3333 4444 5555 6"), .wrongLength(25))
    }

    /// `InstallSerials.normalized` drops these characters; the key check refuses them, so a
    /// pasted sentence or full-width digits do not become a key.
    func testOtherCharactersAreRefusedNotDropped() {
        for key in ["００００ １１１１ ２２２２ ３３３３ ４４４４ ５５５５", "0000/1111/2222/3333/4444/5555",
                    "Key: 0000 1111 2222 3333 4444 5555", "0000 1111 2222 3333 4444 555\u{00E9}"] {
            XCTAssertEqual(AccessKey.check(key), .invalidCharacters, key)
        }
    }

    func testGroupedAndMessagesNeverRepeatTheKey() {
        XCTAssertEqual(AccessKey.grouped("abcd-efgh-ijkl-mnop-qrst-uvwx"), "ABCD EFGH IJKL MNOP QRST UVWX")
        XCTAssertEqual(AccessKey.grouped("abcdef"), "ABCD EF")
        XCTAssertEqual(AccessKey.grouped(""), "")
        XCTAssertNil(AccessKey.message(for: .valid))
        XCTAssertNil(AccessKey.message(for: .empty))
        let message = AccessKey.message(for: AccessKey.check("0000 1111 2222 3333 4444")) ?? ""
        XCTAssertTrue(message.contains("This one has 20"), message)
        XCTAssertFalse(message.contains("1111"))
        XCTAssertNotNil(AccessKey.message(for: .invalidCharacters))
    }

    /// A valid key is a complete, valid SOLIDWORKS serial for the install.
    func testValidKeyIsAValidInstallSerial() {
        var serials = InstallSerials()
        serials[.solidWorks] = "0000-1111-2222-3333-4444-5555"
        XCTAssertEqual(AccessKey.check(serials[.solidWorks]), .valid)
        XCTAssertTrue(serials.isComplete)
        XCTAssertEqual(serials.invalidFields(), [])
    }
}
