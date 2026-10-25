import MacSWCore
import SwiftUI

/// 安装结果保留到用户确认，不能因收到完成通知就消失。
struct InstallationCompletionView: View {
    let autoLaunch: Bool
    let warnings: [String]
    let onRevealLogs: () -> Void
    let onFinish: () -> Void
    @EnvironmentObject private var solidWorksApp: SolidWorksAppStore
    /// Decided once when the page appears, so the result of the install stays visible.
    @State private var offersSolidWorksApp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Installation Complete").font(.title2.bold())
                    Text("SOLIDWORKS has been installed.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Text(autoLaunch
                ? "Click Done to close the installer window and launch SOLIDWORKS."
                : "Click Done to close the installer window. You can launch SOLIDWORKS from the menu bar afterwards.")
                .foregroundStyle(.secondary)

            if offersSolidWorksApp {
                solidWorksAppOffer
            }

            if !warnings.isEmpty {
                GroupBox("Install Notes") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(warnings.indices, id: \.self) { index in
                                Label(warnings[index], systemImage: "exclamationmark.triangle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 120)
                }
            }

            HStack {
                Button("Show Log", action: onRevealLogs)
                Spacer()
                Button("Done", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            solidWorksApp.refresh()
            offersSolidWorksApp = solidWorksApp.status == .notInstalled && solidWorksApp.canInstall
        }
    }

    /// The first-run suggestion (docs/solidworks-app.md, section 4); also in Settings → Maintenance.
    private var solidWorksAppOffer: some View {
        GroupBox("SOLIDWORKS App") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add SOLIDWORKS to the Applications folder to start it from Launchpad, Spotlight and the Dock like any Mac app. SOLIDWORKS documents then open with it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Install SOLIDWORKS App") { Task { await solidWorksApp.install() } }
                        .disabled(!solidWorksApp.canInstall || solidWorksApp.status != .notInstalled)
                    if solidWorksApp.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !solidWorksApp.statusMessage.isEmpty {
                    Text(solidWorksApp.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
