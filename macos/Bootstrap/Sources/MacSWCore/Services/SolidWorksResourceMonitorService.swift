import Foundation

public enum SolidWorksResourceMonitorState: Equatable, Sendable {
    case enabled
    case disabled
    case unavailable
}

public struct SolidWorksResourceMonitorService {
    public static let executableName = "sldProcMon.exe"
    public static let disabledName = "sldProcMon.exe.disable"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func state(paths: AppPaths) -> SolidWorksResourceMonitorState {
        let locations = locations(paths: paths)
        let executableExists = fileManager.fileExists(atPath: locations.executable.path)
        let disabledExists = fileManager.fileExists(atPath: locations.disabled.path)

        switch (executableExists, disabledExists) {
        // 安装或升级可能重新放回 exe；只要它存在，SOLIDWORKS 就会启动它，
        // 所以真实运行状态必须以 exe 为准，旧的 disable 副本不能盖过它。
        case (true, _): return .enabled
        case (false, true): return .disabled
        case (false, false): return .unavailable
        }
    }

    public func setDisabled(_ disabled: Bool, paths: AppPaths) throws {
        let locations = locations(paths: paths)
        let currentState = state(paths: paths)

        switch (disabled, currentState) {
        case (true, .enabled):
            // exe 优先：若升级留下了新 exe 与旧 disable，用户再次开启禁用时
            // 用当前 exe 覆盖旧副本，确保以后恢复的是当前版本。
            if fileManager.fileExists(atPath: locations.disabled.path) {
                try fileManager.removeItem(at: locations.disabled)
            }
            try fileManager.moveItem(at: locations.executable, to: locations.disabled)
        case (false, .disabled):
            try fileManager.moveItem(at: locations.disabled, to: locations.executable)
        case (true, .disabled), (false, .enabled):
            return
        case (_, .unavailable):
            throw MacSWError.make(
                "\(Self.executableName) not found; finish installing SOLIDWORKS first.",
                domain: "MacSW.ResourceMonitor"
            )
        }
    }

    private func locations(paths: AppPaths) -> (executable: URL, disabled: URL) {
        let directory = paths.solidWorksExecutable.deletingLastPathComponent()
        return (
            directory.appendingPathComponent(Self.executableName),
            directory.appendingPathComponent(Self.disabledName)
        )
    }
}
