import Foundation

public struct LicenseServerEndpoint: Hashable, Sendable {
    public let port: UInt16
    public let host: String

    public init(port: UInt16, host: String) {
        self.port = port
        self.host = host
    }

    public var canonical: String { "\(port)@\(host)" }

    public static func == (lhs: LicenseServerEndpoint, rhs: LicenseServerEndpoint) -> Bool {
        lhs.port == rhs.port && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(port)
        hasher.combine(host.lowercased())
    }
}

public struct LicenseServerList: Equatable, Sendable {
    public private(set) var endpoints: [LicenseServerEndpoint]

    public init(endpoints: [LicenseServerEndpoint]) {
        var seen = Set<LicenseServerEndpoint>()
        self.endpoints = endpoints.filter { seen.insert($0).inserted }
    }

    public var canonical: String {
        endpoints.map(\.canonical).joined(separator: ";")
    }
}

public enum LicenseServerAddressError: LocalizedError, Equatable {
    case empty
    case invalidEntry(String)
    case invalidPort(String)
    case ambiguousIPv6(String)
    case loopbackNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Enter at least one license server address."
        case .invalidEntry(let value): return "Unrecognized server address: \(value)"
        case .invalidPort(let value): return "Invalid server port: \(value)"
        case .ambiguousIPv6(let value): return "IPv6 colon format must be written as [IPv6]:port: \(value)"
        case .loopbackNotAllowed(let value):
            return "Loopback license server addresses are not allowed (\(value)). Use the address of a real SolidNetWork license server."
        }
    }
}
