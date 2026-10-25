import Combine
import Foundation

@MainActor
public final class LicenseServerStore: ObservableObject {
    @Published public var addressInput = ""
    @Published public private(set) var addressNotice = ""
    @Published public private(set) var addressHasError = false
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var isOperating = false
    /// 上一次真正写进注册表的内容，用来判断输入框是否需要再写一次。
    @Published public private(set) var appliedAddress: String?

    public let paths: AppPaths
    private let registry: RegistryService
    private let wine: WineService
    private var didSyncFromContainer = false
    var runtimeMaintenanceSuspended = false

    public init(paths: AppPaths, wine: WineService = .shared) {
        self.paths = paths
        self.wine = wine
        self.registry = RegistryService(wine: wine)
    }

    /// 完整刷新：读容器注册表里的许可服务器列表。要起一个 wine 进程，
    /// 所以只在用户显式要求"重新读取"时调用，不进启动路径。
    public func refresh() async {
        let servers: LicenseServerList
        do {
            servers = try await registry.readLicenseServers(prefix: paths.bottle)
        } catch {
            guard !Task.isCancelled else { return }
            statusMessage = "Failed to read the license server: \(error.localizedDescription)"
            return
        }
        // 被取消的那次读回来的是空列表，写进输入框会把已有地址抹掉、把单选框骗成"不配置"。
        guard !Task.isCancelled else { return }
        addressInput = servers.canonical
        appliedAddress = servers.canonical
    }

    /// 读一次容器里的真实配置，让单选框显示的是注册表而不是"我们上次点了什么"。
    /// 一次 `reg query` 要起一个 wine 进程（约 6 秒），所以每次运行默认只自动读一次，
    /// 之后由用户显式要求再读；期间沿用写入的锁，免得读取结果盖掉刚选的东西。
    public func syncFromContainer(force: Bool = false) async {
        guard force || !didSyncFromContainer else { return }
        guard !isOperating else { return }
        isOperating = true
        defer { isOperating = false }
        await refresh()
        // 被取消的同步没读到东西，不能算"这次运行已经同步过"，否则再进这一页也不会重试。
        guard !Task.isCancelled else { return }
        didSyncFromContainer = true
    }

    @discardableResult
    public func normalizeAddressInput() -> Bool {
        if addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addressInput = ""
            addressNotice = ""
            addressHasError = false
            return true
        }
        do {
            let parsed = try LicenseServerAddressService.parse(addressInput)
            let canonical = parsed.canonical
            let changed = canonical != addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
            addressInput = canonical
            addressNotice = changed ? "Converted to the port@host format SOLIDWORKS uses." : ""
            addressHasError = false
            return true
        } catch {
            addressNotice = error.localizedDescription
            addressHasError = true
            return false
        }
    }

    /// 单选即生效：把选中的模式写进容器注册表。
    /// 写入期间 isOperating 为真，界面上整块随之锁住并转菊花，
    /// 因此不会出现用户连着切、旧写入盖掉新选择的情况。
    public func apply(mode: BootstrapLicenseMode) {
        guard startOperationIfIdle() else { return }
        Task {
            defer { isOperating = false }
            do {
                switch mode {
                case .unconfigured:
                    try await registry.clearLicenseServers(prefix: paths.bottle)
                    addressInput = ""
                    appliedAddress = ""
                    statusMessage = "License server address cleared."
                case .remoteServer:
                    guard normalizeAddressInput(), !addressInput.isEmpty else {
                        statusMessage = "No server address entered yet."
                        return
                    }
                    try await registry.writeLicenseServers(
                        try LicenseServerAddressService.parse(addressInput), prefix: paths.bottle
                    )
                    appliedAddress = addressInput
                    statusMessage = "License server address written to the registry."
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Used inline by the installer: writes the remote SolidNetWork address, if any.
    public func configureDuringInstallation(address: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let servers = try LicenseServerAddressService.parse(trimmed)
        try await registry.writeLicenseServers(servers, prefix: paths.bottle)
        addressInput = servers.canonical
    }

    func startOperationIfIdle() -> Bool {
        guard !runtimeMaintenanceSuspended else {
            statusMessage = "A Wine bottle migration is in progress; try license maintenance again later."
            return false
        }
        let runtimeState = WineRuntimeService.status(prefix: paths.bottle)
        guard runtimeState.allowsLaunch else {
            statusMessage = runtimeState.message + " Open Settings → Maintenance."
            return false
        }
        guard !isOperating else { return false }
        isOperating = true
        return true
    }
}
