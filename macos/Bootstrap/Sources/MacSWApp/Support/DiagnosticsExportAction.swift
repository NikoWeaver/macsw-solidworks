import AppKit
import Foundation
import MacSWCore
import UniformTypeIdentifiers

/// "Export Diagnostics…" in the menu bar panel, in Settings and on the install-failure screen:
/// shows the file list first, then writes ~/Desktop/MacSW-diagnostics-<date>.zip
/// (`DiagnosticsExport`). Nothing is uploaded and no Wine program is started. The install-failure
/// screen also passes its step table (`installStatus`, install-status.txt).
@MainActor
enum DiagnosticsExportAction {
    private static var isRunning = false

    static func run(paths: AppPaths, installStatus: String? = nil) {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
            let bundle = MacSWBundle.url
            let processes = await ProcessInventory.snapshot(bottlePath: paths.bottle.path,
                                                            wineRuntimePath: WineService.shared.runtimeURL.path)
            let items = await Task.detached(priority: .userInitiated) {
                DiagnosticsExport.plan(paths: paths, bundle: bundle,
                                       facts: .live(paths: paths, bundle: bundle, processes: processes),
                                       installStatus: installStatus)
            }.value
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            var destination = DiagnosticsExport.destination(in: desktop)
            guard confirm(items: items, destination: destination) else { return }
            while true {
                do {
                    let target = destination
                    let written = try await Task.detached(priority: .userInitiated) {
                        try DiagnosticsExport.write(items, scrubber: .live(paths: paths), to: target)
                    }.value
                    NSWorkspace.shared.activateFileViewerSelecting([written])
                    return
                } catch {
                    // The Desktop can be closed to MacSW (Privacy & Security > Files and Folders).
                    guard let chosen = chooseOtherLocation(after: error, suggested: destination) else { return }
                    destination = chosen
                }
            }
        }
    }

    private static func confirm(items: [DiagnosticsExport.Item], destination: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Export Diagnostics?"
        alert.informativeText = """
            MacSW saves these files as \(destination.lastPathComponent) on your Desktop:

            \(items.map { "• " + $0.name }.joined(separator: "\n"))

            Serial numbers, e-mail addresses, MAC addresses, your user and computer names, cloud account names and licence server addresses are removed. Nothing is uploaded. Look at the zip before you send it.
            """
        alert.addButton(withTitle: "Save to Desktop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func chooseOtherLocation(after error: Error, suggested: URL) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Could not save the diagnostics"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Choose Another Folder…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The panel already asked whether to replace an existing file; the old one goes to the Trash.
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        return url
    }
}
