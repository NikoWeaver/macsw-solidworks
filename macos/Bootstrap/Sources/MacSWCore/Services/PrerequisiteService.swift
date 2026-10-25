import CryptoKit
import Foundation

public final class PrerequisiteService: @unchecked Sendable {
    public static let shared = PrerequisiteService()
    public static let themes = ["Luna", "Aero", "Classic", "Royale", "AeroLite"]
    public static let stdoleDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/stdole.dll"
    public static let loginManagerDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/LoginManager/sldLoginManager.dll"
    public static let swcliDestination = "drive_c/MacSW/Python311"

    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func configureMono(prefix: URL) async throws {
        let mono = wine.runtimeURL.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let data = try Data(contentsOf: mono.appendingPathComponent("bin/libmono-2.0-x86.dll"))
        guard Self.sha256(data) == BuildInfo.monoPatchSHA256 else {
            throw failure("Verification of the App's patched Mono failed; use a repackaged App.")
        }
        let windowsPath = "Z:" + mono.path.replacingOccurrences(of: "/", with: "\\")
        let process = wine.makeProcess(arguments: [
            "reg", "add", "HKCU\\Software\\Wine\\Mono", "/v", "RuntimePath", "/t", "REG_SZ",
            "/d", windowsPath, "/f"
        ], prefix: prefix)
        let code = try await wine.runCancellable(
            process,
            log: wine.logDirectory(prefix.path).appendingPathComponent("mono-runtime.log")
        )
        guard code == 0 else { throw failure("Mono runtime configuration failed; see mono-runtime.log.") }
    }

    public func prepareManagedCOMRegistration(prefix: URL) throws {
        try Self.prepareManagedCOMRegistration(runtime: wine.runtimeURL, prefix: prefix)
    }

    public static func prepareManagedCOMRegistration(
        runtime: URL,
        prefix: URL,
        expectedMscorlibSHA256: String = BuildInfo.monoMscorlibSHA256,
        expectedRegAsmX86SHA256: String = BuildInfo.monoRegAsmX86SHA256,
        expectedRegAsmX64SHA256: String = BuildInfo.monoRegAsmX64SHA256
    ) throws {
        let fileManager = FileManager.default
        let monoRoot = runtime.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let mscorlib = monoRoot.appendingPathComponent("lib/mono/4.5/mscorlib.dll")
        guard Self.sha256(try Data(contentsOf: mscorlib)) == expectedMscorlibSHA256 else {
            throw Self.failure("Verification of the App's Wine-Mono COM registration runtime failed; use a repackaged App.")
        }
        let mappings = [
            ("x86_64-windows", "Framework64", expectedRegAsmX64SHA256),
            ("i386-windows", "Framework", expectedRegAsmX86SHA256)
        ]
        for (architecture, framework, expectedHash) in mappings {
            try Task.checkCancellation()
            let source = runtime.appendingPathComponent("lib/wine/\(architecture)/regasm.exe")
            let data = try Data(contentsOf: source)
            guard Self.sha256(data) == expectedHash else {
                throw Self.failure("Verification of the App's \(framework) RegAsm failed; use a repackaged App.")
            }
            let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(framework)/v4.0.30319/regasm.exe")
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path), try Data(contentsOf: target) == data { continue }
            try data.write(to: target, options: .atomic)
        }
        let logs = prefix.deletingLastPathComponent().appendingPathComponent("logs")
        let message = "\(Date()): Wine-Mono COM registration runtime verified; managed x86/x64 RegAsm frontends installed. Runtime: \(runtime.path)\n"
        try LogFiles.write(Data(message.utf8), to: logs.appendingPathComponent("managed-com-registration.log"))
    }

    public func prepareManagedCOMDependencies(prefix: URL) throws {
        try Self.prepareManagedCOMDependencies(bundleURL: MacSWBundle.url, prefix: prefix)
    }

    public func prepareSWCLI(prefix: URL) throws {
        try Self.prepareSWCLI(bundleURL: MacSWBundle.url, prefix: prefix, installing: wine.isInstalling(prefix: prefix))
    }

    /// SWCLI is optional in this fork. Only its packaging step writes
    /// runtime-manifest.json, so the file marks a build that includes it.
    public static func swcliIncluded(bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL
            .appendingPathComponent("Contents/Resources/SWCLI/runtime-manifest.json").path)
    }

    public static func prepareSWCLI(bundleURL: URL, prefix: URL, installing: Bool = false) throws {
        guard swcliIncluded(bundleURL: bundleURL) else { return }
        let runtimeState = WineRuntimeService.status(prefix: prefix, bundle: bundleURL)
        guard runtimeState.allowsLaunch || (installing && runtimeState == .baseline) else {
            throw failure(runtimeState.message + " Open Settings → Maintenance.")
        }
        let contents = bundleURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/SWCLI")
        let helper = resources.appendingPathComponent("bin/swcli_runtime.py")
        let python = resources.appendingPathComponent("runtime/PythonNative/bin/python3")
        guard FileManager.default.fileExists(atPath: helper.path),
              FileManager.default.isExecutableFile(atPath: python.path) else {
            throw failure("The SWCLI sync components bundled in MacSW are incomplete; download the complete MacSW.app again.")
        }
        // A file captures output without waiting on inherited Wine pipe handles.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-swcli-sync-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw failure("Could not create the SWCLI sync log.")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-B", helper.path, "--contents", contents.path, "--prefix", prefix.path]
        if installing { process.arguments?.append("--installing") }
        process.environment = WineService.shared.environment(winePrefix: prefix, solidWorks: true)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: output), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(message.isEmpty ? "SWCLI backend sync failed; the original version was not overwritten." : message)
        }
    }

    public static func prepareManagedCOMDependencies(
        bundleURL: URL = MacSWBundle.url,
        prefix: URL,
        expectedSHA256: String = BuildInfo.stdoleSHA256
    ) throws {
        let source = bundleURL.appendingPathComponent("Contents/Resources/managed/stdole.dll")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Self.failure("The App is missing stdole \(BuildInfo.stdoleVersion); use a repackaged App.")
        }
        let data = try Data(contentsOf: source)
        guard Self.sha256(data) == expectedSHA256 else {
            throw Self.failure("Verification of the App's stdole \(BuildInfo.stdoleVersion) failed; use a repackaged App.")
        }
        let target = prefix.appendingPathComponent(Self.stdoleDestination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: target) == data { return }
        try data.write(to: target, options: .atomic)
    }

    public func installVC(media: URL, prefix: URL) async throws {
        let installer = media.appendingPathComponent("PreReqs/VCRedist17/VC_redist.x64.exe")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("The chosen media is missing VC_redist.x64.exe.")
        }
        let logs = wine.logDirectory(prefix.path)
        // The installer writes this log itself; created 0600 first so it keeps that mode.
        try LogFiles.prepare(logs.appendingPathComponent("vcredist-x64.log"))
        let windowsLog = try await wine.windowsPath(
            for: logs.appendingPathComponent("vcredist-x64.log"), prefix: prefix
        )
        let process = wine.makeProcess(arguments: [
            installer.path, "/install", "/quiet", "/norestart", "/log",
            windowsLog
        ], prefix: prefix)
        let code = try await wine.runCancellable(process, log: logs.appendingPathComponent("vcredist-wine.log"))
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("VC++ installation failed (\(code)); see \(logs.path).")
        }
        for library in WineService.vcLibraries {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/\(library).dll").path) else {
                throw failure("\(library).dll is still missing after the VC++ install.")
            }
        }
    }

    public func installLoginManager(media: URL, prefix: URL) async throws {
        let installer = media.appendingPathComponent("swloginmgr/SOLIDWORKS Login Manager.msi")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("The chosen media is missing swloginmgr/SOLIDWORKS Login Manager.msi.")
        }
        let logs = wine.logDirectory(prefix.path)
        let msiLog = logs.appendingPathComponent("login-manager-install.log")
        try LogFiles.prepare(msiLog)  // msiexec writes it; 0600 beforehand keeps it 0600
        let process = wine.makeProcess(arguments: [
            "msiexec", "/i", installer.path, "/qn", "/norestart", "DISABLEROLLBACK=1",
            "/l*v", msiLog.path
        ], prefix: prefix)
        let code = try await wine.runCancellable(process, log: logs.appendingPathComponent("login-manager-wine.log"))
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("SOLIDWORKS Login Manager installation failed (\(code)); see \(msiLog.path).")
        }
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent(Self.loginManagerDestination).path) else {
            throw failure("The Login Manager installer exited, but sldLoginManager.dll was not found.")
        }
    }

    /// Installs `VBAPrerequisite.installerNames` in order. The MSIs are copied into the bottle
    /// first, so Wine never reads the source folder: it may be a cloud or protected folder whose
    /// macOS consent prompt would freeze wineserver (the native app takes that prompt instead).
    /// With `knownSHA256` (the team install), the staged copies must match it before msiexec runs.
    public func installVBA(installers: [URL], prefix: URL, knownSHA256: [String: String]? = nil) async throws {
        let fileManager = FileManager.default
        let staging = prefix.appendingPathComponent("drive_c/windows/temp/MacSW-VBA-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let logs = wine.logDirectory(prefix.path)
        var stagedInstallers: [URL] = []
        for installer in installers {
            try Task.checkCancellation()
            let staged = staging.appendingPathComponent(installer.lastPathComponent.lowercased())
            try fileManager.copyItem(at: installer, to: staged)
            stagedInstallers.append(staged)
        }
        // The files msiexec reads, all checked before the first one runs.
        if let knownSHA256 { try VBAPrerequisite.checkKnownHashes(stagedInstallers, known: knownSHA256) }
        for staged in stagedInstallers {
            try Task.checkCancellation()
            let name = staged.deletingPathExtension().lastPathComponent
            let msiLog = logs.appendingPathComponent("\(name)-install.log")
            try LogFiles.prepare(msiLog)  // msiexec writes it; 0600 beforehand keeps it 0600
            let code = try await wine.runMSIExec(
                arguments: SilentInstallerPlan.vbaInstallArguments(msi: staged, log: msiLog),
                prefix: prefix,
                log: logs.appendingPathComponent("vba-wine.log")
            )
            guard WineService.isSuccessfulPrerequisiteStatus(code) else {
                throw failure("\(staged.lastPathComponent) installation failed (\(code)); see \(msiLog.path).")
            }
        }
        guard fileManager.fileExists(atPath: prefix.appendingPathComponent(VBAPrerequisite.apcDestination).path) else {
            throw failure("The VBA installers exited, but \(VBAPrerequisite.apcLibrary) was not found.")
        }
    }

    public func installLanguage(media: URL, language: SolidWorksLanguage, prefix: URL) async throws {
        let installer = media.appendingPathComponent(LanguageCatalog.relativeMSIPath(language))
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("The chosen media is missing the \(language.displayName) language resources.")
        }
        let logs = wine.logDirectory(prefix.path)
        let msiLog = logs.appendingPathComponent("language-install.log")
        try LogFiles.prepare(msiLog)  // msiexec writes it; 0600 beforehand keeps it 0600
        let code = try await wine.runMSIExec(
            arguments: SilentInstallerPlan.languageInstallArguments(msi: installer, log: msiLog),
            prefix: prefix,
            log: logs.appendingPathComponent("language-wine.log")
        )
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("\(language.displayName) language resources installation failed (\(code)); see \(msiLog.path).")
        }
        let resources = AppPaths.resolveSolidWorksExecutable(in: prefix)
            .deletingLastPathComponent()
            .appendingPathComponent("lang/\(language.directoryName)")
        guard FileManager.default.fileExists(atPath: resources.path) else {
            throw failure("The language installer exited, but \(resources.path) was not found.")
        }
    }

    /// Wine 侧部分安装动作会按 8.3 短名解析 Program Files；真实目录存在时补符号链接。
    public static func prepareShortNameAliases(prefix: URL, fileManager: FileManager = .default) throws {
        for (directory, alias) in [("Program Files", "PROGRA~1"), ("Program Files (x86)", "PROGRA~2")] {
            let root = prefix.appendingPathComponent("drive_c")
            guard fileManager.fileExists(atPath: root.appendingPathComponent(directory).path) else { continue }
            let link = root.appendingPathComponent(alias)
            let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey])
            // 已经是指向正确目标的链接就跳过；是真实目录时绝不覆盖删除。
            if values?.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) ?? ""
                if destination == directory { continue }
                try fileManager.removeItem(at: link)
            } else if values?.isSymbolicLink == false {
                continue
            }
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: directory)
        }
    }

    public func prepareShortNameAliases(prefix: URL) throws {
        try Self.prepareShortNameAliases(prefix: prefix)
    }

    /// Wine 把 drive_c/users/<用户>/Desktop 链接到真实的 macOS 桌面，官方 MSI 创建的
    /// .lnk 因此泄漏到桌面（winecfg「桌面整合」页显示的 Links to 就是这个链接）。
    /// 安装期间把 Desktop 换成容器内真实目录，结束后按原目标恢复。
    public struct DesktopRedirection: Equatable, Sendable {
        public let account: String
        /// 原有链接目标；空字符串表示原本就是真实目录或缺失，恢复时保持不动。
        public let originalDestination: String
    }

    public static func redirectDesktopFolders(
        prefix: URL,
        fileManager: FileManager = .default
    ) throws -> [DesktopRedirection] {
        var redirected: [DesktopRedirection] = []
        for account in try userAccounts(in: prefix, fileManager: fileManager) {
            let desktop = account.appendingPathComponent("Desktop")
            let destination = (try? fileManager.destinationOfSymbolicLink(atPath: desktop.path)) ?? ""
            if destination.isEmpty {
                try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
            } else {
                try fileManager.removeItem(at: desktop)
                try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
            }
            redirected.append(DesktopRedirection(
                account: account.lastPathComponent,
                originalDestination: destination
            ))
        }
        return redirected
    }

    public static func restoreDesktopFolders(
        prefix: URL,
        to redirected: [DesktopRedirection],
        fileManager: FileManager = .default
    ) throws {
        for entry in redirected where !entry.originalDestination.isEmpty {
            let desktop = prefix.appendingPathComponent("drive_c/users")
                .appendingPathComponent(entry.account)
                .appendingPathComponent("Desktop")
            // 已经是符号链接说明此前恢复过，保持不动。
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: desktop.path)
            if existing != nil { continue }
            try? fileManager.removeItem(at: desktop)
            try? fileManager.createSymbolicLink(atPath: desktop.path, withDestinationPath: entry.originalDestination)
        }
    }

    private static func userAccounts(in prefix: URL, fileManager: FileManager) throws -> [URL] {
        guard let accounts = try? fileManager.contentsOfDirectory(
            at: prefix.appendingPathComponent("drive_c/users"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return accounts.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    public func redirectDesktopFolders(prefix: URL) throws -> [DesktopRedirection] {
        try Self.redirectDesktopFolders(prefix: prefix)
    }

    public func restoreDesktopFolders(prefix: URL, to redirected: [DesktopRedirection]) throws {
        try Self.restoreDesktopFolders(prefix: prefix, to: redirected)
    }

    public func installThemes(media: URL, prefix: URL, target: URL) async throws {
        let fileManager = FileManager.default
        guard let source = InstallationMedia.dotNetInstaller(in: media, fileManager: fileManager) else {
            throw failure("The chosen media is missing the .NET 4.8 / 4.8.1 installer.")
        }
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("MacSW-WPF-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let log = wine.logDirectory(prefix.path).appendingPathComponent("prerequisites.log")
        let names = try await extractThemeLibraries(from: source, to: temporary, log: log)

        let framework = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/WPF")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
        for name in names {
            guard fileManager.fileExists(atPath: temporary.appendingPathComponent(name).path) else {
                throw failure("\(name) is missing from the installer package.")
            }
        }
        for (theme, name) in zip(Self.themes, names) {
            try Task.checkCancellation()
            let data = try Data(contentsOf: temporary.appendingPathComponent(name))
            let filename = "PresentationFramework.\(theme).dll"
            try data.write(to: target.appendingPathComponent(filename), options: .atomic)
            try data.write(to: framework.appendingPathComponent(filename), options: .atomic)
        }
    }

    /// Where the five WPF theme libraries sit inside the Microsoft .NET installer.
    enum ThemeArchive: Equatable {
        /// .NET 4.8: `netfx_Full.mzz` holds `PresentationFramework.<Theme>_amd64.dll`.
        case netfxFull(member: String)
        /// .NET 4.8.1: an x64 `*-KB<n>-x64.cab` holds `amd64_presentationframework.<theme>_*/presentationframework.<theme>.dll`.
        case updateCab(member: String)
    }

    /// Paths of the archive members in `7zz l -slt -ba` output.
    static func memberPaths(fromListing listing: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("Path = ") ? String(line.dropFirst("Path = ".count)) : nil
        }
    }

    /// Picks the theme source from the installer's top-level members: `netfx_Full.mzz` wins when present
    /// (the 4.8 layout), otherwise the x64 KB cab (the 4.8.1 layout). The KB number is not fixed.
    static func themeArchive(inInstallerMembers members: [String]) -> ThemeArchive? {
        let topLevel = members.filter { !$0.contains("/") && !$0.contains("\\") }
        if let mzz = topLevel.first(where: { $0.lowercased() == "netfx_full.mzz" }) {
            return .netfxFull(member: mzz)
        }
        let cab = topLevel
            .filter { $0.range(of: #"^.*kb[0-9]+.*-x64\.cab$"#, options: [.regularExpression, .caseInsensitive]) != nil }
            .max { $0.lowercased() < $1.lowercased() }
        return cab.map { .updateCab(member: $0) }
    }

    /// The five theme DLLs inside the 4.8.1 x64 cab, in `themes` order. Matching ignores case and only
    /// takes `amd64_presentationframework.<theme>_*/presentationframework.<theme>.dll` (so `aero2` and the
    /// `f`/`r` delta folders never stand in for `aero`). Throws one error naming every missing library.
    static func themeMembers(inCabMembers members: [String]) throws -> [(theme: String, member: String)] {
        var found: [(theme: String, member: String)] = []
        var missing: [String] = []
        for theme in themes {
            let lower = theme.lowercased()
            let member = members
                .filter { member in
                    let parts = member.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" })
                    return parts.count == 2
                        && parts[0].hasPrefix("amd64_presentationframework.\(lower)_")
                        && parts[1] == "presentationframework.\(lower).dll"
                }
                .max { $0.lowercased() < $1.lowercased() }
            if let member { found.append((theme, member)) } else { missing.append("PresentationFramework.\(theme).dll") }
        }
        guard missing.isEmpty else {
            throw failure("The .NET 4.8.1 installer's x64 update package is missing WPF theme libraries: \(missing.joined(separator: ", ")).")
        }
        return found
    }

    /// The file name 7zz gives an extracted member (`e` drops the folders).
    private static func fileName(of member: String) -> String {
        String(member.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(member))
    }

    /// Extracts the five theme DLLs into `directory` and returns their file names in `themes` order.
    private func extractThemeLibraries(from installer: URL, to directory: URL, log: URL) async throws -> [String] {
        switch Self.themeArchive(inInstallerMembers: try await listMembers(of: installer)) {
        case .netfxFull(let member)?:
            try await extract(installer, names: [member], to: directory, log: log)
            let names = Self.themes.map {
                $0 == "AeroLite" ? "PresentationFramework.AeroLite.dll_amd64" : "PresentationFramework.\($0)_amd64.dll"
            }
            try await extract(directory.appendingPathComponent(Self.fileName(of: member)), names: names, to: directory, log: log)
            return names
        case .updateCab(let member)?:
            try await extract(installer, names: [member], to: directory, log: log)
            let cab = directory.appendingPathComponent(Self.fileName(of: member))
            let libraries = try Self.themeMembers(inCabMembers: try await listMembers(of: cab))
            try await extract(cab, names: libraries.map(\.member), to: directory, log: log)
            try? FileManager.default.removeItem(at: cab)  // the cab is ~270 MB; the DLLs are all that is needed
            return libraries.map { Self.fileName(of: $0.member) }
        case nil:
            throw failure("The .NET installer has neither netfx_Full.mzz (4.8) nor an x64 KB*.cab update package (4.8.1); cannot extract the WPF themes.")
        }
    }

    /// The 7-Zip that MacSW.app bundles (also used by `SpatialIOPService`).
    static func sevenZip() throws -> URL {
        let executable = MacSWBundle.url.appendingPathComponent("Contents/MacOS/7zz")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw failure("The App is missing the 7zz extraction tool; repackage the App.")
        }
        return executable
    }

    private func listMembers(of archive: URL) async throws -> [String] {
        let process = Process()
        process.executableURL = try Self.sevenZip()
        process.arguments = ["l", "-slt", "-ba", archive.path]
        let result = try await wine.capturePairCancellable(process)
        guard result.status == 0 else { throw failure("Prerequisite library listing failed (7zz: \(result.status)).") }
        return Self.memberPaths(fromListing: result.standardOutput)
    }

    private func extract(_ archive: URL, names: [String], to directory: URL, log: URL) async throws {
        let executable = try Self.sevenZip()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["e", archive.path] + names + ["-o\(directory.path)", "-y"]
        let code = try await wine.runCancellable(process, log: log)
        guard code == 0 else { throw failure("Prerequisite library extraction failed (7zz: \(code)).") }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.Prerequisites")
    }

    private func failure(_ message: String) -> NSError { Self.failure(message) }
}
