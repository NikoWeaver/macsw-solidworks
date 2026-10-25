import Foundation

/// MacSW's logs hold the user name, paths, MSI properties and Wine output, so the logs directory
/// is 0700 and every log file is 0600 (security audit 2026-10-24, finding 4). Logs that a Wine
/// program writes itself (msiexec /l*v) are created 0600 beforehand with `prepare`: Wine opens
/// them with CREATE_ALWAYS, which truncates an existing file and keeps its mode.
public enum LogFiles {
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600

    /// Creates `directory` (0700) if needed and tightens an existing one to 0700.
    public static func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: directoryPermissions])
        // Older builds created it with the umask (0755). A directory we do not own stays as it is.
        try? fileManager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: directory.path)
    }

    /// Creates `log` as an empty 0600 file in a 0700 directory, or tightens an existing one to 0600.
    public static func prepare(_ log: URL) throws {
        try prepareDirectory(log.deletingLastPathComponent())
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: log.path),
           !fileManager.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: filePermissions]) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: log.path])
        }
        try? fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: log.path)
    }

    /// Appends `text` to `log` (created 0600 in a 0700 directory if needed). Best effort.
    public static func append(_ text: String, to log: URL) {
        let data = Data(text.utf8)
        try? prepare(log)
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }

    /// Replaces the contents of `log` with `data`; the file ends up 0600 in a 0700 directory.
    public static func write(_ data: Data, to log: URL) throws {
        try prepareDirectory(log.deletingLastPathComponent())
        try data.write(to: log, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: log.path)
    }
}
