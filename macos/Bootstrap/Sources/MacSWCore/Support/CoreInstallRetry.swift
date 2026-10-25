import Foundation

/// Windows Installer caches the package it installs (`drive_c/windows/Installer/<hex>.msi`) and uses that
/// copy again for the same ProductCode, even when MacSW passes a newly edited MSI. So a core install that
/// failed in a bottle fails there again. The rule (docs/spatialiop-fix.md): a failed core install in a
/// bottle where SOLIDWORKS never started is retried in a fresh bottle, and the old bottle goes to the Trash.
///
/// "Never started" stands in for "never activated": MacSW does not read licence or activation files, and
/// activation happens in SOLIDWORKS or the wizard that SOLIDWORKS starts. Both facts are files that MacSW
/// writes in the bottle root (like `.macsw-held`), so they go with the bottle. Each one fails safe: a
/// bottle made before this rule has no never-started file, so the rule never replaces it.
public enum CoreInstallRetry {
    /// Written just before the core msiexec starts; removed only when that msiexec succeeds.
    static let incompleteMarkerName = ".macsw-core-install-incomplete"
    /// Written when the installer makes a new bottle; removed the first time MacSW or SOLIDWORKS.app starts
    /// anything there that is or can start SLDWORKS.exe or its activation wizard (`noteSolidWorksMayStart`).
    static let neverStartedName = ".macsw-solidworks-never-started"

    public enum Decision: Equatable, Sendable {
        case keepBottle
        case freshBottle
    }

    /// `receiptExists`: MacSW finished an install (`installation-complete.json`); that bottle is always kept.
    static func decision(bottleExists: Bool, receiptExists: Bool, coreInstallIncomplete: Bool,
                         solidWorksNeverStarted: Bool) -> Decision {
        bottleExists && !receiptExists && coreInstallIncomplete && solidWorksNeverStarted ? .freshBottle : .keepBottle
    }

    public static func decision(prefix: URL, receiptExists: Bool, fileManager: FileManager = .default) -> Decision {
        decision(bottleExists: fileManager.fileExists(atPath: prefix.path),
                 receiptExists: receiptExists,
                 coreInstallIncomplete: fileManager.fileExists(atPath: prefix.appendingPathComponent(incompleteMarkerName).path),
                 solidWorksNeverStarted: fileManager.fileExists(atPath: prefix.appendingPathComponent(neverStartedName).path))
    }

    static func markNewBottle(prefix: URL) throws {
        try stamp("bottle made by the installer", at: prefix.appendingPathComponent(neverStartedName))
    }

    static func markCoreInstallStarted(prefix: URL) throws {
        try stamp("core msiexec started", at: prefix.appendingPathComponent(incompleteMarkerName))
    }

    static func markCoreInstallSucceeded(prefix: URL) {
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(incompleteMarkerName))
    }

    /// Called before SOLIDWORKS, a document hand-off, the SWCLI daemon or a Wine tool (CMD can start any
    /// program) starts in the bottle. Best effort: a launch never waits on or fails because of it.
    static func noteSolidWorksMayStart(prefix: URL) {
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(neverStartedName))
    }

    private static func stamp(_ text: String, at url: URL) throws {
        try Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8).write(to: url, options: .atomic)
    }

    /// Shown before the install starts when the rule applies.
    public static let freshBottleNote = "The last SOLIDWORKS install in this bottle failed. Windows Installer keeps the failed package in the bottle and would use it again, so MacSW moves this bottle to the Trash and installs into a fresh bottle. SOLIDWORKS never started in this bottle, so it was never activated."
    /// Added to a core install failure when the next start will use a fresh bottle.
    static let retryNote = "Start the install again: MacSW then moves this bottle to the Trash and installs into a fresh bottle, because Windows Installer keeps the failed package in this one."
}
