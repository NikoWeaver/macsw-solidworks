import CoreServices
import CryptoKit
import Darwin
import Foundation
import Security

/// "Install SOLIDWORKS App" (docs/solidworks-app.md, section 4).
///
/// MacSW.app carries the finished, signed SOLIDWORKS.app as `Contents/Resources/SOLIDWORKS.app.zip`
/// (`scripts/package_solidworks_app.sh --embed`), with `SOLIDWORKS.app.plist` next to it (versions
/// and the SHA-256 of its executable). It is a zip and not a bundle inside the bundle, so
/// LaunchServices never registers that copy as a second app that owns the SOLIDWORKS types.
/// Unpacking gives the same files, so the copy keeps the build's signature and designated
/// requirement (with the stable identity: the certificate leaf), and macOS privacy grants for
/// SOLIDWORKS.app survive updates. Nothing here signs or changes the copy.
///
/// Pure decisions are static functions; all file-system and system calls go through `Effects`.
public enum SolidWorksAppInstaller {
    public static let bundleName = "SOLIDWORKS.app"
    public static let payloadName = "SOLIDWORKS.app.zip"
    public static let payloadInfoName = "SOLIDWORKS.app.plist"
    public static let executableSHA256Key = "ExecutableSHA256"
    static let executablePath = "Contents/MacOS/SOLIDWORKS"

    // MARK: Payload and installed copy

    /// The SOLIDWORKS.app that this MacSW.app ships. nil: built without it (app shell,
    /// `MACSW_SKIP_SOLIDWORKS_APP=1`).
    public struct Payload: Equatable, Sendable {
        public let archive: URL
        public let version: String
        public let build: String
        public let executableSHA256: String
    }

    public static func payload(in macSW: URL) -> Payload? {
        let resources = macSW.appendingPathComponent("Contents/Resources")
        let archive = resources.appendingPathComponent(payloadName)
        guard FileManager.default.fileExists(atPath: archive.path),
              let info = NSDictionary(contentsOf: resources.appendingPathComponent(payloadInfoName)),
              let hash = info[executableSHA256Key] as? String, hash.count == 64 else { return nil }
        return Payload(archive: archive,
                       version: info["CFBundleShortVersionString"] as? String ?? "",
                       build: info["CFBundleVersion"] as? String ?? "",
                       executableSHA256: hash.lowercased())
    }

    /// Where an installed copy is looked for. The first one is where a new copy goes.
    public static func candidateLocations(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications/\(bundleName)"),
         home.appendingPathComponent("Applications/\(bundleName)")]
    }

    public enum Installed: Equatable, Sendable {
        case none
        case ours(URL)
        /// Another app with that name (for example an older launcher): never replaced or removed.
        case foreign(URL)
    }

    /// Our copy wins over another app with the same name in a later candidate.
    public static func installedCopy(candidates: [URL]) -> Installed {
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let ours = existing.first(where: isSolidWorksApp) { return .ours(ours) }
        return existing.first.map(Installed.foreign) ?? .none
    }

    public static func isSolidWorksApp(_ bundle: URL) -> Bool {
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleIdentifier"] as? String == AppBundleLaunch.solidWorksBundleIdentifier
    }

    /// The executable holds both slices (launcher and MacSW's Wine loader) and the code signature,
    /// which seals Info.plist and the resources; equal bytes mean the same SOLIDWORKS.app build.
    public static func executableSHA256(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent(executablePath), options: .alwaysMapped) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public enum Status: Equatable, Sendable {
        case notInstalled
        /// Installed and the same build as this MacSW's.
        case current(URL)
        /// Installed from another MacSW build: a new launcher, loader or Info.plist is waiting.
        case stale(URL)
        /// Installed, but this MacSW carries no SOLIDWORKS.app to compare with.
        case unknown(URL)
        case foreign(URL)
    }

    public static func status(payload: Payload?, installed: Installed) -> Status {
        switch installed {
        case .none: return .notInstalled
        case .foreign(let url): return .foreign(url)
        case .ours(let url):
            guard let payload else { return .unknown(url) }
            return executableSHA256(of: url) == payload.executableSHA256 ? .current(url) : .stale(url)
        }
    }

    // MARK: Which MacSW the copy uses

    public enum Pairing: Equatable, Sendable {
        case thisMacSW
        case other(URL)
        case none
    }

    /// The MacSW.app that a copy at `target` would use: the launcher's own search
    /// (`AppBundleLaunch.locateMacSW`) without test overrides. Only that MacSW.app installs or
    /// updates it; a copy from another build (for example one run from a build folder) would carry
    /// a loader its MacSW.app does not have, and the launcher would refuse to start.
    public static func pairing(target: URL, thisMacSW: URL, locate: (URL) -> URL?) -> Pairing {
        guard let host = locate(target) else { return .none }
        return canonical(host) == canonical(thisMacSW) ? .thisMacSW : .other(host)
    }

    public static func liveLocate(_ target: URL) -> URL? {
        AppBundleLaunch.locateMacSW(appBundle: target, info: [:], environment: [:])
    }

    // MARK: Running guard

    public struct RunningExecutable: Equatable, Sendable {
        public let pid: Int32
        public let path: String
        public init(pid: Int32, path: String) { self.pid = pid; self.path = path }
    }

    /// Processes whose executable is inside `bundle`: the launcher (it does not check in with
    /// LaunchServices before its exec), the Wine host after the exec (same executable) and the
    /// open-documents helper. Wine processes the host starts run MacSW.app's loader and do not count.
    public static func processes(inside bundle: URL, in running: [RunningExecutable]) -> [Int32] {
        let root = canonical(bundle).lowercased() + "/"
        return running.filter { canonical(URL(fileURLWithPath: $0.path)).lowercased().hasPrefix(root) }.map(\.pid)
    }

    /// Every process of this user whose executable path can be read (`proc_pidpath`).
    public static func liveRunningExecutables() -> [RunningExecutable] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return RunningExecutable(pid: pid, path: String(cString: buffer))
        }
    }

    // MARK: Install and uninstall

    public enum InstallError: LocalizedError, Equatable {
        case noPayload
        case foreignApp(URL)
        case running(URL)
        case damagedPayload
        /// The installed copy is signed with an identity and the new one has another designated
        /// requirement: replacing it would reset its privacy permissions. Needs the user's consent.
        case requirementWouldChange(URL)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noPayload:
                return "This MacSW build does not include SOLIDWORKS.app."
            case .foreignApp(let url):
                return "\(url.path) is another app, not MacSW's SOLIDWORKS.app. Move it away first."
            case .running(let url):
                return "SOLIDWORKS.app (\(url.path)) is running. Quit SOLIDWORKS first."
            case .damagedPayload:
                return "The SOLIDWORKS.app inside MacSW is damaged. Reinstall MacSW."
            case .requirementWouldChange(let url):
                return "\(url.path) is signed with another code signing identity than this MacSW's SOLIDWORKS.app. "
                    + "If MacSW replaces it, macOS forgets its permissions (Desktop, Documents, Downloads, Full Disk Access)."
            case .failed(let message):
                return message
            }
        }
    }

    /// System calls, injected so that tests never touch LaunchServices, the Trash or /Applications.
    public struct Effects: Sendable {
        public var extract: @Sendable (_ archive: URL, _ directory: URL) throws -> Void
        public var verifySignature: @Sendable (_ app: URL) throws -> Void
        public var designatedRequirement: @Sendable (_ app: URL) -> String?
        public var runningExecutables: @Sendable () -> [RunningExecutable]
        public var register: @Sendable (_ app: URL) -> Void
        public var unregister: @Sendable (_ app: URL) -> Void
        public var trash: @Sendable (_ item: URL) throws -> Void

        public init(extract: @escaping @Sendable (URL, URL) throws -> Void,
                    verifySignature: @escaping @Sendable (URL) throws -> Void,
                    designatedRequirement: @escaping @Sendable (URL) -> String?,
                    runningExecutables: @escaping @Sendable () -> [RunningExecutable],
                    register: @escaping @Sendable (URL) -> Void,
                    unregister: @escaping @Sendable (URL) -> Void,
                    trash: @escaping @Sendable (URL) throws -> Void) {
            self.extract = extract
            self.verifySignature = verifySignature
            self.designatedRequirement = designatedRequirement
            self.runningExecutables = runningExecutables
            self.register = register
            self.unregister = unregister
            self.trash = trash
        }
    }

    public struct InstallResult: Equatable, Sendable {
        public let app: URL
        public let replaced: Bool
        /// The previous copy had another designated requirement (for example ad hoc before, the
        /// stable identity now): macOS asks for privacy permissions again.
        public let requirementChanged: Bool
    }

    /// A requirement that names a certificate (stable identity, Developer ID) and not code hashes:
    /// privacy permissions granted to such a copy survive its updates, so they are worth keeping.
    public static func isIdentityRequirement(_ requirement: String?) -> Bool {
        guard let requirement else { return false }
        return requirement.contains("certificate") || requirement.contains("anchor")
    }

    /// Unpacks the payload next to `target` (same volume), checks it, and puts it in place with
    /// one rename: an existing copy is swapped out atomically (`RENAME_SWAP`) and then removed.
    /// Refuses while any process runs from `target`. Registers the result with LaunchServices.
    ///
    /// A copy signed with an identity is replaced by one with another designated requirement only
    /// with `allowRequirementChange` (the user confirmed it); the old copy then goes to the Trash.
    public static func install(_ payload: Payload, to target: URL, effects: Effects,
                               allowRequirementChange: Bool = false) throws -> InstallResult {
        let fileManager = FileManager.default
        let replacing = fileManager.fileExists(atPath: target.path)
        if replacing, !isSolidWorksApp(target) { throw InstallError.foreignApp(target) }
        try ensureNotRunning(target, effects)

        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Hidden folder next to the target. On success it holds the old copy, on failure the new one.
        let staging = parent.appendingPathComponent(".SOLIDWORKS-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { dispose(staging, effects) }

        let staged = staging.appendingPathComponent(bundleName)
        try effects.extract(payload.archive, staging)
        guard isSolidWorksApp(staged), executableSHA256(of: staged) == payload.executableSHA256 else {
            throw InstallError.damagedPayload
        }
        try effects.verifySignature(staged)
        let installedRequirement = replacing ? effects.designatedRequirement(target) : nil
        let requirementChanged = replacing && installedRequirement != effects.designatedRequirement(staged)
        if requirementChanged, isIdentityRequirement(installedRequirement), !allowRequirementChange {
            throw InstallError.requirementWouldChange(target)
        }

        try ensureNotRunning(target, effects)  // again, right before the switch
        if replacing {
            try swap(staged, target)
        } else if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            throw InstallError.failed("Could not move SOLIDWORKS.app to \(target.path): \(String(cString: strerror(errno)))")
        }
        effects.register(target)
        if requirementChanged {
            // The old copy (now in the staging folder) is the user's way back: Trash, not removed.
            effects.unregister(staged)
            try? effects.trash(staged)
        }
        return InstallResult(app: target, replaced: replacing, requirementChanged: requirementChanged)
    }

    /// Unregisters the copy and moves it to the Trash. Refuses while it runs.
    public static func uninstall(_ app: URL, effects: Effects) throws {
        guard isSolidWorksApp(app) else { throw InstallError.foreignApp(app) }
        try ensureNotRunning(app, effects)
        effects.unregister(app)
        try effects.trash(app)
    }

    private static func ensureNotRunning(_ app: URL, _ effects: Effects) throws {
        if !processes(inside: app, in: effects.runningExecutables()).isEmpty { throw InstallError.running(app) }
    }

    /// `RENAME_SWAP` exchanges both directories in one step; where the file system does not support
    /// it, the old copy is moved aside first and put back if the second rename fails.
    private static func swap(_ staged: URL, _ target: URL) throws {
        if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL else {
            throw InstallError.failed("Could not replace \(target.path): \(String(cString: strerror(errno)))")
        }
        let aside = staged.deletingLastPathComponent().appendingPathComponent("previous.app")
        guard rename(target.path, aside.path) == 0 else {
            throw InstallError.failed("Could not replace \(target.path): \(String(cString: strerror(errno)))")
        }
        guard rename(staged.path, target.path) == 0 else {
            let message = String(cString: strerror(errno))
            _ = rename(aside.path, target.path)
            throw InstallError.failed("Could not replace \(target.path): \(message)")
        }
    }

    /// The superseded copy (or a half-done staging folder) is MacSW's own: removed; moved to the
    /// Trash if that fails.
    private static func dispose(_ item: URL, _ effects: Effects) {
        guard FileManager.default.fileExists(atPath: item.path) else { return }
        if (try? FileManager.default.removeItem(at: item)) == nil { try? effects.trash(item) }
    }

    // MARK: Default handler

    /// The content types the app owns (rank Owner in its Info.plist): the SOLIDWORKS documents.
    public static func ownedContentTypes(of app: URL) -> [String] {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let types = info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return types.filter { $0["LSHandlerRank"] as? String == "Owner" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
    }

    /// The types whose default app changes: those that `replacing` (or no app) opens now. A choice
    /// of another app, for example in Get Info, is kept.
    public static func handlerChanges(types: [String], current: (String) -> String?, replacing: String) -> [String] {
        types.filter { type in current(type).map { $0 == replacing } ?? true }
    }

    // MARK: Live effects

    public static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")

    public static let liveEffects = Effects(
        extract: { archive, directory in
            // --noqtn: a downloaded MacSW.app must not hand its quarantine to the installed copy
            // (Gatekeeper, App Translocation). The SHA-256 and the signature are checked after this.
            try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", "--noqtn", archive.path, directory.path])
        },
        verifySignature: { app in
            var code: SecStaticCode?
            var error: Unmanaged<CFError>?
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error) == errSecSuccess else {
                let reason = error.map { $0.takeRetainedValue().localizedDescription } ?? "no code signature"
                throw InstallError.failed("The SOLIDWORKS.app signature is not valid: \(reason)")
            }
        },
        designatedRequirement: { app in
            var code: SecStaticCode?
            var requirement: SecRequirement?
            var text: CFString?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
                  SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
            return text as String?
        },
        runningExecutables: { liveRunningExecutables() },
        register: { app in _ = LSRegisterURL(app as CFURL, true) },
        unregister: { app in try? run(lsregister, ["-u", app.path]) },
        trash: { item in try FileManager.default.trashItem(at: item, resultingItemURL: nil) }
    )

    private static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.failed("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(detail)")
        }
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
