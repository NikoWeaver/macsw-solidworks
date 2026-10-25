import Foundation

/// macOS asks for consent the first time a process opens a file in ~/Desktop, ~/Documents or
/// ~/Downloads, in a cloud folder under ~/Library/CloudStorage (File Provider: Box, OneDrive,
/// Google Drive, Dropbox) or in iCloud Drive. If the first process to do so is a Wine client,
/// wineserver (single-threaded) waits on the prompt and every process in the bottle freezes. This
/// service makes the native app (MacSW, or SOLIDWORKS.app's launcher before it becomes the Wine
/// host) touch the folders the bottle links to, so the prompt appears while only native code waits.
public enum FolderConsentService {
    public struct ProtectedFolder: Equatable, Hashable, Sendable {
        public let name: String
        public let url: URL

        /// iCloud Drive or a folder of ~/Library/CloudStorage: the folders that drive maps bring
        /// into the bottle (`WineBottleGate` sets aside only links to these), as opposed to
        /// Desktop, Documents and Downloads.
        public var isCloud: Bool {
            url.lastPathComponent == "com~apple~CloudDocs" || url.deletingLastPathComponent().lastPathComponent == "CloudStorage"
        }
    }

    public enum Access: Equatable, Sendable {
        case granted
        /// The link points at a folder that does not exist (anymore); nothing to consent to.
        case missing
        case denied(String)
        /// Nobody answered the macOS prompt before the timeout.
        case noAnswer
    }

    public struct Check: Equatable, Sendable {
        public let folder: ProtectedFolder
        public let access: Access
    }

    /// The protected folders this process listed itself, with macOS's consent, since it started.
    /// Only those may stay behind a cloud drive letter or profile link when a Wine session of the
    /// bottle starts (`WineBottleGate`). A grant is remembered for the life of the process and not
    /// checked again: if the owner turns it off in System Settings meanwhile, the next access fails
    /// quietly (no prompt), so Wine cannot freeze on it, it only loses the folder; after
    /// `tccutil reset` the next access can prompt again, from Wine if Wine is first (not covered;
    /// the next start of the app checks again). A listing that macOS still holds (its prompt is on
    /// screen) is not started twice: a second check reports `.noAnswer` at once, and the late
    /// answer is recorded when it comes. Folders are keyed by `comparable` spelling, so
    /// `~/library/cloudstorage/box-box` and `~/Library/CloudStorage/Box-Box` are one folder.
    public final class Session: @unchecked Sendable {
        public static let current = Session()
        private let lock = NSLock()
        private var granted = Set<String>()
        private var listing = Set<String>()

        public init() {}

        private func key(_ folder: URL) -> String {
            FolderConsentService.comparable(folder.standardizedFileURL.path, caseSensitive: false)
        }

        public func isConfirmed(_ folder: URL) -> Bool {
            let key = key(folder)
            lock.lock()
            defer { lock.unlock() }
            return granted.contains(key)
        }

        /// False while an earlier listing of `folder` has not come back.
        func begin(_ folder: URL) -> Bool {
            let key = key(folder)
            lock.lock()
            defer { lock.unlock() }
            return listing.insert(key).inserted
        }

        func finish(_ folder: URL, _ access: Access) {
            let key = key(folder)
            lock.lock()
            defer { lock.unlock() }
            listing.remove(key)
            if access == .granted { granted.insert(key) }
        }
    }

    /// A path or name as the home volume compares it: APFS and HFS+ ignore Unicode normalization,
    /// and their default (case-insensitive) format also ignores case, so `~/documents` is
    /// `~/Documents` there.
    static func comparable(_ text: String, caseSensitive: Bool) -> String {
        let decomposed = text.decomposedStringWithCanonicalMapping
        return caseSensitive ? decomposed : decomposed.lowercased()
    }

    /// Whether the volume of `url` tells "Documents" from "documents" (`_PC_CASE_SENSITIVE`);
    /// false (the macOS default) when it cannot say.
    static func isCaseSensitive(_ url: URL) -> Bool {
        pathconf(url.path, _PC_CASE_SENSITIVE) == 1
    }

    public static let protectedNames = ["Desktop", "Documents", "Downloads"]

    /// The protected folders that the bottle's links point at or into: the
    /// `drive_c/users/<name>/` links of every account and the `dosdevices/<x>:` drive letters
    /// (B: -> Box, I: -> iCloud Drive, see `DriveMapService`), following symbolic links on the way
    /// (`~/Box` -> Box). Only symbolic links count; a real directory in the bottle needs no
    /// consent. A link to a folder that contains protected folders (H: -> home, Z: -> /) does not
    /// count, as Wine's Z: never did. Links set aside by `WineBottleGate` are not in the bottle.
    public static func protectedFolders(
        prefix: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [ProtectedFolder] {
        var found: [ProtectedFolder] = []
        for link in WineBottleGate.links(prefix: prefix, home: home, fileManager: fileManager) {
            if let folder = link.folder, !found.contains(folder) { found.append(folder) }
        }
        return found
    }

    /// The protected folder that `path` is or lies in, judged by the path alone: its name and its
    /// path below `home`, spelled the canonical way ("Documents", "Library/CloudStorage/<provider>",
    /// the provider as `path` spells it). Components compare as `comparable` does.
    private static func protectedRoot(of path: String, home: String, caseSensitive: Bool) -> (name: String, below: [String])? {
        let parts = path.split(separator: "/").map(String.init)
        let base = home.split(separator: "/").map(String.init)
        func starts(_ below: [String]) -> Bool {
            let root = base + below
            return parts.count >= root.count
                && zip(parts, root).allSatisfy { comparable($0, caseSensitive: caseSensitive) == comparable($1, caseSensitive: caseSensitive) }
        }
        for name in protectedNames where starts([name]) { return (name, [name]) }
        let iCloud = ["Library", "Mobile Documents", "com~apple~CloudDocs"]
        if starts(iCloud) { return (DriveMapService.iCloudDriveName, iCloud) }
        let storage = ["Library", "CloudStorage"]
        guard parts.count > base.count + storage.count, starts(storage) else { return nil }
        let provider = parts[base.count + storage.count]
        return (DriveMapService.providerName(provider), storage + [provider])
    }

    private static func folder(_ root: (name: String, below: [String]), home: URL) -> ProtectedFolder {
        let url = root.below.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
        return ProtectedFolder(name: root.name, url: url.standardizedFileURL)
    }

    /// The protected folder that `target` is or lies in: Desktop, Documents, Downloads, iCloud Drive
    /// or one folder of ~/Library/CloudStorage (named by its provider, "Box" for Box-Box).
    static func protectedFolder(containing target: URL, home: URL) -> ProtectedFolder? {
        let home = home.standardizedFileURL
        return protectedRoot(of: target.standardizedFileURL.path, home: home.path, caseSensitive: isCaseSensitive(home))
            .map { folder($0, home: home) }
    }

    /// The protected folder that a link to `target` reaches, following symbolic links on the way
    /// (`~/Box` -> `~/Library/CloudStorage/Box-Box`). It stops as soon as the path is in a
    /// protected folder, so it never looks at anything inside one (that could raise its macOS
    /// prompt); only folders outside them are read (`readlink`). A target that does not exist is
    /// judged by its path. Other spellings of the home folder count: its real path, the Data
    /// volume's name for it (`/System/Volumes/Data/Users/<me>`, a firmlink, which `realpath`
    /// keeps) and, on a case-insensitive volume, other cases and Unicode forms.
    static func protectedFolder(resolving target: URL, home: URL, fileManager: FileManager = .default) -> ProtectedFolder? {
        let given = home.standardizedFileURL
        let caseSensitive = isCaseSensitive(given)
        var homes = [given.path]
        if let physical = realpath(given.path, nil) {
            let resolved = String(cString: physical)
            free(physical)
            if !homes.contains(resolved) { homes.append(resolved) }
        }
        let data = "/System/Volumes/Data"
        for home in homes {
            let other = home.hasPrefix(data + "/") ? String(home.dropFirst(data.count)) : data + home
            if !homes.contains(other), isSameFile(other, home) { homes.append(other) }
        }
        func classify(_ path: String) -> ProtectedFolder? {
            for home in homes {
                // Reported under the home as given, so one folder always has one name.
                if let root = protectedRoot(of: path, home: home, caseSensitive: caseSensitive) { return folder(root, home: given) }
            }
            return nil
        }
        // Lexical "." and "..": `standardizedFileURL` would turn /private/var back into /var.
        func components(_ path: String) -> [String] {
            path.split(separator: "/").reduce(into: [String]()) { parts, part in
                if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
            }
        }
        func join(_ head: String, _ tail: [String]) -> String {
            let path = ([head] + tail).joined(separator: "/")
            return path.isEmpty ? "/" : path
        }
        var resolved = ""  // the part already read, free of symbolic links ("" is /)
        var rest = components(target.standardizedFileURL.path)
        var hops = 0
        while true {
            if let folder = classify(join(resolved, rest)) { return folder }
            guard !rest.isEmpty else { return nil }
            let next = resolved + "/" + rest.removeFirst()
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: next) else {
                resolved = next
                continue
            }
            hops += 1
            guard hops <= 32 else { return nil }
            let base = destination.hasPrefix("/") ? destination : (resolved.isEmpty ? "/" : resolved + "/") + destination
            rest = components(join(base, rest))
            resolved = ""
        }
    }

    private static func isSameFile(_ first: String, _ second: String) -> Bool {
        var a = stat(), b = stat()
        return stat(first, &a) == 0 && stat(second, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// Lists each folder in turn on a background queue. `onWaiting` fires if a folder is still
    /// pending after `announceAfter` seconds (the macOS prompt is probably on screen).
    /// A folder nobody answered for within `timeout` seconds is reported as `.noAnswer`.
    /// Every `.granted` folder is recorded in `session` (also one answered after the timeout).
    public static func check(
        _ folders: [ProtectedFolder],
        timeout: TimeInterval = 120,
        announceAfter: TimeInterval = 1,
        list: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.contentsOfDirectory(atPath: $0.path) },
        session: Session = .current,
        onWaiting: @escaping @Sendable (ProtectedFolder) -> Void
    ) async -> [Check] {
        var results: [Check] = []
        for folder in folders {
            guard let work = listing(folder, list: list, session: session) else {
                results.append(Check(folder: folder, access: .noAnswer))
                continue
            }
            let answer = await bounded(timeout: timeout, announceAfter: announceAfter,
                                       onWaiting: { onWaiting(folder) }, work: work)
            results.append(Check(folder: folder, access: answer ?? .noAnswer))
        }
        return results
    }

    /// `check` for a caller that must not return before it is done (`WineService.start`): blocks
    /// the calling thread, at most `timeout` seconds per folder.
    public static func checkBlocking(
        _ folders: [ProtectedFolder],
        timeout: TimeInterval,
        list: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.contentsOfDirectory(atPath: $0.path) },
        session: Session = .current
    ) -> [Check] {
        folders.map { folder -> Check in
            guard let work = listing(folder, list: list, session: session) else { return Check(folder: folder, access: .noAnswer) }
            let result = ResultBox<Access>()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                result.set(work())
                done.signal()
            }
            let finished = done.wait(timeout: .now() + timeout) == .success
            return Check(folder: folder, access: finished ? (result.value ?? .noAnswer) : .noAnswer)
        }
    }

    /// The listing of `folder`, which records its answer in `session`; nil while an earlier one
    /// has not come back.
    private static func listing(_ folder: ProtectedFolder, list: @escaping @Sendable (URL) throws -> Void,
                                session: Session) -> (@Sendable () -> Access)? {
        guard session.begin(folder.url) else { return nil }
        return {
            let answer = access(folder, list: list)
            session.finish(folder.url, answer)
            return answer
        }
    }

    private static func access(_ folder: ProtectedFolder, list: (URL) throws -> Void) -> Access {
        do {
            try list(folder.url)
            return .granted
        } catch let error as NSError {
            let missing = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            return missing ? .missing : .denied(error.localizedDescription)
        }
    }

    /// Runs `work` on a background queue and waits for it at most `timeout` seconds: nil when it
    /// did not finish in time (a macOS prompt nobody answered). The work itself is not cancelled.
    /// `onWaiting` fires once if it is still running after `announceAfter` seconds.
    public static func bounded<Value: Sendable>(
        timeout: TimeInterval,
        announceAfter: TimeInterval = 1,
        onWaiting: @escaping @Sendable () -> Void = {},
        work: @escaping @Sendable () -> Value
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = Once(continuation)
            DispatchQueue.global(qos: .userInitiated).async { once.finish(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + announceAfter) {
                if !once.isFinished { onWaiting() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(nil) }
        }
    }

    /// The folders SOLIDWORKS will not be able to use, for the status line.
    public static func unavailableSummary(_ checks: [Check]) -> String? {
        let names = checks.filter {
            switch $0.access {
            case .denied, .noAnswer: return true
            case .granted, .missing: return false
            }
        }.map(\.folder.name)
        guard !names.isEmpty else { return nil }
        return "macOS did not allow access to your \(names.joined(separator: ", ")) folder. SOLIDWORKS will not be able to open or save files there; allow MacSW in System Settings → Privacy & Security → Files and Folders."
    }

    public static func waitingMessage(for folder: ProtectedFolder) -> String {
        "macOS is asking for permission to access your \(folder.name) folder — click Allow so SOLIDWORKS can open and save files there."
    }

    /// Appends one line per run to `folder-consent.log`.
    public static func appendLog(_ checks: [Check], to log: URL) {
        let text = checks.map { "\($0.folder.name)=\($0.access)" }.joined(separator: " ")
        LogFiles.append("\(ISO8601DateFormatter().string(from: Date())) \(text.isEmpty ? "(no protected folders linked)" : text)\n", to: log)
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
        var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class Once<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
        func finish(_ value: Value?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
