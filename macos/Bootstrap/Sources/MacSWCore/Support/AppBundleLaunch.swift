import CoreServices
import Foundation

/// SOLIDWORKS.app: a Mac app whose process becomes the SOLIDWORKS Wine host.
/// Its executable is universal: the arm64 slice is the launcher (preflight as in MacSW), the
/// x86_64 slice is the Wine loader. Pure decisions live here; `main.swift` of the launcher
/// target does the I/O.
public enum AppBundleLaunch {
    /// Patch 0025: the bundle path. winemac acts as the bundle's main process (Dock tile from
    /// launch, Command-Q) only in the process whose main bundle is this path, so Wine processes
    /// that the host starts (they inherit the variables) are not affected.
    public static let appBundleKey = "MACSW_APP_BUNDLE"
    /// Patch 0025: winemac passes opened documents to this program with `openDocumentsFlag`.
    public static let openDocumentsHelperKey = "MACSW_OPEN_DOCUMENTS_HELPER"
    public static let openDocumentsFlag = "--open-documents"
    /// Patch 0025: "close" makes Quit post WM_CLOSE (as MacSW's "Quit SOLIDWORKS") instead of
    /// Wine's session end. Set from the MacSW preference `quitClosesWindowsPreference`.
    public static let quitModeKey = "MACSW_APP_QUIT"
    public static let quitClosesWindowsPreference = "MacSW.solidWorksAppQuitClosesWindows"
    /// Test switch for the LaunchServices validation: seconds the launcher waits before the preflight.
    public static let launchDelayKey = "MACSW_LAUNCHER_DELAY"
    /// "1": always run the font-link check (no stamp), as MacSW does.
    public static let fullPreflightKey = "MACSW_LAUNCHER_FULL_PREFLIGHT"
    /// "1": start even when the loader slice differs from MacSW.app's loader.
    public static let skipLoaderCheckKey = "MACSW_SKIP_LOADER_CHECK"
    /// Overrides for a MacSW.app or data directory in another place (tests, side-by-side builds).
    public static let hostAppKey = "MACSW_HOST_APP"
    public static let appSupportKey = "MACSW_APP_SUPPORT"
    /// Info.plist entry with the MacSW.app path, when SOLIDWORKS.app is not installed next to it.
    public static let hostAppInfoKey = "MacSWHostApp"
    /// MacSW's preferences (Wine locale) are read from MacSW's own defaults domain.
    public static let macSWDefaultsDomain = "com.yjbeetle.macsw"
    public static let macSWBundleIdentifier = "com.yjbeetle.macsw"
    public static let solidWorksBundleIdentifier = "com.yjbeetle.macsw.solidworks"

    public enum Mode: Equatable, Sendable {
        /// Started by winemac with documents for the running SOLIDWORKS.
        case openDocuments([URL])
        /// SOLIDWORKS already runs in the bottle, but not as this app (for example MacSW started it):
        /// pass on documents, bring it forward and quit.
        case forward
        /// Preflight, then become the Wine host.
        case launch
    }

    public static func mode(arguments: [String], solidWorksRunning: () -> Bool) -> Mode {
        let rest = Array(arguments.dropFirst())
        if rest.first == openDocumentsFlag {
            return .openDocuments(rest.dropFirst().map { URL(fileURLWithPath: $0) })
        }
        return solidWorksRunning() ? .forward : .launch
    }

    /// `RuntimeStore.launch()` ended without the exec. SOLIDWORKS runs (it started in the meantime),
    /// or another start kept the bottle's start lock for 15 s (F4): forward mode, that is, bring
    /// SOLIDWORKS forward and quit without an alert. Any other end shows an alert.
    public static func endsInForwardMode(_ state: SolidWorksRuntimeState) -> Bool {
        switch state {
        case .running: return true
        case .failed(let message): return message == StartLock.busyMessage
        default: return false
        }
    }

    /// The MacSW.app to use: the override, the Info.plist entry, the one next to this app,
    /// /Applications, then the copies LaunchServices knows. Only a bundle that is MacSW and has
    /// a Wine runtime counts.
    public static func locateMacSW(
        appBundle: URL,
        info: [String: Any],
        environment: [String: String],
        applications: URL = URL(fileURLWithPath: "/Applications"),
        registered: () -> [URL] = AppBundleLaunch.registeredMacSWBundles,
        isMacSW: (URL) -> Bool = AppBundleLaunch.isMacSW
    ) -> URL? {
        var candidates: [URL] = []
        if let path = environment[hostAppKey], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let path = info[hostAppInfoKey] as? String, !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(appBundle.deletingLastPathComponent().appendingPathComponent("MacSW.app"))
        candidates.append(applications.appendingPathComponent("MacSW.app"))
        if let found = candidates.map(\.standardizedFileURL).first(where: isMacSW) { return found }
        return registered().map(\.standardizedFileURL).first(where: isMacSW)
    }

    /// MacSW.app copies registered with LaunchServices (for example in ~/Applications).
    /// CoreServices only: the launcher must not check in with AppKit before the exec.
    public static func registeredMacSWBundles() -> [URL] {
        let urls = LSCopyApplicationURLsForBundleIdentifier(macSWBundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL]
        return urls ?? []
    }

    public static func isMacSW(_ bundle: URL) -> Bool {
        let contents = bundle.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              info["CFBundleIdentifier"] as? String == macSWBundleIdentifier else { return false }
        return FileManager.default.isExecutableFile(
            atPath: contents.appendingPathComponent("Frameworks/wine/lib/wine/x86_64-unix/MacSW").path)
    }

    public static func appPaths(environment: [String: String]) -> AppPaths {
        if let path = environment[appSupportKey], !path.isEmpty {
            return AppPaths(appSupportDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return AppPaths.live()
    }

    // MARK: Loader slice

    public static let cpuTypeX86_64: Int32 = 0x0100_0007

    /// LC_UUID of the `cpuType` image in a Mach-O file (thin 64-bit or fat), nil if it has none.
    public static func machOUUID(_ data: Data, cpuType: Int32) -> UUID? {
        let bytes = [UInt8](data)
        func u32(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return bigEndian ? value : value.byteSwapped
        }
        func u64(_ offset: Int) -> UInt64? {
            guard let high = u32(offset, bigEndian: true), let low = u32(offset + 4, bigEndian: true) else { return nil }
            return UInt64(high) << 32 | UInt64(low)
        }
        func thin(at base: Int) -> UUID? {
            // mach_header_64 (little endian): magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved.
            guard u32(base, bigEndian: false) == 0xfeed_facf,
                  let type = u32(base + 4, bigEndian: false), Int32(bitPattern: type) == cpuType,
                  let count = u32(base + 16, bigEndian: false) else { return nil }
            var offset = base + 32
            for _ in 0..<count {
                guard let command = u32(offset, bigEndian: false), let size = u32(offset + 4, bigEndian: false),
                      size >= 8 else { return nil }
                if command == 0x1b /* LC_UUID */ {
                    guard size >= 24, offset + 24 <= bytes.count else { return nil }
                    return Array(bytes[offset + 8..<offset + 24]).withUnsafeBufferPointer {
                        NSUUID(uuidBytes: $0.baseAddress) as UUID
                    }
                }
                offset += Int(size)
            }
            return nil
        }
        switch u32(0, bigEndian: true) {
        case 0xcafe_babe, 0xcafe_babf:  // fat_header, big endian; fat_arch or fat_arch_64 entries
            let wide = u32(0, bigEndian: true) == 0xcafe_babf
            guard let count = u32(4, bigEndian: true), count < 64 else { return nil }
            for index in 0..<Int(count) {
                let entry = 8 + index * (wide ? 32 : 20)
                guard let type = u32(entry, bigEndian: true), Int32(bitPattern: type) == cpuType else { continue }
                let offset = wide ? u64(entry + 8).map(Int.init) : u32(entry + 8, bigEndian: true).map(Int.init)
                return offset.flatMap(thin(at:))
            }
            return nil
        default:
            return thin(at: 0)
        }
    }

    /// SOLIDWORKS.app's x86_64 slice is a copy of MacSW.app's Wine loader. After a MacSW.app
    /// update with a new loader, an old SOLIDWORKS.app would run the old loader against the new
    /// ntdll.so; the launcher then stops before the exec. nil: a file could not be read.
    public static func loaderSliceMatches(appExecutable: URL, macSW: URL) -> Bool? {
        let loader = macSW.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW")
        guard let app = try? Data(contentsOf: appExecutable, options: .alwaysMapped),
              let wine = try? Data(contentsOf: loader, options: .alwaysMapped),
              let want = machOUUID(wine, cpuType: cpuTypeX86_64) else { return nil }
        return machOUUID(app, cpuType: cpuTypeX86_64) == want
    }

    // MARK: Font-link check stamp

    /// The launcher runs MacSW's Tahoma font-link check (1-2 `wine reg query`, seconds each) only
    /// when this key changed since the last successful check: bottle, prefix ID and runtime identity.
    public static func fontLinkStampKey(prefix: URL, macSW: URL) -> String? {
        guard let identity = try? WineRuntimeService.identity(contents: macSW.appendingPathComponent("Contents")) else {
            return nil
        }
        let id = (try? String(contentsOf: prefix.appendingPathComponent(".macsw-wine-prefix-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ([prefix.standardizedFileURL.path, id] + identity.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            .joined(separator: "\n")
    }

    public static func fontLinkStamp(paths: AppPaths) -> URL {
        paths.appSupportDirectory.appendingPathComponent(".solidworks-app-fontlink")
    }

    /// MacSW's font-link repair, skipped while `stamp` holds the current `fontLinkStampKey` and
    /// stamped after a successful run. Without a key (no build identity) it always runs.
    public static func stampedFontLinkRepair(
        stamp: URL, macSW: URL, repair: @escaping @Sendable (URL) async throws -> Void
    ) -> @Sendable (URL) async throws -> Void {
        { prefix in
            let key = fontLinkStampKey(prefix: prefix, macSW: macSW)
            if let key, (try? String(contentsOf: stamp, encoding: .utf8)) == key { return }
            try await repair(prefix)
            if let key { try? key.write(to: stamp, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: Quitting MacSW

    public enum MacSWQuitPlan: Equatable, Sendable {
        /// No SOLIDWORKS: end the bottle's processes and quit, as before.
        case stopBottleAndQuit
        /// SOLIDWORKS that MacSW started: ask before ending it.
        case confirmEndingSolidWorks
        /// SOLIDWORKS.app's own session: quit MacSW only, the bottle keeps running.
        case quitLeavingSolidWorks
    }

    /// `bundleIdentifier` maps a PID to the identifier of its LaunchServices record.
    public static func macSWQuitPlan(snapshot: [WineProcess], bundleIdentifier: (Int32) -> String?) -> MacSWQuitPlan {
        let hosts = snapshot.filter { $0.name.caseInsensitiveCompare(ProcessInventory.primaryProcess) == .orderedSame }
        guard !hosts.isEmpty else { return .stopBottleAndQuit }
        return hosts.allSatisfy({ bundleIdentifier($0.pid) == solidWorksBundleIdentifier })
            ? .quitLeavingSolidWorks : .confirmEndingSolidWorks
    }
}
