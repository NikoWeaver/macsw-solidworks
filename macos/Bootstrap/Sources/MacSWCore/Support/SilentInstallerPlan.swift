import Foundation

/// 官方 SOLIDWORKS MSI 在 Wine 下静默安装所需的参数与属性集合。
public enum SilentInstallerPlan {
    public static let coreMSIRelativePath = "swwi/data/solidworks.msi"

    /// SOLIDWORKS 的核心特性树定义在 INSTALLLEVEL 100；静默安装没有交互式
    /// 特性选择界面，必须显式列出嵌套依赖，否则单靠 ADDLOCAL=SolidWorks 装不全。
    public static let defaultMSIProperties = [
        "INSTALLLEVEL=100",
        // i386_CosmosXpressFiles holds cosworks.dll (SOLIDWORKS Simulation add-in core). It is a
        // hidden Level-100 child of i386_ProgramFiles without FollowParent, so it is installed only
        // when named here; without it SOLIDWORKS says "cosworks.dll is incompatible".
        "ADDLOCAL=SolidWorks,ProgramFiles,i386_ProgramFiles,i386_ThirdPtyFiles,i386_DCubeFiles,i386_SWFiles,i386_VistaFiles,i386_CosmosXpressFiles",
        "ENABLEPERFORMANCE=0",
        "OFFICEOPTION=3",
        // MSI 的默认值是相对路径，Wine 下会让 InstallFinalize 阶段的
        // WriteToolboxStandardsXML 失败，改用无空格的绝对路径。
        "TOOLBOXFOLDER=C:\\SWData"
    ]

    public static func coreInstallArguments(
        msi: URL, log: URL, serials: InstallSerials, addLocal: [String]? = nil
    ) -> [String] {
        msiexecArguments(msi: msi, log: log, properties: coreMSIProperties(addLocal: addLocal) + serials.msiProperties)
    }

    /// `addLocal` replaces only the ADDLOCAL entry; every other default property stays.
    public static func coreMSIProperties(addLocal: [String]?) -> [String] {
        guard let addLocal else { return defaultMSIProperties }
        return defaultMSIProperties.map {
            $0.hasPrefix("ADDLOCAL=") ? "ADDLOCAL=\(addLocal.joined(separator: ","))" : $0
        }
    }

    public static func languageInstallArguments(msi: URL, log: URL) -> [String] {
        msiexecArguments(msi: msi, log: log, properties: [])
    }

    /// VBA 7.1 is a prerequisite like the Login Manager: no UI at all (`/qn`) and no properties.
    public static func vbaInstallArguments(msi: URL, log: URL) -> [String] {
        ["msiexec", "/i", msi.path, "/qn", "/norestart", "DISABLEROLLBACK=1", "/l*v", log.path]
    }

    /// 关闭静默安装时只带日志参数，其余交给官方安装向导。
    public static func interactiveInstallArguments(msi: URL, log: URL) -> [String] {
        ["msiexec", "/i", msi.path, "DISABLEROLLBACK=1", "/l*v", log.path]
    }

    static func msiexecArguments(msi: URL, log: URL, properties: [String]) -> [String] {
        var arguments = [
            "msiexec", "/i", msi.path, "/qb", "/norestart", "DISABLEROLLBACK=1",
            "/l*v", log.path
        ]
        arguments.append(contentsOf: properties)
        return arguments
    }

    /// SOLIDWORKS 2026 只支持 Windows 11；Wine 默认版本由补丁决定。
    /// 这一步在 MSI 之前对容器执行 `winecfg /v`，默认不启用。
    public static func windowsVersionArguments(_ version: WindowsVersion) -> [String] {
        ["winecfg", "/v", version.rawValue]
    }
}

/// `winecfg /v` 接受的 Windows 版本名。
public enum WindowsVersion: String, CaseIterable, Sendable {
    case windows10 = "win10"
    case windows11 = "win11"
}
