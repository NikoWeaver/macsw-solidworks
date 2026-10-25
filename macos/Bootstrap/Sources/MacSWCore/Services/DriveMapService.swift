import Foundation

/// Drive letters and Windows profile links for the owner's Mac folders, kept by MacSW itself
/// before every SOLIDWORKS launch and after the bottle is created or migrated:
/// - H: the home folder;
/// - B: `~/Library/CloudStorage/Box-Box` (Box Drive);
/// - I: iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`), only if it exists;
/// - every other folder in `~/Library/CloudStorage` (OneDrive-*, GoogleDrive-*, Dropbox, ...):
///   a letter from `poolLetters` (Y: downward, so Wine's mountmgr keeps E:, F:, ... for volumes),
///   stored in `drive-letters.json` next to the bottle so a folder keeps its letter while it is
///   missing for a while and after the bottle is reinstalled.
/// Each cloud folder also gets a link in `drive_c/users/<user>/` ("Box", "iCloud Drive",
/// "OneDrive", ...), where Box Drive and iCloud for Windows put them on a PC. A provider name that
/// is one of the profile's shell folders (Desktop, Documents, Downloads, Music, Pictures, Videos)
/// is not used, the full folder name is ("Pictures-Acme"): `WineBottleGate` never sets those six
/// names aside.
///
/// Nothing is ever removed or replaced. A letter or a profile name that exists and points
/// elsewhere (or is not a link, or dangles) is reported and left alone. A cloud folder already
/// mapped under another letter or profile name keeps it; H:, B: and I: are still made when free
/// (on two letters for one folder, Wine and `WineDocumentPath` use the lower one).
/// C:, D: and Z: (and A:) are never used.
/// Creating a link does not open its target, but Wine opens every drive root at each session
/// start (mountmgr reads `.windows-label`) and SOLIDWORKS can browse a profile link at any time;
/// either would raise a cloud folder's macOS prompt from Wine. So `maintain` first lets the native
/// app open each cloud folder that would get a new letter or link (`FolderConsentService.check`)
/// and maps only those macOS lets it open. Folders mapped already are left to `WineBottleGate`,
/// which runs before every Wine start and sets aside the links this process may not open; a
/// letter or name set aside stays taken here (`WineBottleGate.heldTargets`). While a Wine session
/// of the bottle runs (asked after the native checks), no cloud letter or link is added (the app
/// that started that session may not have been let into the folder); they are made at a later
/// run with no session.
public enum DriveMapService {
    public struct Folder: Equatable, Sendable {
        /// Key in the letter table: "home", "icloud" or "cloud:<folder name>".
        public let key: String
        /// For logs and messages: "Home", "Box", "OneDrive", "iCloud Drive".
        public let name: String
        public let url: URL
        /// H:, B: or I:; nil takes a letter from `poolLetters`.
        public let fixedLetter: Character?
        /// Names for the link in the Windows profile, the first free one is used; empty: no link.
        public let profileNames: [String]

        public init(key: String, name: String, url: URL, fixedLetter: Character?, profileNames: [String]) {
            self.key = key
            self.name = name
            self.url = url.standardizedFileURL
            self.fixedLetter = fixedLetter
            self.profileNames = profileNames
        }
    }

    public enum Outcome: String, Equatable, Sendable {
        case created
        /// Already mapped to this folder (by MacSW earlier, or by hand).
        case present
        /// The letter or name is used for something else; left alone.
        case conflict
        case noFreeLetter
        case failed
        /// macOS did not let the native app open the cloud folder (denied, no answer in time, or
        /// gone): nothing new is made for it; tried again on the next run.
        case noAccess
    }

    public struct Change: Equatable, Sendable {
        /// "B:" or "profile/Box".
        public let item: String
        public let folder: String
        public let outcome: Outcome

        public init(item: String, folder: String, outcome: Outcome) {
            self.item = item
            self.folder = folder
            self.outcome = outcome
        }
    }

    public static let iCloudDriveName = "iCloud Drive"
    public static let boxFolderName = "Box-Box"
    /// A: (floppy), C: (drive_c), D: (first removable volume) and Z: (/) are never mapped.
    public static let neverUsed: Set<Character> = ["A", "C", "D", "Z"]
    /// Letters for the other cloud folders, in order; H:, B: and I: stay free for their folders.
    public static let poolLetters: [Character] = Array("YXWVUTSRQPONMLKJGFE")
    public static let lettersFileName = "drive-letters.json"
    public static let logName = "drive-maps.log"
    public static let waitingMessage = "macOS is asking for permission to look at your cloud folders — click Allow so SOLIDWORKS can use them."

    public static func cloudStorage(home: URL) -> URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    public static func iCloudDrive(home: URL) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// The provider part of a CloudStorage folder name: "Box-Box" -> "Box",
    /// "OneDrive-Personal" -> "OneDrive", "GoogleDrive-me@example.com" -> "GoogleDrive".
    public static func providerName(_ folderName: String) -> String {
        let provider = folderName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return provider.isEmpty ? folderName : provider
    }

    /// Home, each folder in ~/Library/CloudStorage (sorted by name) and iCloud Drive if it exists.
    /// Reads the CloudStorage listing and whether iCloud Drive exists, never the folders' contents.
    public static func folders(home: URL, fileManager: FileManager = .default) -> [Folder] {
        let home = home.standardizedFileURL
        var result = [Folder(key: "home", name: "Home", url: home, fixedLetter: "H", profileNames: [])]
        let storage = cloudStorage(home: home)
        let entries = (try? fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = entry.lastPathComponent
            let provider = providerName(folderName)
            result.append(Folder(key: "cloud:\(folderName)", name: provider,
                                 url: storage.appendingPathComponent(folderName, isDirectory: true),
                                 fixedLetter: folderName == boxFolderName ? "B" : nil,
                                 profileNames: provider == folderName ? [folderName] : [provider, folderName]))
        }
        var isDirectory: ObjCBool = false
        let iCloud = iCloudDrive(home: home)
        if fileManager.fileExists(atPath: iCloud.path, isDirectory: &isDirectory), isDirectory.boolValue {
            result.append(Folder(key: "icloud", name: iCloudDriveName, url: iCloud, fixedLetter: "I",
                                 profileNames: [iCloudDriveName]))
        }
        return result
    }

    /// Creates the missing drive letters (`<prefix>/dosdevices/<x>:`) and profile links
    /// (`<prefix>/drive_c/users/<userName>/<name>`) for `folders`. `letters` is the stored table
    /// (key -> letter); letters found or assigned are written back into it. Idempotent; does
    /// nothing in a prefix without dosdevices (not initialized by wineboot yet). `dryRun` reports
    /// what would be created without creating it.
    public static func apply(
        _ folders: [Folder],
        prefix: URL,
        userName: String,
        letters: inout [String: String],
        dryRun: Bool = false,
        fileManager: FileManager = .default
    ) -> [Change] {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        guard isDirectory(dosdevices, fileManager) else { return [] }
        var taken = Set<Character>()
        var drives: [Character: String] = [:]
        // Letters set aside by WineBottleGate are still the user's or MacSW's: taken, and present
        // for their folder.
        for (name, target) in WineBottleGate.heldTargets(prefix: prefix, directory: "dosdevices", fileManager: fileManager)
            where WineBottleGate.isDriveName(name) {
            let letter = Character(name.prefix(1).uppercased())
            taken.insert(letter)
            drives[letter] = target
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: dosdevices.path)) ?? [] {
            // "x:" is a drive, "x::" its device node; either one takes the letter.
            guard (name.count == 2 && name.hasSuffix(":")) || (name.count == 3 && name.hasSuffix("::")),
                  let first = name.first, first.isASCII, first.isLetter else { continue }
            let letter = Character(first.uppercased())
            taken.insert(letter)
            if name.count == 2,
               let destination = try? fileManager.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent(name).path) {
                drives[letter] = URL(fileURLWithPath: destination, relativeTo: dosdevices).standardizedFileURL.path
            }
        }

        var changes: [Change] = []
        for folder in folders {
            let target = folder.url.path
            let letter: Character?
            if let fixed = folder.fixedLetter {
                letter = fixed
            } else if let existing = drives.filter({ $0.value == target }).keys.min() {
                letter = existing
            } else if let stored = letters[folder.key].flatMap(poolLetter) {
                letter = stored
            } else {
                let heldByOthers = Set(letters.filter { $0.key != folder.key }.values.compactMap(\.first))
                letter = poolLetters.first { !taken.contains($0) && !heldByOthers.contains($0) }
            }
            guard let letter, !neverUsed.contains(letter) else {
                changes.append(Change(item: "-", folder: folder.name, outcome: .noFreeLetter))
                continue
            }
            if drives[letter] == target {
                letters[folder.key] = String(letter)
                changes.append(Change(item: "\(letter):", folder: folder.name, outcome: .present))
                continue
            }
            guard !taken.contains(letter) else {
                changes.append(Change(item: "\(letter):", folder: folder.name, outcome: .conflict))
                continue
            }
            do {
                if !dryRun {
                    try fileManager.createSymbolicLink(atPath: dosdevices.appendingPathComponent(letter.lowercased() + ":").path,
                                                       withDestinationPath: target)
                }
                taken.insert(letter)
                drives[letter] = target
                letters[folder.key] = String(letter)
                changes.append(Change(item: "\(letter):", folder: folder.name, outcome: .created))
            } catch {
                changes.append(Change(item: "\(letter):", folder: folder.name, outcome: .failed))
            }
        }
        return changes + applyProfileLinks(folders, prefix: prefix, userName: userName, dryRun: dryRun, fileManager: fileManager)
    }

    /// Links in `drive_c/users/<userName>/`, only when that profile folder exists (wineboot makes it).
    static func applyProfileLinks(_ folders: [Folder], prefix: URL, userName: String, dryRun: Bool,
                                  fileManager: FileManager) -> [Change] {
        guard !userName.isEmpty, !userName.contains("/"), userName != ".", userName != ".." else { return [] }
        let profile = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
            .appendingPathComponent(userName, isDirectory: true)
        guard isDirectory(profile, fileManager) else { return [] }
        let entries = (try? fileManager.contentsOfDirectory(atPath: profile.path)) ?? []
        // Windows names are case-insensitive: "box" takes "Box".
        var usedNames = Set(entries.map { $0.lowercased() })
        var links: [String: String] = [:]
        for name in entries {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: profile.appendingPathComponent(name).path) {
                links[name] = URL(fileURLWithPath: destination, relativeTo: profile).standardizedFileURL.path
            }
        }
        // Names set aside by WineBottleGate stay taken.
        for (name, target) in WineBottleGate.heldTargets(prefix: prefix, directory: "drive_c/users/\(userName)",
                                                         fileManager: fileManager) {
            usedNames.insert(name.lowercased())
            links[name] = target
        }
        var changes: [Change] = []
        for folder in folders where !folder.profileNames.isEmpty {
            let target = folder.url.path
            if let existing = links.filter({ $0.value == target }).keys.min() {
                changes.append(Change(item: "profile/\(existing)", folder: folder.name, outcome: .present))
                continue
            }
            // Never a shell folder name: the bottle gate could not set that link aside.
            guard let name = folder.profileNames.first(where: {
                !usedNames.contains($0.lowercased()) && !WineBottleGate.shellFolders.contains($0.lowercased())
            }) else {
                changes.append(Change(item: "profile/\(folder.profileNames[0])", folder: folder.name, outcome: .conflict))
                continue
            }
            do {
                if !dryRun {
                    try fileManager.createSymbolicLink(atPath: profile.appendingPathComponent(name).path, withDestinationPath: target)
                }
                usedNames.insert(name.lowercased())
                links[name] = target
                changes.append(Change(item: "profile/\(name)", folder: folder.name, outcome: .created))
            } catch {
                changes.append(Change(item: "profile/\(name)", folder: folder.name, outcome: .failed))
            }
        }
        return changes
    }

    /// The live run for the stores: unless Settings turned it off, applies the mapping for the
    /// user's home folder to `paths.bottle`, keeps the letter table in `paths.appSupportDirectory`
    /// and appends one line to `drive-maps.log`. Finding the folders runs off the main thread and
    /// is waited for at most `timeout` seconds (finding iCloud Drive could show a macOS prompt in
    /// this process). Then every cloud folder that would get a new letter or profile link is
    /// listed natively with `list` (`FolderConsentService.check`, at most `timeout` seconds each);
    /// only folders that macOS lets this process open are mapped (and recorded in `session` for
    /// `WineBottleGate`), the others are reported as `.noAccess`. If a Wine session of the bottle
    /// runs after those checks (`isRunning`, asked last), only the home folder is mapped.
    /// `onWaiting` gets a status line while a macOS prompt is probably on screen.
    /// nil means it was off, the bottle is not initialized, or finding the folders timed out.
    public static func maintain(
        paths: AppPaths,
        enabled: Bool = AppPreferences.mapMacFolders(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userName: String = NSUserName(),
        timeout: TimeInterval = 120,
        list: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.contentsOfDirectory(atPath: $0.path) },
        session: FolderConsentService.Session = .current,
        isRunning: @escaping @Sendable (URL) -> Bool = { WineBottleGate.sessionRunning(prefix: $0) },
        onWaiting: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [Change]? {
        let log = paths.logs.appendingPathComponent(logName)
        let prefix = paths.bottle
        // Checked before anything looks at the home folder: no bottle, nothing to do.
        guard isDirectory(prefix.appendingPathComponent("dosdevices", isDirectory: true), .default) else { return nil }
        guard enabled else {
            appendLog("off in Settings; nothing changed", to: log)
            return nil
        }
        guard var found = await FolderConsentService.bounded(timeout: timeout, onWaiting: { onWaiting(waitingMessage) },
                                                              work: { folders(home: home) }) else {
            appendLog("no answer within \(Int(timeout)) s; continuing without waiting", to: log)
            return nil
        }
        let table = paths.appSupportDirectory.appendingPathComponent(lettersFileName)
        var letters = loadLetters(from: table)
        let before = letters
        // Each folder on its own: other folders' new letters can only turn a "created" into a
        // conflict or noFreeLetter, so no folder that will get something new is left unchecked.
        let pending = found.filter { folder in
            guard folder.key != "home" else { return false }
            var scratch = letters
            return apply([folder], prefix: prefix, userName: userName, letters: &scratch, dryRun: true)
                .contains { $0.outcome == .created }
        }
        let checks = await FolderConsentService.check(
            pending.map { FolderConsentService.ProtectedFolder(name: $0.name, url: $0.url) },
            timeout: timeout, list: list, session: session,
            onWaiting: { onWaiting(FolderConsentService.waitingMessage(for: $0)) })
        // Asked after the native checks, as `WineBottleGate.prepare` does: a session that started
        // while a macOS prompt was on screen gets no new cloud letter or link. Off the caller's
        // thread: it can wait for a wineserver lock to clear.
        let running = await Task.detached { isRunning(prefix) }.value
        if running { found = found.filter { $0.key == "home" } }
        let refused = Set(checks.filter { $0.access != .granted }.map(\.folder.url.path))
        var changes = apply(found.filter { !refused.contains($0.url.path) }, prefix: prefix, userName: userName, letters: &letters)
        changes += found.filter { refused.contains($0.url.path) }
            .map { Change(item: "-", folder: $0.name, outcome: .noAccess) }
        if letters != before { saveLetters(letters, to: table) }
        appendLog(summary(changes) + (running ? "; Wine session running: cloud folders not mapped now" : ""), to: log)
        return changes
    }

    public static func summary(_ changes: [Change]) -> String {
        changes.isEmpty ? "(nothing to map)" : changes.map { "\($0.item) \($0.folder)=\($0.outcome.rawValue)" }.joined(separator: "; ")
    }

    /// The stored letter table; a missing or unreadable file is an empty table.
    public static func loadLetters(from file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table.filter { $0.value.count == 1 && $0.value.first?.isASCII == true && $0.value.first?.isUppercase == true }
    }

    public static func saveLetters(_ letters: [String: String], to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(letters) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        // The keys hold CloudStorage folder names, which can contain an account's email address.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func poolLetter(_ stored: String) -> Character? {
        guard stored.count == 1, let letter = stored.first, poolLetters.contains(letter) else { return nil }
        return letter
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func appendLog(_ text: String, to log: URL) {
        LogFiles.append("\(ISO8601DateFormatter().string(from: Date())) \(text)\n", to: log)
    }
}
