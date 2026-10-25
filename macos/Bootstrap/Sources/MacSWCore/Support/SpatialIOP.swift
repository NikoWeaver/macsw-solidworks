import Darwin
import Foundation

/// SOLIDWORKS 2026's core MSI unzips `swwi/data/spatialiop.zip` (the Spatial InterOp CAD import
/// libraries) in the deferred custom action InstallSpatialIOP, through the Windows shell's zip folder.
/// Wine has no zip folder (WineHQ bug 17368), so the MSI ends with 1603 (67 as MacSW sees it).
///
/// The fix (docs/spatialiop-fix.md): MacSW installs its own copy of the MSI in which the conditions of
/// CopySpatialIOP, set_InstallSpatialIOP and InstallSpatialIOP are 0 (`native/msi_spatialiop.c`), then
/// extracts the zip itself into `[SPIOP]files`, that is `<INSTALLDIR>\spiop\files`. The media is never
/// changed. No public property can switch the actions off: their condition is `NOT REMOVE~="ALL"`.
public enum SpatialIOP {
    public static let payloadRelativePath = "swwi/data/spatialiop.zip"
    /// The helper in MacSW.app; it runs under Wine.
    static let helperRelativePath = "Contents/Resources/helpers/msi_spatialiop.exe"
    /// MacSW's copy of the MSI lives in the bottle: it goes with the bottle, and Windows Installer keeps it
    /// as the install source for repairs.
    static let stageRelativePath = "drive_c/MacSW/InstallMedia"
    /// MSI Directory table: IOPFILES = SPIOP\files, SPIOP = INSTALLDIR\spiop.
    static let payloadDirectory = ["spiop", "files"]
    static let logName = "spatialiop.log"

    /// What `msi_spatialiop.exe` did with the copy.
    public enum PackageEdit: Equatable, Sendable {
        /// The three actions are off: install the copy, then extract the payload.
        case disabled
        /// The MSI has none of the three actions (other media): install the media's own MSI unchanged.
        case notNeeded
    }

    /// Exit codes of `native/msi_spatialiop.c`. A refusal means the copy was not changed.
    static func packageEdit(exitCode: Int32) throws -> PackageEdit {
        let refusal: String
        switch exitCode {
        case 0: return .disabled
        case 3: return .notNeeded
        case 4: refusal = "some of its SpatialIOP actions are missing"
        case 5: refusal = "a SpatialIOP action has a condition MacSW does not know"
        case 6: refusal = "a SpatialIOP custom action is not the one MacSW knows"
        default:
            throw failure("Could not prepare the SOLIDWORKS installer for Wine (msi_spatialiop.exe exit code \(exitCode)); see \(logName).")
        }
        throw failure("MacSW does not know this SOLIDWORKS installer: \(refusal). Nothing was installed and the media was not changed; see \(logName).")
    }

    /// Mirrors the media root in `stage` with symbolic links and puts one real file there: a writable copy
    /// of the core MSI. The cabinets and all other files stay on the media (the copy costs one 64 MB file),
    /// and every path from the MSI back into the media still resolves. Returns the copy.
    static func stageCorePackage(media: URL, stage: URL, fileManager: FileManager = .default) throws -> URL {
        try removeStage(stage, fileManager: fileManager)
        var source = media.standardizedFileURL
        var target = stage
        for part in SilentInstallerPlan.coreMSIRelativePath.split(separator: "/").map(String.init) {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            let entries = try fileManager.contentsOfDirectory(atPath: source.path).sorted()
            // An ISO mount can be case-sensitive; take the media's own spelling.
            guard let match = entries.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else {
                throw failure("The media has no \(SilentInstallerPlan.coreMSIRelativePath).")
            }
            for entry in entries where entry != match {
                try fileManager.createSymbolicLink(at: target.appendingPathComponent(entry),
                                                   withDestinationURL: source.appendingPathComponent(entry))
            }
            source.appendPathComponent(match)
            target.appendPathComponent(match)
        }
        try fileManager.copyItem(at: source, to: target)
        // ISO and read-only media give a read-only copy; the helper must be able to commit.
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        guard isRegularFile(target) else { throw failure("MacSW's copy of the SOLIDWORKS MSI is not a regular file.") }
        return target
    }

    /// Removes a stage made by `stageCorePackage`. Its links are removed, never followed: they point at the media.
    static func removeStage(_ stage: URL, fileManager: FileManager = .default) throws {
        var info = stat()
        guard lstat(stage.path, &info) == 0 else { return }
        try fileManager.removeItem(at: stage)
    }

    /// `C:\…` for a path inside the bottle's drive_c (`dosdevices/c:` is always `../drive_c`).
    static func windowsPath(of url: URL, prefix: URL) -> String? {
        let drive = prefix.appendingPathComponent("drive_c").standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(drive), path.count > drive.count else { return nil }
        return "C:\\" + path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// One member of the payload zip.
    struct PayloadEntry: Equatable, Sendable {
        let path: String
        let size: Int64
        let isFolder: Bool
    }

    /// The members of `7zz l -slt -ba <zip>`. The listing is the reference for the check after the
    /// extraction, so no file count or size is built in. Refuses members that 7zz would write outside the
    /// destination or as a link (absolute path, a `..` part, a backslash, a symbolic link).
    static func payloadEntries(fromListing listing: String) throws -> [PayloadEntry] {
        var entries: [PayloadEntry] = []
        var path: String?
        var size: Int64 = 0
        var isFolder = false
        var isLink = false
        func flush() throws {
            guard let current = path else { return }
            let parts = current.split(separator: "/", omittingEmptySubsequences: false)
            guard !current.isEmpty, !current.hasPrefix("/"), !current.contains("\\"), !current.contains("\0"),
                  !parts.contains(".."), !isLink else {
                throw failure("spatialiop.zip has a member MacSW will not extract: \(current)")
            }
            entries.append(PayloadEntry(path: current, size: size, isFolder: isFolder))
            path = nil; size = 0; isFolder = false; isLink = false
        }
        for line in listing.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Path = ") {
                try flush()
                path = String(line.dropFirst("Path = ".count))
            } else if line.hasPrefix("Folder = ") {
                isFolder = line.hasSuffix("+")
            } else if line.hasPrefix("Size = ") {
                size = Int64(line.dropFirst("Size = ".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("Attributes = ") {
                // "D drwxrwxrwx", " -rw-rw-rw-": the last word is the Unix mode.
                isLink = line.split(separator: " ").last?.hasPrefix("l") == true
            }
        }
        try flush()
        guard entries.contains(where: { !$0.isFolder }) else { throw failure("spatialiop.zip lists no files.") }
        return entries
    }

    /// Every way `destination` differs from the listing: a missing folder, a missing file, or a file of
    /// another size. Empty when the payload is complete.
    static func payloadProblems(_ entries: [PayloadEntry], destination: URL,
                                fileManager: FileManager = .default) -> [String] {
        entries.compactMap { entry in
            let path = destination.appendingPathComponent(entry.path).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                return "missing: \(entry.path)"
            }
            let type = attributes[.type] as? FileAttributeType
            if entry.isFolder { return type == .typeDirectory ? nil : "not a folder: \(entry.path)" }
            guard type == .typeRegular else { return "not a file: \(entry.path)" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            return size == entry.size ? nil : "size \(size) instead of \(entry.size): \(entry.path)"
        }
    }

    /// `"SolidWorks Folder"` of `HKLM\SOFTWARE\[Wow6432Node\]SolidWorks\SOLIDWORKS <year>\Setup`, which the MSI
    /// writes as `[INSTALLDIR]` (Registry table). The newest year wins. Only Setup sections are read: lines
    /// of every other key (the version's Licenses key among them) are skipped, never parsed or kept.
    static func installDirectory(systemRegistry: String) -> String? {
        var best: (year: Int, wow: Bool, folder: String)?
        var section: (year: Int, wow: Bool)?
        for raw in systemRegistry.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = setupSection(line)
                continue
            }
            guard let current = section, line.lowercased().hasPrefix("\"solidworks folder\"=\"") else { continue }
            var value = line.dropFirst("\"SolidWorks Folder\"=\"".count)
            guard value.hasSuffix("\"") else { continue }
            value = value.dropLast()
            let folder = value.replacingOccurrences(of: "\\\\", with: "\\")
            // The 64-bit key wins over Wow6432Node for the same year.
            if let known = best, known.year > current.year || (known.year == current.year && !known.wow) { continue }
            best = (current.year, current.wow, folder)
        }
        return best?.folder
    }

    /// `[Software\\Wow6432Node\\SolidWorks\\SOLIDWORKS 2026\\Setup] 1730000000` -> (2026, true).
    private static func setupSection(_ line: String) -> (year: Int, wow: Bool)? {
        guard let close = line.firstIndex(of: "]"),
              let expression = try? NSRegularExpression(
                pattern: #"^software\\(wow6432node\\)?solidworks\\solidworks ([0-9]{4})\\setup$"#,
                options: [.caseInsensitive]) else { return nil }
        let key = line[line.index(after: line.startIndex)..<close].replacingOccurrences(of: "\\\\", with: "\\")
        guard let match = expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
              let yearRange = Range(match.range(at: 2), in: key),
              let year = Int(key[yearRange]) else { return nil }
        return (year, match.range(at: 1).location != NSNotFound)
    }

    /// `C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\` -> `<prefix>/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/spiop/files`.
    static func payloadDestination(installDirectory: String, prefix: URL) -> URL? {
        guard installDirectory.lowercased().hasPrefix("c:\\") else { return nil }
        let parts = installDirectory.dropFirst(3).split(separator: "\\").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains("/") }) else { return nil }
        return (parts + payloadDirectory).reduce(prefix.appendingPathComponent("drive_c")) { $0.appendingPathComponent($1) }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.SpatialIOP")
    }
}
