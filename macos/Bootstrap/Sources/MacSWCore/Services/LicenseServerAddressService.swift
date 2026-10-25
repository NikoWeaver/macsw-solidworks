import Foundation

public enum LicenseServerAddressService {
    public static func parse(_ text: String) throws -> LicenseServerList {
        let rawEntries = text.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !rawEntries.isEmpty else { throw LicenseServerAddressError.empty }
        return try LicenseServerList(endpoints: rawEntries.map(parseEntry))
    }

    public static func parseEntry(_ value: String) throws -> LicenseServerEndpoint {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") {
            guard trimmed[trimmed.index(after: at)...].firstIndex(of: "@") == nil else {
                throw LicenseServerAddressError.invalidEntry(value)
            }
            let portText = String(trimmed[..<at])
            let host = String(trimmed[trimmed.index(after: at)...])
            return try endpoint(port: portText, host: host, original: value)
        }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]"),
                  trimmed.index(after: close) < trimmed.endIndex,
                  trimmed[trimmed.index(after: close)] == ":" else {
                throw LicenseServerAddressError.invalidEntry(value)
            }
            let host = String(trimmed[...close])
            let portStart = trimmed.index(close, offsetBy: 2)
            return try endpoint(port: String(trimmed[portStart...]), host: host, original: value)
        }

        let colonCount = trimmed.filter { $0 == ":" }.count
        guard colonCount == 1, let colon = trimmed.lastIndex(of: ":") else {
            if colonCount > 1 { throw LicenseServerAddressError.ambiguousIPv6(value) }
            throw LicenseServerAddressError.invalidEntry(value)
        }
        return try endpoint(
            port: String(trimmed[trimmed.index(after: colon)...]),
            host: String(trimmed[..<colon]),
            original: value
        )
    }

    private static func endpoint(port: String, host: String, original: String) throws -> LicenseServerEndpoint {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHost(cleanHost) else { throw LicenseServerAddressError.invalidEntry(original) }
        guard let value = UInt16(port), value > 0 else {
            throw LicenseServerAddressError.invalidPort(port)
        }
        // This fork has no local license server; only a real remote SolidNetWork server is valid.
        guard !isLoopback(cleanHost) else { throw LicenseServerAddressError.loopbackNotAllowed(cleanHost) }
        return LicenseServerEndpoint(port: value, host: cleanHost)
    }

    /// 主机部分只接受主机名 / IP / 方括号 IPv6 的常见字符：这个串会进容器注册表，
    /// 也会被本机端口探测当参数用，空白与控制字符属于打错的输入而不是少见写法。
    private static let allowedHostCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]")

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        guard host.unicodeScalars.allSatisfy(allowedHostCharacters.contains) else { return false }
        if host.hasPrefix("[") { return host.hasSuffix("]") && host.count > 2 }
        return !host.contains("[") && !host.contains("]")
    }

    /// True for localhost, 127.0.0.0/8, and ::1 (including bracketed, expanded and IPv4-mapped forms).
    static func isLoopback(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && UInt8($0) != nil }) {
            return octets[0] == "127"
        }
        if h.contains(":") {
            var groups = h.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if let gap = groups.firstIndex(of: "") , h.contains("::") {
                let present = groups.filter { !$0.isEmpty }.count
                groups = groups.filter { !$0.isEmpty }
                groups.insert(contentsOf: Array(repeating: "0", count: max(0, 8 - present)), at: min(gap, groups.count))
            }
            let values = groups.compactMap { UInt16($0, radix: 16) }
            return values.count == 8 && values.dropLast().allSatisfy { $0 == 0 } && values.last == 1
        }
        return false
    }
}
