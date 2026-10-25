import Foundation

/// Microsoft VBA 7.1, the SOLIDWORKS prerequisite for equations, global variables and macros.
/// Without it SOLIDWORKS starts without a message, but every new or changed equation fails with
/// "The syntax of this equation is incorrect" and no equation drives a dimension.
///
/// It is optional for the install, like Toolbox: the official media keeps it in `PreReqs\VBA`
/// (sldim.xml: `vba71.msi` and `vba71_1033.msi`), but downloaded media often lacks the folder.
public enum VBAPrerequisite {
    /// The APC (VBA host) class SOLIDWORKS creates at startup (`HKCR\CLSID`, 64-bit view).
    public static let apcCLSID = "{CFE9F29B-E1B6-4240-AED7-360846769314}"
    /// Default value of the class's InprocServer32 key, written by vba71.msi.
    public static let apcLibrary = "apc71.dll"
    /// Where vba71.msi puts the APC library (MSI Directory table: CommonFiles64Folder).
    public static let apcDestination = "drive_c/Program Files/Common Files/Microsoft Shared/VBA/VBA7.1/apc71.dll"
    /// Installed in this order: vba71_1033.msi is the English resource pack of vba71.msi.
    public static let installerNames = ["vba71.msi", "vba71_1033.msi"]
    /// Media folders searched for both MSIs, in this order. `PreReqs/VBA` is the official layout.
    public static let mediaDirectories = ["PreReqs/VBA", "PreReqs/Microsoft_VBA", "VBA"]

    /// SHA-256 of the two MSIs the team install accepts, by lowercase name: the Microsoft-signed
    /// VBA 7.1.11.28 that the team admin adds to the media's `PreReqs/VBA` (docs/vba-equations.md,
    /// section 1). Every editor of the team folder can change its files, so the trust anchor is in
    /// the app. Other media can carry another VBA build (the 2026 sldim.xml names 7.1.11.35): the
    /// install without a team config and Settings → Install VBA do not check, and a new build for
    /// the team needs its values here.
    public static let knownSHA256 = [
        "vba71.msi": "08069ec9dfa56d1cdac335ec297451573e1ca8742ecbb358e20ae5be6e9feeee",
        "vba71_1033.msi": "7029661494d24a8b0cba0a176ceab0c18fa02c004288672f21c1f0cfc7a07955"
    ]

    public static let missingWarning = "Microsoft VBA 7.1 is not installed in the bottle: SOLIDWORKS equations and macros will not work."
    public static let repairHint = "Add vba71.msi and vba71_1033.msi in Settings → Maintenance → Install VBA (equations and macros)."
    /// Install summary line when neither the media nor the folder chosen in Settings has the MSIs.
    public static let skippedNote = "Not installed: neither the media (PreReqs/VBA) nor the folder saved in Settings has vba71.msi and vba71_1033.msi, so SOLIDWORKS equations and macros will not work. " + repairHint

    /// Both MSIs directly in `folder`, in install order; nil unless both are non-empty files.
    /// Names are compared without case: an ISO mount can be case-sensitive.
    public static func installers(inFolder folder: URL, fileManager: FileManager = .default) -> [URL]? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var found: [URL] = []
        for name in installerNames {
            guard let match = entries.first(where: { url in
                guard url.lastPathComponent.lowercased() == name,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { return false }
                return (values.fileSize ?? 0) > 0
            }) else { return nil }
            found.append(match)
        }
        return found
    }

    /// The media's VBA folders first (they match the SOLIDWORKS version being installed), then
    /// the team config's `vba.path`, then the folder last chosen in Settings
    /// (`AppPreferences.vbaInstallerFolder`).
    public static func installers(media: URL, teamFolder: URL? = nil, userFolder: URL?,
                                  fileManager: FileManager = .default) -> [URL]? {
        for relative in mediaDirectories {
            if let directory = directory(relative, in: media, fileManager: fileManager),
               let found = installers(inFolder: directory, fileManager: fileManager) {
                return found
            }
        }
        return [teamFolder, userFolder].lazy
            .compactMap { $0.flatMap { installers(inFolder: $0, fileManager: fileManager) } }
            .first
    }

    /// Throws, naming the file, when an installer is not one of the `known` MSIs. Reads every
    /// file in full, so call it off the main thread.
    public static func checkKnownHashes(_ installers: [URL], known: [String: String] = knownSHA256) throws {
        for installer in installers {
            let name = installer.lastPathComponent.lowercased()
            guard let expected = known[name] else {
                throw MacSWError.make("MacSW knows no SHA-256 for \(name).", domain: "MacSW.VBA")
            }
            let actual = try MediaManifest.sha256(of: installer)
            guard actual == expected else {
                throw MacSWError.make(
                    "\(name) is not the Microsoft file MacSW knows (SHA-256 \(actual.prefix(12))…, expected \(expected.prefix(12))…). Tell the team admin.",
                    domain: "MacSW.VBA"
                )
            }
        }
    }

    /// `relativePath` below `root`, matching every folder name without case.
    static func directory(_ relativePath: String, in root: URL, fileManager: FileManager) -> URL? {
        var current = root
        for component in relativePath.split(separator: "/") {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ), let next = entries.first(where: {
                $0.lastPathComponent.lowercased() == component.lowercased()
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }) else { return nil }
            current = next
        }
        return current
    }

    /// Reads the bottle's registry files without starting Wine (the app launch path starts no Wine
    /// process). wineserver writes them at most 30 s after a change and when it exits, so this is
    /// for the state before an install, not for checking one that just ran: use `reg query` for that.
    public static func isRegistered(prefix: URL) -> Bool {
        ["system.reg", "user.reg"].contains { hive in
            guard let data = try? Data(contentsOf: prefix.appendingPathComponent(hive)),
                  let text = PlainTextDecoder.decode(data) else { return false }
            return isRegistered(inHive: text)
        }
    }

    /// True when a Wine registry file has `Software\Classes\CLSID\{APC}\InprocServer32` with a
    /// default value. The 32-bit view (`Wow6432Node`) does not count: SLDWORKS.exe is 64-bit.
    static func isRegistered(inHive text: String) -> Bool {
        let header = #"[software\\classes\\clsid\\"# + apcCLSID.lowercased() + #"\\inprocserver32]"#
        var inSection = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.lowercased().hasPrefix(header)
            } else if inSection, trimmed.hasPrefix("@="), trimmed.count > #"@="""#.count {
                return true
            }
        }
        return false
    }
}
