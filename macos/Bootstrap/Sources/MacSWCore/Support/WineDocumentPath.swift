import Foundation

/// File types SOLIDWORKS can open from Finder, Dock drops and `open -a`.
/// Keep in sync with CFBundleDocumentTypes in resources/Info.plist.in.
public enum SolidWorksDocumentTypes {
    public static let nativeExtensions = ["sldprt", "sldasm", "slddrw", "prtdot", "asmdot", "drwdot"]
    public static let neutralExtensions = ["step", "stp", "iges", "igs", "x_t", "x_b", "stl", "dxf", "dwg"]
    public static let supportedExtensions = Set(nativeExtensions + neutralExtensions)

    public static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Keeps only existing regular files with a SOLIDWORKS-readable extension,
    /// preserving order and dropping duplicates.
    public static func openableFiles(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            guard isSupported(url),
                  fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return false }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}

/// One Wine drive letter and the macOS directory it points at.
public struct WineDrive: Equatable, Sendable {
    public let letter: Character
    public let root: String

    public init(letter: Character, root: String) {
        self.letter = Character(String(letter).uppercased())
        self.root = root
    }
}

/// A macOS folder that Wine links into the user profile, e.g. `<prefix>/drive_c/users/me/Documents` -> `~/Documents`.
public struct WineFolderLink: Equatable, Sendable {
    /// The macOS folder the link points at (symbolic links resolved).
    public let target: String
    /// The link itself inside the prefix (not resolved).
    public let linkPath: String

    public init(target: String, linkPath: String) {
        self.target = target
        self.linkPath = linkPath
    }
}

/// Converts macOS paths to Windows paths using a prefix's real drive mappings
/// (`<prefix>/dosdevices/<x>:` symlinks). Done offline so it needs no Wine process.
public enum WineDocumentPath {
    /// Wine's default: Z: is the whole Unix filesystem.
    public static let defaultDrives = [WineDrive(letter: "Z", root: "/")]

    public static func drives(in prefix: URL, fileManager: FileManager = .default) -> [WineDrive] {
        let dosdevices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dosdevices.path) else { return defaultDrives }
        var found: [WineDrive] = []
        for name in names.sorted() {
            // "c:" is a drive; "c::" is a raw device node.
            guard name.count == 2, name.hasSuffix(":"), let letter = name.first, letter.isLetter, letter.isASCII,
                  let target = try? fileManager.destinationOfSymbolicLink(atPath: dosdevices.appendingPathComponent(name).path)
            else { continue }
            let resolved = URL(fileURLWithPath: target, relativeTo: dosdevices)
                .standardizedFileURL.resolvingSymlinksInPath().path
            found.append(WineDrive(letter: letter, root: resolved))
        }
        return found.isEmpty ? defaultDrives : found
    }

    /// Longest matching drive root wins; ties go to the earlier drive letter.
    /// Returns nil only when no drive contains the path.
    public static func windowsPath(for url: URL, drives: [WineDrive]) -> String? {
        let candidates = [url.standardizedFileURL.path, url.standardizedFileURL.resolvingSymlinksInPath().path]
        for path in candidates {
            var best: (drive: WineDrive, rootLength: Int)?
            for drive in drives {
                guard let relative = relativePath(path, under: drive.root) else { continue }
                let length = path.count - relative.count
                if best == nil || length > best!.rootLength
                    || (length == best!.rootLength && drive.letter < best!.drive.letter) {
                    best = (drive, length)
                }
            }
            if let best, let relative = relativePath(path, under: best.drive.root) {
                let tail = relative.split(separator: "/").joined(separator: "\\")
                return "\(best.drive.letter):\\" + tail
            }
        }
        return nil
    }

    public static func windowsPath(for url: URL, prefix: URL, userName: String = NSUserName()) -> String? {
        windowsPath(for: url, drives: drives(in: prefix), folderLinks: folderLinks(in: prefix, userName: userName))
    }

    /// Like `windowsPath(for:drives:)`, but a file in a folder that Wine links into the user profile
    /// (`~/Documents` behind `drive_c/users/<user>/Documents`) gets the profile path
    /// `C:\users\<user>\Documents\...`. That is the path SOLIDWORKS uses for the same file when it is
    /// opened from its own dialogs or referenced by an assembly, so both name one document.
    public static func windowsPath(for url: URL, drives: [WineDrive], folderLinks: [WineFolderLink]) -> String? {
        linkedFolderPath(for: url, drives: drives, folderLinks: folderLinks) ?? windowsPath(for: url, drives: drives)
    }

    /// The `C:\users\<user>\<folder>\...` path of a file inside a linked folder, or nil if the file is
    /// in none of them.
    public static func linkedFolderPath(for url: URL, drives: [WineDrive], folderLinks: [WineFolderLink]) -> String? {
        let candidates = [url.standardizedFileURL.path, url.standardizedFileURL.resolvingSymlinksInPath().path]
        for path in candidates {
            var best: (link: WineFolderLink, relative: String)?
            for link in folderLinks {
                guard let relative = relativePath(path, under: link.target) else { continue }
                if best == nil || link.target.count > best!.link.target.count { best = (link, relative) }
            }
            if let best {
                let inPrefix = best.relative.isEmpty ? best.link.linkPath : best.link.linkPath + "/" + best.relative
                return windowsPath(for: URL(fileURLWithPath: inPrefix), drives: drives)
            }
        }
        return nil
    }

    /// The symbolic links in `<prefix>/drive_c/users/<userName>/` that point at macOS folders
    /// (Desktop, Documents, Downloads, Music, Pictures, Videos). Plain directories are not links.
    public static func folderLinks(in prefix: URL, userName: String = NSUserName(),
                                   fileManager: FileManager = .default) -> [WineFolderLink] {
        guard !userName.isEmpty, !userName.contains("/") else { return [] }
        let profile = prefix.appendingPathComponent("drive_c", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(userName, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: profile.path) else { return [] }
        var links: [WineFolderLink] = []
        for name in names.sorted() {
            let link = profile.appendingPathComponent(name)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else { continue }
            let target = link.resolvingSymlinksInPath().path
            var isDirectory: ObjCBool = false
            guard target != link.path, fileManager.fileExists(atPath: target, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            links.append(WineFolderLink(target: target, linkPath: link.path))
        }
        return links
    }

    /// Path below `root` without a leading slash ("" for the root itself), or nil if outside.
    private static func relativePath(_ path: String, under root: String) -> String? {
        if root == "/" { return String(path.drop(while: { $0 == "/" })) }
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == trimmedRoot { return "" }
        guard path.hasPrefix(trimmedRoot + "/") else { return nil }
        return String(path.dropFirst(trimmedRoot.count + 1))
    }
}
