import Foundation

/// 微软安装器与注册表导出常见 UTF-16 或传统代码页，逐个兜底解码。
public enum PlainTextDecoder {
    public static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(data: data, encoding: .windowsCP1252)
        }
        // Foundation 不消费 BOM，解码结果会带一个 U+FEFF：它不算空白，
        // 于是首行的 "SERVER …"、"Error 1603" 这类前缀匹配全都会落空。
        guard let decoded = text else { return nil }
        return decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
    }
}
