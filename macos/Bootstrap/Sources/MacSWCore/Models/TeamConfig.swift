import Darwin
import Foundation

/// The team config `macsw-team.json` in the team's shared folder (docs/team-admin.md).
///
/// It is data only and holds no secret: every editor of the team folder can change it, and MacSW
/// never reads a serial from it (or from anything else next to the media). So the config only
/// points at things, and the checks are in the app: the media copy is checked against
/// `media-manifest.sha256`, whose own SHA-256 the config names (`MediaCopyService`). That check
/// finds a partial or changed download; it does not prove who wrote the files.
///
/// Paths are relative to the folder that holds the config. Absolute paths, `..` and links that
/// leave that folder are refused. Unknown keys are ignored; a newer `schema` gives a clear message.
public struct TeamConfig: Equatable, Sendable {
    public static let fileName = "macsw-team.json"
    public static let supportedSchema = 1

    public struct SolidWorks: Equatable, Sendable {
        /// "2026 SP4.1": shown to the member and the name of the local media copy's folder.
        public let release: String
        public let build: String?
    }

    public struct Media: Equatable, Sendable {
        /// The media folder: the SOLIDWORKS media tree, or one ISO.
        public let path: String
        /// SHA-256 of the folder's `media-manifest.sha256`, lowercase hex.
        public let manifestSHA256: String
    }

    /// Defaults for the member's settings. A setting the member has set stays (`applyDefaults`).
    public struct Defaults: Equatable, Sendable {
        public let language: String?
        public let toolbox: Bool?
        public let driveLetters: Bool?
        /// "all", "1" (as `MACSW_NATIVE_FILE_DIALOGS`) or "off".
        public let macFileDialogs: String?
        public let launchSolidWorksAtStart: Bool?

        static let none = Defaults(language: nil, toolbox: nil, driveLetters: nil, macFileDialogs: nil,
                                   launchSolidWorksAtStart: nil)
    }

    /// What the access key step shows besides the one field. Both are off unless the config
    /// turns them on: a member types the team's SOLIDWORKS serial only.
    public struct Install: Equatable, Sendable {
        /// The fields for the Simulation, Motion and MBD serials.
        public let showOtherKeys: Bool
        /// The licence server choice (the address of a SolidNetWork licence server).
        public let showLicenseServer: Bool

        public static let none = Install(showOtherKeys: false, showLicenseServer: false)
    }

    public let schema: Int
    public let team: String
    public let solidWorks: SolidWorks
    public let media: Media
    /// Folder with vba71.msi and vba71_1033.msi.
    public let vbaPath: String?
    public let defaults: Defaults
    public let install: Install
    /// The update feed (`releases/latest.json`).
    public let updatesFeed: String?
    public let supportContact: String?
    /// The member guide ("Start here.pdf").
    public let supportGuide: String?

    public static let macFileDialogModes = ["all", "1", "off"]

    // MARK: Reading

    public static func load(_ file: URL) throws -> TeamConfig {
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            throw TeamConfigError.unreadable(error.localizedDescription)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> TeamConfig {
        // The schema first: a newer schema may change everything else.
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
            throw TeamConfigError.from(error)
        }
        guard let schema = header.schema else { throw TeamConfigError.invalid("schema is missing") }
        guard schema <= supportedSchema else { throw TeamConfigError.newerSchema(schema) }
        guard schema == supportedSchema else { throw TeamConfigError.invalid("schema must be \(supportedSchema)") }

        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch {
            throw TeamConfigError.from(error)
        }
        let team = raw.team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !team.isEmpty else { throw TeamConfigError.invalid("team is empty") }
        let release = raw.solidworks.release.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFolderName(release) else {
            throw TeamConfigError.invalid("solidworks.release must be a short name such as \"2026 SP4.1\" (no / \\ : and not starting with a dot)")
        }
        let manifest = raw.media.manifestSHA256.lowercased()
        guard manifest.count == 64, manifest.allSatisfy(\.isHexDigit) else {
            throw TeamConfigError.invalid("media.manifestSHA256 must be the 64 hex digits of the SHA-256 of media-manifest.sha256")
        }
        let defaults = raw.defaults.map {
            Defaults(language: $0.language, toolbox: $0.toolbox, driveLetters: $0.driveLetters,
                     macFileDialogs: $0.macFileDialogs, launchSolidWorksAtStart: $0.launchSolidWorksAtStart)
        } ?? .none
        if let mode = defaults.macFileDialogs, !macFileDialogModes.contains(mode) {
            throw TeamConfigError.invalid("defaults.macFileDialogs must be \"all\", \"1\" or \"off\"")
        }
        let config = TeamConfig(
            schema: schema,
            team: team,
            solidWorks: SolidWorks(release: release, build: raw.solidworks.build),
            media: Media(path: raw.media.path, manifestSHA256: manifest),
            vbaPath: raw.vba?.path,
            defaults: defaults,
            install: raw.install.map {
                Install(showOtherKeys: $0.showOtherKeys ?? false, showLicenseServer: $0.showLicenseServer ?? false)
            } ?? .none,
            updatesFeed: raw.updates?.feed,
            supportContact: raw.support?.contact,
            supportGuide: raw.support?.guide
        )
        for (field, path) in config.paths {
            try checkRelative(path, field: field)
        }
        return config
    }

    /// Every path in the config, with its key.
    var paths: [(String, String)] {
        [("media.path", media.path)]
            + [("vba.path", vbaPath), ("updates.feed", updatesFeed), ("support.guide", supportGuide)]
                .compactMap { field, path in path.map { (field, $0) } }
    }

    // MARK: Paths

    /// The media folder below `teamFolder` (the folder that holds the config).
    public func mediaFolder(in teamFolder: URL, fileManager: FileManager = .default) throws -> URL {
        let url = try Self.resolve(media.path, field: "media.path", in: teamFolder, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TeamConfigError.invalid("media.path must name a folder")
        }
        return url
    }

    public func vbaFolder(in teamFolder: URL, fileManager: FileManager = .default) throws -> URL? {
        try vbaPath.map { try Self.resolve($0, field: "vba.path", in: teamFolder, fileManager: fileManager) }
    }

    /// `path` below `teamFolder`. It must exist, and with every link followed it must still be
    /// inside `teamFolder`.
    public static func resolve(_ path: String, field: String, in teamFolder: URL,
                               fileManager: FileManager = .default) throws -> URL {
        try checkRelative(path, field: field)
        let url = teamFolder.appendingPathComponent(path).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { throw TeamConfigError.notFound(field: field, path: path) }
        guard isInside(url, folder: teamFolder) else {
            throw TeamConfigError.unsafePath(field: field, path: path, reason: "it leads out of the team folder")
        }
        return url
    }

    static func checkRelative(_ path: String, field: String) throws {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw TeamConfigError.invalid("\(field) is empty") }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            throw TeamConfigError.unsafePath(field: field, path: path, reason: "it must be relative to the team folder")
        }
        if path.contains("\\") || path.contains("\0") {
            throw TeamConfigError.unsafePath(field: field, path: path, reason: "use / between folder names")
        }
        if path.split(separator: "/").contains("..") {
            throw TeamConfigError.unsafePath(field: field, path: path, reason: "it must not contain ..")
        }
    }

    static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && !name.contains { "/\\:".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }
    }

    /// True when `url` exists and, with every link followed, is `folder` or inside it.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        func real(_ url: URL) -> String? {
            guard let resolved = realpath(url.path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let root = real(folder), let target = real(url) else { return false }
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: Defaults

    /// Writes each team default into `defaults` when the member has no value for it yet, and
    /// returns the keys it wrote. MacSW calls it once, when it imports the config; SOLIDWORKS.app
    /// reads the same preferences. Language and Toolbox are install options, not preferences.
    @discardableResult
    public func applyDefaults(to defaults: UserDefaults) -> [String] {
        var written: [String] = []
        func set(_ key: String, _ value: Bool?) {
            guard let value, defaults.object(forKey: key) == nil else { return }
            defaults.set(value, forKey: key)
            written.append(key)
        }
        set(AppPreferences.mapMacFoldersKey, self.defaults.driveLetters)
        set(AppPreferences.autoLaunchSolidWorksKey, self.defaults.launchSolidWorksAtStart)
        switch self.defaults.macFileDialogs {
        case "all":
            set(AppPreferences.useMacFileDialogsKey, true)
            set(AppPreferences.macFileDialogsEverywhereKey, true)
        case "1":
            set(AppPreferences.useMacFileDialogsKey, true)
            set(AppPreferences.macFileDialogsEverywhereKey, false)
        case "off":
            set(AppPreferences.useMacFileDialogsKey, false)
        default:
            break
        }
        return written
    }

    // MARK: JSON

    private struct Header: Decodable {
        let schema: Int?
    }

    private struct Raw: Decodable {
        struct SolidWorks: Decodable { let release: String; let build: String? }
        struct Media: Decodable { let path: String; let manifestSHA256: String }
        struct Folder: Decodable { let path: String }
        struct Defaults: Decodable {
            let language: String?
            let toolbox: Bool?
            let driveLetters: Bool?
            let macFileDialogs: String?
            let launchSolidWorksAtStart: Bool?
        }
        struct Install: Decodable { let showOtherKeys: Bool?; let showLicenseServer: Bool? }
        struct Updates: Decodable { let feed: String? }
        struct Support: Decodable { let contact: String?; let guide: String? }

        let team: String
        let solidworks: SolidWorks
        let media: Media
        let vba: Folder?
        let defaults: Defaults?
        let install: Install?
        let updates: Updates?
        let support: Support?
    }
}

public enum TeamConfigError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case notJSON
    case newerSchema(Int)
    case invalid(String)
    case unsafePath(field: String, path: String, reason: String)
    case notFound(field: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "The team config could not be read: \(reason)"
        case .notJSON:
            return "The team config is not a valid JSON object."
        case .newerSchema(let schema):
            return "This team config is for a newer MacSW (schema \(schema); this MacSW reads schema \(TeamConfig.supportedSchema)). Ask the team admin for the current MacSW."
        case .invalid(let reason):
            return "The team config is not valid: \(reason)."
        case .unsafePath(let field, let path, let reason):
            return "The team config path \(field) \"\(path)\" is refused: \(reason)."
        case .notFound(let field, let path):
            return "The team folder has no \"\(path)\" (\(field) in the team config)."
        }
    }

    static func from(_ error: Error) -> TeamConfigError {
        guard let error = error as? DecodingError else { return .notJSON }
        func name(_ path: [CodingKey]) -> String { path.map(\.stringValue).joined(separator: ".") }
        switch error {
        case .keyNotFound(let key, let context):
            return .invalid("\(name(context.codingPath + [key])) is missing")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            // An empty path: the file is JSON, but not an object.
            return context.codingPath.isEmpty ? .notJSON : .invalid("\(name(context.codingPath)) has the wrong type")
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? .notJSON : .invalid("\(name(context.codingPath)) is not valid")
        @unknown default:
            return .notJSON
        }
    }
}
