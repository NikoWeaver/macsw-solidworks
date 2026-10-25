import Foundation

/// 用户拖入或选择的东西如何变成一份 SOLIDWORKS 安装介质。
public enum ResolvedMedia: Equatable, Sendable {
    case iso(URL)
    /// 介质目录；explicitlySelected 表示用户直接选中的就是这个目录本身。
    case directory(URL, explicitlySelected: Bool)

    /// 安装时真正使用的介质根目录。
    public var mediaDirectory: URL {
        switch self {
        case .iso(let url): return url.deletingLastPathComponent()
        case .directory(let url, _): return url
        }
    }

    public var isIso: Bool {
        if case .iso = self { return true }
        return false
    }

    public var displayURL: URL {
        switch self {
        case .iso(let url): return url
        case .directory(let url, _): return url
        }
    }
}

public enum InstallationMediaResolver {
    public static let maximumDepth = 1

    /// 在给定目录及其一级子目录里定位介质；找不到返回 nil。
    public static func resolve(_ dropped: URL, fileManager: FileManager = .default) -> ResolvedMedia? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dropped.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            let extensionName = dropped.pathExtension.lowercased()
            if extensionName == "iso" { return .iso(dropped.standardizedFileURL) }
            if extensionName == "exe", dropped.lastPathComponent.caseInsensitiveCompare("setup.exe") == .orderedSame {
                return .directory(dropped.deletingLastPathComponent().standardizedFileURL, explicitlySelected: false)
            }
            return nil
        }

        let selected = dropped.standardizedFileURL
        // 先在本级与一级子目录里找 setup.exe，再找 ISO；都按由浅到深、路径排序取首个。
        if let exe = findFile(under: selected, fileManager: fileManager, matches: {
            $0.lastPathComponent.caseInsensitiveCompare("setup.exe") == .orderedSame
        }) {
            return .directory(
                exe.deletingLastPathComponent(),
                explicitlySelected: exe.deletingLastPathComponent().standardizedFileURL == selected
            )
        }
        if fileManager.fileExists(atPath: selected.appendingPathComponent("swwi/data/solidworks.msi").path) {
            return .directory(selected, explicitlySelected: true)
        }
        if let iso = findFile(under: selected, fileManager: fileManager, matches: {
            $0.pathExtension.caseInsensitiveCompare("iso") == .orderedSame
        }) {
            return .iso(iso)
        }
        return nil
    }

    /// 有界深度地找一个文件：同层按路径排序后先取匹配项，再按同样的顺序下钻子目录。
    private static func findFile(
        under directory: URL,
        fileManager: FileManager,
        depth: Int = 0,
        matches: (URL) -> Bool
    ) -> URL? {
        guard depth <= maximumDepth else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let ordered = entries.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        for entry in ordered where isRegularFile(entry) && matches(entry) {
            return entry
        }
        for entry in ordered where isDirectory(entry) {
            if let found = findFile(under: entry, fileManager: fileManager, depth: depth + 1, matches: matches) {
                return found
            }
        }
        return nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Install media that the team wizard found by itself, or that the member dropped.
public struct DiscoveredMedia: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// The finished copy in Application Support (`MediaCopyService`).
        case localCopy
        case teamFolder
        case downloads
        case volume
        case dropped

        public var phrase: String {
            switch self {
            case .localCopy: return "on this Mac (copied earlier)"
            case .teamFolder: return "in your team folder"
            case .downloads: return "in your Downloads folder"
            case .volume: return "on a mounted disk"
            case .dropped: return "where you chose"
            }
        }
    }

    public let media: ResolvedMedia
    public let source: Source
    /// The folder that holds `media-manifest.sha256` when there is one: the team's media folder,
    /// or the media folder itself.
    public let root: URL
    /// Logical size: Box placeholders count with their full size.
    public let sizeBytes: Int64
    /// `root` has `media-manifest.sha256`, so the media can be copied and checked.
    public let hasManifest: Bool

    /// "9.2 GB".
    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

extension InstallationMediaResolver {
    /// The media in this order: a finished local copy, the team config's media folder, `~/Downloads`
    /// (and its first-level folders), then the mounted volumes. Except in the team folder, only real SOLIDWORKS media
    /// counts: a folder with setup.exe and `swwi/data/solidworks.msi`, or an ISO whose name says
    /// SOLIDWORKS ("SOLIDWORKS 2026 SP04.1.iso", "SW2026-SP04.1.iso"). nil: the member drops the
    /// media (`dropped`), as before.
    public static func discover(
        localCopy: URL? = nil,
        teamMedia: URL?,
        downloads: URL?,
        volumes: [URL],
        fileManager: FileManager = .default
    ) -> DiscoveredMedia? {
        if let localCopy, let media = resolve(localCopy, fileManager: fileManager) {
            return discovered(media, source: .localCopy, root: localCopy, fileManager: fileManager)
        }
        if let teamMedia, let media = resolve(teamMedia, fileManager: fileManager) {
            return discovered(media, source: .teamFolder, root: teamMedia, fileManager: fileManager)
        }
        let places = (downloads.map { [($0, DiscoveredMedia.Source.downloads)] } ?? [])
            + volumes.map { ($0, DiscoveredMedia.Source.volume) }
        for (place, source) in places {
            if let media = findSolidWorksMedia(in: place, fileManager: fileManager) {
                return discovered(media, source: source, root: media.mediaDirectory, fileManager: fileManager)
            }
        }
        return nil
    }

    /// A dropped or chosen ISO, setup.exe or folder (`resolve`), with its size.
    public static func dropped(_ url: URL, fileManager: FileManager = .default) -> DiscoveredMedia? {
        resolve(url, fileManager: fileManager).map {
            discovered($0, source: .dropped, root: $0.mediaDirectory, fileManager: fileManager)
        }
    }

    /// Mounted volumes other than the startup disk, for `discover`.
    public static func mountedVolumes(fileManager: FileManager = .default) -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey]
        return (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { (try? $0.resourceValues(forKeys: Set(keys)).volumeIsRootFileSystem) != true }
    }

    static func findSolidWorksMedia(in place: URL, fileManager: FileManager) -> ResolvedMedia? {
        if let exe = findFile(under: place, fileManager: fileManager, matches: {
            $0.lastPathComponent.caseInsensitiveCompare("setup.exe") == .orderedSame
                && fileManager.fileExists(atPath: $0.deletingLastPathComponent()
                    .appendingPathComponent(SilentInstallerPlan.coreMSIRelativePath).path)
        }) {
            return .directory(exe.deletingLastPathComponent(), explicitlySelected: false)
        }
        return findFile(under: place, fileManager: fileManager, matches: {
            $0.pathExtension.caseInsensitiveCompare("iso") == .orderedSame && isSolidWorksImageName($0.lastPathComponent)
        }).map { .iso($0) }
    }

    static func isSolidWorksImageName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("solidworks") || lowered.range(of: #"^sw\s*20\d\d"#, options: .regularExpression) != nil
    }

    private static func discovered(_ media: ResolvedMedia, source: DiscoveredMedia.Source, root: URL,
                                   fileManager: FileManager) -> DiscoveredMedia {
        DiscoveredMedia(media: media, source: source, root: root.standardizedFileURL,
                        sizeBytes: size(of: media, fileManager: fileManager),
                        hasManifest: fileManager.fileExists(atPath: root.appendingPathComponent(MediaManifest.fileName).path))
    }

    /// An ISO's file size, or the sum of the regular files in a media folder (hidden files skipped).
    public static func size(of media: ResolvedMedia, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        switch media {
        case .iso(let url):
            return Int64((try? url.resourceValues(forKeys: keys).fileSize) ?? 0)
        case .directory(let url, _):
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }
    }
}
