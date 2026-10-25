import Foundation
import XCTest
@testable import MacSWCore

final class PlainTextDecoderTests: XCTestCase {
    func testDecodesByteOrderMarksAndFallsBackToLegacyCodePage() {
        XCTAssertEqual(PlainTextDecoder.decode(Data([0xFF, 0xFE, 0x41, 0x00])), "A")
        XCTAssertEqual(PlainTextDecoder.decode(Data([0xFE, 0xFF, 0x00, 0x41])), "A")
        XCTAssertEqual(PlainTextDecoder.decode(Data("注册表".utf8)), "注册表")
        // windowsCP1252 里 0x81/0xFE 是无定义字节，整段就不是有效文本。
        XCTAssertNil(PlainTextDecoder.decode(Data([0x81, 0xFE])))
        XCTAssertEqual(PlainTextDecoder.decode(Data([0x41, 0xE9, 0x0A])), "Aé\n")
        XCTAssertNil(PlainTextDecoder.decode(Data()))
    }

    /// MSI 日志在中文系统上是 GBK：解码器给出的是"能读下去"而不是"字字正确"，
    /// 但关键字与 ASCII 内容必须保住，否则诊断会整段丢掉。
    func testMSIStyleLogKeepsItsASCIIContent() {
        var bytes = [UInt8]("Action ended 22:20:18: InstallFinalPackage. Return value 3.\n".utf8)
        bytes.append(contentsOf: [0xCE, 0xAA, 0xB4, 0xED])   // GBK "错误"
        bytes.append(contentsOf: "\nError 1603. Configuration failure\n".utf8)
        let text = try? XCTUnwrap(PlainTextDecoder.decode(Data(bytes)))
        XCTAssertTrue(text?.contains("InstallFinalPackage") == true)
        XCTAssertTrue(text?.contains("Error 1603") == true)
    }
}
