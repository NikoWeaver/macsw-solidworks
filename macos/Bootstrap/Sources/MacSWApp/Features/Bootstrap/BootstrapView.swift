import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

struct BootstrapView: View {
    @ObservedObject var store: BootstrapStore
    /// The team first-run wizard; `.manual` shows the install window as before.
    @ObservedObject var team: TeamSetupStore
    let onFinish: () -> Void
    @State private var showCleanInstallConfirmation = false
    @State private var additionalOptionsExpanded = false
    @State private var showCleanupConfirmation = false
    @State private var heights = WindowHeights()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.state == .completed {
                InstallationCompletionView(
                    autoLaunch: AppPreferences.autoLaunchSolidWorks(),
                    warnings: InstallationStep.allCases.compactMap { step in
                        guard store.stepStatuses[step] == .warning else { return nil }
                        return "\(step.title): \(store.stepDetails[step] ?? "See the log for details.")"
                    },
                    onRevealLogs: { LogReveal.open(store.paths.logs) },
                    onFinish: onFinish
                )
                .reportIdealScrollHeight()
                .reportViewportHeight()
                // The access key is not needed any more: forget it now, not only on Done.
                .onAppear { team.finish(store) }
            } else if team.page == .manual {
                header
                Divider()
                if store.state.isActive || isTerminalState {
                    progressContent
                } else {
                    configurationContent
                }
            } else if team.page == .install, store.state.isActive || isTerminalState {
                TeamSetupHeader(team: team)
                Divider()
                progressContent
            } else {
                TeamSetupView(store: store, team: team, heights: heights)
            }
        }
        .padding(24)
        .frame(minWidth: 620)
        .reportRootHeight()
        .collectWindowHeights { heights = $0 }
        .autoHeightWindow(targetContentHeight: heights.targetContentHeight)
        .alert("A clean install deletes the existing bottle", isPresented: $showCleanInstallConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete and Install", role: .destructive) { store.start() }
        } message: {
            Text("Programs, settings and files inside the bottle will be deleted. Move out anything you want to keep first.")
        }
        .alert("Clean Up Incomplete Install", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Stop Bottle and Delete", role: .destructive) {
                store.requestCleanupOfIncompleteInstallation()
            }
        } message: {
            Text("The incomplete install in the current Wine bottle will be deleted. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 36))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Install SOLIDWORKS").font(.title2.bold())
                Text("Deploys the official install media silently; no interaction in the installer window")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("SOLIDWORKS Install Media") {
                    HStack(spacing: 14) {
                        Image(systemName: store.selectedMedia == nil ? "opticaldisc" : "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(store.selectedMedia == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.selectedMedia?.lastPathComponent ?? "Not selected")
                                .fontWeight(.semibold)
                            Text(store.selectedMedia?.path ?? "Drop the official ISO, setup.exe or media folder here, or click to choose")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(store.selectedMedia == nil ? "Choose…" : "Change…") {
                            if let url = OpenPanelService.chooseInstallationMedia() { store.selectMedia(url) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .modifier(FileDropArea { store.selectMedia($0) })

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        additionalOptionsExpanded.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(additionalOptionsExpanded ? 90 : 0))
                            Text("Install Options").fontWeight(.medium)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    if additionalOptionsExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Silent install", isOn: $store.silentInstall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(store.silentInstall
                                ? "The official installer runs unattended; serial numbers and component choices are passed as MSI properties."
                                : "When off, the official installer wizard is shown and you pick components and enter serial numbers in its window.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }

                        if store.showsCleanInstall {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Clean install", isOn: $store.cleanInstall)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if store.cleanInstall {
                                    Text("Deletes the entire Wine bottle and redeploys; no backup is made.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 20)
                                }
                            }
                        }

                        if store.silentInstall {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Install Serial Numbers").fontWeight(.medium)
                                SerialFieldRow(
                                    title: InstallSerialField.solidWorks.title,
                                    text: $store.serialSolidWorks
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.simulation.title,
                                    text: $store.serialSimulation
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.motion.title,
                                    text: $store.serialMotion
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.mbd.title,
                                    text: $store.serialMBD
                                )
                                Text("The SOLIDWORKS serial number is required; the other three only license the products installed with the core and do not decide what gets installed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Interface Language").fontWeight(.medium)
                            Picker("Interface Language", selection: $store.selectedLanguage) {
                                Text("English").tag(Optional<SolidWorksLanguage>.none)
                                ForEach(store.availableLanguages) { language in
                                    Text(language.displayName).tag(Optional(language))
                                }
                            }
                            .labelsHidden()
                            .disabled(store.availableLanguages.isEmpty)
                            Text("Language resources come from the media's swwi/lang and are added silently after the main install.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LicenseServerOptions(store: store)
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                if store.replacesFailedBottle {
                    Label(CoreInstallRetry.freshBottleNote, systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let hint = store.startHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .reportIdealScrollHeight()
        }
        .frame(height: heights.pinnedScrollHeight)
        .reportViewportHeight()

        HStack {
            Button("Show Log") { LogReveal.open(store.paths.logs) }
            Button("Team Setup…") { team.showTeamSetup() }
            Spacer()
            Button(store.silentInstall ? "Start Silent Install" : "Start Install") { requestStart() }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStart)
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: progressValue, total: Double(InstallationStep.allCases.count))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(InstallationStep.allCases) { step in
                        InstallationStepRow(
                            step: step,
                            status: store.stepStatuses[step] ?? .pending,
                            detail: store.stepDetails[step]
                        )
                    }
                }
                .reportIdealScrollHeight()
            }
            .frame(height: heights.pinnedScrollHeight)
            .reportViewportHeight()
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Show Log") { LogReveal.open(store.paths.logs) }
                if !store.state.isActive {
                    Button("Export Diagnostics…") {
                        DiagnosticsExportAction.run(paths: store.paths, installStatus: store.installStatusReport)
                    }
                        .help("Saves the logs, with serials and other private values removed, as a zip on the Desktop. Shows the file list first.")
                }
                Spacer()
                if store.state.isActive {
                    Button("Stop Install", role: .destructive) { store.cancel() }
                        .disabled(store.state == .cancelling)
                } else {
                    Button("Clean Up Incomplete Install…", role: .destructive) { showCleanupConfirmation = true }
                    Button("Adjust Options and Retry") {
                        store.resetAfterFailure()
                        // The team setup returns to the access key page.
                        if team.page == .install { team.back() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var isTerminalState: Bool {
        switch store.state {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    private var progressValue: Double {
        Double(store.stepStatuses.values.filter { [.completed, .warning, .skipped].contains($0) }.count)
    }

    private func requestStart() {
        if store.cleanInstall { showCleanInstallConfirmation = true }
        else { store.start() }
    }
}

/// 可拖入文件URL的区域：拖入时给出描边与底色反馈，禁用状态下不接收。
struct FileDropArea: ViewModifier {
    let receive: (URL) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted && isEnabled ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted && isEnabled ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                guard isEnabled, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard error == nil, let url = Self.url(from: item) else { return }
                    // 拖放会话仍在事件跟踪循环里；等它收尾再处理，否则窗口会不吃鼠标事件。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { receive(url) }
                }
                return true
            }
    }

    /// 拖放载荷可能是 URL、其归档数据，也可能是纯字符串。
    private nonisolated static func url(from item: Any?) -> URL? {
        if let value = item as? URL { return value }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }
}

struct SerialFieldRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                TextField("XXXX XXXX XXXX XXXX XXXX XXXX", text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }        }
    }
}

private struct InstallationStepRow: View {
    let step: InstallationStep
    let status: InstallationStepStatus
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(step.title).fontWeight(.medium)
                    Spacer()
                    Text(status.rawValue).font(.caption).foregroundStyle(color)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 7)
        if step != InstallationStep.allCases.last { Divider() }
    }

    private var symbol: String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .pending, .skipped: return "circle"
        }
    }

    private var color: Color {
        switch status {
        case .running: return .purple
        case .completed: return .green
        case .failed: return .red
        case .warning: return .orange
        case .cancelled: return .secondary
        case .pending, .skipped: return .secondary
        }
    }
}

/// The licence server choice of the install options; the team setup shows it when its config does.
struct LicenseServerOptions: View {
    @ObservedObject var store: BootstrapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License Server").fontWeight(.medium)
            Picker("License Server", selection: $store.licenseMode) {
                ForEach(BootstrapLicenseMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()

            switch store.licenseMode {
            case .unconfigured:
                EmptyView()
            case .remoteServer:
                HStack(spacing: 8) {
                    Text("Server address")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    TextField("25734@192.168.1.20", text: $store.licenseServerAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            Text(store.licenseMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
