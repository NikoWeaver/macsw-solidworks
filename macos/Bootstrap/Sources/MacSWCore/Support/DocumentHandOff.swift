import CoreGraphics
import Foundation

/// A macOS window as seen from outside Wine (owner pid, layer and size only; no title, so no
/// Screen Recording permission is needed).
public struct HostWindow: Equatable, Sendable {
    public let ownerPID: Int32
    public let layer: Int
    public let width: Double
    public let height: Double

    public init(ownerPID: Int32, layer: Int, width: Double, height: Double) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.width = width
        self.height = height
    }
}

public enum HostWindowInspector {
    /// All windows (including minimized ones) owned by the given processes.
    public static func windows(ownedBy pids: [Int32]) -> [HostWindow] {
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let wanted = Set(pids)
        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, wanted.contains(pid),
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
            return HostWindow(ownerPID: pid, layer: layer, width: width, height: height)
        }
    }
}

public enum SolidWorksReadiness: Equatable, Sendable {
    /// No SLDWORKS.exe process.
    case notRunning
    /// SLDWORKS.exe exists but shows no main-sized window yet (splash, license check, loading).
    case starting
    /// A main-sized window exists: SOLIDWORKS can take documents.
    case ready
}

public enum DocumentHandOffAction: Equatable, Sendable {
    /// Start SOLIDWORKS with the documents as command-line arguments.
    case coldStart
    /// Keep the documents queued until SOLIDWORKS is ready.
    case waitForReadiness
    /// Pass the documents to the running instance.
    case handOffToRunning
}

public enum DocumentHandOffPoll: Equatable, Sendable {
    case handOff
    case keepWaiting
    /// SOLIDWORKS never appeared (or went away); drop the queue.
    case abandon
}

/// Pure decisions for opening documents in SOLIDWORKS. No Wine, no timers: callers feed it observations.
public enum DocumentHandOff {
    /// Smaller windows are treated as splash screens or tool windows.
    public static let minimumMainWindowSize = (width: 640.0, height: 480.0)
    public static let pollInterval: TimeInterval = 2
    /// Without a readiness signal the hand-off goes ahead after this long (windows may be undetectable).
    public static let readinessTimeout: TimeInterval = 240
    /// How long a missing SLDWORKS.exe is tolerated while a launch is in flight.
    public static let startGrace: TimeInterval = 30

    public static func readiness(processes: [WineProcess], windows: [HostWindow]) -> SolidWorksReadiness {
        let pids = processes
            .filter { $0.name.caseInsensitiveCompare(ProcessInventory.primaryProcess) == .orderedSame }
            .map(\.pid)
        guard !pids.isEmpty else { return .notRunning }
        let hasMainWindow = windows.contains {
            pids.contains($0.ownerPID) && $0.layer == 0
                && $0.width >= minimumMainWindowSize.width && $0.height >= minimumMainWindowSize.height
        }
        return hasMainWindow ? .ready : .starting
    }

    public static func action(readiness: SolidWorksReadiness, launchInFlight: Bool) -> DocumentHandOffAction {
        switch readiness {
        case .ready: return .handOffToRunning
        case .starting: return .waitForReadiness
        case .notRunning: return launchInFlight ? .waitForReadiness : .coldStart
        }
    }

    public static func pollDecision(readiness: SolidWorksReadiness, waited: TimeInterval) -> DocumentHandOffPoll {
        switch readiness {
        case .ready: return .handOff
        case .starting: return waited >= readinessTimeout ? .handOff : .keepWaiting
        case .notRunning: return waited >= startGrace ? .abandon : .keepWaiting
        }
    }

    /// `wine start /unix <file>`: Wine's ShellExecute uses the open verb or DDE command SOLIDWORKS registered,
    /// so the running instance receives the file instead of a second SLDWORKS.exe starting.
    /// With `windowsPath` (a file in a linked profile folder) it is `wine start C:\users\<user>\...`:
    /// `/unix` would give the file its `Z:\Users\...` alias, and SOLIDWORKS then refuses the same file
    /// opened later through `C:\users\...` ("a document with the same name is already open").
    public static func startArguments(for file: URL, windowsPath: String? = nil) -> [String] {
        if let windowsPath { return ["start", windowsPath] }
        return ["start", "/unix", file.standardizedFileURL.path]
    }

    /// One `wine start` command per file, using the profile path for files in linked folders.
    public static func startArguments(for files: [URL], prefix: URL, userName: String = NSUserName()) -> [[String]] {
        let drives = WineDocumentPath.drives(in: prefix)
        let links = WineDocumentPath.folderLinks(in: prefix, userName: userName)
        return files.map { file in
            startArguments(for: file,
                           windowsPath: WineDocumentPath.linkedFolderPath(for: file, drives: drives, folderLinks: links))
        }
    }
}
