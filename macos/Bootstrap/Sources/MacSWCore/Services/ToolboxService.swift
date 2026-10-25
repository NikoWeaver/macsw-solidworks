import Foundation

/// Finish the official Toolbox deployment separately from the x86 MSI host.
/// WPF's x64 window setup fails under Mono interpreter mode; do not change the
/// interpreter setting used by the other installer/RegAsm processes.
public final class ToolboxService: @unchecked Sendable {
    private let wine: WineService

    public init(wine: WineService = .shared) { self.wine = wine }

    public func install(media: URL, paths: AppPaths) async throws -> Int {
        let rootPath = try Self.configuredDataPath(prefix: paths.bottle)
        let mapping = wine.makeProcess(arguments: ["winepath", "-u", rootPath], prefix: paths.bottle)
        let root = try await resolveDataDirectory(using: mapping,
            log: paths.logs.appendingPathComponent("toolbox-path.log"))
        let selected = try Self.selectedStandards(in: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("lang/english/swbrowser.sldedb").path) else {
            throw Self.failure("The Toolbox database is missing; the install cannot continue on MSI success alone.")
        }
        let executable = paths.solidWorksExecutable.deletingLastPathComponent().appendingPathComponent("sldtoolboxupdater.exe")
        let archives = media.appendingPathComponent(InstallationMedia.toolboxDirectory)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw Self.failure("The official Toolbox update tool is missing.")
        }
        for standard in selected {
            guard FileManager.default.fileExists(atPath: archives.appendingPathComponent(standard.source).path) else {
                throw Self.failure("The media is missing the Toolbox standard parts package: \(standard.source).")
            }
        }
        let archivePath = try await wine.windowsPath(for: archives, prefix: paths.bottle)
        let process = makeUpdater(executable: executable, dataPath: rootPath, archivesPath: archivePath, prefix: paths.bottle)
        let code = try await wine.runCancellable(process, log: paths.logs.appendingPathComponent("toolbox-install.log"))
        guard code == 0 else {
            throw Self.failure("Toolbox standard parts deployment failed (\(code)); see toolbox-install.log. The install was not marked successful.")
        }
        return try await Task.detached { try Self.validate(root: root, standards: selected) }.value
    }

    /// winepath's stdout is a machine-readable path, not a combined transcript.
    /// Keep stderr for diagnosis without treating it as part of the directory.
    func resolveDataDirectory(using process: Process, log: URL) async throws -> URL {
        let result = try await wine.capturePairCancellable(process)
        let diagnostic: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "exit_code": result.status,
            "stdout": result.standardOutput,
            "stderr": result.standardError
        ]
        try LogFiles.write(JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]),
                           to: log)
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, path.hasPrefix("/"),
              !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
              !path.contains("\u{FFFD}") else {
            throw Self.failure("Could not resolve the configured Toolbox data directory (exit code \(result.status)); see toolbox-path.log.")
        }
        return URL(fileURLWithPath: path)
    }

    func makeUpdater(executable: URL, dataPath: String, archivesPath: String, prefix: URL) -> Process {
        let process = wine.makeProcess(arguments: [executable.path, dataPath, archivesPath, "TRUE"], prefix: prefix)
        process.environment?["WINE_MONO_AOT"] = "none"
        return process
    }

    struct Standard: Equatable, Sendable {
        let name: String
        let source: String
    }

    /// Read the official installation's choice rather than hard-code a year or
    /// override the folder selected in the interactive wizard. Ambiguity fails
    /// closed instead of silently writing into another version's data folder.
    static func configuredDataPath(prefix: URL) throws -> String {
        for hive in ["user.reg", "system.reg"] {
            guard let data = try? Data(contentsOf: prefix.appendingPathComponent(hive)),
                  let text = PlainTextDecoder.decode(data) else { continue }
            let paths = dataPaths(in: text)
            if paths.count == 1 { return paths[0] }
            if paths.count > 1 { throw failure("Multiple Toolbox data directories exist; a deployment target cannot be chosen safely.") }
        }
        throw failure("The official install did not record a Toolbox data directory.")
    }

    static func dataPaths(in registry: String) -> [String] {
        var general = false
        var paths = Set<String>()
        for line in registry.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[") {
                general = text.hasPrefix(#"[Software\\SolidWorks\\SOLIDWORKS "#)
                    && text.contains(#"\\General]"#)
            } else if general, text.hasPrefix("\"Toolbox Data Location\"=\""), text.hasSuffix("\"") {
                let value = String(text.dropFirst("\"Toolbox Data Location\"=\"".count).dropLast())
                    .replacingOccurrences(of: "\\\\", with: "\\")
                if value.count > 3, WineService.parsedWindowsPath(value) != nil { paths.insert(value) }
            }
        }
        return paths.sorted()
    }

    private final class StandardsParser: NSObject, XMLParserDelegate {
        var element = ""
        var values: [String: String] = [:]
        var standards: [Standard] = []
        var rootElement: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if rootElement == nil { rootElement = name }
            element = name
            if name == "Standard" { values = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { values[element, default: ""] += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Standard", values["Install"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" {
                standards.append(Standard(name: values["Name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines),
                                          source: values["Source", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            element = ""
        }
    }

    static func selectedStandards(in root: URL) throws -> [Standard] {
        let parser = XMLParser(data: try Data(contentsOf: root.appendingPathComponent("ToolboxStandards.xml")))
        let delegate = StandardsParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.rootElement == "ToolboxStandards",
              delegate.standards.allSatisfy({ safeName($0.name) && safeName($0.source) && $0.source.lowercased().hasSuffix(".zip") }) else {
            throw failure("The Toolbox standard parts configuration is invalid; refusing to deploy.")
        }
        return delegate.standards
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains(":")
    }

    static func validate(root: URL, standards: [Standard]) throws -> Int {
        let fm = FileManager.default
        let browser = root.appendingPathComponent("browser")
        let index = browser.appendingPathComponent("ToolboxFiles.index")
        guard ((try? index.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 else {
            throw failure("The Toolbox update tool exited, but the official standard parts index is missing.")
        }
        var total = 0
        for standard in standards {
            try Task.checkCancellation()
            let folder = browser.appendingPathComponent(standard.name)
            var count = 0
            if let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in files where file.pathExtension.lowercased() == "sldprt" {
                    try Task.checkCancellation()
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
                }
            }
            guard count > 0 else { throw failure("The \(standard.name) standard part models are missing from Toolbox.") }
            total += count
        }
        return total
    }

    private static func failure(_ message: String) -> NSError { MacSWError.make(message, domain: "MacSW.Toolbox") }
}
