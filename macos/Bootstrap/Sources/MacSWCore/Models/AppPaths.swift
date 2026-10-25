import Foundation

public struct AppPaths: Sendable {
    public let appSupportDirectory: URL
    public let bottle: URL
    public let logs: URL
    /// Local copies of the install media, one folder per SOLIDWORKS release (`MediaCopyService`).
    public let media: URL
    /// The imported team config (`TeamConfigLocator`).
    public let teamConfig: URL

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory.standardizedFileURL
        self.bottle = self.appSupportDirectory.appendingPathComponent("bottle", isDirectory: true)
        self.logs = self.appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        self.media = self.appSupportDirectory.appendingPathComponent("media", isDirectory: true)
        self.teamConfig = self.appSupportDirectory.appendingPathComponent("team.json")
    }

    public static func live(fileManager: FileManager = .default) -> AppPaths {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSW", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return AppPaths(appSupportDirectory: root)
    }

    public var bottleExists: Bool {
        FileManager.default.fileExists(atPath: bottle.path)
    }

    public var solidWorksExecutable: URL {
        Self.resolveSolidWorksExecutable(in: bottle)
    }

    public var solidWorksInstalled: Bool {
        FileManager.default.fileExists(atPath: solidWorksExecutable.path)
    }

    private final class ExecutableCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: URL] = [:]
        var generation = 0
    }

    private static let executableCache = ExecutableCache()

    /// 解析结果按容器路径缓存：system.reg 有十几 MB，逐行扫描不能出现在界面刷新路径上。
    public static func resolveSolidWorksExecutable(in bottle: URL, fileManager: FileManager = .default) -> URL {
        let key = bottle.standardizedFileURL.path
        executableCache.lock.lock()
        if let cached = executableCache.values[key] {
            executableCache.lock.unlock()
            return cached
        }
        let generation = executableCache.generation
        executableCache.lock.unlock()
        let resolved = locateSolidWorksExecutable(in: bottle, fileManager: fileManager)
        executableCache.lock.lock()
        // 扫描期间磁盘状态变过（安装写入、容器被删），这份结果已经过期，留下就会一直指错。
        if generation == executableCache.generation { executableCache.values[key] = resolved }
        executableCache.lock.unlock()
        return resolved
    }

    /// 安装完成、容器被删除等改变磁盘状态之后必须调用。
    public static func invalidateInstallationState() {
        executableCache.lock.lock()
        executableCache.values.removeAll()
        executableCache.generation += 1
        executableCache.lock.unlock()
    }

    private static func locateSolidWorksExecutable(in bottle: URL, fileManager: FileManager) -> URL {
        let systemRegistry = bottle.appendingPathComponent("system.reg")
        // 注册表文本 hive 的编码不止一种（BOM/传统代码页都见过），按解码器兜底读。
        if let contents = (try? Data(contentsOf: systemRegistry)).flatMap(PlainTextDecoder.decode) {
            for line in contents.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("\"SolidWorks Folder\"="), let separator = text.firstIndex(of: "=") else { continue }
                let value = text[text.index(after: separator)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n"))
                    .replacingOccurrences(of: "\\\\", with: "/")
                    .replacingOccurrences(of: "\\", with: "/")
                guard value.lowercased().hasPrefix("c:/") else { continue }
                let relative = String(value.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let candidate = bottle.appendingPathComponent("drive_c")
                    .appendingPathComponent(relative)
                    .appendingPathComponent("SLDWORKS.exe")
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        let common = [
            "drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe",
            "drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"
        ].map { bottle.appendingPathComponent($0) }
        if let existing = common.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existing
        }

        let programFiles = bottle.appendingPathComponent("drive_c/Program Files")
        if let enumerator = fileManager.enumerator(
            at: programFiles,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent.caseInsensitiveCompare("SLDWORKS.exe") == .orderedSame {
                return url
            }
        }
        return common[0]
    }
}
