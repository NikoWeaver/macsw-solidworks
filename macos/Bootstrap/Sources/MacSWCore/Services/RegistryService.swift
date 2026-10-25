import Foundation

public final class RegistryService: @unchecked Sendable {
    private let wine: WineService
    private static let pingFangFileName = "PingFang.ttc"
    private static let pingFangFaceName = "PingFang SC"
    static let macShortcutKey = #"HKCU\Software\Wine\Mac Driver"#
    static let macShortcutValueNames = [
        "LeftCommandIsCtrl", "RightCommandIsCtrl", "LeftOptionIsAlt", "RightOptionIsAlt"
    ]

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    /// 一次 reg import 顶掉逐条 reg add：每次 wine 进程启动就要 6 秒左右，
    /// 逐条写六个值能把一次点击拖成四十秒。
    public func write(_ assignments: [RegistryAssignment], prefix: URL) async throws {
        try await importRegistry(assignments, prefix: prefix)
    }

    /// 只在安装环境准备阶段写入。这些设置属于同一套 SOLIDWORKS/Wine 兼容配置，
    /// 合并成一次导入，避免为每个值单独启动 Wine，也不在日常启动时重复迁移已有容器。
    public func configureSolidWorksCompatibility(prefix: URL) async throws {
        try await write(Self.solidWorksCompatibilityAssignments, prefix: prefix)
    }

    public func macShortcutsEnabled(prefix: URL) async throws -> Bool {
        let process = wine.makeProcess(arguments: ["reg", "query", Self.macShortcutKey], prefix: prefix)
        let (status, output) = try await wine.captureCancellable(process)
        guard status == 0 || status == 1 else {
            throw Self.registryError("Failed to read the Wine keyboard shortcut settings (\(status)).")
        }
        return Self.macShortcutsEnabled(fromQueryStatus: status, output: output)
    }

    public func setMacShortcutsEnabled(_ enabled: Bool, prefix: URL) async throws {
        if enabled {
            try await write(Self.macShortcutValueNames.map {
                RegistryAssignment(key: Self.macShortcutKey, name: $0, value: "Y")
            }, prefix: prefix)
        } else {
            try await importRegistryData(try Self.utf16RegistryData(Self.macShortcutDeletionText()), prefix: prefix)
        }
    }

    /// 只解析 ASCII 值名和值；reg query 在中文 Wine locale 下可能以 GBK 输出其他字段。
    static func macShortcutsEnabled(fromQueryStatus status: Int32, output: String) -> Bool {
        guard status == 0 else { return false }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3, columns[1] == "REG_SZ" else { continue }
            values[String(columns[0])] = String(columns[2])
        }
        return macShortcutValueNames.allSatisfy { values[$0]?.uppercased() == "Y" }
    }

    static func macShortcutDeletionText() -> String {
        let lines = ["Windows Registry Editor Version 5.00", "", "[\(fullHive(macShortcutKey))]"]
            + macShortcutValueNames.map { "\"\($0)\"=-" } + [""]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 只在安装环境准备期间，优先使用 Wine 已枚举的系统苹方；不复制 Apple 字体。
    /// 区分未检测到苹方与现有链接无法安全回写；兼容设置两种情况下都照常写入。
    @discardableResult
    public func configureInstallationEnvironment(prefix: URL) async throws -> InstallationFontStatus {
        let fontsKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#
        let linksKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#
        // Do not query by family name with /v: the value name is localized (Chinese under zh_CN,
        // English under en_US). The trailing PingFang.ttc path is locale-independent.
        let fontQuery = wine.makeProcess(arguments: ["reg", "query", fontsKey], prefix: prefix)
        let (fontStatus, fontOutput) = try await wine.captureCancellable(fontQuery)
        guard Self.hasRegisteredPingFang(fromQueryStatus: fontStatus, output: fontOutput) else {
            try await configureSolidWorksCompatibility(prefix: prefix)
            return .notDetected
        }
        let linksQuery = wine.makeProcess(arguments: ["reg", "query", linksKey, "/v", "Tahoma"], prefix: prefix)
        let (linksStatus, linksOutput) = try await wine.captureCancellable(linksQuery)
        guard let existingLinks = Self.tahomaLinks(fromQueryStatus: linksStatus, output: linksOutput) else {
            try await configureSolidWorksCompatibility(prefix: prefix)
            return .existingLinksUnreadable
        }
        try await write(
            Self.appleFontAssignments(existingTahomaLinks: existingLinks)
                + Self.solidWorksCompatibilityAssignments,
            prefix: prefix
        )
        return .enabled
    }

    /// App 启动时只修复 Tahoma 的缺字回退链接，不改动字体族替换或其他安装期设置。
    /// 现有链接无法安全解析时不写入，以免丢失 Wine 已生成的回退项。
    @discardableResult
    public func repairTahomaFontLinkIfNeeded(prefix: URL) async throws -> Bool {
        let fontsKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#
        let linksKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#
        let fontQuery = wine.makeProcess(arguments: ["reg", "query", fontsKey], prefix: prefix)
        let (fontStatus, fontOutput) = try await wine.captureCancellable(fontQuery)
        guard try Self.hasRegisteredPingFangForStartup(fromQueryStatus: fontStatus, output: fontOutput) else {
            return false
        }

        let linksQuery = wine.makeProcess(arguments: ["reg", "query", linksKey, "/v", "Tahoma"], prefix: prefix)
        let (linksStatus, linksOutput) = try await wine.captureCancellable(linksQuery)
        guard let existingLinks = Self.tahomaLinks(fromQueryStatus: linksStatus, output: linksOutput) else {
            throw Self.registryError("The existing Tahoma font link could not be read safely; font settings were left unchanged.")
        }
        guard let assignment = Self.missingPingFangLinkAssignment(existingTahomaLinks: existingLinks) else {
            return false
        }
        try await write([assignment], prefix: prefix)
        return true
    }

    private func importRegistry(_ assignments: [RegistryAssignment], prefix: URL) async throws {
        guard !assignments.isEmpty else { return }
        try await importRegistryData(Self.registryFileData(assignments), prefix: prefix)
    }

    private func importRegistryData(_ data: Data, prefix: URL) async throws {
        let name = "MacSW-\(UUID().uuidString).reg"
        let insideBottle = prefix.appendingPathComponent("drive_c/windows/temp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: insideBottle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: insideBottle, options: .atomic)
        defer { try? FileManager.default.removeItem(at: insideBottle) }
        let process = wine.makeProcess(
            arguments: ["reg", "import", "C:\\windows\\temp\\\(name)"],
            prefix: prefix
        )
        let log = wine.logDirectory(prefix.path).appendingPathComponent("registry-write.log")
        let code = try await wine.runCancellable(process, log: log)
        guard code == 0 else { throw Self.registryError("Registry import failed (\(code)).") }
    }

    /// 生成 .reg 文本。.reg 的行格式没有"值里含换行"的转义写法，一条赋值会被拆成两行
    /// 并静默写坏注册表，所以这种输入在生成阶段就拒绝。
    static func registryFileText(_ assignments: [RegistryAssignment]) throws -> String {
        for assignment in assignments {
            let hasIllegalCharacter = assignment.value.contains { $0.isNewline || $0 == "\t" }
            let hasInvalidMultiString = assignment.valueKind == .multiString
                && assignment.value.components(separatedBy: "\0").contains(where: \.isEmpty)
            let hasInvalidStringNUL = assignment.valueKind == .string && assignment.value.contains("\0")
            if hasIllegalCharacter || hasInvalidMultiString || hasInvalidStringNUL {
                throw registryError("Registry values cannot contain empty entries, newlines, tabs or illegal NUL: \(assignment.name).")
            }
        }
        var lines = ["Windows Registry Editor Version 5.00", ""]
        let grouped = Dictionary(grouping: assignments, by: { $0.key })
        for key in grouped.keys.sorted() {
            lines.append("[\(Self.fullHive(key))]")
            for assignment in (grouped[key] ?? []).sorted(by: { $0.name < $1.name }) {
                switch assignment.valueKind {
                case .string:
                    lines.append("\"\(Self.escape(assignment.name))\"=\"\(Self.escape(assignment.value))\"")
                case .multiString:
                    lines.append("\"\(Self.escape(assignment.name))\"=hex(7):\(Self.registryMultiStringHex(assignment.value))")
                case .dword:
                    guard let value = assignment.dwordValue else {
                        throw registryError("Registry DWORD is missing a value: \(assignment.name).")
                    }
                    lines.append(String(format: "\"%@\"=dword:%08x", Self.escape(assignment.name), value))
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// 带 BOM 的 UTF-16LE .reg 文件同时正确处理中文值名与标准 UTF-16LE hex(7)。
    static func registryFileData(_ assignments: [RegistryAssignment]) throws -> Data {
        try utf16RegistryData(registryFileText(assignments))
    }

    private static func utf16RegistryData(_ text: String) throws -> Data {
        guard let body = text.data(using: .utf16LittleEndian) else {
            throw registryError("The registry text cannot be encoded as UTF-16LE.")
        }
        return Data([0xff, 0xfe]) + body
    }

    static func registryMultiStringHex(_ joinedValues: String) -> String {
        var bytes: [UInt8] = []
        for value in joinedValues.components(separatedBy: "\0") {
            for codeUnit in value.utf16 {
                bytes.append(UInt8(codeUnit & 0xff))
                bytes.append(UInt8(codeUnit >> 8))
            }
            bytes.append(contentsOf: [0, 0])
        }
        bytes.append(contentsOf: [0, 0])
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
    }

    /// reg query 的中文值名经有损 UTF-8 解码后不可依赖；这里只检查 ASCII 类型和文件名。
    static func hasRegisteredPingFang(fromQueryStatus status: Int32, output: String) -> Bool {
        guard status == 0 else { return false }
        for line in output.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: "REG_SZ") else { continue }
            let path = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let fileName = path.split(separator: "\\").last,
                  fileName.caseInsensitiveCompare(Self.pingFangFileName) == .orderedSame else { continue }
            return true
        }
        return false
    }

    static func hasRegisteredPingFangForStartup(fromQueryStatus status: Int32, output: String) throws -> Bool {
        guard status == 0 else {
            throw registryError("Failed to read Wine font registration (\(status)).")
        }
        return hasRegisteredPingFang(fromQueryStatus: status, output: output)
    }

    /// 拒绝 REG_MULTI_SZ 的缩进续行或无法确认编码的内容，避免回写截断值。
    /// reg query 在中文 locale 下可能输出 GBK；这里不能依赖中文内容作匹配，
    /// 且回写的链接值必须全为 ASCII，避免有损 UTF-8 解码把原值改坏。
    static func tahomaLinks(fromQueryStatus status: Int32, output: String) -> [String]? {
        guard status == 0 else { return nil }
        let lines = output.split(whereSeparator: \.isNewline)
        guard let index = lines.firstIndex(where: {
                  guard let marker = $0.range(of: "REG_MULTI_SZ") else { return false }
                  return $0[..<marker.lowerBound].trimmingCharacters(in: .whitespaces) == "Tahoma"
              }),
              let marker = lines[index].range(of: "REG_MULTI_SZ") else { return nil }
        if let next = lines.dropFirst(index + 1).first,
           next.first == " " || next.first == "\t" {
            return nil
        }
        let line = lines[index]
        let value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let links = value.components(separatedBy: "\\0")
        return !links.isEmpty && links.allSatisfy({ !$0.isEmpty }) ? links : nil
    }

    static func fullHive(_ key: String) -> String {
        for (short, full) in [("HKLM\\", "HKEY_LOCAL_MACHINE\\"), ("HKCU\\", "HKEY_CURRENT_USER\\")] where key.hasPrefix(short) {
            return full + key.dropFirst(short.count)
        }
        return key
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 托管 COM 只有注册表内容才算证据；查询失败按全部缺失处理。
    public func missingCOMRegistrations(
        at path: String,
        requires: [String],
        prefix: URL
    ) async -> [String] {
        let process = wine.makeProcess(arguments: ["reg", "query", path, "/s"], prefix: prefix)
        guard let (status, output) = try? await wine.captureCancellable(process), status == 0 else {
            return requires
        }
        return InstallerDiagnostics.missingRequirements(output: output, required: requires)
    }

    public func solidWorksApplicationCLSID(prefix: URL) async -> String? {
        let process = wine.makeProcess(
            arguments: ["reg", "query", #"HKCR\SldWorks.Application\CLSID"#, "/ve"],
            prefix: prefix
        )
        guard let (_, output) = try? await wine.captureCancellable(process) else { return nil }
        return InstallerDiagnostics.registeredCLSID(fromQuery: output)
    }

    public func writeLicenseServers(_ servers: LicenseServerList, prefix: URL) async throws {
        guard !servers.endpoints.isEmpty else {
            try await clearLicenseServers(prefix: prefix)
            return
        }
        try await write(Self.licenseAssignments(servers), prefix: prefix)
    }

    /// The SolidNetWork client address (port@host) goes into the same six values the
    /// official installer uses; SOLIDWORKS and its FlexNet client read different keys.
    static func licenseAssignments(_ servers: LicenseServerList) -> [RegistryAssignment] {
        let address = servers.canonical
        return licenseValueTargets.map { RegistryAssignment(key: $0.key, name: $0.name, value: address) }
    }

    public func readLicenseServers(prefix: URL) async throws -> LicenseServerList {
        let process = wine.makeProcess(arguments: [
            "reg", "query", "HKLM\\SOFTWARE\\FLEXlm License Manager", "/v", "SW_D_LICENSE_FILE"
        ], prefix: prefix)
        let (code, output) = try await wine.captureCancellable(process)
        return try Self.licenseServers(fromQueryStatus: code, output: output)
    }

    static func licenseServers(fromQueryStatus code: Int32, output: String) throws -> LicenseServerList {
        if code == 1 { return LicenseServerList(endpoints: []) }
        guard code == 0 else { throw Self.registryError("Failed to read the license server registry (\(code)).") }
        guard let marker = output.range(of: "REG_SZ", options: .caseInsensitive) else {
            throw Self.registryError("The license server registry returned unrecognized content.")
        }
        let value = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return LicenseServerList(endpoints: []) }
        return try LicenseServerAddressService.parse(value)
    }

    /// 清空即写空串（跟刚装完的容器状态一致），六个值一次导入搞定。
    public func clearLicenseServers(prefix: URL) async throws {
        let assignments = Self.licenseValueTargets.map { RegistryAssignment(key: $0.key, name: $0.name, value: "") }
        try await importRegistry(assignments, prefix: prefix)
    }

    static let solidWorksCompatibilityAssignments = [
        RegistryAssignment(
            key: "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
            name: "sldworks.exe",
            value: "WINE_NOCAPTURERESEND WINE_PRINTWINDOW_SURFACE"
        ),
        RegistryAssignment(
            key: "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ThemeManager",
            name: "ThemeActive",
            value: "0"
        ),
        RegistryAssignment(
            key: "HKCU\\Control Panel\\Desktop",
            name: "FontSmoothingType",
            dwordValue: 2
        ),
        // WebView2 needs Windows 7 semantics (software compositing) under Wine; only this process.
        RegistryAssignment(
            key: "HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe",
            name: "Version",
            value: "win7"
        )
    ]

    static func appleFontAssignments(existingTahomaLinks: [String]) -> [RegistryAssignment] {
        let substitutionsKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#
        let linksKey = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#
        let aliases = [
            "MS Shell Dlg", "MS Shell Dlg 2", "Microsoft Sans Serif", "Microsoft YaHei",
            "Microsoft YaHei UI", "Segoe UI", "SimSun", "NSimSun", "宋体"
        ]
        let pingFang = "\(Self.pingFangFileName),\(Self.pingFangFaceName)"
        let links = [pingFang] + existingTahomaLinks.filter { $0.caseInsensitiveCompare(pingFang) != .orderedSame }
        return aliases.map { RegistryAssignment(key: substitutionsKey, name: $0, value: "Tahoma") }
            + [RegistryAssignment(key: linksKey, name: "Tahoma", multiStringValues: links)]
    }

    static func missingPingFangLinkAssignment(existingTahomaLinks: [String]) -> RegistryAssignment? {
        let pingFang = "\(pingFangFileName),\(pingFangFaceName)"
        guard !existingTahomaLinks.contains(where: { $0.caseInsensitiveCompare(pingFang) == .orderedSame }) else {
            return nil
        }
        return RegistryAssignment(
            key: #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink"#,
            name: "Tahoma",
            multiStringValues: [pingFang] + existingTahomaLinks
        )
    }

    static let licenseValueTargets: [(key: String, name: String)] = [
        ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
        ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SEEMAGE_LICENSE_FILE"),
        ("HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager", "SW_D_LICENSE_FILE")
    ]

    private static func registryError(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.Registry")
    }
}
