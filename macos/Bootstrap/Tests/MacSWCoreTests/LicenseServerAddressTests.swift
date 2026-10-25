import XCTest
@testable import MacSWCore

final class LicenseServerAddressTests: XCTestCase {
    func testOfficialAndConvenienceFormatsNormalizeToOfficialForm() throws {
        XCTAssertEqual(try LicenseServerAddressService.parse("25734@server").canonical, "25734@server")
        XCTAssertEqual(try LicenseServerAddressService.parse("server:25734").canonical, "25734@server")
        XCTAssertEqual(try LicenseServerAddressService.parse("[2001:db8::1]:25734").canonical, "25734@[2001:db8::1]")
        XCTAssertThrowsError(try LicenseServerAddressService.parse("2001:db8::1:25734")) { error in
            guard case .ambiguousIPv6 = error as? LicenseServerAddressError else {
                return XCTFail("Expected ambiguous IPv6 error, got \(error)")
            }
        }
    }

    func testMultipleServersAreDeduplicatedAndOrderIsPreserved() throws {
        let list = try LicenseServerAddressService.parse("27000@backup;server:25734;27000@BACKUP")
        XCTAssertEqual(list.canonical, "27000@backup;25734@server")
    }

    /// 主机名不带空白与控制字符：它会直接进注册表值和命令行。
    func testEmptyHostsPortsAndWhitespaceAreRejected() {
        XCTAssertThrowsError(try LicenseServerAddressService.parse(""))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("   "))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("0@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("99999@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@bad host"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@a\nb"))
        XCTAssertEqual(try LicenseServerAddressService.parse(" 25734@server ; 27000@backup ").canonical, "25734@server;27000@backup")
        // parseEntry 是列表拆分之内的单条判定，空串同样不能通过。
        XCTAssertThrowsError(try LicenseServerAddressService.parseEntry(""))
        XCTAssertThrowsError(try LicenseServerAddressService.parseEntry("25734@[::"))
    }

    func testLoopbackHostsAreRejected() {
        for text in ["25734@localhost", "25734@LOCALHOST", "25734@localhost.", "localhost:25734",
                     "25734@127.0.0.1", "27000@127.1.2.3", "25734@[::1]", "[::1]:25734",
                     "25734@[0:0:0:0:0:0:0:1]", "25734@[::ffff:127.0.0.1]", "25734@a.localhost",
                     "25734@server;25734@127.0.0.1"] {
            XCTAssertThrowsError(try LicenseServerAddressService.parse(text), text) { error in
                XCTAssertTrue(error is LicenseServerAddressError, text)
                if case .loopbackNotAllowed = error as? LicenseServerAddressError {} else {
                    XCTFail("expected loopbackNotAllowed for \(text), got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try LicenseServerAddressService.parse("25734@128.0.0.1"))
        XCTAssertNoThrow(try LicenseServerAddressService.parse("25734@localhost.example.edu"))
        XCTAssertNoThrow(try LicenseServerAddressService.parse("25734@[2001:db8::1]"))
    }

    func testEndpointsCompareCaseInsensitivelyAndConsistentlyWithHashing() {
        let upper = LicenseServerEndpoint(port: 27000, host: "BACKUP")
        let lower = LicenseServerEndpoint(port: 27000, host: "backup")
        XCTAssertEqual(upper, lower)
        XCTAssertEqual(Set([upper, lower]).count, 1)
        XCTAssertNotEqual(upper, LicenseServerEndpoint(port: 27001, host: "backup"))
    }
}
