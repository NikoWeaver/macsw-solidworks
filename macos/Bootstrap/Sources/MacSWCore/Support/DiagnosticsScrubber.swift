import Darwin
import Foundation
import SystemConfiguration

/// Removes private values from the text files of a diagnostics export (`DiagnosticsExport`) by
/// pattern. MacSW does not keep the serial after an install, so serials are found by their
/// shape, not by their value (sharing plan, C4):
///
/// | What | Rule | Replaced with |
/// |---|---|---|
/// | installer property lines | a line that names SERIALNUMBER or SERVERLIST | dropped |
/// | cloud folder names | the CloudStorage folders and the drive-letter keys MacSW knows, then any `CloudStorage/<provider>-<account>` | the provider |
/// | licence servers | `port@host` | `<server>` |
/// | e-mail addresses | the usual pattern | `<email>` |
/// | serial-shaped strings | six groups of four letters or digits, optional space or hyphen; GUIDs stay | `<serial>` |
/// | MAC addresses | six hex pairs; `02:00:00:00:00:00` (the macOS placeholder) stays | `<mac>` |
/// | home folders | `/Users/<name>`, `C:\users\<name>`, `Z:\Users\<name>` | `~`, `<user>` |
/// | host names | the Mac's host names, Wine's computer name of it, `ComputerName = …` | `<host>` |
/// | the user's names | the account name and full name as words, `LogonUser = …` | `<user>` |
///
/// The order matters: cloud folder names before e-mail ("GoogleDrive-me@example.com"), licence
/// servers before e-mail ("25734@license.example.com" is not an address), the full name before
/// the `USERNAME = …` property.
public struct DiagnosticsScrubber: Sendable {
    public struct Context: Equatable, Sendable {
        public var homePath: String
        public var userName: String
        public var fullName: String
        public var hostNames: [String]
        /// Folder names in ~/Library/CloudStorage ("OneDrive-Acme", "GoogleDrive-me@example.com").
        public var cloudFolderNames: [String]

        public init(homePath: String, userName: String, fullName: String, hostNames: [String], cloudFolderNames: [String]) {
            self.homePath = homePath
            self.userName = userName
            self.fullName = fullName
            self.hostNames = hostNames
            self.cloudFolderNames = cloudFolderNames
        }
    }

    public static let serial = "<serial>"
    public static let email = "<email>"
    public static let mac = "<mac>"
    public static let user = "<user>"
    public static let host = "<host>"
    public static let server = "<server>"
    static let propertyMarkers = ["SERIALNUMBER", "SERVERLIST"]
    static let macPlaceholder = "02:00:00:00:00:00"
    /// A GUID (8-4-4-4-12 hex digits), matched before the serial and kept: its last groups have the
    /// serial's shape ("0000-0000-0000-000000000000"). Captured, so the replacement can tell it apart.
    static let guidPattern = "([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})"
    /// Not inside a longer run of letters and digits. A hyphen next to it is no guard: "SN-<serial>",
    /// "<serial>-1".
    static let serialPattern = "(?<![0-9A-Za-z])[0-9A-Za-z]{4}(?:[ -]?[0-9A-Za-z]{4}){5}(?![0-9A-Za-z])"
    /// Shorter names would match ordinary words and numbers too often.
    static let minimumNameLength = 3

    public let context: Context

    public init(context: Context) {
        self.context = context
    }

    public func scrub(_ text: String) -> String {
        // components(separatedBy:) also splits CRLF ("\r\n" is one Character for split(separator:)).
        var result = text.components(separatedBy: "\n").filter { line in
            let upper = line.uppercased()
            return !Self.propertyMarkers.contains { upper.contains($0) }
        }.joined(separator: "\n")

        for name in context.cloudFolderNames.sorted(by: { $0.count > $1.count }) {
            let provider = DriveMapService.providerName(name)
            if provider != name { result = result.replacingOccurrences(of: name, with: provider, options: .caseInsensitive) }
        }
        result = Self.replace(#"(?i)(CloudStorage[/\\]+)([A-Za-z0-9]+)-[^/\\\s"'<>]+"#, in: result, template: "$1$2")
        result = Self.replace(#"(?<![A-Za-z0-9._%+-])[0-9]{1,5}@(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)"#,
                              in: result, with: Self.server)
        result = Self.replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, in: result, with: Self.email)
        // One expression for both: a GUID found first is consumed whole, so no serial match starts inside it.
        result = Self.replace("\(Self.guidPattern)|\(Self.serialPattern)", in: result) { found, match in
            match.range(at: 1).location != NSNotFound ? found : Self.serial
        }
        result = Self.replace(#"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])"#, in: result) { found, _ in
            found.lowercased().replacingOccurrences(of: "-", with: ":") == Self.macPlaceholder ? found : Self.mac
        }

        if !context.homePath.isEmpty, context.homePath != "/" {
            result = result.replacingOccurrences(of: context.homePath, with: "~")
        }
        // A path that starts at /Users, not "drive_c/users/<name>" (the user name rule below).
        result = Self.replace(#"(?<![A-Za-z0-9_.-])/Users/(?!Shared(?![^/\s"'<>]))[^/\s"'<>:]+"#, in: result, with: "~")
        result = Self.replace(#"(?i)([A-Z]:)(\\\\|\\|/)(users)\2(?!public(?![^\\/\s"'<>]))[^\\/\s"'<>]+"#,
                              in: result, template: "$1$2$3$2\(Self.user)")

        for name in hostNameForms { result = Self.replaceWord(name, in: result, with: Self.host) }
        result = Self.replace(#"(?i)(computername\s*[=:]\s*)[^\s,;"'<>]+"#, in: result, template: "$1\(Self.host)")
        // The full name first: "USERNAME = First Last" must not keep "Last".
        for name in [context.fullName, context.userName] where name.count >= Self.minimumNameLength {
            result = Self.replaceWord(name, in: result, with: Self.user)
        }
        result = Self.replace(#"(?i)\b(logonuser|username)(\s*[=:]\s*)[^\s,;"'<>]+"#, in: result, template: "$1$2\(Self.user)")
        return result
    }

    /// The host names as given, the first label of each, and the name Wine gives the computer
    /// (wineboot: the first label in upper case, at most 15 characters), longest first.
    var hostNameForms: [String] {
        var names = Set<String>()
        for raw in context.hostNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.split(separator: ".").first.map(String.init) ?? name
            // A computer name with spaces ("Fake's MacBook Pro") is not a host name: Wine never sees it.
            let wine = label.contains(" ") ? "" : String(label.uppercased().prefix(15))
            for candidate in [name, label, wine]
            where candidate.count >= Self.minimumNameLength && candidate.lowercased() != "localhost" {
                names.insert(candidate)
            }
        }
        return names.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        replace(pattern, in: text, template: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func replace(_ pattern: String, in text: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replace(_ pattern: String, in text: String, using transform: (String, NSTextCheckingResult) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        let result = NSMutableString(string: source)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            result.replaceCharacters(in: match.range, with: transform(source.substring(with: match.range), match))
        }
        return result as String
    }

    private static func replaceWord(_ word: String, in text: String, with replacement: String) -> String {
        let pattern = "(?i)(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_-])"
        return replace(pattern, in: text, with: replacement)
    }
}

public extension DiagnosticsScrubber {
    /// The values of this Mac and this user: names only, nothing is opened.
    static func live(paths: AppPaths, fileManager: FileManager = .default) -> DiagnosticsScrubber {
        let home = fileManager.homeDirectoryForCurrentUser
        var hosts: [String] = []
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 { hosts.append(String(cString: buffer)) }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { hosts.append(local) }
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? { hosts.append(computer) }
        let storage = DriveMapService.cloudStorage(home: home)
        var clouds = (try? fileManager.contentsOfDirectory(atPath: storage.path)) ?? []
        let letters = DriveMapService.loadLetters(from: paths.appSupportDirectory.appendingPathComponent(DriveMapService.lettersFileName))
        clouds += letters.keys.compactMap { $0.hasPrefix("cloud:") ? String($0.dropFirst("cloud:".count)) : nil }
        return DiagnosticsScrubber(context: Context(
            homePath: home.standardizedFileURL.path, userName: NSUserName(), fullName: NSFullUserName(),
            hostNames: hosts, cloudFolderNames: Array(Set(clouds)).sorted()))
    }
}
