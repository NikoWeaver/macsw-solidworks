import CryptoKit
import Foundation

/// `media-manifest.sha256` in the team's media folder, as `scripts/make_media_manifest.sh` (or
/// `shasum -a 256`) writes it: one line per file, the SHA-256 in hex, two spaces (or a space and
/// `*`) and the path relative to the media folder, usually with a leading `./`. It lists the files
/// that make the media; `MediaCopyService` copies exactly these. Paths that are absolute or have
/// `..`, and names that `shasum` had to escape (a line that starts with `\`), are refused.
public struct MediaManifest: Equatable, Sendable {
    public static let fileName = "media-manifest.sha256"

    public struct Entry: Equatable, Sendable {
        /// Relative to the media folder, without `./`, with `/` between folder names.
        public let path: String
        /// Lowercase hex.
        public let sha256: String
    }

    public let entries: [Entry]

    public static func parse(_ text: String) throws -> MediaManifest {
        var entries: [Entry] = []
        var seen = Set<String>()
        // \r\n is one Character in Swift, and a newline.
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let number = index + 1
            guard !line.hasPrefix("\\") else { throw failure("line \(number) has a file name with \\ or a line break") }
            let hash = line.prefix(64)
            let rest = line.dropFirst(64)
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), rest.hasPrefix("  ") || rest.hasPrefix(" *") else {
                throw failure("line \(number) is not \"<sha256>  <path>\"")
            }
            var path = String(rest.dropFirst(2))
            while path.hasPrefix("./") { path.removeFirst(2) }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw failure("line \(number) has an unsafe path: \(path)")
            }
            guard path != fileName else { continue }
            // One file on the default (case-insensitive) APFS volume.
            guard seen.insert(path.lowercased()).inserted else { throw failure("\(path) is listed twice") }
            entries.append(Entry(path: path, sha256: hash.lowercased()))
        }
        guard !entries.isEmpty else { throw failure("it lists no files") }
        return MediaManifest(entries: entries)
    }

    /// SHA-256 of a file in lowercase hex, read in chunks. Stops between chunks when the
    /// current task is cancelled.
    public static func sha256(of file: URL, chunkSize: Int = 8 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ reason: String) -> NSError {
        MacSWError.make("\(fileName) is not valid: \(reason).", domain: "MacSW.MediaCopy")
    }
}
