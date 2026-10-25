import AppKit
import MacSWCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @ObservedObject var resourceMonitor: SolidWorksResourceMonitorStore
    @ObservedObject var keyboardShortcuts: WineKeyboardShortcutStore
    @ObservedObject var solidWorksApp: SolidWorksAppStore
    @ObservedObject var vba: VBAStore
    @AppStorage(AppPreferences.autoLaunchSolidWorksKey) private var autoLaunchSolidWorks = AppPreferences.autoLaunchSolidWorksDefault
    @AppStorage(AppPreferences.wineLocaleKey) private var wineLocale = AppPreferences.wineLocaleDefault
    @AppStorage(AppPreferences.useMacFileDialogsKey) private var useMacFileDialogs = AppPreferences.useMacFileDialogsDefault
    @AppStorage(AppPreferences.mapMacFoldersKey) private var mapMacFolders = AppPreferences.mapMacFoldersDefault
    @FocusState private var addressFocused: Bool
    @State private var runtimeAction: String?
    @State private var maintainsVisibility = false
    @State private var generalVisible = false
    @State private var confirmsAppUninstall = false
    @State private var confirmsAppRequirementChange = false
    /// nil 表示还没手工选过，此时按容器里的真实状态推导。
    @State private var chosenLicenseMode: BootstrapLicenseMode?

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            maintenanceSettings
                .tabItem { Label("Maintenance", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(SettingsWindowLifecycle())
        .padding(16)
        .alert("Confirm Wine bottle maintenance?", isPresented: Binding(
            get: { runtimeAction != nil }, set: { if !$0 { runtimeAction = nil } }
        )) {
            Button("Cancel", role: .cancel) { runtimeAction = nil }
            Button("Confirm and Continue") {
                if let action = runtimeAction { runtime.maintainWineRuntime(action) }
                runtimeAction = nil
            }
        } message: {
            Text(runtimeAction == "baseline"
                 ? "Only record this when SOLIDWORKS already works with the current Wine. The full App is archived, wineboot is not triggered, and the baseline will not be used to bypass a recorded version difference."
                 : "Save your documents first. All Windows processes in this bottle will be stopped; the old App and a full bottle backup are kept before the upgrade or recovery runs. On the same volume an APFS clone is used; across volumes free space is checked and the bottle is copied. Rollback restores the pre-upgrade snapshot; later settings and files stay in the failed copy and are not merged automatically. After recovery, quit the new version and open the archived old App. Do not quit MacSW during maintenance.")
        }
    }

    private var generalSettings: some View {
        Form {
            personalizationSection
            licenseSection
        }
        .disabled(runtime.isMigratingWine)
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            generalVisible = true
            resourceMonitor.refresh()
        }
        .onDisappear { generalVisible = false }
        // 打开设置才去容器里读一次真实配置：App 启动路径上不起 wine 进程。
        .task(id: generalVisible) {
            guard generalVisible else { return }
            await licenseServer.syncFromContainer()
        }
    }

    private var licenseSection: some View {
        Section("License Server") {
            HStack(spacing: 8) {
                Picker("License Server", selection: licenseMode) {
                    ForEach(BootstrapLicenseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                Spacer()
                // 写入注册表期间整块锁住，顺便转个菊花表示"在做事"。
                if licenseServer.isOperating {
                    ProgressView()
                        .controlSize(.small)
                }
                // 手工改过注册表（维护页就能打开注册表编辑器）之后用这个把真实配置读回来。
                Button {
                    Task {
                        await licenseServer.syncFromContainer(force: true)
                        // 手工选过的模式要让位给读回来的真实状态。
                        chosenLicenseMode = nil
                    }
                } label: {
                    Label("Reload Bottle Settings", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Reads the license server address back from the bottle registry; takes a few seconds")
            }
            .disabled(licenseServer.isOperating)
            switch licenseMode.wrappedValue {
            case .unconfigured:
                Text(BootstrapLicenseMode.unconfigured.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .remoteServer:
                addressEditor
            }
        }
    }

    private var personalizationSection: some View {
        Section("Personalization") {
            Toggle("Launch SOLIDWORKS automatically when MacSW starts", isOn: $autoLaunchSolidWorks)
            Picker("Wine language", selection: $wineLocale) {
                Text("English (en_US)").tag("en_US.UTF-8")
                Text("Chinese, Simplified (zh_CN)").tag("zh_CN.UTF-8")
            }
            Text("Sets the Windows locale and ANSI code page used by Wine (English: 1252, Chinese: 936). Chinese file names render with either choice. Restart Wine programs after changing this.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: macShortcutMapping) {
                HStack(spacing: 8) {
                    Text("Use Mac-style shortcuts in Wine")
                    Spacer(minLength: 0)
                    if keyboardShortcuts.isLoading || keyboardShortcuts.isOperating {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!keyboardShortcuts.canChange)
            .task { await keyboardShortcuts.refresh() }
            Text("Maps ⌘ to Windows Ctrl and ⌥ to Alt; reopen Wine programs after changing this.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !keyboardShortcuts.statusMessage.isEmpty {
                Text(keyboardShortcuts.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Give your Mac folders drive letters", isOn: $mapMacFolders)
            Text("Before each SOLIDWORKS start: H: is your home folder, B: Box, I: iCloud Drive, and other cloud folders (OneDrive, Google Drive, Dropbox) get a free letter from Y: down. Cloud folders also appear in C:\\users\\\(NSUserName()). A cloud folder gets its letter once you allow MacSW to access it. Letters already used for something else are left alone. Any letter or profile folder that leads into a cloud folder macOS has not let MacSW open yet is set aside before Wine starts and comes back once you allow it (not while SOLIDWORKS or another Wine program runs). Turning this off adds nothing new; existing letters stay.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Use macOS file dialogs", isOn: $useMacFileDialogs)
            Text("Open, Save As, Insert and Export use the Mac file browser instead of the Windows-style dialog, File > Open included. There, SOLIDWORKS's own options (open mode, configuration, display state) are then not shown. Takes effect the next time SOLIDWORKS starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Disable sldProcMon", isOn: resourceMonitorDisabled)
                .disabled(!resourceMonitor.canChange)
            Text("Prevents SOLIDWORKS Resource Monitor from starting. When on, sldProcMon.exe is renamed to sldProcMon.exe.disable and restored when turned off; if SOLIDWORKS is running, this takes effect at its next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !resourceMonitor.statusMessage.isEmpty {
                Text(resourceMonitor.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resourceMonitorDisabled: Binding<Bool> {
        Binding(
            get: { resourceMonitor.isDisabled },
            set: { resourceMonitor.setDisabled($0) }
        )
    }

    private var macShortcutMapping: Binding<Bool> {
        Binding(
            get: { keyboardShortcuts.isEnabled },
            set: { keyboardShortcuts.setEnabled($0) }
        )
    }

    private var addressEditor: some View {
        Group {
            HStack(spacing: 8) {
                Text("Server address")
                TextField("", text: $licenseServer.addressInput, prompt: Text("25734@license.example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { commitAddressIfNeeded() }
                    .onChange(of: addressFocused) { focused in
                        if !focused { commitAddressIfNeeded() }
                    }
            }
            .disabled(licenseServer.isOperating)
            Text("port@host; host:port and [IPv6]:port are also accepted. Separate multiple addresses with semicolons. Press Return or click elsewhere to write to the registry; takes effect at the next SOLIDWORKS launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !licenseServer.addressNotice.isEmpty {
                Text(licenseServer.addressNotice)
                    .font(.caption)
                    .foregroundStyle(licenseServer.addressHasError ? .red : .secondary)
            }
        }
    }

    /// 地址只有真的改过才再写一次，避免每次失焦都起一个 reg 进程。
    private func commitAddressIfNeeded() {
        guard licenseServer.appliedAddress != licenseServer.addressInput else { return }
        licenseServer.apply(mode: .remoteServer)
    }

    private var maintenanceSettings: some View {
        Form {
            Section("Wine Version and Upgrade") {
                Text(runtime.wineRuntimeState.message).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if runtime.wineRuntimeState == .baseline {
                        Button("Record Current Working Version…") { runtimeAction = "baseline" }
                    }
                    if runtime.wineRuntimeState == .upgrade {
                        Button("Back Up and Upgrade Bottle…") { runtimeAction = "upgrade" }
                    }
                    if runtime.wineRuntimeState == .recovery {
                        Button("Restore Old Bottle…") { runtimeAction = "recover" }
                    }
                    if runtime.wineRuntimeState == .ready, runtime.canRollbackWine {
                        Button("Roll Back Last Upgrade…") { runtimeAction = "rollback" }
                    }
                    Button("Show Backups and Logs") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:
                            WineRuntimeService.root(prefix: runtime.paths.bottle).path)
                    }
                    if runtime.isMigratingWine { ProgressView().controlSize(.small) }
                }
                .disabled(runtime.isMigratingWine)
                Text("The version identity covers Wine, Mono and patches. After migrating, still verify that SOLIDWORKS opens, models and saves; backups are not deleted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Wine Tools") {
                HStack(spacing: 10) {
                    wineToolButton("Registry Editor", name: "regedit")
                    wineToolButton("Wine Configuration", name: "winecfg")
                    wineToolButton("CMD", name: "cmd")
                    Button("Browse Virtual C: Drive") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.paths.bottle.appendingPathComponent("drive_c").path)
                    }
                }
            }
            Section("Bottle Processes") {
                ProcessTable(processes: runtime.processes)
                HStack {
                    Text("Total \(ProcessInventory.formatMegabytes(ProcessInventory.totalResidentMB(runtime.processes))) · \(runtime.processes.count) processes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Bottle Actions") {
                // 两个动作各占一行，说明写在各自按钮右边，读的人不用再去下面找对应关系。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("Restart Bottle") { runtime.restartContainer() }.disabled(runtime.isMigratingWine)
                    Text("Ends wineserver; relaunches SOLIDWORKS if it is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(role: .destructive) { runtime.forceStop() } label: {
                        // macOS 的 Form 按钮不会因为 role 变红（只在告警里生效），所以标签自己上色。
                        Text("Force Quit All Processes").foregroundStyle(.red)
                    }
                    .disabled(runtime.isMigratingWine)
                    Text("Terminates every process in the bottle and ends wineserver if necessary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !runtime.statusMessage.isEmpty {
                    Text(runtime.statusMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            solidWorksAppSection
            vbaSection
            Section("Diagnostics") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("Export Diagnostics…") { DiagnosticsExportAction.run(paths: runtime.paths) }
                    Text("Saves MacSW's logs and facts about this Mac as a zip on the Desktop, for the person who helps you. Shows the file list first. Serial numbers, e-mail addresses and other private values are removed; nothing is uploaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Install") {
                Button("Install or Reinstall SOLIDWORKS…") {
                    AppShell.shared.showBootstrapWindow()
                }
                .disabled(runtime.isMigratingWine)
                Text("Opens the separate Bootstrap window; the clean install option only appears when a bottle already exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            maintainsVisibility = true; runtime.refreshWineRuntime(); solidWorksApp.refresh()
            Task { await vba.refresh() }
        }
        .onDisappear { maintainsVisibility = false }
        .task(id: maintainsVisibility) {
            guard maintainsVisibility else { return }
            while !Task.isCancelled {
                // 只在设置窗口真的在前台时跑 ps，切到别的 App 就停。
                if NSApp.isActive { await runtime.refreshNow() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// SOLIDWORKS.app in /Applications (docs/solidworks-app.md, section 4).
    private var solidWorksAppSection: some View {
        Section("SOLIDWORKS App") {
            Text(solidWorksApp.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = solidWorksApp.pairingProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(solidWorksAppInstallTitle) {
                    // A copy signed with another identity is replaced only after the question below.
                    if solidWorksApp.requirementChangeNeedsConsent {
                        confirmsAppRequirementChange = true
                    } else {
                        Task {
                            await solidWorksApp.install()
                            if solidWorksApp.requirementChangeNeedsConsent { confirmsAppRequirementChange = true }
                        }
                    }
                }
                .disabled(!solidWorksApp.canInstall)
                if let installed = solidWorksApp.installedURL {
                    Button("Uninstall…") { confirmsAppUninstall = true }
                        .disabled(!solidWorksApp.canUninstall)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([installed]) }
                }
                if solidWorksApp.isWorking { ProgressView().controlSize(.small) }
            }
            if !solidWorksApp.statusMessage.isEmpty {
                Text(solidWorksApp.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Uninstall the SOLIDWORKS app?", isPresented: $confirmsAppUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash") { Task { await solidWorksApp.uninstall() } }
        } message: {
            Text("SOLIDWORKS.app is moved to the Trash and SOLIDWORKS documents open with MacSW again. SOLIDWORKS itself, the bottle and your files are not changed.")
        }
        .alert("Replace SOLIDWORKS.app?", isPresented: $confirmsAppRequirementChange) {
            Button("Cancel", role: .cancel) {}
            Button("Replace") { Task { await solidWorksApp.install(allowRequirementChange: true) } }
        } message: {
            Text("The installed SOLIDWORKS.app is signed with another code signing identity than the copy in this MacSW. After the replacement, macOS asks again for access to Desktop, Documents and Downloads, and Full Disk Access must be given again. The current copy is moved to the Trash.")
        }
    }

    /// VBA 7.1 (VBAPrerequisite): SOLIDWORKS needs it for equations, global variables and macros.
    /// The chosen folder is remembered, and later SOLIDWORKS installs search it too.
    private var vbaSection: some View {
        Section("VBA (Equations and Macros)") {
            Text(vbaSummary)
                .font(.caption)
                .foregroundStyle(vba.missingWarning != nil ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Install VBA (equations and macros)…") {
                    guard let folder = OpenPanelService.chooseVBAInstallerFolder(startingAt: vba.installerFolder) else { return }
                    Task { await vba.install(from: folder) }
                }
                .disabled(vba.isWorking || runtime.isMigratingWine || !runtime.paths.bottleExists)
                if vba.isWorking { ProgressView().controlSize(.small) }
            }
            if !vba.statusMessage.isEmpty {
                Text(vba.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var vbaSummary: String {
        switch vba.isRegistered {
        case true?: return "Microsoft VBA 7.1 is installed in the bottle."
        case false?: return VBAPrerequisite.missingWarning + " Choose the folder with vba71.msi and vba71_1033.msi (PreReqs\\VBA of the SOLIDWORKS media)."
        case nil: return "SOLIDWORKS needs Microsoft VBA 7.1 for equations, global variables and macros."
        }
    }

    private var solidWorksAppInstallTitle: String {
        switch solidWorksApp.status {
        case .stale: return "Update SOLIDWORKS App"
        case .current: return "Reinstall SOLIDWORKS App"
        case .notInstalled, .unknown, .foreign: return "Install SOLIDWORKS App"
        }
    }

    /// Wine 工具窗口不是瞬间出现：点下去之后按钮变灰并转菊花，直到进程真的起来。
    private func wineToolButton(_ title: String, name: String) -> some View {
        HStack(spacing: 6) {
            Button(title) { runtime.openWineTool(name) }
                .disabled(runtime.pendingWineTool != nil)
            if runtime.pendingWineTool == name {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// 单选未手工选过时，按容器里的真实配置推导当前模式。
    private var licenseMode: Binding<BootstrapLicenseMode> {
        Binding {
            if let chosenLicenseMode { return chosenLicenseMode }
            return licenseServer.addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unconfigured : .remoteServer
        } set: { mode in
            chosenLicenseMode = mode
            licenseServer.apply(mode: mode)
        }
    }
}

/// 活动监视器同款控件：可点表头排序、隔行底色、固定高度内嵌滚动。
private struct ProcessTable: View {
    let processes: [WineProcess]

    @State private var sortOrder: [KeyPathComparator<WineProcess>] = []

    var body: some View {
        Table(sortedProcesses, sortOrder: $sortOrder) {
            TableColumn("Process Name", value: \.name)
            TableColumn("PID", value: \.pid) { process in
                Text(Self.grouping.string(from: NSNumber(value: process.pid)) ?? "\(process.pid)")
            }
            TableColumn("Memory", value: \.residentMB) { process in
                Text("\(process.residentMB) MB")
            }
            TableColumn("Uptime", value: \.elapsedSeconds) { process in
                Text(ProcessInventory.formatElapsed(process.elapsed))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: 176)
        .overlay {
            if processes.isEmpty {
                Text("No running processes detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var sortedProcesses: [WineProcess] {
        guard !sortOrder.isEmpty else {
            return processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return processes.sorted(using: sortOrder)
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
