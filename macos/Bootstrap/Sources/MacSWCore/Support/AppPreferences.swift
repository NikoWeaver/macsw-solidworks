import Foundation

/// 应用级偏好的单一来源：键名与默认值只在这里定义一次。
public enum AppPreferences {
    public static let autoLaunchSolidWorksKey = "MacSW.autoLaunchSolidWorks"

    /// 打开 MacSW 只为了看状态和改设置，因此默认不自动拉起 SOLIDWORKS。
    public static let autoLaunchSolidWorksDefault = false

    public static func autoLaunchSolidWorks(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoLaunchSolidWorksKey) != nil else {
            return autoLaunchSolidWorksDefault
        }
        return defaults.bool(forKey: autoLaunchSolidWorksKey)
    }

    /// Wine/Windows locale (single setting). It drives LANG/LC_ALL for every Wine process,
    /// and therefore the Windows ANSI code page: en_US -> 1252/437, zh_CN -> 936.
    /// Shell/Python launchers read the same key with `defaults read` (see scripts/swcli).
    public static let wineLocaleKey = "MacSW.wineLocale"
    public static let wineLocaleDefault = "en_US.UTF-8"
    public static let supportedWineLocales = ["en_US.UTF-8", "zh_CN.UTF-8"]

    /// Unknown or missing values fall back to the default so a stray value never reaches Wine.
    public static func wineLocale(defaults: UserDefaults = .standard) -> String {
        guard let value = defaults.string(forKey: wineLocaleKey),
              supportedWineLocales.contains(value) else {
            return wineLocaleDefault
        }
        return value
    }

    /// "Use macOS file dialogs" (default on): SOLIDWORKS gets NSOpenPanel/NSSavePanel instead of
    /// Wine's Windows-style dialogs (Wine patches 0023/0024, MACSW_NATIVE_FILE_DIALOGS). On by
    /// default since the hidden dialog window of patch 0024 fixed the SOLIDWORKS 2026 File > Open
    /// crash (docs/native-file-dialogs.md).
    public static let useMacFileDialogsKey = "MacSW.useMacFileDialogs"
    public static let useMacFileDialogsDefault = true

    public static func useMacFileDialogs(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: useMacFileDialogsKey) != nil else {
            return useMacFileDialogsDefault
        }
        return defaults.bool(forKey: useMacFileDialogsKey)
    }

    /// "Give Mac folders drive letters" (default on): before every SOLIDWORKS launch MacSW maps
    /// H: (home), B: (Box), I: (iCloud Drive) and the other cloud folders, and links the cloud
    /// folders into the Windows profile (`DriveMapService`). Off: MacSW adds nothing; letters and
    /// links that exist stay. SOLIDWORKS.app reads it from MacSW's domain (its launcher adds it).
    public static let mapMacFoldersKey = "MacSW.mapMacFoldersToDrives"
    public static let mapMacFoldersDefault = true

    public static func mapMacFolders(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: mapMacFoldersKey) != nil else {
            return mapMacFoldersDefault
        }
        return defaults.bool(forKey: mapMacFoldersKey)
    }

    /// Not in Settings (default on): the Mac panel also where SOLIDWORKS embeds its own pane in
    /// the dialog (File > Open options, which are then not shown; MACSW_NATIVE_FILE_DIALOGS=all).
    /// Off gives `1`: rule 5 keeps the Windows-style dialog there (docs/native-file-dialogs.md).
    public static let macFileDialogsEverywhereKey = "MacSW.macFileDialogsEverywhere"
    public static let macFileDialogsEverywhereDefault = true

    public static func macFileDialogsEverywhere(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: macFileDialogsEverywhereKey) != nil else {
            return macFileDialogsEverywhereDefault
        }
        return defaults.bool(forKey: macFileDialogsEverywhereKey)
    }

    /// SHA-256 of the SOLIDWORKS.app build whose "Install SOLIDWORKS App" suggestion was dismissed
    /// (`SolidWorksAppStore.suggestsInstall`): the next MacSW build offers it again.
    public static let solidWorksAppSuggestionDismissedKey = "MacSW.solidWorksAppSuggestionDismissed"

    /// Folder with vba71.msi and vba71_1033.msi (`VBAPrerequisite`). Settings → Maintenance → Install VBA
    /// saves the folder it installed from; the installer searches it after the media's own VBA folders.
    public static let vbaInstallerFolderKey = "MacSW.vbaInstallerFolder"

    public static func vbaInstallerFolder(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: vbaInstallerFolderKey), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func setVBAInstallerFolder(_ folder: URL, defaults: UserDefaults = .standard) {
        defaults.set(folder.standardizedFileURL.path, forKey: vbaInstallerFolderKey)
    }

    /// "Do not warn again" in the launch-time alert about missing VBA.
    public static let vbaWarningSuppressedKey = "MacSW.vbaWarningSuppressed"

    /// The team folder of the imported team config (`TeamConfigLocator`): the config's paths are
    /// relative to it, not to the imported copy in Application Support.
    public static let teamFolderKey = "MacSW.teamFolder"

    public static func teamFolder(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: teamFolderKey), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func setTeamFolder(_ folder: URL, defaults: UserDefaults = .standard) {
        defaults.set(folder.standardizedFileURL.path, forKey: teamFolderKey)
    }

    /// "Do not ask again" in the launch-time question about the download flag (`DownloadQuarantine`).
    public static let downloadFlagQuestionSuppressedKey = "MacSW.downloadFlagQuestionSuppressed"
}

public enum BootstrapWindowIdentity {
    /// 用于在 13/14 上精确关闭引导窗口，避免按标题字符串匹配。
    public static let identifier = "MacSW.bootstrap"
}
