import Darwin
import Foundation

/// One SOLIDWORKS start at a time per bottle (bughunt F4). MacSW and each SOLIDWORKS.app launch
/// are separate processes, so `RuntimeStore.launch()` runs its last "is SOLIDWORKS running?" check
/// and the start under an exclusive `flock` on `start.lock`:
/// - MacSW releases it after `Process.run()` returned: the child exists and `ps` names SLDWORKS.exe.
/// - SOLIDWORKS.app does not release it. The descriptor is close-on-exec, so the exec that makes the
///   launcher the Wine host releases it at the moment the host exists.
/// Lock order: `start.lock`, then `launch.lock` (`WineRuntimeService.withLaunchLock`, shared and
/// non-blocking). A migration (wine_runtime.py) takes only `launch.lock`, so the two cannot deadlock.
public final class StartLock: @unchecked Sendable {
    public enum Outcome: Sendable {
        case acquired(StartLock)
        /// Another start held the lock for the whole wait.
        case busy
        /// The lock file could not be opened (the reason). The start goes on without it, as before F4.
        case unavailable(String)
    }

    /// How long a start waits for another one. Normally the lock is held for well under a second.
    public static let timeout: TimeInterval = 15
    public static let busyMessage = "Another start of SOLIDWORKS in this bottle did not finish within 15 s."

    /// A managed bottle: next to `launch.lock`. An unmanaged one: next to the bottle. The upgrade
    /// state directory is never made for it, because that directory makes a bottle managed.
    public static func url(prefix: URL) -> URL {
        url(prefix: prefix, managed: WineRuntimeService.isManaged(prefix: prefix))
    }

    private static func url(prefix: URL, managed: Bool) -> URL {
        managed ? WineRuntimeService.root(prefix: prefix).appendingPathComponent("start.lock")
            : prefix.deletingLastPathComponent().appendingPathComponent(".\(prefix.lastPathComponent).start.lock")
    }

    /// Waits up to `timeout` for the lock (it blocks: call it off the main thread).
    public static func acquire(prefix: URL, timeout: TimeInterval = timeout) -> Outcome {
        let managed = WineRuntimeService.isManaged(prefix: prefix)
        let file = url(prefix: prefix, managed: managed)
        if managed {
            let directory = file.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // The same rule as launch.lock (whose check then refuses the start).
                if (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                    return .unavailable("the Wine upgrade state directory is a symbolic link")
                }
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else {
                close(fd)
                return .unavailable(String(cString: strerror(failure)))
            }
            guard Date() < deadline else {
                close(fd)
                return .busy
            }
            usleep(50_000)
        }
        return .acquired(StartLock(descriptor: fd))
    }

    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// -1 after `release()`.
    public var fileDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return descriptor
    }

    /// Idempotent. Closing the descriptor (the only reference: it is close-on-exec) unlocks.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
