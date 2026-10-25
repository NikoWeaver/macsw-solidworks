import Foundation

public struct SolidWorksLanguage: Identifiable, Hashable, Sendable {
    public let directoryName: String
    public let msiFileName: String
    public let displayName: String

    public init(directoryName: String, msiFileName: String, displayName: String) {
        self.directoryName = directoryName
        self.msiFileName = msiFileName
        self.displayName = displayName
    }

    public var id: String { directoryName }
}

public enum LanguageCatalog {
    public static let relativeDirectory = "swwi/lang"

    private static let displayNames: [String: String] = [
        "chinese": "繁體中文",
        "chinese-simplified": "简体中文",
        "czech": "čeština",
        "dutch": "Nederlands",
        "english": "English",
        "french": "français",
        "german": "Deutsch",
        "italian": "italiano",
        "japanese": "日本語",
        "korean": "한국어",
        "polish": "polski",
        "portuguese-brazilian": "português (Brasil)",
        "russian": "русский",
        "spanish": "español",
        "turkish": "Türkçe"
    ]

    /// 官方介质 swwi/lang 提供的语言；下拉直接用这份，避免为了列清单去挂载介质。
    /// 安装时仍会校验所选语言在介质中确实存在。
    public static let official: [SolidWorksLanguage] = [
        "chinese", "chinese-simplified", "czech", "french", "german", "italian",
        "japanese", "korean", "polish", "portuguese-brazilian", "russian", "spanish", "turkish"
    ].map { SolidWorksLanguage(directoryName: $0, msiFileName: "\($0).msi", displayName: displayName(for: $0)) }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    public static func displayName(for directoryName: String) -> String {
        displayNames[directoryName.lowercased()] ?? directoryName
    }

    public static func discover(in media: URL, fileManager: FileManager = .default) -> [SolidWorksLanguage] {
        let root = media.appendingPathComponent(relativeDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { directory -> SolidWorksLanguage? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = directory.lastPathComponent
            guard let msi = languageMSI(in: directory, name: name, fileManager: fileManager) else { return nil }
            return SolidWorksLanguage(
                directoryName: name,
                msiFileName: msi,
                displayName: displayName(for: name)
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func relativeMSIPath(_ language: SolidWorksLanguage) -> String {
        "\(relativeDirectory)/\(language.directoryName)/\(language.msiFileName)"
    }

    public enum SystemLanguageMatch: Equatable {
        /// 英语就是介质基础语言，不需要追加语言资源。
        case baseLanguage
        case directory(String)
        case unknown
    }

    public static func match(for identifier: String) -> SystemLanguageMatch {
        let parts = identifier.lowercased().split(separator: "-").map(String.init)
        guard let primary = parts.first else { return .unknown }
        switch primary {
        case "en": return .baseLanguage
        case "cs": return .directory("czech")
        case "de": return .directory("german")
        case "es": return .directory("spanish")
        case "fr": return .directory("french")
        case "it": return .directory("italian")
        case "ja": return .directory("japanese")
        case "ko": return .directory("korean")
        case "pl": return .directory("polish")
        case "pt": return .directory("portuguese-brazilian")
        case "ru": return .directory("russian")
        case "tr": return .directory("turkish")
        case "zh":
            if parts.contains(where: { $0.hasPrefix("hant") }) { return .directory("chinese") }
            if parts.dropFirst().contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .directory("chinese") }
            return .directory("chinese-simplified")
        default: return .unknown
        }
    }

    /// 按系统偏好顺序取介质实际提供的语言；都不匹配时保持介质默认语言。
    public static func autoSelection(
        from languages: [SolidWorksLanguage],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> SolidWorksLanguage? {
        for identifier in preferredLanguages {
            switch match(for: identifier) {
            case .baseLanguage:
                return nil
            case .directory(let name):
                if let match = languages.first(where: {
                    $0.directoryName.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    return match
                }
            case .unknown:
                continue
            }
        }
        return nil
    }

    private static func languageMSI(in directory: URL, name: String, fileManager: FileManager) -> String? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let expected = "\(name).msi"
        if let match = files.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame
        }) {
            return match.lastPathComponent
        }
        return files
            .filter { $0.pathExtension.caseInsensitiveCompare("msi") == .orderedSame }
            .map(\.lastPathComponent)
            .sorted()
            .first
    }
}
