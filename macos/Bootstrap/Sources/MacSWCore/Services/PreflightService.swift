import Darwin
import Foundation

/// The checks of the team first-run wizard before anything is copied or installed
/// (docs/team-admin.md): an Apple silicon Mac, macOS 13 to 27, Rosetta, enough free disk space
/// and, as a note only, the memory. `evaluate` is pure, so the rules are tested with made-up facts.
public enum PreflightService {
    public enum Item: String, CaseIterable, Sendable {
        case appleSilicon
        case macOSVersion
        case rosetta
        case freeSpace
        case memory

        public var title: String {
            switch self {
            case .appleSilicon: return "Apple silicon"
            case .macOSVersion: return "macOS version"
            case .rosetta: return "Rosetta"
            case .freeSpace: return "Free disk space"
            case .memory: return "Memory"
            }
        }
    }

    public enum Verdict: String, Sendable {
        case passed
        /// Shown to the member, but the install can go on.
        case note
        /// The install cannot start until this is fixed.
        case blocked
    }

    public struct Check: Equatable, Identifiable, Sendable {
        public let item: Item
        public let verdict: Verdict
        public let message: String

        public var id: Item { item }
    }

    public struct Facts: Sendable {
        public var isAppleSilicon: Bool
        public var macOSVersion: OperatingSystemVersion
        public var rosettaInstalled: Bool
        /// Free space on the volume of MacSW's Application Support folder; nil when unknown.
        public var freeBytes: Int64?
        public var physicalMemory: UInt64

        public init(isAppleSilicon: Bool, macOSVersion: OperatingSystemVersion, rosettaInstalled: Bool,
                    freeBytes: Int64?, physicalMemory: UInt64) {
            self.isAppleSilicon = isAppleSilicon
            self.macOSVersion = macOSVersion
            self.rosettaInstalled = rosettaInstalled
            self.freeBytes = freeBytes
            self.physicalMemory = physicalMemory
        }
    }

    public static let oldestMacOS = 13
    /// Apple keeps full Rosetta through macOS 27; macOS 28 keeps only a part of it, and the whole
    /// Wine runtime is x86_64.
    public static let newestMacOS = 27
    /// The media copy (9-20 GB), the bottle (about 8-10 GB) and the app (0.9 GB), with room to spare.
    public static let minimumFreeBytes: Int64 = 40_000_000_000
    public static let recommendedMemory: UInt64 = 16 << 30
    /// For the member to run in Terminal when Apple's dialog does not appear. MacSW never runs it
    /// with `--agree-to-license`: the member accepts Apple's licence in Apple's own dialog or prompt.
    public static let rosettaInstallCommand = "softwareupdate --install-rosetta"
    /// The app that shows Apple's "install Rosetta" dialog.
    public static let rosettaUpdater = URL(fileURLWithPath: "/System/Library/CoreServices/Rosetta 2 Updater.app")

    /// `alreadyCopiedBytes`: bytes of the media copy that are already on this Mac (they no longer
    /// need free space), so a second run after a failed install does not block on the copy itself.
    public static func evaluate(_ facts: Facts, alreadyCopiedBytes: Int64 = 0) -> [Check] {
        var checks: [Check] = []
        checks.append(facts.isAppleSilicon
            ? Check(item: .appleSilicon, verdict: .passed, message: "This Mac has Apple silicon.")
            : Check(item: .appleSilicon, verdict: .blocked, message: "MacSW needs a Mac with Apple silicon (M1 or later)."))

        let version = facts.macOSVersion
        let versionText = "\(version.majorVersion).\(version.minorVersion)"
        if version.majorVersion < oldestMacOS {
            checks.append(Check(item: .macOSVersion, verdict: .blocked,
                                message: "macOS \(versionText) is too old. MacSW needs macOS \(oldestMacOS) or later."))
        } else if version.majorVersion > newestMacOS {
            checks.append(Check(item: .macOSVersion, verdict: .blocked,
                                message: "macOS \(versionText) is not supported. From macOS 28, Apple keeps only a part of Rosetta, and SOLIDWORKS runs through Rosetta. Use macOS \(newestMacOS) or earlier."))
        } else {
            checks.append(Check(item: .macOSVersion, verdict: .passed, message: "macOS \(versionText) is supported."))
        }

        checks.append(facts.rosettaInstalled
            ? Check(item: .rosetta, verdict: .passed, message: "Rosetta is installed.")
            : Check(item: .rosetta, verdict: .blocked,
                    message: "Rosetta is not installed. SOLIDWORKS runs through Rosetta. Click Install Rosetta, or run \"\(rosettaInstallCommand)\" in Terminal."))

        let required = max(minimumFreeBytes - max(alreadyCopiedBytes, 0), 0)
        if let free = facts.freeBytes {
            checks.append(free >= required
                ? Check(item: .freeSpace, verdict: .passed, message: "\(bytes(free)) free.")
                : Check(item: .freeSpace, verdict: .blocked,
                        message: "\(bytes(free)) free, but MacSW needs \(bytes(required)): the media copy, the bottle and the app. Free some space, then check again."))
        } else {
            checks.append(Check(item: .freeSpace, verdict: .note,
                                message: "MacSW could not read the free disk space. It needs about \(bytes(required))."))
        }

        checks.append(facts.physicalMemory >= recommendedMemory
            ? Check(item: .memory, verdict: .passed, message: "\(memory(facts.physicalMemory)) of memory.")
            : Check(item: .memory, verdict: .note,
                    message: "This Mac has \(memory(facts.physicalMemory)) of memory. 16 GB or more is recommended: large assemblies can be slow."))
        return checks
    }

    public static func isBlocked(_ checks: [Check]) -> Bool {
        checks.contains { $0.verdict == .blocked }
    }

    /// Reads the facts of this Mac. The Rosetta probe starts one short process, so call it off
    /// the main actor. `run` returns the exit status, or nil when the program could not start.
    public static func gatherFacts(
        volume: URL,
        processInfo: ProcessInfo = .processInfo,
        run: (URL, [String]) -> Int32? = runProcess
    ) -> Facts {
        Facts(
            isAppleSilicon: isAppleSilicon(),
            macOSVersion: processInfo.operatingSystemVersion,
            rosettaInstalled: rosettaInstalled(run: run),
            freeBytes: freeBytes(at: volume),
            physicalMemory: processInfo.physicalMemory
        )
    }

    /// True on Apple silicon, also when this process itself runs under Rosetta.
    static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// `arch -x86_64 /usr/bin/true` runs only when Rosetta can translate it.
    static func rosettaInstalled(run: (URL, [String]) -> Int32?) -> Bool {
        run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"]) == 0
    }

    public static func freeBytes(at volume: URL) -> Int64? {
        guard let values = try? volume.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Opens Apple's Rosetta installer; the member answers its dialog. False when it could not be
    /// opened: then the member runs `rosettaInstallCommand` in Terminal.
    public static func startRosettaInstall(fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: rosettaUpdater.path) else { return false }
        return runProcess(URL(fileURLWithPath: "/usr/bin/open"), [rosettaUpdater.path]) == 0
    }

    public static func runProcess(_ executable: URL, _ arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Memory in binary units, as Apple sells it: 16 GB is 16 GiB.
    private static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }
}
