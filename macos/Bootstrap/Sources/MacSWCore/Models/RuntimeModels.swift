import Foundation

public enum SolidWorksRuntimeState: Equatable, Sendable {
    case unavailable
    /// 尚未探测过进程状态；只有用户主动查看或需要启动时才探测。
    case unknown
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

public extension SolidWorksRuntimeState {
    /// 进程表是唯一证据，但 `starting/stopping/failed` 是用户刚点出来的意图：
    /// 一次与意图相反的观测不能把它冲掉，否则按钮会闪、启动看起来像失败、错误悄悄消失。
    func applying(observedRunning running: Bool, installed: Bool) -> SolidWorksRuntimeState {
        let settled: SolidWorksRuntimeState = installed ? .stopped : .unavailable
        switch self {
        case .starting: return running ? .running : self
        case .stopping: return running ? self : settled
        case .failed: return running ? .running : self
        default: return running ? .running : settled
        }
    }
}
