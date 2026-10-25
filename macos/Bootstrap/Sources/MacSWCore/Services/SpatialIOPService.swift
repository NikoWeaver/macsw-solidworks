import Foundation

/// Runs the two halves of the SpatialIOP fix (`SpatialIOP`, docs/spatialiop-fix.md): before the core MSI,
/// MacSW's edited copy of the MSI; after it, the payload that the disabled action would have unzipped.
public final class SpatialIOPService: @unchecked Sendable {
    private let wine: WineService

    public init(wine: WineService = .shared) { self.wine = wine }

    /// The MSI to install and whether the payload must be extracted after it. Stages a copy of the media's
    /// core MSI in the bottle and runs `msi_spatialiop.exe` on it under Wine; the media is only read.
    public func prepareCorePackage(media: URL, prefix: URL) async throws -> (msi: URL, needsPayload: Bool) {
        let helper = MacSWBundle.url.appendingPathComponent(SpatialIOP.helperRelativePath)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw SpatialIOP.failure("The App is missing msi_spatialiop.exe; repackage the App.")
        }
        let stage = prefix.appendingPathComponent(SpatialIOP.stageRelativePath)
        let staged = try await Task.detached(priority: .utility) {
            try SpatialIOP.stageCorePackage(media: media, stage: stage)
        }.value
        guard let windowsPath = SpatialIOP.windowsPath(of: staged, prefix: prefix) else {
            throw SpatialIOP.failure("MacSW's copy of the SOLIDWORKS MSI is not inside the bottle's C: drive.")
        }
        let result = try await wine.capturePairCancellable(
            wine.makeProcess(arguments: [helper.path, windowsPath], prefix: prefix))
        log("msi_spatialiop.exe \(windowsPath): exit code \(result.status)\n\(result.standardOutput)\(result.standardError)",
            prefix: prefix)
        switch try SpatialIOP.packageEdit(exitCode: result.status) {
        case .disabled:
            // Check before the ten-minute MSI, not after it.
            guard FileManager.default.fileExists(atPath: media.appendingPathComponent(SpatialIOP.payloadRelativePath).path) else {
                throw SpatialIOP.failure("The media is missing \(SpatialIOP.payloadRelativePath), which the SOLIDWORKS installer needs.")
            }
            return (staged, true)
        case .notNeeded:
            try? SpatialIOP.removeStage(stage)
            return (media.appendingPathComponent(SilentInstallerPlan.coreMSIRelativePath), false)
        }
    }

    /// Extracts the media's `spatialiop.zip` with the bundled 7zz into `[SPIOP]files` and checks the result
    /// against the zip's own listing. Skips the extraction when the files are already complete. Returns
    /// the number of files.
    public func installPayload(media: URL, prefix: URL) async throws -> Int {
        let archive = media.appendingPathComponent(SpatialIOP.payloadRelativePath)
        let sevenZip = try PrerequisiteService.sevenZip()
        let listing = Process()
        listing.executableURL = sevenZip
        listing.arguments = ["l", "-slt", "-ba", archive.path]
        let listed = try await wine.capturePairCancellable(listing)
        guard listed.status == 0 else {
            throw SpatialIOP.failure("Could not list \(SpatialIOP.payloadRelativePath) (7zz: \(listed.status)).")
        }
        let entries = try SpatialIOP.payloadEntries(fromListing: listed.standardOutput)
        let files = entries.filter { !$0.isFolder }
        let registry = try? Data(contentsOf: prefix.appendingPathComponent("system.reg"))
        guard let folder = registry.flatMap(PlainTextDecoder.decode).flatMap(SpatialIOP.installDirectory(systemRegistry:)),
              let destination = SpatialIOP.payloadDestination(installDirectory: folder, prefix: prefix) else {
            throw SpatialIOP.failure("The SOLIDWORKS Setup registry key has no usable \"SolidWorks Folder\"; cannot place the SpatialIOP files.")
        }
        log("payload: \(entries.count) members (\(files.count) files) -> \(destination.path)", prefix: prefix)

        if await problems(entries, destination).isEmpty {
            log("payload already complete; nothing extracted", prefix: prefix)
            return files.count
        }
        let needed = files.reduce(Int64(0)) { $0 + $1.size }
        if let free = try? prefix.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < needed {
            throw SpatialIOP.failure("The SpatialIOP files need \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) but only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free.")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let extraction = Process()
        extraction.executableURL = sevenZip
        // -aoa replaces what an interrupted run left; x keeps the zip's folders.
        extraction.arguments = ["x", "-aoa", "-y", "-bso0", "-bsp0", "-o\(destination.path)", archive.path]
        let code = try await wine.runCancellable(extraction, log: logURL(prefix))
        guard code == 0 else {
            throw SpatialIOP.failure("Extracting \(SpatialIOP.payloadRelativePath) failed (7zz: \(code)); see \(SpatialIOP.logName).")
        }
        let remaining = await problems(entries, destination)
        guard remaining.isEmpty else {
            log("payload check failed (\(remaining.count)):\n" + remaining.prefix(20).joined(separator: "\n"), prefix: prefix)
            throw SpatialIOP.failure("The extracted SpatialIOP files do not match the zip's listing (\(remaining.count) differences, first: \(remaining[0])); see \(SpatialIOP.logName).")
        }
        log("payload extracted and checked: \(files.count) files, \(needed) bytes", prefix: prefix)
        return files.count
    }

    /// 11,000 file checks: off the main thread.
    private func problems(_ entries: [SpatialIOP.PayloadEntry], _ destination: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            SpatialIOP.payloadProblems(entries, destination: destination)
        }.value
    }

    private func logURL(_ prefix: URL) -> URL {
        wine.logDirectory(prefix.path).appendingPathComponent(SpatialIOP.logName)
    }

    private func log(_ text: String, prefix: URL) {
        LogFiles.append("\(ISO8601DateFormatter().string(from: Date())) \(text)\n", to: logURL(prefix))
    }
}
