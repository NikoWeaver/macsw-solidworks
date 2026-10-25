import Darwin
import Foundation

/// No Wine session of a managed bottle starts while a drive letter (`dosdevices/<x>:`) or a
/// profile link (`drive_c/users/<account>/<name>`) points into a cloud folder (iCloud Drive, a
/// folder of ~/Library/CloudStorage) that the current process has not opened itself, with macOS's
/// consent, since it started. These are the mappings drive maps add (`DriveMapService`), and the
/// same ones made by hand.
///
/// Why: when a Wine session starts, Wine's mountmgr (winedevice.exe) opens the root of every
/// drive letter (`.windows-label`, `.windows-serial`: dlls/mountmgr.sys/device.c, called from
/// `disk_driver_entry`), and SOLIDWORKS can open a profile link at any time. If a Wine process is
/// the first to open a protected folder, macOS shows its prompt for Wine's responsible app and
/// wineserver waits for the answer. MacSW starts Wine as soon as it opens (font link, SWCLI), and
/// a new build of MacSW or SOLIDWORKS.app (another app) has no grant yet.
///
/// How: `prepare` lists each such folder natively first (at most `timeout` seconds each, the
/// macOS prompt belongs to this process then). A link to a cloud folder that macOS did not let
/// this process open (denied, no answer, or gone) is set aside: moved, unchanged, to
/// `<prefix>/.macsw-held/<same path>`, where Wine never looks. A later `prepare` in a process
/// that may open the folder moves it back. `guardWineStart` runs before every Wine process MacSW
/// starts and does the same without waiting for held folders again.
///
/// Never moved: links that point elsewhere (C:, H:, Z:, a project folder); links into Desktop,
/// Documents or Downloads (`prepare` lists those natively first, as before drive maps, and
/// leaves them); and the profile's Desktop, Documents, Downloads, Music, Pictures and Videos
/// whatever they point at. Wine makes those six again as links to `$HOME/<folder>` as soon as
/// one is missing (shell32 `SHGetFolderPath` with `CSIDL_FLAG_CREATE` -> mountmgr
/// `set_shell_folder`, also `wineboot -u`), so setting one aside would not keep Wine out.
///
/// While a Wine session of the bottle runs (`sessionRunning`), no link moves in either
/// direction: mountmgr read the drive roots when that session started, Wine resolves
/// `dosdevices/<x>:` at every path, so taking a letter away would break `B:\...` in the running
/// SOLIDWORKS, and a letter moved back would reach a folder that the app which started the
/// session (maybe another one) was never let into. Held links come back at the next start of a
/// session.
public enum WineBottleGate {
    public static let heldDirectoryName = ".macsw-held"
    static let lockFileName = ".macsw-held.lock"
    public static let defaultTimeout: TimeInterval = 120
    /// `guardWineStart` (inside `WineService.start`) waits less: the stores ran `prepare` first.
    public static let backstopTimeout: TimeInterval = 10
    /// How long `sessionRunning` waits for the lock of a wineserver that takes no clients to clear
    /// (shutting down: up to 4 s plus the registry save, server/process.c). A lock still held
    /// then counts as a running session.
    public static let sessionEndWait: TimeInterval = 8
    /// Profile folders that Wine links to `$HOME/<folder>` again when they are missing
    /// (dlls/shell32/shellpath.c `_SHCreateSymbolicLink`).
    static let shellFolders: Set<String> = ["desktop", "documents", "downloads", "music", "pictures", "videos"]

    /// A symbolic link that Wine reads by itself.
    public struct Link: Equatable, Sendable {
        /// Path in the bottle: "dosdevices/b:" or "drive_c/users/me/Box".
        public let item: String
        /// The link's text, unchanged when it is set aside and moved back.
        public let destination: String
        /// The protected folder it reaches; nil only for a held link that no longer reaches one.
        public let folder: FolderConsentService.ProtectedFolder?

        /// Set aside when this process may not open its folder: a link into a cloud folder,
        /// except the profile's shell folders (Wine makes those again at once).
        public var isGated: Bool {
            guard folder?.isCloud == true else { return false }
            let parts = item.split(separator: "/")
            let isShellFolder = parts.count == 4 && parts[0] == "drive_c" && parts[1] == "users"
                && WineBottleGate.shellFolders.contains(parts[3].lowercased())
            return !isShellFolder
        }
    }

    public struct Report: Equatable, Sendable {
        public var checks: [FolderConsentService.Check] = []
        /// A Wine session of the bottle ran: no link was moved.
        public var sessionRunning = false
        public var setAside: [Link] = []
        public var restored: [Link] = []
        /// Everything in `.macsw-held` after this run.
        public var stillHeld: [Link] = []
        /// Held links that cannot go back: their name is used by a file, a link or a folder.
        public var blocked: [Link] = []
        /// Links that could not be set aside. Wine must not start then.
        public var failed: [Link] = []

        public init() {}

        var changed: Bool {
            !setAside.isEmpty || !restored.isEmpty || !blocked.isEmpty || !failed.isEmpty
        }
    }

    public static let defaultList: @Sendable (URL) throws -> Void = { _ = try FileManager.default.contentsOfDirectory(atPath: $0.path) }

    // MARK: - The step

    /// Lists every protected folder that a present or held link reaches and that this process has
    /// not opened yet (`session`): Desktop, Documents and Downloads too, so their macOS prompts
    /// come from this process. Then sets aside the gated links (`Link.isGated`) to folders macOS
    /// refused and moves back the held links to folders it allowed, unless a Wine session of the
    /// bottle runs. `onWaiting` fires while a prompt is probably on screen. Appends one line to
    /// `log` when it checked or moved something.
    public static func prepare(
        prefix: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = defaultTimeout,
        session: FolderConsentService.Session = .current,
        isRunning: @escaping @Sendable (URL) -> Bool = { sessionRunning(prefix: $0) },
        list: @escaping @Sendable (URL) throws -> Void = defaultList,
        onWaiting: @escaping @Sendable (FolderConsentService.ProtectedFolder) -> Void = { _ in },
        log: URL? = nil
    ) async -> Report {
        let folders = foldersToCheck(prefix: prefix, home: home, session: session, includeHeld: true, gatedOnly: false)
        let checks = await FolderConsentService.check(folders, timeout: timeout, list: list, session: session,
                                                      onWaiting: onWaiting)
        // Off the caller's thread: it can wait for a wineserver that is shutting down.
        let running = await Task.detached { isRunning(prefix) }.value
        var report = apply(prefix: prefix, home: home, session: session, sessionRunning: running)
        report.checks = checks
        if let log, !checks.isEmpty || report.changed { appendLog(report, to: log) }
        return report
    }

    /// The last check before a Wine process of a managed bottle starts (`WineService.start`,
    /// `execSolidWorks`; never for wineserver, which opens no drive). Blocks the calling thread:
    /// gated links that are new since the last `prepare` are listed (at most `timeout` seconds
    /// each), held links are not listed again. Throws when a link could not be set aside.
    public static func guardWineStart(
        prefix: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = backstopTimeout,
        session: FolderConsentService.Session = .current,
        isRunning: (URL) -> Bool = { sessionRunning(prefix: $0) },
        list: @escaping @Sendable (URL) throws -> Void = defaultList,
        log: URL? = nil
    ) throws {
        guard WineRuntimeService.isManaged(prefix: prefix) else { return }
        var checks: [FolderConsentService.Check] = []
        if !isRunning(prefix) {
            let folders = foldersToCheck(prefix: prefix, home: home, session: session, includeHeld: false, gatedOnly: true)
            checks = FolderConsentService.checkBlocking(folders, timeout: timeout, list: list, session: session)
        }
        // Asked again: a session that ended meanwhile means this process starts the next one.
        var report = apply(prefix: prefix, home: home, session: session, sessionRunning: isRunning(prefix))
        report.checks = checks
        if let log, !checks.isEmpty || report.changed { appendLog(report, to: log) }
        guard report.failed.isEmpty else {
            throw MacSWError.make("MacSW could not set aside \(report.failed.map(\.item).joined(separator: ", ")) in the bottle, so Wine was not started (macOS has not let MacSW open \(Set(report.failed.compactMap(\.folder?.name)).sorted().joined(separator: ", ")) yet).",
                                  domain: "MacSW.WineBottleGate")
        }
    }

    /// The folders to list natively: reached by a present link (or a held one when `includeHeld`;
    /// only by gated links when `gatedOnly`) and not opened by this process yet, each once.
    static func foldersToCheck(prefix: URL, home: URL, session: FolderConsentService.Session, includeHeld: Bool,
                               gatedOnly: Bool, fileManager: FileManager = .default) -> [FolderConsentService.ProtectedFolder] {
        var folders: [FolderConsentService.ProtectedFolder] = []
        var seen = Set<String>()
        let held = includeHeld ? heldLinks(prefix: prefix, home: home, fileManager: fileManager) : []
        for link in links(prefix: prefix, home: home, fileManager: fileManager) + held where link.isGated || !gatedOnly {
            guard let folder = link.folder, !session.isConfirmed(folder.url),
                  seen.insert(FolderConsentService.comparable(folder.url.path, caseSensitive: false)).inserted else { continue }
            folders.append(folder)
        }
        return folders
    }

    /// Unless a Wine session of the bottle runs (then nothing moves): sets aside every present
    /// gated link to a folder `session` has not confirmed, and moves back every held link that is
    /// not such a link. File system only; never opens a protected folder. Serialized with other
    /// processes by a lock file.
    public static func apply(prefix: URL, home: URL, session: FolderConsentService.Session, sessionRunning: Bool,
                             fileManager: FileManager = .default) -> Report {
        var report = Report()
        report.sessionRunning = sessionRunning
        let held = heldLinks(prefix: prefix, home: home, fileManager: fileManager)
        func blocked(_ link: Link) -> Bool { link.isGated && link.folder.map { !session.isConfirmed($0.url) } == true }
        let toHold = sessionRunning ? [] : links(prefix: prefix, home: home, fileManager: fileManager).filter(blocked)
        guard !sessionRunning, !toHold.isEmpty || held.contains(where: { !blocked($0) }) else {
            report.stillHeld = held
            return report
        }
        guard let lock = lockBottle(prefix) else {
            report.failed = toHold
            report.stillHeld = held
            return report
        }
        defer { flock(lock, LOCK_UN); close(lock) }
        // Again under the lock: another process may have moved links meanwhile.
        for link in links(prefix: prefix, home: home, fileManager: fileManager) where blocked(link) {
            setAside(link, prefix: prefix, fileManager: fileManager, report: &report)
        }
        for link in heldLinks(prefix: prefix, home: home, fileManager: fileManager) where !blocked(link) {
            restore(link, prefix: prefix, fileManager: fileManager, report: &report)
        }
        report.stillHeld = heldLinks(prefix: prefix, home: home, fileManager: fileManager)
        return report
    }

    // MARK: - Links

    /// The links in the bottle that reach a protected folder, profile links first.
    public static func links(prefix: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             fileManager: FileManager = .default) -> [Link] {
        items(under: prefix, fileManager: fileManager).compactMap {
            link($0, at: prefix.appendingPathComponent($0), prefix: prefix, home: home, fileManager: fileManager)
        }.filter { $0.folder != nil }
    }

    /// The links set aside in `<prefix>/.macsw-held`.
    public static func heldLinks(prefix: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 fileManager: FileManager = .default) -> [Link] {
        let held = prefix.appendingPathComponent(heldDirectoryName, isDirectory: true)
        return items(under: held, fileManager: fileManager).compactMap {
            link($0, at: held.appendingPathComponent($0), prefix: prefix, home: home, fileManager: fileManager)
        }
    }

    /// The held links of one bottle folder ("dosdevices", "drive_c/users/me"): name -> absolute
    /// target, so `DriveMapService` keeps their letters and names taken while they are away.
    public static func heldTargets(prefix: URL, directory: String, fileManager: FileManager = .default) -> [String: String] {
        let held = prefix.appendingPathComponent(heldDirectoryName, isDirectory: true).appendingPathComponent(directory)
        let original = prefix.appendingPathComponent(directory, isDirectory: true)
        var targets: [String: String] = [:]
        for name in (try? fileManager.contentsOfDirectory(atPath: held.path)) ?? [] {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: held.appendingPathComponent(name).path)
            else { continue }
            targets[name] = URL(fileURLWithPath: destination, relativeTo: original).standardizedFileURL.path
        }
        return targets
    }

    /// "x:" is a drive letter ("x::" is its device node).
    static func isDriveName(_ name: String) -> Bool {
        name.count == 2 && name.hasSuffix(":") && name.first.map { $0.isASCII && $0.isLetter } == true
    }

    /// Paths, relative to `root`, of every entry of a profile folder and of every drive letter.
    private static func items(under root: URL, fileManager: FileManager) -> [String] {
        var items: [String] = []
        let users = root.appendingPathComponent("drive_c/users", isDirectory: true)
        for account in ((try? fileManager.contentsOfDirectory(atPath: users.path)) ?? []).sorted() {
            let folder = users.appendingPathComponent(account, isDirectory: true)
            for name in ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
                items.append("drive_c/users/\(account)/\(name)")
            }
        }
        let dosdevices = root.appendingPathComponent("dosdevices", isDirectory: true)
        for name in ((try? fileManager.contentsOfDirectory(atPath: dosdevices.path)) ?? []).sorted() where isDriveName(name) {
            items.append("dosdevices/\(name)")
        }
        return items
    }

    /// The link at `url` (in the bottle or held), its target taken relative to where it belongs.
    private static func link(_ item: String, at url: URL, prefix: URL, home: URL, fileManager: FileManager) -> Link? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let directory = prefix.appendingPathComponent(item).deletingLastPathComponent()
        let target = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
        return Link(item: item, destination: destination,
                    folder: FolderConsentService.protectedFolder(resolving: target, home: home, fileManager: fileManager))
    }

    // MARK: - Moving links

    private static func setAside(_ link: Link, prefix: URL, fileManager: FileManager, report: inout Report) {
        let source = prefix.appendingPathComponent(link.item)
        let target = prefix.appendingPathComponent(heldDirectoryName).appendingPathComponent(link.item)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            report.failed.append(link)
            return
        }
        // rename(2) of the link itself, on one volume; a link held under this name before is
        // replaced (the same link again, or an older one that this newer link took the name of).
        if rename(source.path, target.path) == 0 {
            report.setAside.append(link)
        } else {
            report.failed.append(link)
        }
    }

    private static func restore(_ link: Link, prefix: URL, fileManager: FileManager, report: inout Report) {
        let source = prefix.appendingPathComponent(heldDirectoryName).appendingPathComponent(link.item)
        let target = prefix.appendingPathComponent(link.item)
        var info = stat()
        if lstat(target.path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                // The same link was made again meanwhile.
                if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) == link.destination,
                   unlink(source.path) == 0 {
                    report.restored.append(link)
                } else {
                    report.blocked.append(link)
                }
                return
            case S_IFDIR:
                // An empty folder makes room (rmdir fails on anything else).
                guard rmdir(target.path) == 0 else { report.blocked.append(link); return }
            default:
                report.blocked.append(link)
                return
            }
        } else if errno != ENOENT || !isDirectory(target.deletingLastPathComponent(), fileManager) {
            report.blocked.append(link)
            return
        }
        if rename(source.path, target.path) == 0 {
            report.restored.append(link)
        } else {
            report.blocked.append(link)
        }
    }

    private static func lockBottle(_ prefix: URL) -> Int32? {
        let fd = open(prefix.appendingPathComponent(lockFileName).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX) == 0 else { close(fd); return nil }
        return fd
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Wine session

    /// Whether a Wine session of `prefix` runs: its wineserver holds a write lock on
    /// `/tmp/.wine-<uid>/server-<device>-<inode>/lock` for as long as it lives (server/request.c,
    /// `acquire_lock`; the name comes from the prefix folder, dlls/ntdll/unix/server.c
    /// `init_server_dir`). While that lock is held this is true (fail safe: no link moves); only
    /// a cleared lock means no session. No new session can start while it is held (the server
    /// that holds it owns the bottle; a Wine process started then waits for it to exit), and the
    /// next start after it clears is gated as usual. A server that takes a test connection on
    /// `socket` next to the lock answers at once. One that does not (shutting down: it closes the
    /// socket first and keeps the lock for seconds more, `close_master_socket`, then the registry
    /// save; or frozen on a macOS prompt with its `listen(5)` backlog full, so connects are
    /// refused) is waited for up to `endWait` seconds: false if the lock clears meanwhile, true
    /// otherwise. Never creates a file. The test connection makes wineserver count a client for a
    /// moment, which can put off the end of an idle session by its 3 s grace time.
    public static func sessionRunning(prefix: URL, serverRoot: String = "/tmp/.wine-\(getuid())",
                                      endWait: TimeInterval = sessionEndWait) -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let device = String(UInt64(bitPattern: Int64(info.st_dev)), radix: 16)
        let inode = String(UInt64(info.st_ino), radix: 16)
        let directory = "\(serverRoot)/server-\(device)-\(inode)"
        let deadline = Date().addingTimeInterval(endWait)
        while isLocked(directory + "/lock") {
            if acceptsConnection(directory + "/socket") { return true }
            // Still held: a live server, maybe frozen with a full listen backlog.
            guard Date() < deadline else { return true }
            usleep(100_000)
        }
        return false
    }

    /// Before a SOLIDWORKS launch (SOLIDWORKS known not to run): a short Wine helper started just
    /// before (the font-link check) leaves an idle wineserver for a few seconds, which
    /// `sessionRunning` must count as a session. Waits up to `timeout` for such a server to end, so
    /// the drive letters and held links are maintained on this launch, not skipped. Returns whether
    /// a session is still running afterwards.
    public static func waitForIdleSessionEnd(prefix: URL, timeout: TimeInterval = 10,
                                             isRunning: (URL) -> Bool = { sessionRunning(prefix: $0, endWait: 0.5) }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning(prefix) {
            guard Date() < deadline else { return true }
            usleep(250_000)
        }
        return false
    }

    /// Whether another process holds the write lock on the first byte of `path`, as wineserver does.
    private static func isLocked(_ path: String) -> Bool {
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var query = flock(l_start: 0, l_len: 1, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &query) == 0 else { return false }
        return query.l_type != Int16(F_UNLCK)
    }

    /// Whether a server listens on the Unix socket at `path` (connects, then closes at once).
    private static func acceptsConnection(_ path: String) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0 || errno == EINPROGRESS
    }

    // MARK: - Messages

    /// For the status line: the folders SOLIDWORKS cannot use and the letters set aside.
    public static func notice(_ report: Report) -> String? {
        var parts: [String] = []
        if let unavailable = FolderConsentService.unavailableSummary(report.checks) {
            parts.append(unavailable)
            let refused = Set(report.checks.filter { $0.access != .granted && $0.access != .missing }.map(\.folder))
            let letters = report.stillHeld.filter { $0.item.hasPrefix("dosdevices/") && $0.folder.map(refused.contains) == true }
                .map { String($0.item.dropFirst("dosdevices/".count)).uppercased() }
            if !letters.isEmpty {
                parts.append("\(letters.joined(separator: ", ")) \(letters.count == 1 ? "is" : "are") unavailable until then.")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One line per run in `folder-consent.log`.
    public static func appendLog(_ report: Report, to log: URL) {
        var parts = [report.checks.isEmpty ? "(nothing to check)" : report.checks.map { "\($0.folder.name)=\($0.access)" }.joined(separator: " ")]
        if report.sessionRunning { parts.append("Wine session running") }
        func items(_ label: String, _ values: [String]) {
            if !values.isEmpty { parts.append("\(label): \(values.joined(separator: ", "))") }
        }
        items("set aside", report.setAside.map(\.item))
        items("moved back", report.restored.map(\.item))
        items("cannot move back", report.blocked.map(\.item))
        items("could not set aside", report.failed.map(\.item))
        items("set aside now", report.stillHeld.map(\.item))
        LogFiles.append("\(ISO8601DateFormatter().string(from: Date())) \(parts.joined(separator: "; "))\n", to: log)
    }
}
