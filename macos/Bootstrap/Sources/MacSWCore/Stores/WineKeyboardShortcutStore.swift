import Combine
import Foundation

@MainActor
public final class WineKeyboardShortcutStore: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var isLoading = true
    @Published public private(set) var isOperating = false
    @Published public private(set) var statusMessage = ""

    private let paths: AppPaths
    private let registry: RegistryService
    private var didSyncFromContainer = false

    public init(paths: AppPaths, registry: RegistryService = RegistryService()) {
        self.paths = paths
        self.registry = registry
    }

    public var canChange: Bool { paths.bottleExists && !isLoading && !isOperating }

    public func refresh() async {
        // 与许可服务器设置一致：一次运行只自动查询一次，重新打开设置沿用上次读到的状态。
        guard !didSyncFromContainer else { return }
        guard !isOperating else { return }
        isLoading = true
        defer { isLoading = false }
        guard paths.bottleExists else {
            isEnabled = false
            statusMessage = "Shortcuts can be set after the bottle is installed."
            return
        }
        do {
            let enabled = try await registry.macShortcutsEnabled(prefix: paths.bottle)
            guard !Task.isCancelled else { return }
            isEnabled = enabled
            didSyncFromContainer = true
            statusMessage = ""
        } catch is CancellationError {
            return
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard canChange else { return }
        isOperating = true
        Task {
            defer { isOperating = false }
            do {
                try await registry.setMacShortcutsEnabled(enabled, prefix: paths.bottle)
                isEnabled = try await registry.macShortcutsEnabled(prefix: paths.bottle)
                didSyncFromContainer = true
                statusMessage = "Updated; takes effect after Wine programs are reopened."
            } catch {
                statusMessage = error.localizedDescription
                if let actual = try? await registry.macShortcutsEnabled(prefix: paths.bottle) {
                    isEnabled = actual
                    didSyncFromContainer = true
                }
            }
        }
    }
}
