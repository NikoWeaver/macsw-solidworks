import AppKit
import MacSWCore
import SwiftUI

/// 菜单栏面板：朴素的标题与状态行 + 菜单式操作行 + 底部会变化的进程条。
/// 整块面板保持系统语义色，只有鼠标经过的行才用强调色底与白字，与系统菜单一致；不注册任何快捷键。
struct MenuBarPanelView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject private var swcliDaemon: SWCLIDaemonStore
    @ObservedObject var solidWorksApp: SolidWorksAppStore
    @ObservedObject var vba: VBAStore
    /// False in builds without SWCLI: the daemon and AI-connection UI stay hidden.
    private let swcliIncluded: Bool
    @State private var isRefreshing = false
    @State private var isQuitting = false
    @State private var panelWindow: NSWindow?
    @State private var copySucceeded: Bool?
    @State private var copyFailureReason: String?
    @State private var copyFeedbackTimer: Timer?

    private static let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(runtime: RuntimeStore, solidWorksApp: SolidWorksAppStore, vba: VBAStore) {
        self.runtime = runtime
        self.solidWorksApp = solidWorksApp
        self.vba = vba
        self.swcliDaemon = runtime.swcliDaemon
        self.swcliIncluded = PrerequisiteService.swcliIncluded(bundleURL: Bundle.main.bundleURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chips
            if runtime.isMigratingWine || !runtime.wineRuntimeState.allowsLaunch {
                Text(runtime.isMigratingWine ? "Wine bottle maintenance in progress. Do not quit…" : runtime.wineRuntimeState.message + " Open Settings → Maintenance.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
            }
            if let reason = failureReason {
                // "运行异常"不能只有一个词，原因要看得见，不然只能去猜或翻日志。
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Divider()
            actions
            Divider()
            processSection
        }
        .padding(10)
        .frame(width: 296, alignment: .leading)
        .background(MenuBarWindowReader { panelWindow = $0 })
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // MenuBarExtra can retain its view while hidden, so .task alone
            // does not guarantee a fresh observation on every reopening.
            guard let window = notification.object as? NSWindow,
                  window === panelWindow, window.isVisible else { return }
            Task { await refresh() }
        }
        .onReceive(Self.tick) { _ in
            // 面板收起即停止轮询：直接看承载窗口的可见性，
            // MenuBarExtra 的窗口关闭不保证会触发 onDisappear。
            guard panelWindow?.isVisible == true, !isRefreshing else { return }
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("MacSW").font(.system(size: 13, weight: .semibold))
            Text("Wine \(BuildInfo.wineVersion) · Mono \(BuildInfo.monoVersion)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            MenuBarSettingsButton {
                Image(systemName: "gearshape").font(.system(size: 11.5))
            }
            .simultaneousGesture(TapGesture().onEnded { dismissPanel() })
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                MenuBarStatusChip(title: solidWorksStatus, active: runtime.isRunning)
                if swcliIncluded {
                    MenuBarStatusChip(title: swcliDaemon.state.title, active: swcliDaemon.state.isReady,
                                      help: swcliDaemon.failureMessage ?? swcliDaemon.state.reason ?? "Shown as available when both the daemon and the SOLIDWORKS COM host are ready.")
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 1) {
            if runtime.isRunning {
                MenuBarActionRow(
                    title: "Quit SOLIDWORKS",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    large: true
                ) { runtime.requestQuit() }
                .disabled(runtime.isMigratingWine || swcliDaemon.isOperating)
            } else {
                MenuBarActionRow(
                    title: runtime.state == .starting ? "Starting…" : "Launch SOLIDWORKS",
                    systemImage: "play.fill",
                    large: true
                ) { runtime.launch() }
                .disabled(!runtime.isInstalled || runtime.state == .starting || runtime.isMigratingWine || swcliDaemon.isOperating || !runtime.wineRuntimeState.allowsLaunch)
            }
            if runtime.isInstalled, solidWorksApp.suggestsInstall {
                solidWorksAppSuggestion
            }
            if solidWorksApp.requirementChangeNeedsConsent {
                // MacSW did not update SOLIDWORKS.app on its own (another signing identity): Settings asks.
                MenuBarSettingsButton {
                    Label("Update SOLIDWORKS App in Settings…", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .help(solidWorksApp.statusMessage)
                .simultaneousGesture(TapGesture().onEnded { dismissPanel() })
            }
            if let warning = vba.missingWarning {
                // SOLIDWORKS itself says nothing: every equation just fails. Settings installs VBA.
                MenuBarSettingsButton {
                    Label("VBA missing: equations and macros will not work", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .help(warning + " " + VBAPrerequisite.repairHint)
                .simultaneousGesture(TapGesture().onEnded { dismissPanel() })
            }
            if swcliIncluded {
                MenuBarActionRow(title: daemonActionTitle, systemImage: "terminal") {
                    runtime.startSWCLIDaemon()
                }
                .disabled(!runtime.isInstalled || runtime.isMigratingWine || swcliDaemon.isOperating || swcliDaemon.state.isReady || runtime.state == .starting || runtime.state == .stopping || !runtime.wineRuntimeState.allowsLaunch)
                .help("Attaches to a running SOLIDWORKS if there is one; otherwise starts it hidden. Never force-quits an existing instance.")
                MenuBarActionRow(
                    title: copySucceeded == true ? "Copied" : copySucceeded == false ? "Copy failed" : "Copy AI Connection Info",
                    systemImage: copySucceeded == true ? "checkmark" : "doc.on.doc"
                ) {
                    copyAIConnectionInfo()
                }
                .help(copyFailureReason ?? "Copies the local tool, skill and guide paths plus check commands; does not start Wine or SOLIDWORKS.")
                if let reason = copyFailureReason {
                    Text(reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(reason)
                }
            }
            MenuBarActionRow(title: "Show Log", systemImage: "doc.text") {
                LogReveal.open(runtime.paths.logs)
                dismissPanel()
            }
            MenuBarActionRow(title: "Export Diagnostics…", systemImage: "archivebox") {
                dismissPanel()
                DiagnosticsExportAction.run(paths: runtime.paths)
            }
            .help("Saves a zip of MacSW's logs and Mac facts to the Desktop, with serials and other private values removed. Shows the file list first; nothing is uploaded.")
            if !runtime.processes.isEmpty {
                MenuBarActionRow(title: "Force Stop All Processes", systemImage: "stop.fill", destructive: true) {
                    runtime.forceStop()
                }
                .disabled(runtime.isMigratingWine || swcliDaemon.isOperating)
            }
            MenuBarActionRow(title: isQuitting ? "Ending bottle processes…" : "Quit MacSW", systemImage: "power", destructive: true) {
                quitMacSW()
            }
            .disabled(isQuitting || runtime.isMigratingWine || swcliDaemon.isOperating)
        }
    }

    /// Once per MacSW build until installed or dismissed (docs/solidworks-app.md, section 4).
    private var solidWorksAppSuggestion: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                MenuBarActionRow(title: solidWorksApp.isWorking ? "Installing SOLIDWORKS App…" : "Install SOLIDWORKS App",
                                 systemImage: "square.and.arrow.down") {
                    Task { await solidWorksApp.install() }
                }
                .disabled(solidWorksApp.isWorking)
                .help("Adds SOLIDWORKS.app to the Applications folder: start SOLIDWORKS from Launchpad, Spotlight and the Dock.")
                Button { solidWorksApp.dismissSuggestion() } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Not now. Settings → Maintenance → SOLIDWORKS App has it too.")
            }
            if !solidWorksApp.statusMessage.isEmpty {
                Text(solidWorksApp.statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    /// 进程数量会变化，放在最底部，避免上面的操作行位置跳动。
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bottle Processes")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            if runtime.processes.isEmpty {
                Text("No running processes detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(runtime.processes.prefix(Self.visibleProcessLimit), id: \.pid) { process in
                        MenuBarProcessRow(process: process, share: share(of: process))
                    }
                }
                Text(summaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private static let visibleProcessLimit = 8

    @MainActor
    private func copyAIConnectionInfo() {
        do {
            try AIConnectionClipboard.copy(paths: runtime.paths)
            copySucceeded = true
            copyFailureReason = nil
        } catch {
            copySucceeded = false
            copyFailureReason = error.localizedDescription
        }
        // 菜单打开时不依赖 SwiftUI task 的调度／生命周期；common 模式也覆盖菜单跟踪。
        // 每次点击都取消旧计时器，避免旧回调提前清除新一轮反馈。
        copyFeedbackTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
            // 计时器只注册到主运行循环，直接在主线程复位，不再排队异步任务。
            MainActor.assumeIsolated {
                copySucceeded = nil
                copyFeedbackTimer = nil
            }
        }
        copyFeedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var summaryText: String {
        let hidden = runtime.processes.count - Self.visibleProcessLimit
        let suffix = hidden > 0 ? " (\(hidden) more not shown)" : ""
        var text = "Total \(ProcessInventory.formatMegabytes(ProcessInventory.totalResidentMB(runtime.processes)))"
        // SOLIDWORKS 没跑就没有"已运行"可说，别留一个孤零零的横杠。
        if let uptime = uptimeText { text += " · running \(uptime)" }
        return text + suffix
    }

    private func share(of process: WineProcess) -> Double {
        let peak = runtime.processes.map(\.residentKB).max() ?? 1
        guard peak > 0 else { return 0 }
        return min(Double(process.residentKB) / Double(peak), 1)
    }

    private var uptimeText: String? {
        guard let primary = runtime.processes.first(where: { $0.name == ProcessInventory.primaryProcess }) else {
            return nil
        }
        return ProcessInventory.formatElapsed(primary.elapsed)
    }

    /// 面板由系统托管，先按 Escape 的语义让它自己收起；仍可见时再隐藏。
    private func dismissPanel() {
        guard let panel = panelWindow else { return }
        panel.cancelOperation(nil)
        DispatchQueue.main.async {
            if panel.isVisible { panel.orderOut(nil) }
        }
    }

    private func quitMacSW() {
        guard !isQuitting else { return }
        isQuitting = true
        Task { @MainActor in
            defer { isQuitting = false }
            // 点击当下重新读进程，不能用菜单两秒轮询留下的状态决定是否警告。
            let snapshot = await ProcessInventory.snapshot(
                bottlePath: runtime.paths.bottle.path,
                wineRuntimePath: WineService.shared.runtimeURL.path
            )
            let plan = AppBundleLaunch.macSWQuitPlan(snapshot: snapshot) {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            }
            // SOLIDWORKS.app's own session does not depend on MacSW: leave the bottle running.
            if plan == .quitLeavingSolidWorks {
                NSApplication.shared.terminate(nil)
                return
            }
            if plan == .confirmEndingSolidWorks {
                let alert = NSAlert()
                alert.messageText = "End SOLIDWORKS and quit MacSW?"
                alert.informativeText = "Unsaved SOLIDWORKS work will be lost. The activation program and any other Wine programs in this bottle will also be ended."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "End Programs and Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            do {
                try await runtime.stopContainerForAppQuit()
                NSApplication.shared.terminate(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not quit MacSW"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// 面板可见时每两秒刷新；只用 ps 及原生 health 请求，不启动 Wine。
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let running: Void = runtime.refreshNow()
        // Without SWCLI there is no daemon to probe every two seconds.
        if swcliIncluded { await swcliDaemon.refresh() }
        await running
    }

    /// 面板上的"异常"要能把原因一起说出来。
    private var failureReason: String? {
        if let reason = swcliDaemon.failureMessage ?? swcliDaemon.state.reason { return reason }
        if case .failed(let reason) = runtime.state { return reason }
        return nil
    }

    private var daemonActionTitle: String {
        if swcliDaemon.isOperating { return "Starting SWCLI…" }
        if swcliDaemon.state.isReady { return "SWCLI daemon ready" }
        if case .needsRecovery = swcliDaemon.state { return "Recover SWCLI daemon" }
        return "Start SWCLI daemon"
    }

    private var solidWorksStatus: String {
        switch runtime.state {
        case .unknown: return "SOLIDWORKS not checked"
        case .unavailable: return "SOLIDWORKS not installed"
        case .stopped: return "SOLIDWORKS stopped"
        case .starting: return "SOLIDWORKS starting"
        case .running: return "SOLIDWORKS running"
        case .stopping: return "SOLIDWORKS quitting"
        case .failed: return "SOLIDWORKS error"
        }
    }
}

/// 取到承载面板的窗口，用于操作完成后收起它。
private struct MenuBarWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

private struct MenuBarStatusChip: View {
    let title: String
    let active: Bool
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color(red: 0.24, green: 0.86, blue: 0.52) : Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .help(help.isEmpty ? title : help)
    }
}

/// macOS 14+ 走系统的 openSettings，更早版本回退 AppKit 动作。
private struct MenuBarSettingsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            MenuBarSettingsShortcut(label: label)
        } else {
            Button { AppLifecycleBridge.openLegacySettings() } label: { label() }
                .buttonStyle(.plain)
        }
    }
}

@available(macOS 14.0, *)
private struct MenuBarSettingsShortcut<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    let label: () -> Label

    var body: some View {
        Button {
            openSettings()
            AppLifecycleBridge.bringSettingsToFront()
        } label: { label() }
        .buttonStyle(.plain)
    }
}

private struct MenuBarActionRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    var large = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: large ? 13 : 11))
                    .frame(width: large ? 16 : 13)
                Text(title).font(.system(size: large ? 13 : 12, weight: large ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(rowTint)
            .padding(.horizontal, large ? 10 : 8)
            .padding(.vertical, large ? 9 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(rowBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    // 选中态用系统语义色，窗口非激活时会自动降级为灰色选中态。
    private var rowTint: Color {
        if isHovering { return Color(nsColor: .selectedTextColor) }
        return destructive ? .red : .primary
    }

    private var rowBackground: AnyShapeStyle {
        isHovering
            ? AnyShapeStyle(Color(nsColor: .selectedTextBackgroundColor))
            : AnyShapeStyle(Color.clear)
    }
}

private struct MenuBarProcessRow: View {
    let process: WineProcess
    let share: Double

    var body: some View {
        HStack(spacing: 7) {
            Text(process.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Text(String(process.pid))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor).frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 4)
            Text(memoryText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var memoryText: String {
        let megabytes = process.residentMB
        if megabytes >= 1024 { return String(format: "%.1f GB", Double(megabytes) / 1024) }
        return "\(megabytes) MB"
    }
}
