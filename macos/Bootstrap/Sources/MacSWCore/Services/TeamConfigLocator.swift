import Foundation

/// Finds `macsw-team.json` (`TeamConfig`), in this order (docs/team-admin.md):
/// 1. the imported copy in Application Support (`AppPaths.teamConfig`), with the team folder that
///    was saved when it was imported (`AppPreferences.teamFolder`);
/// 2. the folders that hold the app or the DMG it runs from (the caller names them);
/// 3. `~/Downloads`;
/// 4. `~/Library/CloudStorage/Box-*/MacSW/` and `Box-*/<top-level folder>/MacSW/`: names only,
///    no deep scan of Box.
/// The first valid config wins. If none is valid, the first invalid one is reported, so the admin
/// learns what to fix. Before it reads a file in Desktop, Documents, Downloads or a cloud folder,
/// it asks `mayOpen` for that folder: there macOS shows its consent prompt, and the native app
/// must take it (`FolderConsentService`).
public enum TeamConfigLocator {
    public enum Source: String, Sendable {
        case imported
        case appFolder
        case downloads
        case box
        case chosen

        /// "in your team folder" and so on, for "Found SOLIDWORKS 2026 SP4.1 …".
        public var phrase: String {
            switch self {
            case .imported: return "in the team config MacSW imported earlier"
            case .appFolder: return "next to MacSW"
            case .downloads: return "in your Downloads folder"
            case .box: return "in your Box team folder"
            case .chosen: return "in the folder you chose"
            }
        }
    }

    public struct Found: Equatable, Sendable {
        public let config: TeamConfig
        /// The file that was read (for `.imported`, the copy in Application Support).
        public let file: URL
        /// The folder that the config's paths are relative to.
        public let teamFolder: URL
        public let source: Source
    }

    public enum Outcome: Equatable, Sendable {
        case found(Found)
        case invalid(file: URL, message: String)
        case notFound
    }

    public static let boxPrefix = "Box-"
    public static let teamFolderName = "MacSW"

    public static func locate(
        paths: AppPaths,
        defaults: UserDefaults = .standard,
        appFolders: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        mayOpen: (URL) async -> Bool
    ) async -> Outcome {
        var firstInvalid: Outcome?
        func consider(_ outcome: Outcome?) -> Found? {
            switch outcome {
            case .found(let found)?: return found
            case .invalid?: if firstInvalid == nil { firstInvalid = outcome }
            case .notFound?, nil: break
            }
            return nil
        }
        /// False when `folder` is in a protected folder that macOS did not open for MacSW.
        func readable(_ folder: URL) async -> Bool {
            guard let protected = FolderConsentService.protectedFolder(containing: folder, home: home) else { return true }
            return await mayOpen(protected.url)
        }

        if fileManager.fileExists(atPath: paths.teamConfig.path), let folder = AppPreferences.teamFolder(defaults: defaults),
           let found = consider(examine(paths.teamConfig, teamFolder: folder, source: .imported)) {
            return .found(found)
        }
        for folder in appFolders where await readable(folder) {
            if let found = consider(examine(folder.appendingPathComponent(TeamConfig.fileName), source: .appFolder)) {
                return .found(found)
            }
        }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        if await readable(downloads),
           let found = consider(examine(downloads.appendingPathComponent(TeamConfig.fileName), source: .downloads)) {
            return .found(found)
        }
        for root in boxRoots(home: home, fileManager: fileManager) where await mayOpen(root) {
            for folder in boxTeamFolders(in: root, fileManager: fileManager) {
                if let found = consider(examine(folder.appendingPathComponent(TeamConfig.fileName), source: .box)) {
                    return .found(found)
                }
            }
        }
        return firstInvalid ?? .notFound
    }

    /// "Choose team folder…": the folder with `macsw-team.json`, or the file itself.
    public static func examineChosen(_ url: URL, fileManager: FileManager = .default) -> Outcome {
        var isDirectory: ObjCBool = false
        let isFolder = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let file = isFolder ? url.appendingPathComponent(TeamConfig.fileName) : url
        return examine(file, source: .chosen) ?? .invalid(
            file: file, message: "\(url.lastPathComponent) has no \(TeamConfig.fileName). Choose the team's MacSW folder."
        )
    }

    /// nil when there is no file; otherwise the parsed config or why it is not valid.
    static func examine(_ file: URL, teamFolder: URL? = nil, source: Source,
                        fileManager: FileManager = .default) -> Outcome? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        do {
            let config = try TeamConfig.load(file)
            return .found(Found(config: config, file: file.standardizedFileURL,
                                teamFolder: (teamFolder ?? file.deletingLastPathComponent()).standardizedFileURL,
                                source: source))
        } catch {
            return .invalid(file: file, message: error.localizedDescription)
        }
    }

    /// The Box Drive folders in ~/Library/CloudStorage (Box-Box, or Box-<account>). Reading this
    /// listing raises no prompt; reading inside a Box folder can.
    public static func boxRoots(home: URL, fileManager: FileManager = .default) -> [URL] {
        DriveMapService.folders(home: home, fileManager: fileManager)
            .filter { $0.key.hasPrefix("cloud:\(boxPrefix)") }
            .map(\.url)
    }

    /// `<root>/MacSW`, then `<root>/<each top-level folder>/MacSW`, sorted by name.
    static func boxTeamFolders(in root: URL, fileManager: FileManager = .default) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
        let folders = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return [root.appendingPathComponent(teamFolderName, isDirectory: true)]
            + folders.filter { $0.lastPathComponent.caseInsensitiveCompare(teamFolderName) != .orderedSame }
                .map { $0.appendingPathComponent(teamFolderName, isDirectory: true) }
    }

    /// Keeps a copy of the config in Application Support, remembers its team folder, and writes
    /// the team defaults the member has not set (`TeamConfig.applyDefaults`). The copy is the
    /// config exactly as read, so a later search finds it first without reading Box.
    public static func importConfig(_ found: Found, paths: AppPaths, defaults: UserDefaults = .standard) throws {
        if found.source != .imported {
            let data = try Data(contentsOf: found.file)
            try FileManager.default.createDirectory(at: paths.appSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: paths.teamConfig, options: .atomic)
        }
        AppPreferences.setTeamFolder(found.teamFolder, defaults: defaults)
        found.config.applyDefaults(to: defaults)
    }
}
