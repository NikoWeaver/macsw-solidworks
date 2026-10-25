import AppKit
import MacSWCore
import SwiftUI

/// The team first-run wizard (docs/team-admin.md): check this Mac and find the team folder and
/// the media, enter the access key, copy the media. `TeamSetupStore` holds the pages; the install
/// itself is `BootstrapStore`'s, and `BootstrapView` shows its progress.
struct TeamSetupView: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var team: TeamSetupStore
    let heights: WindowHeights

    var body: some View {
        TeamSetupHeader(team: team)
        Divider()
        switch team.page {
        case .check: checkPage
        case .accessKey: accessKeyPage
        case .install: copyPage
        case .manual: EmptyView()
        }
    }

    private var isSearching: Bool { team.isSearchingTeamConfig || team.isSearchingMedia }

    // MARK: Check

    @ViewBuilder
    private var checkPage: some View {
        page {
            GroupBox("This Mac") { preflightSection }
            GroupBox("Team Folder") { teamFolderSection }
            if team.teamConfig != nil {
                GroupBox("SOLIDWORKS Install Media") { mediaSection }
                    .modifier(FileDropArea { url in Task { await team.useDroppedMedia(url) } })
                    .disabled(isSearching)
            }
            // While searching, it says which macOS prompt MacSW waits for.
            if isSearching, !team.statusMessage.isEmpty {
                Text(team.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task { await team.begin() }

        HStack {
            Button("Install Without Team Folder") { team.useManualInstall(store) }
            Spacer()
            if team.hasSearched, team.teamConfig != nil {
                Button("Continue") { team.continueToAccessKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!team.isReady || isSearching)
            } else {
                Button(team.hasSearched ? "Search Again" : "Continue") { Task { await team.search() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(team.preflight.isEmpty || team.preflightBlocked || isSearching)
            }
        }
    }

    @ViewBuilder
    private var preflightSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if team.preflight.isEmpty {
                ProgressRow(text: "Checking this Mac…")
            }
            ForEach(team.preflight) { check in
                PreflightRow(check: check)
            }
            if team.preflightBlocked {
                HStack(spacing: 8) {
                    if team.preflight.contains(where: { $0.item == .rosetta && $0.verdict == .blocked }) {
                        Button("Install Rosetta") { team.installRosetta() }
                    }
                    Button("Check Again") { Task { await team.runPreflight() } }
                        .disabled(team.isCheckingPreflight)
                    Spacer()
                }
                .padding(.top, 8)
                // What to do when Apple's Rosetta window does not open.
                if !team.hasSearched, !team.statusMessage.isEmpty {
                    Text(team.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var teamFolderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let found = team.teamConfig {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(found.config.team).fontWeight(.semibold)
                        Text("SOLIDWORKS \(found.config.solidWorks.release), found \(found.source.phrase)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else if team.isSearchingTeamConfig {
                ProgressRow(text: "Looking for the team folder…")
            } else if !team.hasSearched {
                Text("MacSW now looks for your team folder in Downloads and in Box. macOS asks whether MacSW may open these folders. Click Allow.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(team.teamConfigProblem ?? "No team folder found in Downloads or Box.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Choose the team's MacSW folder (it holds macsw-team.json), or install without a team folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if team.hasSearched, !isSearching {
                HStack {
                    Button("Choose Team Folder…") {
                        if let url = OpenPanelService.chooseTeamFolder() { Task { await team.chooseTeamFolder(url) } }
                    }
                    Spacer()
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if team.isSearchingMedia {
                ProgressRow(text: "Looking for the SOLIDWORKS media…")
            } else if let summary = team.mediaSummary, let media = team.media {
                HStack(spacing: 12) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary).fontWeight(.semibold)
                        Text(media.media.displayURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            } else {
                Label(team.mediaProblem ?? "No SOLIDWORKS media found.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drop the ISO or the media folder here, or click Choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Search Again") { Task { await team.findMedia() } }
                Button("Choose…") {
                    if let url = OpenPanelService.chooseInstallationMedia() { Task { await team.useDroppedMedia(url) } }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Access key

    private var keyFormat: AccessKey.Format { AccessKey.check(store.serialSolidWorks) }

    private var install: TeamConfig.Install { team.teamConfig?.config.install ?? TeamConfig.Install.none }

    /// The fields this page shows are ready; the store checks again before it starts.
    private var canInstall: Bool {
        keyFormat == .valid
            && (!install.showOtherKeys || store.serials.invalidFields().isEmpty)
            && (!install.showLicenseServer || store.licenseMode.missingInputMessage(address: store.licenseServerAddress) == nil)
    }

    @ViewBuilder
    private var accessKeyPage: some View {
        page {
            if let found = team.teamConfig {
                GroupBox("Team") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(found.config.team).fontWeight(.semibold)
                        Text(team.mediaSummary ?? "SOLIDWORKS \(found.config.solidWorks.release)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if team.needsCopy, team.installMedia == nil {
                            Text("MacSW copies the media to this Mac first and checks every file. This takes 10 minutes to an hour.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GroupBox("Access Key") { accessKeySection }
            // Only when the team config could not be saved (TeamSetupStore.importTeamConfig).
            if let problem = team.teamConfigProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The retry rule (CoreInstallRetry), said before Install as in the install window.
            if store.replacesFailedBottle {
                Label(CoreInstallRetry.freshBottleNote, systemImage: "arrow.counterclockwise.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if install.showOtherKeys {
                GroupBox("Other Serial Numbers") {
                    VStack(alignment: .leading, spacing: 8) {
                        SerialFieldRow(title: InstallSerialField.simulation.title, text: $store.serialSimulation)
                        SerialFieldRow(title: InstallSerialField.motion.title, text: $store.serialMotion)
                        SerialFieldRow(title: InstallSerialField.mbd.title, text: $store.serialMBD)
                        Text("Only if your team lead gave you these. They license products that are installed with SOLIDWORKS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }
            if install.showLicenseServer {
                GroupBox {
                    LicenseServerOptions(store: store)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        HStack {
            Button("Back") { team.back() }
            Spacer()
            Button("Install") { Task { await team.install(into: store) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
        }
    }

    @ViewBuilder
    private var accessKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("XXXX XXXX XXXX XXXX XXXX XXXX", text: $store.serialSolidWorks)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Access key")
                Button("Paste") { pasteAccessKey() }
            }
            if let message = AccessKey.message(for: keyFormat) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if keyFormat == .valid {
                Label("Six groups of four: the format is right.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text("Your team lead gives you the access key: the team's SOLIDWORKS serial number. MacSW gives it to the installer and does not save it. Do not put it in a chat or a screenshot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let contact = team.teamConfig?.config.supportContact {
                Text("Questions: \(contact)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A key in the right format goes into the field in groups of four; anything else as it is,
    /// so the format check under the field says what is wrong.
    private func pasteAccessKey() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        store.serialSolidWorks = AccessKey.check(text) == .valid
            ? AccessKey.grouped(text)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Copy

    @ViewBuilder
    private var copyPage: some View {
        page {
            switch team.copyState {
            case .copying(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    Text("You can use your Mac meanwhile. Keep it plugged in.")
                    ProgressView(value: progress.fraction)
                    Text("Copying the media to this Mac: \(Self.bytes(progress.completedBytes)) of \(Self.bytes(progress.totalBytes))")
                        .font(.caption)
                    if progress.totalFiles > 0 {
                        Text("File \(progress.completedFiles) of \(progress.totalFiles)\(progress.currentFile.map { ": \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .cancelled:
                Label("The copy stopped. Try Again goes on where it stopped.", systemImage: "stop.circle.fill")
            case .idle, .completed:
                if team.statusMessage.isEmpty {
                    ProgressRow(text: "Starting the install…")
                } else {
                    Text(team.statusMessage)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }

        HStack {
            Button("Show Log") { LogReveal.open(store.paths.logs) }
            Spacer()
            if team.copyState.isActive {
                Button("Stop Copy", role: .destructive) { team.cancelCopy() }
            } else {
                Button("Back") { team.back() }
                Button("Try Again") { Task { await team.install(into: store) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Layout

    /// One scrolling page, measured like the install window (BootstrapWindowSizing).
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .reportIdealScrollHeight()
        }
        .frame(height: heights.pinnedScrollHeight)
        .reportViewportHeight()
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// "Set Up SOLIDWORKS", the team, and where the member is: Check, Access Key, Install.
struct TeamSetupHeader: View {
    @ObservedObject var team: TeamSetupStore

    private static let steps: [(page: TeamSetupStore.Page, title: String)] = [
        (.check, "Check"), (.accessKey, "Access Key"), (.install, "Install")
    ]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 30))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 5) {
                Text(team.teamConfig.map { "Set Up SOLIDWORKS for \($0.config.team)" } ?? "Set Up SOLIDWORKS")
                    .font(.title2.bold())
                HStack(spacing: 12) {
                    ForEach(Self.steps.indices, id: \.self) { index in
                        Label(Self.steps[index].title, systemImage: symbol(index))
                            .font(.caption.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(index == current ? Color.accentColor : Color.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private var current: Int { Self.steps.firstIndex { $0.page == team.page } ?? 0 }

    private func symbol(_ index: Int) -> String {
        index < current ? "checkmark.circle.fill" : "\(index + 1).circle\(index == current ? ".fill" : "")"
    }
}

private struct PreflightRow: View {
    let check: PreflightService.Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.item.title).fontWeight(.medium)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch check.verdict {
        case .passed: return "checkmark.circle.fill"
        case .note: return "info.circle.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch check.verdict {
        case .passed: return .green
        case .note: return .orange
        case .blocked: return .red
        }
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
