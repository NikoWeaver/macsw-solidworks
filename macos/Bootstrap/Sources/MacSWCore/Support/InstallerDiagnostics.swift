import Foundation

/// 安装器退出码不足以证明安装成功，这里提供可判定的日志摘要与 COM 注册校验。
public enum InstallerDiagnostics {
    public static let loginManagerCLSID = "{69EF7FA2-6705-47CF-AA78-2E4264D24EB3}"

    /// 托管 COM 必须同时具备 mscoree 宿主、托管类和程序集 CodeBase。
    public static let loginManagerRequirements = [
        "mscoree.dll",
        "sldLoginManager.LoginManager",
        "sldLoginManager.dll"
    ]

    public static let solidWorksRequirements = [
        "LocalServer32",
        "SLDWORKS.exe",
        "VersionIndependentProgID",
        "SldWorks.Application",
        "TypeLib"
    ]

    private static let secretMarkers = ["SERIALNUMBER", "SERVERLIST"]
    private static let summaryLimit = 40

    public static func msiErrorSummary(_ log: String) -> [String] {
        let expression = try? NSRegularExpression(
            pattern: #"SW MESSAGE\|ERROR\||Return value 3|Error [0-9]{4}|source file.{0,80}not found|cannot find|unable to"#,
            options: [.caseInsensitive]
        )
        guard let expression else { return [] }
        let matched = log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let uppercased = line.uppercased()
            guard !secretMarkers.contains(where: { uppercased.contains($0) }) else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            guard expression.firstMatch(in: line, options: [], range: range) != nil else { return nil }
            return line
        }
        // 截断留前面的：MSI 失败时第一条才是根因，后面多是级联的"return value 3"。
        return Array(matched.prefix(Self.summaryLimit))
    }

    /// 安装失败的完整说明：日志里才有真正的 MSI 返回码，摘要另存一份便于回看。
    /// 调用方给的是 `/l*v` 日志路径，几十 MB 的读取与正则请放到非主线程上跑。
    public static func failureDetail(log: URL) -> String {
        guard let data = try? Data(contentsOf: log), let text = PlainTextDecoder.decode(data) else {
            return "See \(log.path)."
        }
        let code = msiReturnCode(text).map { "MSI returned \($0). " } ?? ""
        let summary = msiErrorSummary(text)
        guard !summary.isEmpty else { return code + "See \(log.path)." }
        let errors = log.deletingLastPathComponent().appendingPathComponent("install_msi_errors.log")
        try? LogFiles.write(Data(summary.joined(separator: "\n").utf8), to: errors)
        return code + "First errors:\n\(summary.prefix(6).joined(separator: "\n"))\nFull summary: \(errors.path)."
    }

    /// 真正的 MSI 返回码只写在 `/l*v` 日志里：Unix 进程状态只保留低 8 位，
    /// 1603 到调用方手上就成了 67，光看数字没法判断。取最后一条 MainEngineThread 的返回值。
    public static func msiReturnCode(_ log: String) -> Int32? {
        guard let expression = try? NSRegularExpression(
            pattern: #"MainEngineThread\s+(?:is\s+)?returning\s+(\d{1,5})"#,
            options: [.caseInsensitive]
        ) else { return nil }
        var found: Int32?
        for line in log.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let match = expression.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text)
            ), match.numberOfRanges == 2, let digits = Range(match.range(at: 1), in: text),
            let code = Int32(text[digits]) else { continue }
            found = code
        }
        return found
    }

    public static func missingRequirements(output: String, required: [String]) -> [String] {
        let lowered = output.lowercased()
        return required.filter { !lowered.contains($0.lowercased()) }
    }

    public static func registeredCLSID(fromQuery output: String) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #"REG_SZ\s+(\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\})"#
        )
        guard let expression,
              let match = expression.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
}

/// msiexec `/l*v` logs its command line and every property, so after an install the verbose log
/// holds the serial numbers that MacSW passed (`SilentInstallerPlan`), and in the official wizard
/// the ones the user typed. `redact` removes every line that names a serial-number or
/// license-server property and masks any other copy of a known serial (plain, grouped with
/// hyphens or spaces). MSI return codes and error lines stay, so `InstallerDiagnostics` still works.
public enum InstallLogRedaction {
    static let markers = ["SERIALNUMBER", "SERVERLIST"]

    public static func redact(_ text: String, serials: InstallSerials) -> String {
        // components(separatedBy:) also splits CRLF ("\r\n" is one Character, so split(separator:) would not).
        let kept = text.components(separatedBy: "\n").filter { line in
            let upper = line.uppercased()
            return !markers.contains { upper.contains($0) }
        }
        var result = kept.joined(separator: "\n")
        for field in InstallSerialField.allCases {
            let serial = serials.normalized(field)
            if !serial.isEmpty { result = HeadlessRedactor(serial: serial).scrub(result) }
        }
        return result
    }

    /// Rewrites `log` in its own encoding and makes it 0600. False when it is missing or unreadable.
    @discardableResult
    public static func redact(log: URL, serials: InstallSerials) -> Bool {
        guard let data = try? Data(contentsOf: log), let text = PlainTextDecoder.decode(data) else { return false }
        let redacted = redact(text, serials: serials)
        if redacted == text {
            try? FileManager.default.setAttributes([.posixPermissions: LogFiles.filePermissions], ofItemAtPath: log.path)
            return true
        }
        guard let encoded = encode(redacted, like: data) else { return false }
        return (try? LogFiles.write(encoded, to: log)) != nil
    }

    /// Same encoding and byte-order mark as `original` (Windows installers often write UTF-16).
    static func encode(_ text: String, like original: Data) -> Data? {
        if original.starts(with: [0xFF, 0xFE]) {
            return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        }
        if original.starts(with: [0xFE, 0xFF]) {
            return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        }
        if String(data: original, encoding: .utf8) != nil {
            let bom = original.starts(with: [0xEF, 0xBB, 0xBF]) ? Data([0xEF, 0xBB, 0xBF]) : Data()
            return text.data(using: .utf8).map { bom + $0 }
        }
        return text.data(using: .windowsCP1252, allowLossyConversion: true)
    }
}
