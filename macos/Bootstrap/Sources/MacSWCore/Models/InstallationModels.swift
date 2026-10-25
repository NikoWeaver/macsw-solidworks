import Foundation

public enum InstallationStep: Int, CaseIterable, Identifiable, Sendable {
    case media = 1
    case environment
    case vcRuntime
    case loginManager
    case vba
    case installer
    /// The files the MSI's InstallSpatialIOP would unzip; MacSW turns that action off (`SpatialIOP`).
    case spatialInterop
    case language
    case wpfThemes
    case toolbox
    case licensing
    case validation

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .media: return "Verify the official install media"
        case .environment: return "Prepare the Wine environment and managed COM"
        case .vcRuntime: return "Install the Microsoft VC++ runtime"
        case .loginManager: return "Install SOLIDWORKS Login Manager"
        case .vba: return "Install Microsoft VBA 7.1 (equations and macros)"
        case .installer: return "Silently deploy the SOLIDWORKS core"
        case .spatialInterop: return "Add the SpatialIOP files (CAD import)"
        case .language: return "Install the official language resources"
        case .wpfThemes: return "Add the official Microsoft WPF theme libraries"
        case .toolbox: return "Deploy and verify the Toolbox standard parts library"
        case .licensing: return "Deploy the license server" 
        case .validation: return "Check the deployment result"
        }
    }
}

public enum InstallationStepStatus: String, Sendable {
    case pending = "Pending"
    case running = "In progress"
    case completed = "Completed"
    case warning = "Warning"
    case failed = "Failed"
    case skipped = "Skipped"
    case cancelled = "Cancelled"
}

public enum InstallationState: Equatable, Sendable {
    case idle
    case preparing
    case installing(InstallationStep)
    case cancelling
    case cancelled
    case failed(String)
    case completed

    public var isActive: Bool {
        switch self {
        case .preparing, .installing, .cancelling: return true
        default: return false
        }
    }
}
