import Darwin
import Foundation

/// A MacSW.app copied from a downloaded disk image carries `com.apple.quarantine` on every file.
/// "Open Anyway" lets MacSW itself start, but the flag stays on the Wine loader, wineserver and 7zz
/// in the bundle, and macOS can block those helpers when MacSW starts them. At the first launch
/// MacSW asks, and with the user's consent removes the flag from its own bundle only
/// (docs/packaging.md). The attribute is not sealed by the code signature, so the signature stays valid.
public enum DownloadQuarantine {
    public static let attribute = "com.apple.quarantine"

    /// The question MacSW asks before it changes anything.
    public static let consentText =
        "MacSW will remove the download flag from its own files so that macOS does not block its Wine helpers."

    public enum Decision: Equatable, Sendable {
        /// No flag on the bundle (a copy from Box Drive, or the flag was removed already).
        case nothing
        /// Ask the user, then remove the flag from the bundle.
        case ask
        /// The user chose "Do not ask again".
        case suppressed
        /// macOS runs a read-only copy (App Translocation), where nothing can be removed. The user
        /// moves MacSW to Applications and opens it from there.
        case translocated
    }

    /// What to do at launch for the bundle at `bundle`. Only the bundle folder itself is checked.
    public static func decision(bundle: URL, suppressed: Bool,
                                isQuarantined: (URL) -> Bool = hasAttribute) -> Decision {
        guard isQuarantined(bundle) else { return .nothing }
        if isTranslocated(bundle) { return .translocated }
        return suppressed ? .suppressed : .ask
    }

    /// macOS starts a quarantined app that was not moved (for example one opened on the disk image)
    /// from a random read-only path below `.../AppTranslocation/<UUID>/`.
    static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.standardizedFileURL.pathComponents.contains("AppTranslocation")
    }

    public static func hasAttribute(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the flag from every item in `bundle`, then from `bundle` itself. Symbolic links are
    /// changed themselves and never followed, so nothing outside the bundle changes. Returns the
    /// number of items that had the flag. Stops at the first item it cannot change; the bundle
    /// folder keeps its flag then, so the next launch asks again.
    @discardableResult
    public static func remove(from bundle: URL, fileManager: FileManager = .default) throws -> Int {
        guard bundle.pathExtension == "app",
              (try? bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: bundle.path])
        }
        var enumerationError: Error?
        let items = fileManager.enumerator(at: bundle, includingPropertiesForKeys: nil, options: []) { _, error in
            enumerationError = error
            return false
        }
        var removed = 0
        func clear(_ url: URL) throws {
            if removexattr(url.path, attribute, XATTR_NOFOLLOW) == 0 {
                removed += 1
            } else if errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        while let item = items?.nextObject() as? URL {
            try clear(item)
        }
        if let enumerationError { throw enumerationError }
        try clear(bundle)
        return removed
    }
}
