import Foundation
import XCTest
@testable import MacSWCore

final class PreflightServiceTests: XCTestCase {
    private func facts(
        macOS major: Int = 27,
        appleSilicon: Bool = true,
        rosetta: Bool = true,
        free: Int64? = 100_000_000_000,
        memory: UInt64 = 16 << 30
    ) -> PreflightService.Facts {
        PreflightService.Facts(
            isAppleSilicon: appleSilicon,
            macOSVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0),
            rosettaInstalled: rosetta,
            freeBytes: free,
            physicalMemory: memory
        )
    }

    private func verdict(_ item: PreflightService.Item, _ checks: [PreflightService.Check]) -> PreflightService.Verdict? {
        checks.first { $0.item == item }?.verdict
    }

    func testSupportedMacPassesEveryCheckInOrder() {
        let checks = PreflightService.evaluate(facts())
        XCTAssertEqual(checks.map(\.item), PreflightService.Item.allCases)
        XCTAssertTrue(checks.allSatisfy { $0.verdict == .passed })
        XCTAssertFalse(PreflightService.isBlocked(checks))
    }

    /// Full Rosetta ends with macOS 27; macOS 13 is the deployment target.
    func testOnlyMacOS13To27Pass() {
        for major in [13, 14, 15, 26, 27] {
            XCTAssertEqual(verdict(.macOSVersion, PreflightService.evaluate(facts(macOS: major))), .passed, "macOS \(major)")
        }
        for major in [12, 28, 29] {
            let checks = PreflightService.evaluate(facts(macOS: major))
            XCTAssertEqual(verdict(.macOSVersion, checks), .blocked, "macOS \(major)")
            XCTAssertTrue(PreflightService.isBlocked(checks))
        }
        let message = PreflightService.evaluate(facts(macOS: 28)).first { $0.item == .macOSVersion }?.message ?? ""
        XCTAssertTrue(message.contains("Rosetta"), message)
    }

    func testIntelMacAndMissingRosettaBlock() {
        XCTAssertEqual(verdict(.appleSilicon, PreflightService.evaluate(facts(appleSilicon: false))), .blocked)
        let checks = PreflightService.evaluate(facts(rosetta: false))
        XCTAssertEqual(verdict(.rosetta, checks), .blocked)
        let message = checks.first { $0.item == .rosetta }?.message ?? ""
        XCTAssertTrue(message.contains(PreflightService.rosettaInstallCommand), message)
        // The member accepts Apple's licence; MacSW never passes it for them.
        XCTAssertFalse(PreflightService.rosettaInstallCommand.contains("agree"))
    }

    func testFreeSpaceBelow40GBBlocksUnlessTheMediaIsAlreadyCopied() {
        XCTAssertEqual(verdict(.freeSpace, PreflightService.evaluate(facts(free: 40_000_000_000))), .passed)
        XCTAssertEqual(verdict(.freeSpace, PreflightService.evaluate(facts(free: 30_000_000_000))), .blocked)
        // After a copy of 15 GB, 25 GB are still needed.
        XCTAssertEqual(verdict(.freeSpace, PreflightService.evaluate(facts(free: 30_000_000_000),
                                                                     alreadyCopiedBytes: 15_000_000_000)), .passed)
        XCTAssertEqual(verdict(.freeSpace, PreflightService.evaluate(facts(free: 20_000_000_000),
                                                                     alreadyCopiedBytes: 15_000_000_000)), .blocked)
        // Unknown free space is shown, but does not block.
        let unknown = PreflightService.evaluate(facts(free: nil))
        XCTAssertEqual(verdict(.freeSpace, unknown), .note)
        XCTAssertFalse(PreflightService.isBlocked(unknown))
    }

    func testLessThan16GBOfMemoryIsANoteOnly() {
        let checks = PreflightService.evaluate(facts(memory: 8 << 30))
        XCTAssertEqual(verdict(.memory, checks), .note)
        XCTAssertFalse(PreflightService.isBlocked(checks))
        XCTAssertEqual(verdict(.memory, PreflightService.evaluate(facts(memory: 16 << 30))), .passed)
    }

    func testRosettaProbeRunsArchX86_64() {
        var calls: [String] = []
        for status: Int32? in [0, 1, nil] {
            let installed = PreflightService.rosettaInstalled { executable, arguments in
                calls.append(([executable.path] + arguments).joined(separator: " "))
                return status
            }
            XCTAssertEqual(installed, status == 0)
        }
        XCTAssertEqual(Set(calls), ["/usr/bin/arch -x86_64 /usr/bin/true"])
    }

    func testGatherFactsReadsThisMacWithoutStartingTheProbe() throws {
        let volume = FileManager.default.temporaryDirectory
        let gathered = PreflightService.gatherFacts(volume: volume, run: { _, _ in 0 })
        XCTAssertTrue(gathered.rosettaInstalled)
        XCTAssertNotNil(gathered.freeBytes)
        XCTAssertLessThan(UInt64(0), gathered.physicalMemory)
        XCTAssertLessThan(12, gathered.macOSVersion.majorVersion)
    }
}
