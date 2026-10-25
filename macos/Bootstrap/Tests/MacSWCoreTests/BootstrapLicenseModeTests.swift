import XCTest
@testable import MacSWCore

final class BootstrapLicenseModeTests: XCTestCase {
    func testUnconfiguredNeedsNoInput() {
        XCTAssertNil(BootstrapLicenseMode.unconfigured.missingInputMessage(address: " "))
    }

    func testRemoteServerRequiresParsableAddress() {
        let mode = BootstrapLicenseMode.remoteServer
        XCTAssertNotNil(mode.missingInputMessage(address: "  "))
        XCTAssertNotNil(mode.missingInputMessage(address: "not-an-address"))
        XCTAssertNil(mode.missingInputMessage(address: " 25734@192.168.1.20 "))
    }

    /// Only Dassault's own activation or a real SolidNetWork server are offered.
    func testOnlyLegitimateLicenseSourcesExist() {
        XCTAssertEqual(BootstrapLicenseMode.allCases, [.unconfigured, .remoteServer])
    }
}
