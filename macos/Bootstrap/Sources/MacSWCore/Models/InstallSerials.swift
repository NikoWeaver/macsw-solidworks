import Foundation

/// The four public serial-number properties the official SOLIDWORKS MSI accepts.
/// Serials are only passed to msiexec; MacSW never writes them to the registry.
public enum InstallSerialField: String, CaseIterable, Identifiable, Sendable {
    case solidWorks
    case simulation
    case motion
    case mbd

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .solidWorks: return "SOLIDWORKS"
        case .simulation: return "Simulation"
        case .motion: return "Motion"
        case .mbd: return "MBD"
        }
    }

    public var msiProperty: String {
        switch self {
        case .solidWorks: return "SOLIDWORKSSERIALNUMBER"
        case .simulation: return "SIMULATIONSERIALNUMBER"
        case .motion: return "MOTIONSERIALNUMBER"
        case .mbd: return "MBDSERIALNUMBER"
        }
    }

}

public struct InstallSerials: Equatable, Sendable {
    public static let groupCount = 6
    public static let groupLength = 4
    public static var expectedLength: Int { Self.groupCount * Self.groupLength }

    public var values: [InstallSerialField: String]

    public init(values: [InstallSerialField: String] = [:]) {
        self.values = values
    }

    public subscript(field: InstallSerialField) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }

    /// MSI 只认 ASCII 大写字母与数字。`CharacterSet.alphanumerics` 是 Unicode 范围的，
    /// 全角 `１`、西里尔 `Ｖ` 都会被留下并凑够 24 位，`String.count` 数的是字形簇也挡不住，
    /// 所以先按标量滤到 ASCII 再大写：这样"长度"才等于真正会传给 msiexec 的字符数。
    private static let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public static func normalized(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { allowedScalars.contains($0) }
        return String(String.UnicodeScalarView(kept)).uppercased()
    }

    public func normalized(_ field: InstallSerialField) -> String {
        Self.normalized(self[field])
    }

    public var isEmpty: Bool {
        InstallSerialField.allCases.allSatisfy { normalized($0).isEmpty }
    }

    public var isComplete: Bool {
        !normalized(.solidWorks).isEmpty
    }

    public var msiProperties: [String] {
        InstallSerialField.allCases.compactMap { field in
            let value = normalized(field)
            guard !value.isEmpty else { return nil }
            return "\(field.msiProperty)=\(value)"
        }.sorted()
    }

    /// 填过内容、规范化之后却不是六组四字符的字段。判定看原始输入而不是规范化结果：
    /// 一整串全角数字规范化后会变成空，只查长度就会漏成"没填"，用户看到的是莫名其妙的提示。
    public func invalidFields() -> [InstallSerialField] {
        InstallSerialField.allCases.filter { field in
            let typed = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return false }
            return normalized(field).count != Self.expectedLength
        }
    }
}

/// The access key of the team wizard: the team's SOLIDWORKS serial, typed or pasted once into one
/// field (`BootstrapStore.serialSolidWorks`). It stays in memory: MacSW passes it to msiexec and
/// never writes it to a file, a log, the preferences or the team config.
public enum AccessKey {
    public enum Format: Equatable, Sendable {
        case empty
        case valid
        /// A character other than an ASCII letter, a digit, a space, a line break or a hyphen.
        case invalidCharacters
        /// The number of letters and digits, which is not 24.
        case wrongLength(Int)
    }

    private static let separators = CharacterSet(charactersIn: " \t\r\n-")

    /// Six groups of four ASCII letters or digits. Spaces, line breaks and hyphens between them
    /// do not count. Any other character is refused, not dropped as `InstallSerials.normalized`
    /// does, so a pasted sentence or full-width digits do not become a key.
    public static func check(_ raw: String) -> Format {
        let typed = raw.trimmingCharacters(in: separators)
        guard !typed.isEmpty else { return .empty }
        guard typed.unicodeScalars.allSatisfy({ $0.isASCII && (separators.contains($0) || CharacterSet.alphanumerics.contains($0)) }) else {
            return .invalidCharacters
        }
        let count = InstallSerials.normalized(typed).count
        return count == InstallSerials.expectedLength ? .valid : .wrongLength(count)
    }

    /// "ABCD EFGH IJKL MNOP QRST UVWX": uppercase, in groups of four, for the field after Paste.
    public static func grouped(_ raw: String) -> String {
        let key = Array(InstallSerials.normalized(raw))
        return stride(from: 0, to: key.count, by: InstallSerials.groupLength)
            .map { String(key[$0..<min($0 + InstallSerials.groupLength, key.count)]) }
            .joined(separator: " ")
    }

    /// The text under the field; nil when there is nothing to say. It never repeats the key.
    public static func message(for format: Format) -> String? {
        switch format {
        case .empty, .valid:
            return nil
        case .invalidCharacters:
            return "The access key has only letters and digits (spaces and hyphens between the groups are fine)."
        case .wrongLength(let count):
            return "The access key has 24 letters and digits in six groups of four. This one has \(count)."
        }
    }
}
