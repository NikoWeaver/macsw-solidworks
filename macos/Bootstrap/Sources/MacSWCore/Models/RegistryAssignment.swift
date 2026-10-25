public struct RegistryAssignment: Equatable, Sendable {
    public enum ValueKind: Equatable, Sendable {
        case string
        case multiString
        case dword
    }

    public let key: String
    public let name: String
    public let value: String
    public let dwordValue: UInt32?
    public let valueKind: ValueKind

    public init(key: String, name: String, value: String) {
        self.key = key
        self.name = name
        self.value = value
        self.dwordValue = nil
        self.valueKind = .string
    }

    public init(key: String, name: String, multiStringValues: [String]) {
        self.key = key
        self.name = name
        self.value = multiStringValues.joined(separator: "\0")
        self.dwordValue = nil
        self.valueKind = .multiString
    }

    public init(key: String, name: String, dwordValue: UInt32) {
        self.key = key
        self.name = name
        self.value = ""
        self.dwordValue = dwordValue
        self.valueKind = .dword
    }
}
