import Foundation
import XCTest
@testable import MacSWCore

final class MediaManifestTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "B", count: 64)

    private func reason(_ text: String) -> String? {
        do {
            _ = try MediaManifest.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The lines that `shasum -a 256` (and scripts/make_media_manifest.sh) writes.
    func testParsesShasumOutput() throws {
        let manifest = try MediaManifest.parse("""
        \(hashA)  ./setup.exe
        \(hashB) *./swwi/data/solidworks.msi\r

        \(hashA)  ./PreReqs/VBA/vba71 copy.msi
        \(hashA)  ./media-manifest.sha256
        """)
        XCTAssertEqual(manifest.entries, [
            MediaManifest.Entry(path: "setup.exe", sha256: hashA),
            MediaManifest.Entry(path: "swwi/data/solidworks.msi", sha256: hashB.lowercased()),
            MediaManifest.Entry(path: "PreReqs/VBA/vba71 copy.msi", sha256: hashA)
        ])
    }

    func testRefusesUnsafeAndMalformedLines() {
        for line in ["\(hashA)  ../outside", "\(hashA)  /etc/passwd", "\(hashA)  ./a//b", "\(hashA)  ./",
                     "\(hashA)  a/./b", "\(hashA) one-space", "abc  ./short.exe", "\\\(hashA)  ./bad\\\\name"] {
            XCTAssertNotNil(reason(line), line)
        }
        XCTAssertTrue(reason("\(hashA)  ./A.exe\n\(hashA)  ./a.EXE")?.contains("listed twice") == true)
        XCTAssertTrue(reason("\n\n")?.contains("lists no files") == true)
    }

    func testSHA256OfFileMatchesData() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        try data.write(to: file)
        XCTAssertEqual(try MediaManifest.sha256(of: file, chunkSize: 333), MediaManifest.sha256(data))
        // printf abc | shasum -a 256
        XCTAssertEqual(MediaManifest.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class MediaCopyServiceTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private let fileManager = FileManager.default
    private let plenty: (URL) -> Int64? = { _ in 1 << 50 }

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-MediaCopy-\(UUID().uuidString)")
        source = root.appendingPathComponent("Box/MacSW/media/SW2026", isDirectory: true)
        destination = root.appendingPathComponent("support/media/2026 SP4.1", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// Writes the files to the source folder with a manifest of them; returns the manifest's SHA-256.
    @discardableResult
    private func makeMedia(_ files: [String: Data], unlisted: [String: Data] = [:]) throws -> String {
        var lines: [String] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try put(data, at: path)
            lines.append("\(MediaManifest.sha256(data))  ./\(path)")
        }
        for (path, data) in unlisted { try put(data, at: path) }
        let manifest = Data((lines.joined(separator: "\n") + "\n").utf8)
        try manifest.write(to: source.appendingPathComponent(MediaManifest.fileName))
        return MediaManifest.sha256(manifest)
    }

    private func put(_ data: Data, at path: String, in folder: URL? = nil) throws {
        let url = (folder ?? source).appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func copy(expected: String? = nil, chunkSize: Int = 1 << 20, reportInterval: TimeInterval = 0.2,
                      freeBytes: ((URL) -> Int64?)? = nil,
                      progress: (MediaCopyService.Progress) -> Void = { _ in }) throws -> MediaCopyService.Result {
        try MediaCopyService.copy(from: source, to: destination, expectedManifestSHA256: expected, chunkSize: chunkSize,
                                  reportInterval: reportInterval, freeBytes: freeBytes ?? plenty, progress: progress)
    }

    private func partial(of path: String) -> URL {
        let target = destination.appendingPathComponent(path)
        return target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)\(MediaCopyService.partialSuffix)")
    }

    private func message(_ body: () throws -> Void) -> String {
        do {
            try body()
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func testCopiesExactlyTheListedFilesAndWritesAReceipt() throws {
        let files = ["setup.exe": bytes(3000), "swwi/data/solidworks.msi": bytes(5000, seed: 7), "with space/a b.txt": bytes(10)]
        let manifestSHA = try makeMedia(files, unlisted: ["notes.txt": bytes(5), ".DS_Store": bytes(5)])
        var reports: [MediaCopyService.Progress] = []

        let result = try copy(expected: manifestSHA.uppercased(), progress: { reports.append($0) })

        for (path, data) in files {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), data, path)
            XCTAssertFalse(fileManager.fileExists(atPath: partial(of: path).path), path)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("notes.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent(".DS_Store").path))
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent(MediaManifest.fileName).path))
        XCTAssertEqual(result.copiedBytes, 8010)
        XCTAssertEqual(result.receipt.totalBytes, 8010)
        XCTAssertEqual(result.receipt.fileCount, 3)
        XCTAssertEqual(MediaCopyService.receipt(in: destination), result.receipt)
        XCTAssertEqual(MediaCopyService.receipt(in: destination)?.manifestSHA256, manifestSHA)
        XCTAssertEqual(reports.first?.completedBytes, 0)
        XCTAssertEqual(reports.last?.completedBytes, 8010)
        XCTAssertEqual(reports.last?.completedFiles, 3)
        XCTAssertEqual(reports.last?.fraction, 1)
        // The copy is a media folder that the install window accepts.
        XCTAssertEqual(InstallationMediaResolver.resolve(destination)?.mediaDirectory.resolvingSymlinksInPath(),
                       destination.resolvingSymlinksInPath())
    }

    /// The copy is kept: a second run for the same manifest reads nothing from the team folder.
    func testFinishedCopyIsNotCopiedAgain() throws {
        try makeMedia(["setup.exe": bytes(100)])
        _ = try copy()
        try fileManager.removeItem(at: source.appendingPathComponent("setup.exe"))
        let again = try copy()
        XCTAssertEqual(again.copiedBytes, 0)
    }

    /// After an interruption, files in place are kept and a partial file goes on where it stopped.
    func testResumeKeepsFinishedFilesAndContinuesAPartialFile() throws {
        let big = bytes(10_000, seed: 3)
        try makeMedia(["a.cab": bytes(4000), "b.cab": big, "c.cab": bytes(500, seed: 9)])
        try put(bytes(4000), at: "a.cab", in: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try big.prefix(6000).write(to: partial(of: "b.cab"))

        let result = try copy(chunkSize: 1024)

        XCTAssertEqual(result.copiedBytes, 4000 + 500)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("b.cab")), big)
        XCTAssertNotNil(MediaCopyService.receipt(in: destination))
    }

    func testCancelledCopyLeavesAPartialFileThatTheNextRunContinues() async throws {
        let big = bytes(64 * 1024, seed: 5)
        try makeMedia(["big.cab": big])
        let source = self.source!, destination = self.destination!
        let job = Task.detached { () -> MediaCopyService.Result in
            try MediaCopyService.copy(from: source, to: destination, expectedManifestSHA256: nil, chunkSize: 4096,
                                      reportInterval: 0, freeBytes: { _ in 1 << 50 }, progress: { progress in
                if progress.completedBytes >= 16 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do {
            _ = try await job.value
            XCTFail("the copy did not stop")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let kept = try XCTUnwrap(try fileManager.attributesOfItem(atPath: partial(of: "big.cab").path)[.size] as? NSNumber).int64Value
        XCTAssertLessThan(Int64(16 * 1024 - 1), kept)
        XCTAssertLessThan(kept, Int64(big.count))
        XCTAssertNil(MediaCopyService.receipt(in: destination))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("big.cab").path))

        let result = try copy(chunkSize: 4096)
        XCTAssertEqual(result.copiedBytes, Int64(big.count) - kept)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("big.cab")), big)
    }

    /// A partial file of an older version of the file is copied once more, whole.
    func testStalePartialFileIsCopiedAgain() throws {
        let data = bytes(3000, seed: 2)
        try makeMedia(["data.cab": data])
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try bytes(1000, seed: 99).write(to: partial(of: "data.cab"))
        let result = try copy(chunkSize: 512)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("data.cab")), data)
        XCTAssertEqual(result.copiedBytes, 2000 + 3000)
    }

    /// A file in place from an older manifest is checked, and copied again when it changed.
    func testChangedFileInPlaceIsReplaced() throws {
        try makeMedia(["setup.exe": bytes(100, seed: 1)])
        try put(bytes(100, seed: 2), at: "setup.exe", in: destination)
        let result = try copy()
        XCTAssertEqual(result.copiedBytes, 100)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("setup.exe")), bytes(100, seed: 1))
    }

    func testManifestOfAnotherVersionStopsBeforeCopying() throws {
        try makeMedia(["setup.exe": bytes(100)])
        let text = message { _ = try copy(expected: String(repeating: "0", count: 64)) }
        XCTAssertTrue(text.contains("does not match the team config"), text)
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testFileThatDoesNotMatchItsHashIsNotKept() throws {
        try makeMedia(["setup.exe": bytes(100)])
        try bytes(100, seed: 42).write(to: source.appendingPathComponent("setup.exe"))
        let text = message { _ = try copy() }
        XCTAssertTrue(text.contains("setup.exe does not match"), text)
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("setup.exe").path))
        XCTAssertFalse(fileManager.fileExists(atPath: partial(of: "setup.exe").path))
        XCTAssertNil(MediaCopyService.receipt(in: destination))
    }

    /// A listed file that is missing, or a link (also one out of the media folder), stops the copy.
    func testMissingAndLinkedFilesAreRefused() throws {
        let outside = root.appendingPathComponent("private.txt")
        try bytes(10).write(to: outside)
        try makeMedia(["setup.exe": bytes(100)])
        try fileManager.removeItem(at: source.appendingPathComponent("setup.exe"))
        XCTAssertTrue(message { _ = try copy() }.contains("not complete"))

        try fileManager.createSymbolicLink(at: source.appendingPathComponent("setup.exe"), withDestinationURL: outside)
        let manifest = Data("\(MediaManifest.sha256(bytes(10)))  ./setup.exe\n".utf8)
        try manifest.write(to: source.appendingPathComponent(MediaManifest.fileName))
        XCTAssertTrue(message { _ = try copy() }.contains("not a file in the media folder"))

        try fileManager.removeItem(at: source.appendingPathComponent("setup.exe"))
        try fileManager.createSymbolicLink(at: source.appendingPathComponent("swwi"), withDestinationURL: root)
        try Data("\(MediaManifest.sha256(bytes(10)))  ./swwi/private.txt\n".utf8)
            .write(to: source.appendingPathComponent(MediaManifest.fileName))
        XCTAssertTrue(message { _ = try copy() }.contains("not a file in the media folder"))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("swwi/private.txt").path))
    }

    func testNoManifestOrNotEnoughSpaceStopsBeforeCopying() throws {
        try put(bytes(100), at: "setup.exe")
        XCTAssertTrue(message { _ = try copy() }.contains("has no \(MediaManifest.fileName)"))

        try makeMedia(["setup.exe": bytes(100)])
        let text = message { _ = try copy(freeBytes: { _ in MediaCopyService.reserveBytes }) }
        XCTAssertTrue(text.contains("Not enough free disk space"), text)
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("setup.exe").path))
        XCTAssertNoThrow(try copy(freeBytes: { _ in MediaCopyService.reserveBytes + 100 }))
    }

    func testBytesOnDiskCountsPartialFiles() throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try bytes(300).write(to: destination.appendingPathComponent("done.cab"))
        try bytes(200).write(to: partial(of: "next.cab"))
        XCTAssertEqual(MediaCopyService.bytesOnDisk(in: destination), 500)
        XCTAssertEqual(MediaCopyService.bytesOnDisk(in: root.appendingPathComponent("missing")), 0)
    }

    /// Only a folder in MacSW's media folder may go to the Trash (not run here: it would use the real Trash).
    func testTrashCopyRefusesOtherFolders() {
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        XCTAssertEqual(MediaCopyService.destination(release: "2026 SP4.1", paths: paths), destination.standardizedFileURL)
        XCTAssertThrowsError(try MediaCopyService.trashCopy(source, paths: paths))
        XCTAssertThrowsError(try MediaCopyService.trashCopy(paths.media, paths: paths))
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
    }
}
