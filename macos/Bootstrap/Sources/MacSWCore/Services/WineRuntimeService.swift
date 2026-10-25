import Darwin
import Foundation

/// Pure file-based preflight: querying Wine here would itself update the bottle.
public enum WineRuntimeService {
    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.WineRuntime")
    }
    public enum State: String, Sendable {
        case unmanaged, fresh, baseline, ready, upgrade, recovery, invalid

        public var allowsLaunch: Bool { self == .ready || self == .fresh || self == .unmanaged }
        public var message: String {
            switch self {
            case .unmanaged: return "Custom bottles are not covered by Wine upgrade management."
            case .fresh: return "The bottle is not initialized yet; the version is recorded after installation finishes."
            case .baseline: return "No known-working Wine version has been recorded. Confirm the current version works, then record a baseline."
            case .ready: return "The bottle matches the current Wine / Mono / patches."
            case .upgrade: return "Wine, Mono, patches or the App location have changed; back up and migrate the bottle first."
            case .recovery: return "An unfinished migration exists; the new Wine is blocked from starting. Recover first."
            case .invalid: return "The Wine version record is invalid; the new Wine is blocked from starting. Check the upgrade log."
            }
        }
    }

    public static func root(prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent(".\(prefix.lastPathComponent).wine-runtime")
    }

    public static func identity(contents: URL) throws -> [String: String] {
        let data = try Data(contentsOf: contents.appendingPathComponent("Resources/BuildManifest.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let values = plist.reduce(into: [String: String]()) { result, entry in
            if (entry.key.hasPrefix("Wine") || entry.key.hasPrefix("Mono")), let value = entry.value as? String {
                result[entry.key] = value
            }
        }
        guard ["WineVersion", "MonoVersion", "WineMacModuleSHA256", "WineInputModuleSHA256",
               "WineCOMBaseModuleSHA256", "WineComctl32V6ModuleSHA256", "WineNtdllModuleSHA256",
               "WineLoaderSHA256", "MonoPatchSHA256", "MonoMscorlibSHA256", "MonoRegAsmX86SHA256",
               "MonoRegAsmX64SHA256"].allSatisfy({ !(values[$0] ?? "").isEmpty }) else {
            throw failure("The Wine / Mono build identity is incomplete.")
        }
        let msxmlKeys = ["WineMSXMLSchemaPatchSHA256", "WineMSXML3ModuleSHA256"]
        if msxmlKeys.contains(where: { values[$0] != nil }),
           !msxmlKeys.allSatisfy({ !(values[$0] ?? "").isEmpty }) {
            throw failure("The MSXML runtime build identity is incomplete.")
        }
        let toolboxKeys = ["MonoCCWModuleSHA256", "MonoBTLSModuleSHA256"]
        if toolboxKeys.contains(where: { values[$0] != nil }),
           !toolboxKeys.allSatisfy({ !(values[$0] ?? "").isEmpty }) {
            throw failure("The Toolbox runtime build identity is incomplete.")
        }
        return values
    }

    public static func status(prefix: URL, bundle: URL = MacSWBundle.url) -> State {
        let directory = root(prefix: prefix)
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pending.json").path) { return .recovery }
        guard isManaged(prefix: prefix) else { return .unmanaged }
        guard fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else { return .fresh }
        let receipt = directory.appendingPathComponent("receipt.json")
        guard fm.fileExists(atPath: receipt.path) else { return .baseline }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any] ?? [:]
            let marker = prefix.appendingPathComponent(".macsw-wine-prefix-id")
            guard let id = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  id == value["prefix_id"] as? String else { return .baseline }
            guard value["format"] as? Int == 1, let recorded = value["identity"] as? [String: String] else { return .invalid }
            let sameLocation = (value["active_app"] as? String).map { $0 == bundle.resolvingSymlinksInPath().path } ?? true
            return recorded == (try identity(contents: bundle.appendingPathComponent("Contents"))) && sameLocation ? .ready : .upgrade
        } catch { return .invalid }
    }

    /// MacSW's own bottle, or one with a Wine upgrade state directory next to it.
    public static func isManaged(prefix: URL) -> Bool {
        let fm = FileManager.default
        let main = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSW/bottle")
        return prefix.standardizedFileURL == main || fm.fileExists(atPath: root(prefix: prefix).path)
    }

    public static func canRollback(prefix: URL) -> Bool {
        do {
            let directory = root(prefix: prefix)
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("last-upgrade.json"))) as? [String: Any]
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("receipt.json"))) as? [String: Any]
            guard let previous = journal?["new_identity"] as? [String: String],
                  let current = receipt?["identity"] as? [String: String] else { return false }
            return previous == current
        } catch { return false }
    }

    /// Shared launch-lock protocol with wine_runtime.py. Hold only across
    /// preflight + Process.run, so explicit migration can stop existing hosts.
    static func withLaunchLock<T>(prefix: URL, checkIdentity: Bool = true, operation: () throws -> T) throws -> T {
        guard status(prefix: prefix) != .unmanaged else { return try operation() }
        let directory = root(prefix: prefix)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw failure("The Wine upgrade state directory cannot be a symbolic link.")
        }
        let fd = open(directory.appendingPathComponent("launch.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Could not open the Wine launch lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw failure("A Wine bottle upgrade is in progress.") }
        defer { flock(fd, LOCK_UN) }
        let state = status(prefix: prefix)
        guard !checkIdentity || state.allowsLaunch else { throw failure(state.message + " Open Settings → Maintenance.") }
        return try operation()
    }

    public static func perform(_ command: String, prefix: URL, bundle: URL = MacSWBundle.url) async throws -> String {
        try await Task.detached {
            let contents = bundle.appendingPathComponent("Contents")
            let resources = contents.appendingPathComponent("Resources/SWCLI")
            let process = Process()
            process.executableURL = resources.appendingPathComponent("runtime/PythonNative/bin/python3")
            // -B: never write bytecode into the signed bundle.
            process.arguments = ["-I", "-B", resources.appendingPathComponent("bin/wine_runtime.py").path,
                                 command, "--contents", contents.path, "--prefix", prefix.path]
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-wine-upgrade-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw failure("Could not create the migration log.") }
            defer { try? FileManager.default.removeItem(at: log) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: try Data(contentsOf: log), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw failure(message) }
            return message
        }.value
    }
}
