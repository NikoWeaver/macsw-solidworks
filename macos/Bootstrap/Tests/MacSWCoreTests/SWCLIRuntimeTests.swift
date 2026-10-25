import Foundation
import XCTest
@testable import MacSWCore

final class SWCLIRuntimeTests: XCTestCase {
    private func prepareBundle(_ bundle: URL, prefix: URL) throws {
        let files = FileManager.default
        let contents = bundle.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/SWCLI")
        let native = resources.appendingPathComponent("runtime/PythonNative/bin")
        let bin = resources.appendingPathComponent("bin")
        let wine = contents.appendingPathComponent("Frameworks/wine/bin")
        for directory in [native, bin, wine, prefix.appendingPathComponent("drive_c")] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try files.createSymbolicLink(atPath: native.appendingPathComponent("python3").path, withDestinationPath: "/usr/bin/python3")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../").standardizedFileURL
        let helper = bin.appendingPathComponent("swcli_runtime.py")
        try files.copyItem(at: project.appendingPathComponent("scripts/swcli/swcli_runtime.py"), to: helper)
        try files.copyItem(at: project.appendingPathComponent("scripts/swcli/wine_runtime.py"),
                           to: bin.appendingPathComponent("wine_runtime.py"))
        let loader = wine.appendingPathComponent("wineloader")
        try Data("#!/bin/sh\nprintf '\"tasklist.exe\",\"42\",\"Console\",\"1\",\"0 K\"\\n'\n".utf8).write(to: loader)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        try Data("pythonw".utf8).write(to: resources.appendingPathComponent("runtime/Python311/pythonw.exe"))
        let process = Process()
        process.executableURL = native.appendingPathComponent("python3")
        process.arguments = ["-I", helper.path, "--contents", contents.path, "--build-manifest",
                             "--version", "test-version", "--source-commit", "test-commit"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testFreshInstallationCopiesBundledRuntimeIntoBottle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-swcli-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let source = bundle.appendingPathComponent("Contents/Resources/SWCLI/runtime/Python311")
        let prefix = root.appendingPathComponent("bottle")
        try fileManager.createDirectory(
            at: source.appendingPathComponent("Lib/site-packages/swcli"),
            withIntermediateDirectories: true
        )
        try Data("python".utf8).write(to: source.appendingPathComponent("python.exe"))
        try Data("entrypoint".utf8).write(
            to: source.appendingPathComponent("Lib/site-packages/swcli/__main__.py")
        )

        try prepareBundle(bundle, prefix: prefix)
        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix)

        let target = prefix.appendingPathComponent(PrerequisiteService.swcliDestination)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("python.exe")), Data("python".utf8))
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("Lib/site-packages/swcli/__main__.py")),
            Data("entrypoint".utf8)
        )
    }

    func testMissingBundledRuntimeIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MacSW-swcli-missing-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        // A build that declares SWCLI but lacks its runtime must still fail.
        let resources = root.appendingPathComponent("MacSW.app/Contents/Resources/SWCLI")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: resources.appendingPathComponent("runtime-manifest.json"))
        XCTAssertThrowsError(
            try PrerequisiteService.prepareSWCLI(
                bundleURL: root.appendingPathComponent("MacSW.app"),
                prefix: root.appendingPathComponent("bottle")
            )
        )
    }

    func testBuildWithoutSWCLISkipsDeployment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MacSW-swcli-excluded-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let prefix = root.appendingPathComponent("bottle")
        // The excluded layout: native Python and wine_runtime.py, no runtime-manifest.json.
        let resources = bundle.appendingPathComponent("Contents/Resources/SWCLI")
        try fileManager.createDirectory(
            at: resources.appendingPathComponent("runtime/PythonNative/bin"), withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: resources.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent("bin/wine_runtime.py"))
        try fileManager.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)

        XCTAssertFalse(PrerequisiteService.swcliIncluded(bundleURL: bundle))
        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix)
        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix, installing: true)
        XCTAssertFalse(fileManager.fileExists(atPath: prefix.appendingPathComponent("drive_c/MacSW").path))
    }

    func testDeploymentReplacesOldDaemonAndRemovesStaleFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-swcli-replace-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let source = bundle.appendingPathComponent("Contents/Resources/SWCLI/runtime/Python311")
        let prefix = root.appendingPathComponent("bottle")
        let target = prefix.appendingPathComponent(PrerequisiteService.swcliDestination)
        for directory in [source, target] {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("Lib/site-packages/swcli"), withIntermediateDirectories: true
            )
            try Data("python".utf8).write(to: directory.appendingPathComponent("python.exe"))
        }
        let entry = "Lib/site-packages/swcli/__main__.py"
        try Data("current daemon".utf8).write(to: source.appendingPathComponent(entry))
        try Data("older daemon".utf8).write(to: target.appendingPathComponent(entry))
        try Data("stale".utf8).write(to: target.appendingPathComponent("old-module.py"))

        try prepareBundle(bundle, prefix: prefix)
        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix)

        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(entry)), Data("current daemon".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: target.appendingPathComponent("old-module.py").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(entry)), Data("current daemon".utf8))
        let stamp = target.appendingPathComponent(".macsw-runtime.json")
        XCTAssertTrue(fileManager.fileExists(atPath: stamp.path))
        let date = try fileManager.attributesOfItem(atPath: stamp.path)[.modificationDate] as? Date
        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix)
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: stamp.path)[.modificationDate] as? Date, date)
    }
}
