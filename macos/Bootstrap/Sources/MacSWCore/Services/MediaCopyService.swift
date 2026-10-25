import CryptoKit
import Foundation

/// Copies the install media to `AppPaths.media/<release>/` before the install (docs/team-admin.md).
/// Box File Provider placeholders can fail while an installer reads them, and the MSI fix needs a
/// writable copy, so the install runs from this copy. MacSW keeps it: MSI repairs and add-ins read
/// their source from it.
///
/// The copy is exactly the files that `media-manifest.sha256` lists (`MediaManifest`), each checked
/// against its SHA-256 while it is copied. The manifest's own SHA-256 can be pinned by the team
/// config. This finds a partial or changed download, not who wrote the files: any editor of the
/// team folder can change the media, the manifest and the config together.
///
/// Resume: a file is copied to a hidden `.<name>.macsw-partial` next to its place and renamed when
/// its hash matches. After an interruption the next run keeps the files already in place whose hash
/// matches, and goes on with a partial file from where it stopped. A receipt marks a finished copy,
/// so a later run for the same manifest does nothing.
public enum MediaCopyService {
    public struct Progress: Equatable, Sendable {
        /// Bytes in place so far, also those that an earlier run copied.
        public let completedBytes: Int64
        public let totalBytes: Int64
        public let completedFiles: Int
        public let totalFiles: Int
        public let currentFile: String?

        public var fraction: Double {
            totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 0
        }
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public let manifestSHA256: String
        public let fileCount: Int
        public let totalBytes: Int64
        public let completedAt: String
    }

    public struct Result: Equatable, Sendable {
        public let folder: URL
        public let receipt: Receipt
        /// Bytes read from the source in this run; 0 when the copy was already complete.
        public let copiedBytes: Int64
    }

    public static let receiptName = ".macsw-media-copy.json"
    public static let partialSuffix = ".macsw-partial"
    /// Free space that must stay after the copy: the bottle needs about 8-10 GB.
    public static let reserveBytes: Int64 = 10_000_000_000

    /// `AppPaths.media/<release>`; `release` is a checked folder name (`TeamConfig`).
    public static func destination(release: String, paths: AppPaths) -> URL {
        paths.media.appendingPathComponent(release, isDirectory: true)
    }

    /// The receipt of a finished copy in `folder`, if any.
    public static func receipt(in folder: URL) -> Receipt? {
        (try? Data(contentsOf: folder.appendingPathComponent(receiptName)))
            .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
    }

    /// Bytes on disk in `folder`, partial files included (they no longer need free space).
    public static func bytesOnDisk(in folder: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Copies the media folder `source` (which holds `media-manifest.sha256`) to `destination`.
    /// Blocking: call it off the main actor. It stops with `CancellationError` between chunks when
    /// the current task is cancelled, and the next call goes on from there. `progress` is called on
    /// the copying thread, at most once per `reportInterval` while a file is copied, and after each file.
    public static func copy(
        from source: URL,
        to destination: URL,
        expectedManifestSHA256: String?,
        chunkSize: Int = 8 << 20,
        reportInterval: TimeInterval = 0.2,
        freeBytes: (URL) -> Int64? = PreflightService.freeBytes(at:),
        fileManager: FileManager = .default,
        progress: (Progress) -> Void = { _ in }
    ) throws -> Result {
        let manifestURL = source.appendingPathComponent(MediaManifest.fileName)
        guard isRegularFile(manifestURL, fileManager: fileManager) else {
            throw failure("The media folder \(source.lastPathComponent) has no \(MediaManifest.fileName). Ask the team admin to make it (scripts/make_media_manifest.sh).")
        }
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL) } catch {
            throw failure("Could not read \(MediaManifest.fileName): \(error.localizedDescription)")
        }
        let manifestSHA256 = MediaManifest.sha256(manifestData)
        if let expected = expectedManifestSHA256, expected.lowercased() != manifestSHA256 {
            throw failure("\(MediaManifest.fileName) does not match the team config: the media in the team folder is not the version the config names, or Box has not finished downloading it. Ask the team admin.")
        }
        if let done = receipt(in: destination), done.manifestSHA256 == manifestSHA256 {
            return Result(folder: destination, receipt: done, copiedBytes: 0)
        }
        guard let text = String(data: manifestData, encoding: .utf8) else {
            throw failure("\(MediaManifest.fileName) is not UTF-8 text.")
        }
        let manifest = try MediaManifest.parse(text)

        // Every listed file must be a regular file inside the media folder: no links out of it.
        var sizes: [Int64] = []
        for entry in manifest.entries {
            let file = source.appendingPathComponent(entry.path)
            guard TeamConfig.isInside(file, folder: source), isRegularFile(file, fileManager: fileManager),
                  let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
                throw failure("\(entry.path) is in \(MediaManifest.fileName) but not a file in the media folder. The media in the team folder is not complete; ask the team admin.")
            }
            sizes.append(size)
        }
        let totalBytes = sizes.reduce(0, +)

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // A receipt of another manifest must not make this copy look finished if it stops.
        try? fileManager.removeItem(at: destination.appendingPathComponent(receiptName))
        let remaining = max(totalBytes - bytesOnDisk(in: destination, fileManager: fileManager), 0)
        if let free = freeBytes(destination), free < remaining + reserveBytes {
            throw failure("Not enough free disk space: the copy needs \(PreflightService.bytes(remaining)) more and \(PreflightService.bytes(reserveBytes)) must stay free for the bottle, but \(PreflightService.bytes(free)) are free.")
        }

        var completedBytes: Int64 = 0
        var copiedBytes: Int64 = 0
        var lastReport = Date.distantPast
        func report(file: String?, files: Int, force: Bool) {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) >= reportInterval else { return }
            lastReport = now
            progress(Progress(completedBytes: completedBytes, totalBytes: totalBytes, completedFiles: files,
                              totalFiles: manifest.entries.count, currentFile: file))
        }
        report(file: nil, files: 0, force: true)
        for (index, entry) in manifest.entries.enumerated() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.path)
            if isRegularFile(target, fileManager: fileManager) {
                let inPlace: String?
                do { inPlace = try MediaManifest.sha256(of: target, chunkSize: chunkSize) } catch is CancellationError {
                    throw CancellationError()
                } catch { inPlace = nil }
                if inPlace == entry.sha256 {
                    completedBytes += sizes[index]
                    report(file: entry.path, files: index + 1, force: true)
                    continue
                }
                try fileManager.removeItem(at: target)
            }
            let before = completedBytes
            copiedBytes += try copyFile(
                entry, from: source.appendingPathComponent(entry.path), to: target, size: sizes[index],
                chunkSize: chunkSize, fileManager: fileManager,
                onChunk: { done in
                    completedBytes = before + done
                    report(file: entry.path, files: index, force: false)
                })
            completedBytes = before + sizes[index]
            report(file: entry.path, files: index + 1, force: true)
        }

        // The manifest goes with the copy, so the copy says what it is.
        let localManifest = destination.appendingPathComponent(MediaManifest.fileName)
        try manifestData.write(to: localManifest, options: .atomic)
        let done = Receipt(manifestSHA256: manifestSHA256, fileCount: manifest.entries.count, totalBytes: totalBytes,
                           completedAt: ISO8601DateFormatter().string(from: Date()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(done).write(to: destination.appendingPathComponent(receiptName), options: .atomic)
        return Result(folder: destination, receipt: done, copiedBytes: copiedBytes)
    }

    /// Copies one file through its partial file and returns the bytes read from `source`.
    /// `onChunk` gets the bytes of this file in place so far.
    private static func copyFile(
        _ entry: MediaManifest.Entry,
        from source: URL,
        to target: URL,
        size: Int64,
        chunkSize: Int,
        fileManager: FileManager,
        onChunk: (Int64) -> Void
    ) throws -> Int64 {
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent)\(partialSuffix)")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var hasher = SHA256()
        var offset: Int64 = 0
        if let existing = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value,
           existing <= size {
            // Go on where the last run stopped: the bytes in place are hashed again, not copied.
            let handle = try FileHandle(forReadingFrom: partial)
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                offset += Int64(chunk.count)
            }
            try handle.close()
        } else {
            try? fileManager.removeItem(at: partial)
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw failure("Could not write \(entry.path) to \(target.deletingLastPathComponent().path).")
            }
        }
        let resumedAt = offset

        do {
            let reader: FileHandle
            do {
                reader = try FileHandle(forReadingFrom: source)
                try reader.seek(toOffset: UInt64(offset))
            } catch {
                throw readFailure(entry, error)
            }
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: partial)
            defer { try? writer.close() }
            try writer.truncate(atOffset: UInt64(offset))
            try writer.seek(toOffset: UInt64(offset))
            onChunk(offset)
            while true {
                try Task.checkCancellation()
                let chunk: Data
                do {
                    guard let data = try reader.read(upToCount: chunkSize), !data.isEmpty else { break }
                    chunk = data
                } catch {
                    throw readFailure(entry, error)
                }
                hasher.update(data: chunk)
                do { try writer.write(contentsOf: chunk) } catch {
                    throw failure("Could not write \(entry.path): \(error.localizedDescription)")
                }
                offset += Int64(chunk.count)
                onChunk(offset)
            }
        }

        guard offset == size, MediaManifest.hex(hasher.finalize()) == entry.sha256 else {
            try? fileManager.removeItem(at: partial)
            // The bytes kept from the last run may be of an older file: copy it once more, whole.
            if resumedAt > 0 {
                return try copyFile(entry, from: source, to: target, size: size, chunkSize: chunkSize,
                                    fileManager: fileManager, onChunk: onChunk) + (offset - resumedAt)
            }
            throw failure("\(entry.path) does not match \(MediaManifest.fileName) (its SHA-256 is different). Box may not have the whole file yet: wait, then try again. If it happens again, ask the team admin.")
        }
        try fileManager.moveItem(at: partial, to: target)
        return offset - resumedAt
    }

    /// Moves a media copy to the Trash. The next install or repair then needs the team folder again.
    public static func trashCopy(_ folder: URL, paths: AppPaths, fileManager: FileManager = .default) throws {
        guard folder.deletingLastPathComponent().standardizedFileURL == paths.media.standardizedFileURL else {
            throw failure("\(folder.path) is not a media copy of MacSW; it was not moved.")
        }
        try fileManager.trashItem(at: folder, resultingItemURL: nil)
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        // attributesOfItem does not follow a link: a link is not a regular file here.
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private static func readFailure(_ entry: MediaManifest.Entry, _ error: Error) -> NSError {
        failure("Could not read \(entry.path) from the media folder: \(error.localizedDescription) If the media is in Box, check that Box is online, then try again: the copy goes on where it stopped.")
    }

    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.MediaCopy")
    }
}
