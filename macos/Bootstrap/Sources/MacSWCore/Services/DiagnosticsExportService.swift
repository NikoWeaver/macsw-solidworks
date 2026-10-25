import Darwin
import Foundation

/// "Export Diagnostics…" (sharing plan, C4): a zip on the Desktop with MacSW's own logs and facts
/// about this Mac, for the team admin. Nothing is uploaded. The files come from a fixed list of
/// names (`plan`), never from a folder listing, and every text goes through `DiagnosticsScrubber`.
/// The export starts no Wine program, so it can never turn on `+msxml` or `+wininet` traces (they
/// print request bodies, which hold the serial; `wine-network.md`, 4.4). `refusal` rejects what
/// must never be in the zip: registry hives, licence and activation files, Internet caches,
/// crash dumps, model files and anything inside the bottle's drive_c.
public enum DiagnosticsExport {
    public struct Item: Equatable, Sendable {
        public enum Content: Equatable, Sendable {
            case file(URL)
            case text(String)
        }

        /// The path in the zip, below its top folder.
        public let name: String
        public let content: Content

        public init(name: String, content: Content) {
            self.name = name
            self.content = content
        }
    }

    public struct Refused: Error, LocalizedError, Equatable {
        public let path: String
        public let reason: String

        public var errorDescription: String? { "\(path) is never exported (\(reason))." }
    }

    /// MacSW's logs in `<App Support>/MacSW/logs`; install_msi.log is the verbose MSI log, spatialiop.log
    /// the SpatialIOP MSI edit and payload check (`SpatialIOPService`). Then the logs of the other
    /// install steps (`BootstrapStore`, `PrerequisiteService`, `ToolboxService`), in install order. Only
    /// the core msiexec gets the serial; its two logs are redacted by value after it ends.
    public static let logNames = ["sw_launch.log", "folder-consent.log", "sw_open.log", "solidworks-app.log", "install_msi.log",
                                  "spatialiop.log",
                                  "wineboot.log", "mono-runtime.log", "managed-com-registration.log", "registry-write.log",
                                  "vcredist-x64.log", "vcredist-wine.log", "login-manager-install.log", "login-manager-wine.log",
                                  "vba71-install.log", "vba71_1033-install.log", "vba-wine.log", "winecfg.log",
                                  "installer-wine.log", "install_msi_errors.log", "language-install.log", "language-wine.log",
                                  "prerequisites.log", "toolbox-path.log", "toolbox-install.log"]
    /// In the Wine upgrade state folder (`WineRuntimeService.root`).
    public static let runtimeNames = ["migration.log", "receipt.json", "last-upgrade.json"]
    /// A larger file is cut to its last part: the end of a log holds the latest run.
    public static let maximumFileBytes = 32 << 20

    static let hiveNames: Set<String> = ["system.reg", "user.reg", "userdef.reg"]
    static let refusedFolders: [String: String] = [
        "flexnet": "licence data", "inetcache": "Internet cache", "cxpa": "crash dumps", "drive_c": "inside the bottle"
    ]
    static let licenceExtensions: Set<String> = ["lic", "tsf"]
    /// SOLIDWORKS documents, templates and macros, and the common exchange formats.
    static let modelExtensions: Set<String> = [
        "sldprt", "sldasm", "slddrw", "sldlfp", "sldblk", "slddrt", "sldmat", "sldstd", "sldftp", "sldtbt",
        "prtdot", "asmdot", "drwdot", "swp", "swb", "step", "stp", "iges", "igs", "x_t", "x_b", "sat", "stl",
        "3mf", "dwg", "dxf", "eprt", "easm", "edrw", "eprtx", "easmx", "edrwx", "ifc", "obj", "3dxml"
    ]

    /// Why `url` must never be exported, or nil.
    public static func refusal(_ url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if hiveNames.contains(name) || url.pathExtension.lowercased() == "reg" { return "registry" }
        if name.hasPrefix("swactivaterequest") { return "activation request" }
        if licenceExtensions.contains(url.pathExtension.lowercased()) { return "licence file" }
        if modelExtensions.contains(url.pathExtension.lowercased()) { return "model file" }
        for component in url.standardizedFileURL.pathComponents.map({ $0.lowercased() }) {
            if let reason = refusedFolders[component] { return reason }
        }
        return nil
    }

    /// The files that exist from the fixed list, then the reports made from `facts`, then
    /// install-status.txt when the export starts from the install window (`installStatusReport`).
    public static func plan(paths: AppPaths, bundle: URL, facts: Facts, installStatus: String? = nil,
                            fileManager: FileManager = .default) -> [Item] {
        var candidates = logNames.map { ("logs/\($0)", paths.logs.appendingPathComponent($0)) }
        let runtime = WineRuntimeService.root(prefix: paths.bottle)
        candidates += runtimeNames.map { ("runtime/\($0)", runtime.appendingPathComponent($0)) }
        candidates.append(("BuildManifest.plist", bundle.appendingPathComponent("Contents/Resources/BuildManifest.plist")))
        var items = candidates.filter { fileManager.isReadableFile(atPath: $0.1.path) }
            .map { Item(name: $0.0, content: .file($0.1)) }
        items += [Item(name: "system.txt", content: .text(facts.systemReport)),
                  Item(name: "folder-access.txt", content: .text(facts.folderReport)),
                  Item(name: "processes.txt", content: .text(facts.processReport))]
        if let installStatus { items.append(Item(name: "install-status.txt", content: .text(installStatus))) }
        items.insert(Item(name: "README.txt", content: .text(readme(items.map(\.name)))), at: 0)
        return items
    }

    /// Writes every item, scrubbed, into `directory/<top>/`. Refuses the whole export when one
    /// item is a file that must never be exported.
    public static func stage(_ items: [Item], scrubber: DiagnosticsScrubber, top: String, in directory: URL,
                             maximumBytes: Int = maximumFileBytes) throws -> URL {
        for item in items {
            // A log that is a link to a refused file is refused too.
            if case .file(let url) = item.content, let reason = refusal(url) ?? refusal(url.resolvingSymlinksInPath()) {
                throw Refused(path: url.path, reason: reason)
            }
        }
        let root = directory.appendingPathComponent(top, isDirectory: true)
        try LogFiles.prepareDirectory(root)
        for item in items {
            let text: String
            switch item.content {
            case .text(let value): text = value
            case .file(let url): text = try readText(url, maximumBytes: maximumBytes)
            }
            let target = root.appendingPathComponent(item.name)
            try LogFiles.write(Data(scrubber.scrub(text).utf8), to: target)
        }
        return root
    }

    /// Stages the items in a private temporary folder, zips them to `destination` (which must not
    /// exist) and removes the temporary folder.
    @discardableResult
    public static func write(_ items: [Item], scrubber: DiagnosticsScrubber, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("MacSW-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try LogFiles.prepareDirectory(work)
        defer { try? fileManager.removeItem(at: work) }
        let top = destination.deletingPathExtension().lastPathComponent
        let root = try stage(items, scrubber: scrubber, top: top, in: work)
        let zip = work.appendingPathComponent("export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", root.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacSWError.make("Could not make the zip (ditto exited with \(process.terminationStatus)).", domain: "MacSW.Diagnostics")
        }
        try fileManager.moveItem(at: zip, to: destination)
        return destination
    }

    /// `~/Desktop/MacSW-diagnostics-<date>.zip`, with "-2", "-3", … when that name is taken.
    public static func destination(in folder: URL, date: Date = Date(), fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = "MacSW-diagnostics-\(formatter.string(from: date))"
        var candidate = folder.appendingPathComponent("\(base).zip")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(number).zip")
            number += 1
        }
        return candidate
    }

    /// The text of a log or JSON file in any of the encodings MacSW meets (UTF-8, UTF-16 with a
    /// byte-order mark, Windows-1252), or an XML property list. A file larger than `maximumBytes`
    /// keeps its last part, from the start of a line.
    static func readText(_ url: URL, maximumBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var data: Data
        var cut = false
        if size > maximumBytes {
            try handle.seek(toOffset: 0)
            let bom = try handle.read(upToCount: 2) ?? Data()
            let utf16 = bom == Data([0xFF, 0xFE]) || bom == Data([0xFE, 0xFF])
            let start = (size - maximumBytes) & (utf16 ? ~1 : ~0)
            try handle.seek(toOffset: UInt64(start))
            data = (utf16 ? bom : Data()) + (try handle.readToEnd() ?? Data())
            cut = true
        } else {
            try handle.seek(toOffset: 0)
            data = try handle.readToEnd() ?? Data()
        }
        if data.starts(with: Array("bplist".utf8)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            data = xml
        }
        guard var text = PlainTextDecoder.decode(data) else { return "" }
        if cut {
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            text = "[MacSW: only the last \(maximumBytes >> 20) MB of this \(size >> 20) MB file]\n" + text
        }
        return text
    }

    /// What the install window shows: its state, its message, and each step with its status and
    /// detail, so the zip says which step failed and why.
    static func installStatusReport(state: InstallationState, message: String,
                                    statuses: [InstallationStep: InstallationStepStatus],
                                    details: [InstallationStep: String]) -> String {
        let stateText: String
        switch state {
        case .idle: stateText = "idle"
        case .preparing: stateText = "preparing"
        case .installing(let step): stateText = "installing (step \(step.rawValue))"
        case .cancelling: stateText = "stopping"
        case .cancelled: stateText = "stopped"
        case .failed: stateText = "failed"
        case .completed: stateText = "completed"
        }
        var lines = ["Install: \(stateText)", "Message: \(message)", "", "Steps:"]
        for step in InstallationStep.allCases {
            let detail = details[step].map { ": " + $0.replacingOccurrences(of: "\n", with: "\n    ") } ?? ""
            lines.append("\(step.rawValue). \(step.title) - \((statuses[step] ?? .pending).rawValue)\(detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func readme(_ names: [String]) -> String {
        """
        MacSW diagnostics

        MacSW made this zip on this Mac with "Export Diagnostics…". Nothing was uploaded.
        Send it only to the person who helps you with MacSW.

        Files:
        \((["README.txt"] + names).map { "  " + $0 }.joined(separator: "\n"))

        MacSW removed these values from every file: serial-shaped strings (<serial>),
        installer lines with SERIALNUMBER or SERVERLIST, e-mail addresses (<email>), MAC
        addresses (<mac>), your user name and home folder (<user>, ~), the computer's host
        names (<host>), the account part of cloud folder names, and licence server
        addresses (<server>).

        Never included: the bottle's registry, licence and activation files (FLEXnet,
        SWActivateRequest, .lic, .tsf), Internet caches, crash dumps, model files and
        the environment of any process.
        """
    }
}

public extension DiagnosticsExport {
    /// What MacSW knows about this Mac and the bottle, as text. Made without Wine.
    struct Facts: Equatable, Sendable {
        public var systemReport: String
        public var folderReport: String
        public var processReport: String

        public init(systemReport: String, folderReport: String, processReport: String) {
            self.systemReport = systemReport
            self.folderReport = folderReport
            self.processReport = processReport
        }

        /// The reports of this Mac. `processes` is a `ProcessInventory` snapshot: names only.
        public static func live(paths: AppPaths, bundle: URL, processes: [WineProcess],
                                session: FolderConsentService.Session = .current) -> Facts {
            Facts(systemReport: system(paths: paths, bundle: bundle),
                  folderReport: folders(prefix: paths.bottle, session: session),
                  processReport: processNames(processes))
        }

        static func system(paths: AppPaths, bundle: URL) -> String {
            let info = Bundle(url: bundle)?.infoDictionary ?? [:]
            let manifest = (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/BuildManifest.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            let free = (try? FileManager.default.homeDirectoryForCurrentUser
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            let lines = [
                "Date: \(ISO8601DateFormatter().string(from: Date()))",
                "MacSW: \(info["CFBundleShortVersionString"] as? String ?? "unknown") (build \(info["CFBundleVersion"] as? String ?? "unknown")), commit \(manifest["GitCommit"] as? String ?? "unknown") (\(manifest["GitBranch"] as? String ?? "unknown"))",
                "Wine: \(info["MacSWWineVersion"] as? String ?? "unknown"), Mono: \(info["MacSWMonoVersion"] as? String ?? "unknown")",
                "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "Mac model: \(sysctlString("hw.model") ?? "unknown")",
                "Processor: \(sysctlString("machdep.cpu.brand_string") ?? "unknown")",
                "Memory: \(ProcessInfo.processInfo.physicalMemory >> 30) GB",
                "Free disk (home volume): \(free.map { "\($0 >> 30) GB" } ?? "unknown")",
                "Rosetta: \(rosettaWorks() ? "works" : "not installed or not working")",
                "Bottle: \(paths.bottleExists ? "present" : "missing"), SOLIDWORKS \(paths.solidWorksInstalled ? "installed" : "not installed")",
                "Wine bottle state: \(WineRuntimeService.status(prefix: paths.bottle, bundle: bundle).rawValue)"
            ]
            return lines.joined(separator: "\n") + "\n"
        }

        /// The protected folders that the bottle links to, and whether macOS let this MacSW
        /// process open them. Read from the links only: no folder is opened, so no prompt appears.
        static func folders(prefix: URL, session: FolderConsentService.Session) -> String {
            let links = WineBottleGate.links(prefix: prefix)
            let held = WineBottleGate.heldLinks(prefix: prefix)
            guard !links.isEmpty || !held.isEmpty else { return "No links from the bottle to protected folders.\n" }
            var lines = links.compactMap { link -> String? in
                guard let folder = link.folder else { return nil }
                let state = session.isConfirmed(folder.url) ? "allowed" : "not confirmed in this MacSW session"
                return "\(link.item) -> \(folder.name) (\(folder.url.path)): \(state)"
            }
            lines += held.map { "\($0.item): set aside before Wine started (macOS has not let MacSW open it)" }
            return lines.joined(separator: "\n") + "\n"
        }

        static func processNames(_ processes: [WineProcess]) -> String {
            guard !processes.isEmpty else { return "No bottle processes running.\n" }
            return processes.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n") + "\n"
        }

        static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }

        /// The preflight test of the plan (C0.1): an x86_64 program runs.
        static func rosettaWorks() -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            process.arguments = ["-x86_64", "/usr/bin/true"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }
}
