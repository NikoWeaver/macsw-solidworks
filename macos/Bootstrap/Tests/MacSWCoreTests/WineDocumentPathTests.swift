import XCTest
@testable import MacSWCore

final class WineDocumentPathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wdp-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testDefaultZDriveMapsWholeFilesystem() {
        let drives = WineDocumentPath.defaultDrives
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Users/me/Part1.SLDPRT"), drives: drives),
                       #"Z:\Users\me\Part1.SLDPRT"#)
    }

    func testSpacesAndNonASCIIArePreserved() {
        let drives = WineDocumentPath.defaultDrives
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Users/me/My Parts/底盘 – café ü.sldasm"), drives: drives),
                       #"Z:\Users\me\My Parts\底盘 – café ü.sldasm"#)
        // Decomposed (NFD) names from HFS-style APIs are passed through untouched.
        let nfd = "re\u{0301}sume\u{0301}.sldprt"
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/tmp/\(nfd)"), drives: drives), #"Z:\tmp\"# + nfd)
    }

    func testLongestDriveRootWins() {
        let drives = [
            WineDrive(letter: "z", root: "/"),
            WineDrive(letter: "c", root: "/Users/me/bottle/drive_c"),
            WineDrive(letter: "d", root: "/Volumes/Data")
        ]
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Users/me/bottle/drive_c/Program Files/x.step"), drives: drives),
                       #"C:\Program Files\x.step"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Volumes/Data/cad/a.stp"), drives: drives),
                       #"D:\cad\a.stp"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Volumes/Data2/a.stp"), drives: drives),
                       #"Z:\Volumes\Data2\a.stp"#)
    }

    func testRootPrefixMustMatchWholeComponent() {
        let drives = [WineDrive(letter: "d", root: "/Volumes/Data")]
        XCTAssertNil(WineDocumentPath.windowsPath(for: url("/Volumes/DataExtra/a.stl"), drives: drives))
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Volumes/Data"), drives: drives), #"D:\"#)
    }

    func testDotDotIsNormalized() {
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/a/b/../c/p.sldprt"), drives: WineDocumentPath.defaultDrives),
                       #"Z:\a\c\p.sldprt"#)
    }

    func testDrivesDiscoveredFromDosdevices() throws {
        let prefix = root.appendingPathComponent("prefix")
        let dos = prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: dos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("z:").path, withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("c::").path, withDestinationPath: "/dev/disk1")

        let drives = WineDocumentPath.drives(in: prefix)
        XCTAssertEqual(drives.map { String($0.letter) }, ["C", "Z"])

        let file = prefix.appendingPathComponent("drive_c/users/me/My Part.sldprt")
        XCTAssertEqual(WineDocumentPath.windowsPath(for: file, prefix: prefix), #"C:\users\me\My Part.sldprt"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: url("/Users/me/x.dwg"), prefix: prefix), #"Z:\Users\me\x.dwg"#)
    }

    func testNoZDriveIsNotAssumedWhenPrefixDefinesDrives() throws {
        let prefix = root.appendingPathComponent("prefix2")
        let dos = prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: dos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        XCTAssertNil(WineDocumentPath.windowsPath(for: url("/Users/me/x.dwg"), prefix: prefix))
    }

    /// A prefix like a real bottle: C: and Z: drives, and the profile folders of user "me" linked to
    /// macOS folders under `home`.
    private func makeLinkedPrefix() throws -> (prefix: URL, home: URL) {
        let fm = FileManager.default
        let prefix = root.appendingPathComponent("bottle")
        let home = root.appendingPathComponent("home")
        let dos = prefix.appendingPathComponent("dosdevices")
        let profile = prefix.appendingPathComponent("drive_c/users/me")
        for dir in [dos, profile.appendingPathComponent("AppData"), prefix.appendingPathComponent("drive_c/users/Public"),
                    home.appendingPathComponent("Documents/My Parts"), home.appendingPathComponent("Movies"),
                    home.appendingPathComponent("Other")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: dos.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: dos.appendingPathComponent("z:").path, withDestinationPath: "/")
        try fm.createSymbolicLink(atPath: profile.appendingPathComponent("Documents").path,
                                  withDestinationPath: home.appendingPathComponent("Documents").path)
        // Wine names the link Videos; the macOS folder is Movies.
        try fm.createSymbolicLink(atPath: profile.appendingPathComponent("Videos").path,
                                  withDestinationPath: home.appendingPathComponent("Movies").path)
        // A link whose target does not exist is ignored.
        try fm.createSymbolicLink(atPath: profile.appendingPathComponent("Music").path,
                                  withDestinationPath: home.appendingPathComponent("Music").path)
        return (prefix, home)
    }

    func testFolderLinksAreTheProfileSymlinksOnly() throws {
        let (prefix, home) = try makeLinkedPrefix()
        let links = WineDocumentPath.folderLinks(in: prefix, userName: "me")
        XCTAssertEqual(links.map { URL(fileURLWithPath: $0.linkPath).lastPathComponent }, ["Documents", "Videos"])
        XCTAssertEqual(links.first?.target, home.appendingPathComponent("Documents").path)
        XCTAssertEqual(WineDocumentPath.folderLinks(in: prefix, userName: "someone-else"), [])
        XCTAssertEqual(WineDocumentPath.folderLinks(in: prefix, userName: "../me"), [])
    }

    func testFileInLinkedFolderGetsTheProfilePath() throws {
        let (prefix, home) = try makeLinkedPrefix()
        let part = home.appendingPathComponent("Documents/My Parts/Block Test 1.SLDPRT")
        XCTAssertEqual(WineDocumentPath.windowsPath(for: part, prefix: prefix, userName: "me"),
                       #"C:\users\me\Documents\My Parts\Block Test 1.SLDPRT"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: home.appendingPathComponent("Movies/clip.step"), prefix: prefix, userName: "me"),
                       #"C:\users\me\Videos\clip.step"#)
        // Outside the linked folders nothing changes: Z: for macOS paths, C: inside drive_c.
        let other = home.appendingPathComponent("Other/x.sldprt")
        XCTAssertEqual(WineDocumentPath.windowsPath(for: other, prefix: prefix, userName: "me"),
                       "Z:" + other.path.replacingOccurrences(of: "/", with: "\\"))
        XCTAssertEqual(WineDocumentPath.windowsPath(for: prefix.appendingPathComponent("drive_c/SWData/a.sldprt"), prefix: prefix, userName: "me"),
                       #"C:\SWData\a.sldprt"#)
        // Without the link (another user name) the file keeps its Z: path, as before.
        XCTAssertEqual(WineDocumentPath.windowsPath(for: part, prefix: prefix, userName: "someone-else"),
                       "Z:" + part.path.replacingOccurrences(of: "/", with: "\\"))
    }

    func testLinkedFolderPathIsNilOutsideLinkedFolders() throws {
        let (prefix, home) = try makeLinkedPrefix()
        let drives = WineDocumentPath.drives(in: prefix)
        let links = WineDocumentPath.folderLinks(in: prefix, userName: "me")
        XCTAssertNil(WineDocumentPath.linkedFolderPath(for: home.appendingPathComponent("Other/x.sldprt"), drives: drives, folderLinks: links))
        // The folder name must match a whole component: "Documents2" is not inside "Documents".
        XCTAssertNil(WineDocumentPath.linkedFolderPath(for: home.appendingPathComponent("Documents2/x.sldprt"), drives: drives, folderLinks: links))
        XCTAssertEqual(WineDocumentPath.linkedFolderPath(for: home.appendingPathComponent("Documents/x.sldprt"), drives: drives, folderLinks: links),
                       #"C:\users\me\Documents\x.sldprt"#)
    }

    /// After `DriveMapService` (H: home, B: Box, I: iCloud Drive, Y:/X: other cloud folders, and the
    /// cloud folders linked into the profile): a linked profile folder keeps its C:\users\<user>\...
    /// path first (Documents, and Box/iCloud Drive through their profile links, where Box Drive and
    /// iCloud for Windows keep them on a PC); a drive letter names only files outside those links.
    func testPathsAfterDriveMaps() throws {
        let (prefix, home) = try makeLinkedPrefix()
        let fm = FileManager.default
        for dir in ["Library/CloudStorage/Box-Box/Project", "Library/CloudStorage/OneDrive-Personal/Team",
                    "Library/Mobile Documents/com~apple~CloudDocs/CAD"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        var letters: [String: String] = [:]
        _ = DriveMapService.apply(DriveMapService.folders(home: home), prefix: prefix, userName: "me", letters: &letters)
        XCTAssertEqual(letters["cloud:OneDrive-Personal"], "Y")

        let box = home.appendingPathComponent("Library/CloudStorage/Box-Box/Project/Bracket.SLDPRT")
        let oneDrive = home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal/Team/a.sldasm")
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/CAD/b.step")
        let document = home.appendingPathComponent("Documents/My Parts/p.sldprt")
        let other = home.appendingPathComponent("Other/x.sldprt")
        func path(_ url: URL, _ user: String = "me") -> String? { WineDocumentPath.windowsPath(for: url, prefix: prefix, userName: user) }

        XCTAssertEqual(path(document), #"C:\users\me\Documents\My Parts\p.sldprt"#)
        XCTAssertEqual(path(box), #"C:\users\me\Box\Project\Bracket.SLDPRT"#)
        XCTAssertEqual(path(oneDrive), #"C:\users\me\OneDrive\Team\a.sldasm"#)
        XCTAssertEqual(path(iCloud), #"C:\users\me\iCloud Drive\CAD\b.step"#)
        XCTAssertEqual(path(other), #"H:\Other\x.sldprt"#, "H: (home) is longer than Z: (/)")
        // Without the profile links (another user's view) the drive letters name the cloud files.
        XCTAssertEqual(path(box, "someone-else"), #"B:\Project\Bracket.SLDPRT"#)
        XCTAssertEqual(path(oneDrive, "someone-else"), #"Y:\Team\a.sldasm"#)
        XCTAssertEqual(path(iCloud, "someone-else"), #"I:\CAD\b.step"#)
        XCTAssertEqual(path(document, "someone-else"), #"H:\Documents\My Parts\p.sldprt"#)

        // The running instance gets the same profile path; other files go through `start /unix`,
        // where Wine picks the deepest drive root (H:) just like `windowsPath`.
        XCTAssertEqual(DocumentHandOff.startArguments(for: [box, other], prefix: prefix, userName: "me"), [
            ["start", #"C:\users\me\Box\Project\Bracket.SLDPRT"#],
            ["start", "/unix", other.path]
        ])
    }

    /// The real layout: the bottle lives in ~/Library/Application Support/MacSW, inside H:.
    /// C: (the longer root) still names everything in drive_c, including the profile links.
    func testBottleInsideHomeKeepsCPaths() throws {
        let fm = FileManager.default
        let home = root.appendingPathComponent("realhome")
        let prefix = home.appendingPathComponent("Library/Application Support/MacSW/bottle")
        for dir in ["dosdevices", "drive_c/users/me", "drive_c/SWData"] {
            try fm.createDirectory(at: prefix.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/Box-Box/Project"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        var letters: [String: String] = [:]
        _ = DriveMapService.apply(DriveMapService.folders(home: home), prefix: prefix, userName: "me", letters: &letters)

        XCTAssertEqual(WineDocumentPath.windowsPath(for: home.appendingPathComponent("Library/CloudStorage/Box-Box/Project/a.sldprt"),
                                                    prefix: prefix, userName: "me"), #"C:\users\me\Box\Project\a.sldprt"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: prefix.appendingPathComponent("drive_c/SWData/b.sldprt"), prefix: prefix, userName: "me"),
                       #"C:\SWData\b.sldprt"#)
        XCTAssertEqual(WineDocumentPath.windowsPath(for: home.appendingPathComponent("Projects/c.sldprt"), prefix: prefix, userName: "me"),
                       #"H:\Projects\c.sldprt"#)
    }

    func testMissingDosdevicesFallsBackToZ() {
        let prefix = root.appendingPathComponent("none")
        XCTAssertEqual(WineDocumentPath.drives(in: prefix), WineDocumentPath.defaultDrives)
    }

    func testDocumentTypeFiltering() throws {
        let part = root.appendingPathComponent("A B.SLDPRT")
        let step = root.appendingPathComponent("ü.stp")
        let text = root.appendingPathComponent("notes.txt")
        let dir = root.appendingPathComponent("folder.sldasm")
        for f in [part, step, text] { FileManager.default.createFile(atPath: f.path, contents: Data()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let result = SolidWorksDocumentTypes.openableFiles([part, text, step, dir, part, root.appendingPathComponent("missing.sldprt")])
        XCTAssertEqual(result, [part, step])
        XCTAssertFalse(SolidWorksDocumentTypes.isSupported(URL(string: "https://example.com/a.sldprt")!))
        for ext in ["x_t", "x_b", "IGES", "igs", "dwg", "dxf", "stl", "prtdot", "asmdot", "drwdot"] {
            XCTAssertTrue(SolidWorksDocumentTypes.isSupported(url("/tmp/f.\(ext)")), ext)
        }
    }
}
