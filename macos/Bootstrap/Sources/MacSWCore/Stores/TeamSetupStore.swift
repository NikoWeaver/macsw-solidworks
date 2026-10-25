import Combine
import Foundation

/// The team first-run wizard (docs/team-admin.md): the preflight, the team config, the media and
/// its local copy, the access key and the hand-off to `BootstrapStore`. Its `page` is the step
/// the window shows:
/// 1. `.check`: `begin()` runs the preflight (while `preflightBlocked`, offer `installRosetta()`
///    and `runPreflight()` again). The searches can raise macOS's folder prompts (Downloads, Box),
///    so the page shows the privacy text first, and its Continue is `search()`: the team config,
///    then its media. With a config imported earlier, `begin()` searches by itself. Without a
///    team config, `chooseTeamFolder(_:)` or `useManualInstall(_:)`. When the preflight passed
///    and the config and the media were found, the page goes on to the access key by itself.
/// 2. `.accessKey`: the access key is `BootstrapStore.serialSolidWorks` (`AccessKey.check`);
///    Install is `install(into:)`.
/// 3. `.install`: the media copy when it is not on this Mac yet (`copyState`; `cancelCopy()`
///    stops it, Install again goes on from there), then `handOff(to:)` and the install in
///    `BootstrapStore`, which installs as before. `back()` returns to the access key.
/// `.manual` is the install window without the team setup; `showTeamSetup()` returns from it.
/// `finish(_:)` after the install forgets the access key.
/// Nothing here starts Wine, and nothing here reads or keeps a serial.
@MainActor
public final class TeamSetupStore: ObservableObject {
    public enum Page: Equatable, Sendable {
        /// The preflight, then the team config and the media.
        case check
        case accessKey
        /// The media copy, then the install in `BootstrapStore`.
        case install
        /// The install window without the team setup.
        case manual
    }

    public enum CopyState: Equatable, Sendable {
        case idle
        case copying(MediaCopyService.Progress)
        case completed(URL)
        case cancelled
        case failed(String)

        public var isActive: Bool {
            if case .copying = self { return true }
            return false
        }
    }

    @Published public private(set) var page: Page = .check
    /// The search for the team config has started (the privacy text was shown before it).
    @Published public private(set) var hasSearched = false
    @Published public private(set) var preflight: [PreflightService.Check] = []
    @Published public private(set) var isCheckingPreflight = false
    @Published public private(set) var teamConfig: TeamConfigLocator.Found?
    /// Why the team config that was found (or chosen) cannot be used.
    @Published public private(set) var teamConfigProblem: String?
    @Published public private(set) var isSearchingTeamConfig = false
    @Published public private(set) var media: DiscoveredMedia?
    @Published public private(set) var mediaProblem: String?
    @Published public private(set) var isSearchingMedia = false
    @Published public private(set) var copyState: CopyState = .idle
    @Published public private(set) var statusMessage = ""

    public let paths: AppPaths
    private let defaults: UserDefaults
    private let home: URL
    private let factsOverride: (@Sendable () -> PreflightService.Facts)?
    private let appFoldersOverride: [URL]?
    private let volumesOverride: [URL]?
    private let mayOpenOverride: (@Sendable (URL) async -> Bool)?
    private let freeBytes: @Sendable (URL) -> Int64?
    private let startInstall: @MainActor (BootstrapStore) -> Void
    private var copyJob: Task<MediaCopyService.Result, Error>?
    /// The team config's `vba.path`, found by `findMedia()` while the team folder was readable.
    private var teamVBAFolder: URL?

    /// The overrides are for tests; nil uses this Mac (its facts, MacSW's own folder and DMG, the
    /// mounted volumes, `FolderConsentService` for protected folders, the free disk space, and
    /// `BootstrapStore.start()`).
    public init(
        paths: AppPaths,
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        facts: (@Sendable () -> PreflightService.Facts)? = nil,
        appFolders: [URL]? = nil,
        volumes: [URL]? = nil,
        mayOpen: (@Sendable (URL) async -> Bool)? = nil,
        freeBytes: (@Sendable (URL) -> Int64?)? = nil,
        startInstall: (@MainActor (BootstrapStore) -> Void)? = nil
    ) {
        self.paths = paths
        self.defaults = defaults
        self.home = home
        self.factsOverride = facts
        self.appFoldersOverride = appFolders
        self.volumesOverride = volumes
        self.mayOpenOverride = mayOpen
        self.freeBytes = freeBytes ?? { PreflightService.freeBytes(at: $0) }
        self.startInstall = startInstall ?? { $0.start() }
    }

    public var preflightBlocked: Bool { PreflightService.isBlocked(preflight) }

    /// The check page is done: the preflight passed, and the team config and its media were found.
    public var isReady: Bool {
        !preflight.isEmpty && !preflightBlocked && teamConfig != nil && media != nil
    }

    /// "Found SOLIDWORKS 2026 SP4.1 in your team folder, 9.2 GB".
    public var mediaSummary: String? {
        guard let media else { return nil }
        let isTeamMedia = media.source == .teamFolder || media.source == .localCopy
        let name = teamConfig.flatMap { isTeamMedia ? "SOLIDWORKS \($0.config.solidWorks.release)" : nil }
            ?? media.media.displayURL.lastPathComponent
        return "Found \(name) \(media.source.phrase), \(media.sizeText)"
    }

    /// The media is copied to this Mac first: team-mode media with a manifest that is not on this
    /// Mac yet. Other media is used where it is, as before.
    public var needsCopy: Bool {
        guard teamConfig != nil, let media, media.source != .localCopy else { return false }
        return media.source == .teamFolder || media.hasManifest
    }

    /// Where the install reads the media from: the finished copy, or media used where it is.
    public var installMedia: URL? {
        if case .completed(let folder) = copyState { return folder }
        guard let media, !needsCopy else { return nil }
        return media.source == .localCopy ? media.root : media.media.displayURL
    }

    // MARK: Preflight

    public func runPreflight() async {
        guard !isCheckingPreflight else { return }
        isCheckingPreflight = true
        defer { isCheckingPreflight = false }
        let volume = paths.appSupportDirectory
        let media = paths.media
        let facts = factsOverride ?? { PreflightService.gatherFacts(volume: volume) }
        let (gathered, copied) = await Task.detached(priority: .userInitiated) {
            (facts(), MediaCopyService.bytesOnDisk(in: media))
        }.value
        preflight = PreflightService.evaluate(gathered, alreadyCopiedBytes: copied)
        advanceIfReady()
    }

    /// Opens Apple's Rosetta installer. The member answers Apple's dialog; MacSW accepts nothing.
    public func installRosetta() {
        statusMessage = PreflightService.startRosettaInstall()
            ? "Follow the steps in Apple's window, then click Check Again."
            : "Open Terminal and run: \(PreflightService.rosettaInstallCommand)"
    }

    // MARK: Pages

    /// When the window opens: the preflight, then the search if a config was imported earlier
    /// (it needs no new macOS prompt). Otherwise the page shows the privacy text and Continue.
    public func begin() async {
        guard page == .check, !hasSearched, !isCheckingPreflight else { return }
        await runPreflight()
        if FileManager.default.fileExists(atPath: paths.teamConfig.path) { await search() }
    }

    /// Continue after the privacy text: the team config, then its media.
    public func search() async {
        guard page == .check, !isSearchingTeamConfig, !isSearchingMedia else { return }
        hasSearched = true
        await locateTeamConfig()
        if teamConfig != nil { await findMedia() }
    }

    /// Install on the access key page (and Try Again after a stopped copy): checks the fields
    /// before anything is copied, keeps the team config, copies the media when it is not on this
    /// Mac yet, gives the media and the team options to `bootstrap` and starts its install. When
    /// the copy stops, the page stays, and `copyState` says why.
    public func install(into bootstrap: BootstrapStore) async {
        guard page == .accessKey || page == .install, !copyState.isActive, !bootstrap.state.isActive,
              AccessKey.check(bootstrap.serialSolidWorks) == .valid else { return }
        applyTeamOptions(to: bootstrap)
        if let hint = bootstrap.startHint {
            statusMessage = hint
            return
        }
        guard importTeamConfig() else { return }
        page = .install
        if installMedia == nil { await copyMedia() }
        guard handOff(to: bootstrap) else {
            if case .completed = copyState { statusMessage = bootstrap.statusMessage }
            return
        }
        guard bootstrap.canStart else {
            statusMessage = bootstrap.startHint ?? bootstrap.statusMessage
            return
        }
        startInstall(bootstrap)
    }

    /// From the access key to the check page; from a stopped copy or a failed install (after
    /// `BootstrapStore.resetAfterFailure()`) to the access key.
    public func back() {
        switch page {
        case .accessKey: page = .check
        case .install where !copyState.isActive: page = .accessKey
        default: break
        }
    }

    /// "Install without a team folder": the install window as before, without the team options.
    public func useManualInstall(_ bootstrap: BootstrapStore) {
        guard !copyState.isActive, !bootstrap.state.isActive else { return }
        Self.clearTeamOptions(of: bootstrap)
        page = .manual
    }

    public func showTeamSetup() {
        guard page == .manual else { return }
        page = .check
    }

    /// The team install has finished: forgets the access key. SOLIDWORKS is installed now, so
    /// the window opens as the install window later (a reinstall from Settings).
    public func finish(_ bootstrap: BootstrapStore) {
        guard page == .install else { return }
        bootstrap.forgetSerials()
        Self.clearTeamOptions(of: bootstrap)
        page = .manual
        hasSearched = false
    }

    /// The install window without the team setup installs as before.
    private static func clearTeamOptions(of bootstrap: BootstrapStore) {
        bootstrap.requiresKnownVBA = false
        bootstrap.teamVBAFolder = nil
    }

    /// Continue on the check page (after Back); the page also goes on by itself when it is ready.
    public func continueToAccessKey() {
        if page == .check, isReady { page = .accessKey }
    }

    private func advanceIfReady() { continueToAccessKey() }

    // MARK: Team config

    public func locateTeamConfig() async {
        guard !isSearchingTeamConfig, !copyState.isActive else { return }
        isSearchingTeamConfig = true
        defer { isSearchingTeamConfig = false }
        statusMessage = "Looking for the team config…"
        let folders = await appFolders()
        let outcome = await TeamConfigLocator.locate(
            paths: paths, defaults: defaults, appFolders: folders, home: home,
            mayOpen: { [weak self] folder in await self?.mayOpen(folder) ?? false }
        )
        apply(outcome)
    }

    /// "Choose team folder…": the team's MacSW folder, or its `macsw-team.json`; then its media.
    public func chooseTeamFolder(_ url: URL) async {
        guard !copyState.isActive else { return }
        hasSearched = true
        apply(TeamConfigLocator.examineChosen(url))
        if teamConfig != nil { await findMedia() }
    }

    /// Keeps the config for later starts and writes its defaults the member has not set.
    @discardableResult
    public func importTeamConfig() -> Bool {
        guard let teamConfig else { return false }
        do {
            try TeamConfigLocator.importConfig(teamConfig, paths: paths, defaults: defaults)
            return true
        } catch {
            teamConfigProblem = "The team config could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private func apply(_ outcome: TeamConfigLocator.Outcome) {
        switch outcome {
        case .found(let found):
            teamConfig = found
            teamConfigProblem = nil
            statusMessage = "Found the team config of \(found.config.team) \(found.source.phrase)."
        case .invalid(let file, let message):
            teamConfig = nil
            teamConfigProblem = "\(file.path): \(message)"
            statusMessage = message
        case .notFound:
            teamConfig = nil
            teamConfigProblem = nil
            statusMessage = "No team config found. Choose the team folder, or install without one."
        }
        media = nil
        mediaProblem = nil
        copyState = .idle
        teamVBAFolder = nil
    }

    // MARK: Media

    /// The local copy if it is finished, then the team folder, ~/Downloads and the mounted volumes.
    /// Downloads is opened (and its macOS prompt shown) only when the team media was not found.
    public func findMedia() async {
        guard !isSearchingMedia, !copyState.isActive else { return }
        isSearchingMedia = true
        defer { isSearchingMedia = false }
        statusMessage = "Looking for the SOLIDWORKS media…"
        mediaProblem = nil
        if let team = teamConfig {
            let copy = MediaCopyService.destination(release: team.config.solidWorks.release, paths: paths)
            let teamFolderReadable = await mayOpen(team.teamFolder)
            let (found, problem, vbaFolder) = await Task.detached(priority: .userInitiated) { () -> (DiscoveredMedia?, String?, URL?) in
                let vbaFolder = teamFolderReadable ? (try? team.config.vbaFolder(in: team.teamFolder)) ?? nil : nil
                if MediaCopyService.receipt(in: copy)?.manifestSHA256 == team.config.media.manifestSHA256 {
                    return (InstallationMediaResolver.discover(localCopy: copy, teamMedia: nil, downloads: nil, volumes: []), nil, vbaFolder)
                }
                guard teamFolderReadable else { return (nil, "macOS did not let MacSW open the team folder.", nil) }
                do {
                    let folder = try team.config.mediaFolder(in: team.teamFolder)
                    let found = InstallationMediaResolver.discover(teamMedia: folder, downloads: nil, volumes: [])
                    return (found, found == nil ? "The team media folder has no setup.exe or ISO." : nil, vbaFolder)
                } catch {
                    return (nil, error.localizedDescription, vbaFolder)
                }
            }.value
            mediaProblem = problem
            teamVBAFolder = vbaFolder
            if let found {
                use(found)
                return
            }
        }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let readableDownloads = await mayOpen(downloads) ? downloads : nil
        let volumes = volumesOverride
        let found = await Task.detached(priority: .userInitiated) {
            InstallationMediaResolver.discover(teamMedia: nil, downloads: readableDownloads,
                                               volumes: volumes ?? InstallationMediaResolver.mountedVolumes())
        }.value
        use(found)
    }

    /// An ISO, setup.exe or media folder that the member dropped or chose.
    public func useDroppedMedia(_ url: URL) async {
        guard url.isFileURL, !copyState.isActive else { return }
        let found = await Task.detached(priority: .userInitiated) { InstallationMediaResolver.dropped(url) }.value
        mediaProblem = found == nil
            ? "Install media not found: it must contain setup.exe or an .iso (directly or in a first-level subfolder of the chosen folder)."
            : nil
        use(found)
    }

    private func use(_ found: DiscoveredMedia?) {
        media = found
        if let found, found.source == .localCopy {
            copyState = .completed(found.root)
        } else if !copyState.isActive {
            copyState = .idle
        }
        statusMessage = mediaSummary ?? mediaProblem ?? "No SOLIDWORKS media found. Drop the ISO or the media folder here."
        advanceIfReady()
    }

    // MARK: Copy

    public func startCopy() {
        Task { await copyMedia() }
    }

    /// Copies the media to `AppPaths.media/<release>` and checks it against its manifest; returns
    /// when the copy has finished, failed or stopped.
    public func copyMedia() async {
        guard copyJob == nil, needsCopy, let media, let teamConfig else { return }
        let source = media.root
        let destination = MediaCopyService.destination(release: teamConfig.config.solidWorks.release, paths: paths)
        // Only the team folder's media must be the version the team config names.
        let expected = media.source == .teamFolder ? teamConfig.config.media.manifestSHA256 : nil
        copyState = .copying(MediaCopyService.Progress(completedBytes: 0, totalBytes: media.sizeBytes, completedFiles: 0,
                                                       totalFiles: 0, currentFile: nil))
        statusMessage = "Copying the media to this Mac. You can use your Mac meanwhile."
        let freeBytes = self.freeBytes
        let job = Task.detached(priority: .utility) { [weak self] in
            try MediaCopyService.copy(from: source, to: destination, expectedManifestSHA256: expected,
                                      freeBytes: freeBytes, progress: { progress in
                Task { @MainActor in self?.showProgress(progress) }
            })
        }
        copyJob = job
        defer { copyJob = nil }
        do {
            let result = try await job.value
            copyState = .completed(result.folder)
            statusMessage = "The media is on this Mac and matches its manifest (\(result.receipt.fileCount) files, \(PreflightService.bytes(result.receipt.totalBytes)))."
        } catch is CancellationError {
            copyState = .cancelled
            statusMessage = "The copy stopped. Start it again to go on where it stopped."
        } catch {
            copyState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    public func cancelCopy() {
        copyJob?.cancel()
    }

    private func showProgress(_ progress: MediaCopyService.Progress) {
        guard case .copying = copyState else { return }
        copyState = .copying(progress)
    }

    /// Settings "Remove installer copy": moves the copy of the team's release to the Trash.
    /// MSI repairs and add-ins then need the team folder again.
    public func removeMediaCopy() {
        guard !copyState.isActive, let teamConfig else { return }
        let folder = MediaCopyService.destination(release: teamConfig.config.solidWorks.release, paths: paths)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try MediaCopyService.trashCopy(folder, paths: paths)
            if media?.source == .localCopy { media = nil }
            copyState = .idle
            statusMessage = "The installer copy is in the Trash. Repairs now need the team folder."
        } catch {
            statusMessage = "The installer copy could not be moved to the Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Hand-off

    /// Gives the media to the install window; false when there is none yet. With a team config,
    /// also the team's language and the team options (`applyTeamOptions`).
    @discardableResult
    public func handOff(to bootstrap: BootstrapStore) -> Bool {
        guard let installMedia else { return false }
        bootstrap.selectMedia(installMedia)
        guard bootstrap.resolvedMedia != nil else { return false }
        if let code = teamConfig?.config.defaults.language { Self.apply(language: code, to: bootstrap) }
        applyTeamOptions(to: bootstrap)
        return true
    }

    /// With a team config: a silent install with the one access key, VBA only from the MSIs MacSW
    /// knows (also from `vba.path`), and no other serials or licence server unless the config
    /// shows those fields.
    private func applyTeamOptions(to bootstrap: BootstrapStore) {
        guard let config = teamConfig?.config else { return }
        bootstrap.silentInstall = true
        bootstrap.cleanInstall = false
        bootstrap.requiresKnownVBA = true
        bootstrap.teamVBAFolder = teamVBAFolder
        if !config.install.showOtherKeys {
            bootstrap.serialSimulation = ""
            bootstrap.serialMotion = ""
            bootstrap.serialMBD = ""
        }
        if !config.install.showLicenseServer { bootstrap.licenseMode = .unconfigured }
    }

    /// `defaults.language` ("en", "de", "zh-Hant"). A code MacSW does not know keeps the language
    /// that `selectMedia` chose from the Mac's own languages.
    private static func apply(language code: String, to bootstrap: BootstrapStore) {
        switch LanguageCatalog.match(for: code) {
        case .baseLanguage:
            bootstrap.selectedLanguage = nil
        case .directory(let name):
            if let language = bootstrap.availableLanguages.first(where: { $0.directoryName == name }) {
                bootstrap.selectedLanguage = language
            }
        case .unknown:
            break
        }
    }

    // MARK: This Mac

    /// MacSW's own folder, and the folder of the DMG it runs from and the folder above that
    /// (the team folder keeps the DMG in `releases/`).
    private func appFolders() async -> [URL] {
        if let appFoldersOverride { return appFoldersOverride }
        let app = MacSWBundle.url
        var folders = [app.deletingLastPathComponent()]
        if let image = await IsoService.shared.diskImage(containing: app) {
            let folder = image.deletingLastPathComponent()
            folders += [folder, folder.deletingLastPathComponent()]
        }
        return folders
    }

    /// The native app opens a protected folder first, so a macOS prompt appears while only native
    /// code waits (`FolderConsentService`). Folders outside the protected ones need no check.
    private func mayOpen(_ folder: URL) async -> Bool {
        if let mayOpenOverride { return await mayOpenOverride(folder) }
        guard let protected = FolderConsentService.protectedFolder(containing: folder, home: home) else { return true }
        let checks = await FolderConsentService.check([protected], onWaiting: { [weak self] folder in
            Task { @MainActor in self?.statusMessage = FolderConsentService.waitingMessage(for: folder) }
        })
        return checks.first?.access == .granted
    }
}
