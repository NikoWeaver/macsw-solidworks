import Foundation
import CryptoKit
import XCTest
@testable import MacSWCore

final class RegAsmTests: XCTestCase {
    func testManagedCOMRuntimeIsValidatedInstalledAndRepeatable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-RegAsm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let prefix = root.appendingPathComponent("bottle")

        let sources = [
            "x86_64-windows": Data("managed-x64".utf8),
            "i386-windows": Data("managed-x86".utf8)
        ]
        for (arch, data) in sources {
            let source = runtime.appendingPathComponent("lib/wine/\(arch)/regasm.exe")
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: source)
        }
        let mscorlib = runtime.appendingPathComponent("share/wine/mono/wine-mono-unknown/lib/mono/4.5/mscorlib.dll")
        let mscorlibData = Data("registration-services".utf8)
        try fm.createDirectory(at: mscorlib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mscorlibData.write(to: mscorlib)
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }

        let prepare = {
            try PrerequisiteService.prepareManagedCOMRegistration(
                runtime: runtime,
                prefix: prefix,
                expectedMscorlibSHA256: hash(mscorlibData),
                expectedRegAsmX86SHA256: hash(sources["i386-windows"]!),
                expectedRegAsmX64SHA256: hash(sources["x86_64-windows"]!)
            )
        }
        try prepare()
        try prepare()
        let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/regasm.exe")
        XCTAssertEqual(try Data(contentsOf: target), sources["x86_64-windows"])
        let log = try String(contentsOf: root.appendingPathComponent("logs/managed-com-registration.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("COM registration runtime verified"))

        try Data("old tool".utf8).write(to: target)
        try prepare()
        XCTAssertEqual(try Data(contentsOf: target), sources["x86_64-windows"])

        try Data("wrong runtime".utf8).write(to: mscorlib)
        XCTAssertThrowsError(try prepare())
    }
}
