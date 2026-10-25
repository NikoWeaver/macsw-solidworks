import Combine
import Foundation

@MainActor
public final class SWCLIDaemonStore: ObservableObject {
    @Published public private(set) var state: SWCLIDaemonState = .unknown
    @Published public private(set) var isOperating = false
    @Published public private(set) var failureMessage: String?
    private var isRefreshing = false
    private var generation = 0
    private var operation: Task<Void, Never>?
    private let probe: @Sendable () async -> SWCLIDaemonState
    private let startCommand: @Sendable ([String]) async throws -> Void

    public init(service: SWCLIDaemonService) {
        probe = { await service.probe() }
        startCommand = { try await service.start(arguments: $0) }
    }

    init(probe: @escaping @Sendable () async -> SWCLIDaemonState,
         startCommand: @escaping @Sendable ([String]) async throws -> Void) {
        self.probe = probe
        self.startCommand = startCommand
    }

    public func refresh() async {
        guard !isOperating, !isRefreshing else { return }
        isRefreshing = true
        let revision = generation
        let observed = await probe()
        isRefreshing = false
        guard revision == generation, !isOperating else { return }
        state = observed
        if observed.isReady { failureMessage = nil }
    }

    /// prepare returns a fresh, container-scoped SW process observation.
    /// It runs only when a daemon actually needs starting or recovery.
    func start(prepare: @escaping @MainActor (SWCLIDaemonState) async throws -> Bool) {
        guard !isOperating else { return }
        generation += 1
        isOperating = true
        failureMessage = nil
        state = .starting
        operation = Task {
            defer { isOperating = false; operation = nil }
            do {
                let observed = await probe()
                if observed.isReady { state = observed; return }
                // Reject an unresponsive/foreign endpoint before preparation.
                _ = try SWCLIDaemonService.startArguments(state: observed, solidWorksRunning: false)
                let running = try await prepare(observed)
                // Preparation can take time. Do not restart a daemon another
                // client has recovered meanwhile, or use a stale port decision.
                let current = await probe()
                if let arguments = try SWCLIDaemonService.startArguments(state: current, solidWorksRunning: running) {
                    try await startCommand(arguments)
                }
                let verified = await probe()
                guard verified.isReady else {
                    throw MacSWError.make(verified.reason ?? "The daemon start command finished, but the daemon is not ready yet.", domain: "MacSW.SWCLI")
                }
                state = verified
            } catch {
                failureMessage = error.localizedDescription
                state = .failed(error.localizedDescription)
            }
        }
    }

    func waitForOperation() async {
        if let operation { await operation.value }
    }
}
