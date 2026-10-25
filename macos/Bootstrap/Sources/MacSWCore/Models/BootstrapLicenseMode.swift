import Foundation

/// License source chosen at install time. Only Dassault's own activation
/// (`unconfigured`) or a real SolidNetWork server (`remoteServer`) are supported.
public enum BootstrapLicenseMode: String, CaseIterable, Identifiable, Sendable {
    case unconfigured
    case remoteServer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unconfigured: return "Do not configure"
        case .remoteServer: return "Use specified address"
        }
    }

    public var detail: String {
        switch self {
        case .unconfigured: return "No license server address is written; SOLIDWORKS asks how to activate when it starts."
        case .remoteServer: return "Writes the address to the bottle registry; the license service runs on another machine."
        }
    }

    /// 选定模式后该模式的输入不能再留空或无效，否则许可步骤会静默跳过。
    public func missingInputMessage(address: String) -> String? {
        switch self {
        case .unconfigured:
            return nil
        case .remoteServer:
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "\"Use specified address\" is selected; enter the license server address." }
            guard (try? LicenseServerAddressService.parse(trimmed)) != nil else {
                return "The license server address format must be \"port@host\"; separate multiple addresses with semicolons."
            }
            return nil
        }
    }
}
