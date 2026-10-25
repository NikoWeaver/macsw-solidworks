import Foundation

/// 静默安装会一次性走完整个部署，因此必须在做任何改动之前确认介质完整，
/// 避免把用户带到装了一半的状态。
public enum InstallationMedia {
    public struct Component: Equatable, Sendable {
        public let relativePath: String
        public let label: String

        public init(relativePath: String, label: String) {
            self.relativePath = relativePath
            self.label = label
        }
    }

    public static let requiredComponents: [Component] = [
        Component(relativePath: SilentInstallerPlan.coreMSIRelativePath, label: "SOLIDWORKS core MSI"),
        Component(
            relativePath: "PreReqs/VCRedist17/VC_redist.x64.exe",
            label: "Official VC++ x64 runtime"
        ),
        Component(
            relativePath: "swloginmgr/SOLIDWORKS Login Manager.msi",
            label: "SOLIDWORKS Login Manager"
        )
    ]

    /// WPF 主题来源：SOLIDWORKS 2026 介质带 .NET 4.8.1，旧介质带 4.8，两者都认，优先 4.8.1。
    public static let dotNetDirectory = "PreReqs/dotNetFx"
    public static let dotNetComponent = Component(
        relativePath: "\(dotNetDirectory)/ndp48*-x86-x64-allos-enu.exe",
        label: "Official .NET 4.8 / 4.8.1 installer (source of the WPF themes)"
    )

    public static func dotNetInstaller(
        in media: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory = media.appendingPathComponent(dotNetDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = entries.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("ndp48"), name.hasSuffix(".exe"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return false }
            return (values.fileSize ?? 0) > 0
        }
        return candidates.min {
            let lhs = $0.lastPathComponent.lowercased(), rhs = $1.lastPathComponent.lowercased()
            let lhsNew = lhs.hasPrefix("ndp481"), rhsNew = rhs.hasPrefix("ndp481")
            return lhsNew != rhsNew ? lhsNew : lhs < rhs
        }
    }

    public static let toolboxDirectory = "Toolbox"

    /// 安装摘要里的一行说明：Toolbox 不在必需组件内，缺失时只跳过部署步骤。
    public static let toolboxSkippedNote = "Toolbox not installed: the media has no Toolbox folder (or no ZIP standard parts packages in it)"

    public static func missingComponents(
        in media: URL,
        language: SolidWorksLanguage?,
        fileManager: FileManager = .default
    ) -> [Component] {
        var missing = requiredComponents.filter { !hasFile(at: media, relativePath: $0.relativePath, fileManager: fileManager) }
        if let language,
           !hasFile(at: media, relativePath: LanguageCatalog.relativeMSIPath(language), fileManager: fileManager) {
            missing.append(Component(
                relativePath: LanguageCatalog.relativeMSIPath(language),
                label: "\(language.displayName) language resources"
            ))
        }
        if dotNetInstaller(in: media, fileManager: fileManager) == nil {
            missing.append(dotNetComponent)
        }
        return missing
    }

    private static func hasFile(at media: URL, relativePath: String, fileManager: FileManager) -> Bool {
        let path = media.appendingPathComponent(relativePath).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return false }
        return (attributes[.size] as? Int) ?? 0 > 0
    }

    /// Toolbox 是可选载荷（体积大，介质可以先不带）：没有 Toolbox 文件夹、或文件夹里没有
    /// 非空 ZIP 都返回 false，调用方据此跳过 ToolboxService，而不是判介质不完整。
    public static func hasToolboxPayload(in media: URL, fileManager: FileManager = .default) -> Bool {
        let directory = media.appendingPathComponent(toolboxDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.contains { url in
            guard url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return false }
            return (values.fileSize ?? 0) > 0
        }
    }
}
