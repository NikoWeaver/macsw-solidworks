import Darwin
import Foundation

/// `MacSW --headless-install`: drives the same BootstrapStore pipeline as the install window,
/// without any UI. The serial is read from a private file and only reaches the MSI property
/// the window would pass; it is never printed or logged.
public struct HeadlessInstallOptions: Equatable, Sendable {
    public static let flag = "--headless-install"

    public static let usage = """
    Usage: MacSW --headless-install --media <dir|iso|setup.exe> --serial-file <path>
                 [--license standalone | --license-server <port@host>]
                 [--windows-version win10|win11] [--language <name>]
                 [--addlocal <feature,feature,...>] [--locale en_US.UTF-8|zh_CN.UTF-8]
                 [--log <file>]
    The serial file must be a regular file owned by you with mode 0600 or stricter.
    """

    public enum License: Equatable, Sendable {
        case standalone
        case server(String)
    }

    public var media: URL
    public var serialFile: URL
    public var license: License = .standalone
    public var windowsVersion: WindowsVersion?
    public var language: String?
    public var addLocal: [String]?
    public var locale: String = AppPreferences.wineLocaleDefault
    public var log: URL?

    public static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// `arguments` is the full argv; argv[0] is ignored. Errors never echo option values
    /// other than the ones the user typed on the command line.
    public static func parse(_ arguments: [String]) throws -> HeadlessInstallOptions {
        var media: URL?
        var serialFile: URL?
        var license: License?
        var windowsVersion: WindowsVersion?
        var language: String?
        var addLocal: [String]?
        var locale: String?
        var log: URL?
        var seen = Set<String>()
        var iterator = arguments.dropFirst().makeIterator()

        func value(for option: String) throws -> String {
            guard let next = iterator.next(), !next.hasPrefix("--"), !next.isEmpty else {
                throw HeadlessInstallError.usage("\(option) needs a value.")
            }
            return next
        }

        while let argument = iterator.next() {
            // Launch Services may add a -psn_ argument when the binary is started from Finder.
            if argument.hasPrefix("-psn_") { continue }
            guard seen.insert(argument).inserted else {
                throw HeadlessInstallError.usage("\(argument) was given more than once.")
            }
            switch argument {
            case flag:
                continue
            case "--media":
                media = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            case "--serial-file":
                serialFile = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            case "--license":
                let mode = try value(for: argument)
                guard mode == "standalone" else {
                    throw HeadlessInstallError.usage("--license only accepts \"standalone\"; use --license-server <port@host> for a SolidNetWork server.")
                }
                guard license == nil else { throw HeadlessInstallError.usage("Use either --license or --license-server, not both.") }
                license = .standalone
            case "--license-server":
                let address = try value(for: argument).trimmingCharacters(in: .whitespacesAndNewlines)
                guard license == nil else { throw HeadlessInstallError.usage("Use either --license or --license-server, not both.") }
                guard (try? LicenseServerAddressService.parse(address)) != nil else {
                    throw HeadlessInstallError.usage("The license server address format must be \"port@host\"; separate multiple addresses with semicolons.")
                }
                license = .server(address)
            case "--windows-version":
                let raw = try value(for: argument)
                guard let version = WindowsVersion(rawValue: raw.lowercased()) else {
                    throw HeadlessInstallError.usage("--windows-version must be win10 or win11.")
                }
                windowsVersion = version
            case "--language":
                language = try value(for: argument)
            case "--addlocal":
                addLocal = try parseFeatureList(try value(for: argument))
            case "--locale":
                let raw = try value(for: argument)
                guard AppPreferences.supportedWineLocales.contains(raw) else {
                    throw HeadlessInstallError.usage("--locale must be one of: \(AppPreferences.supportedWineLocales.joined(separator: ", ")).")
                }
                locale = raw
            case "--log":
                log = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
            default:
                throw HeadlessInstallError.usage("Unknown option \(argument).")
            }
        }
        guard let media else { throw HeadlessInstallError.usage("--media is required.") }
        guard let serialFile else { throw HeadlessInstallError.usage("--serial-file is required.") }
        var options = HeadlessInstallOptions(media: media, serialFile: serialFile)
        options.license = license ?? .standalone
        options.windowsVersion = windowsVersion
        options.language = language
        options.addLocal = addLocal
        options.locale = locale ?? AppPreferences.wineLocaleDefault
        options.log = log
        return options
    }

    /// MSI feature names are identifiers; anything else would change the msiexec command line.
    static func parseFeatureList(_ raw: String) throws -> [String] {
        let features = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_."))
        guard !features.isEmpty, features.allSatisfy({ feature in
            !feature.isEmpty && feature.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }) else {
            throw HeadlessInstallError.usage("--addlocal must be a comma-separated list of MSI feature names.")
        }
        return features
    }

    /// `english` (the media's base language) means no extra language pack.
    public static func resolveLanguage(_ name: String) throws -> SolidWorksLanguage? {
        if name.caseInsensitiveCompare("english") == .orderedSame { return nil }
        if let match = LanguageCatalog.official.first(where: {
            $0.directoryName.caseInsensitiveCompare(name) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return match
        }
        let names = (["english"] + LanguageCatalog.official.map(\.directoryName)).joined(separator: ", ")
        throw HeadlessInstallError.usage("Unknown language \"\(name)\". Use one of: \(names).")
    }
}

public enum HeadlessInstallError: Error, Equatable, LocalizedError {
    case usage(String)
    case serialFile(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let message), .serialFile(let message): return message
        }
    }
}

public enum HeadlessSerialFile {
    static let maximumBytes = 4096

    /// Reads the SOLIDWORKS serial from a regular file (no symlink) owned by the current user
    /// with no group/other access and no execute bit. Messages name the path, never the content.
    public static func read(_ url: URL) throws -> String {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw HeadlessInstallError.serialFile("Cannot read the serial file \(path): \(String(cString: strerror(errno))).")
        }
        try check(info, path: path)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HeadlessInstallError.serialFile("Cannot open the serial file \(path): \(String(cString: strerror(errno))).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // Check the opened file again so a swap between lstat and open cannot slip through.
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw HeadlessInstallError.serialFile("The serial file \(path) changed while it was being opened.")
        }
        try check(opened, path: path)
        let data = (try? handle.read(upToCount: maximumBytes + 1)) ?? Data()
        guard data.count <= maximumBytes else {
            throw HeadlessInstallError.serialFile("The serial file \(path) is too large to be a serial number file.")
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let serials = InstallSerials(values: [.solidWorks: text])
        guard serials.isComplete, serials.invalidFields().isEmpty else {
            throw HeadlessInstallError.serialFile("The serial file \(path) must contain one SOLIDWORKS serial number: six groups of four characters.")
        }
        return serials.normalized(.solidWorks)
    }

    static func check(_ info: stat, path: String) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw HeadlessInstallError.serialFile("The serial file \(path) must be a regular file (not a link, folder or device).")
        }
        guard info.st_uid == getuid() else {
            throw HeadlessInstallError.serialFile("The serial file \(path) must be owned by the current user.")
        }
        guard (info.st_mode & 0o177) == 0 else {
            let mode = String(info.st_mode & 0o777, radix: 8)
            throw HeadlessInstallError.serialFile("The serial file \(path) has mode \(mode); run chmod 600 on it first (0600 or stricter).")
        }
    }
}

/// Every line the headless installer prints or logs goes through this.
public struct HeadlessRedactor: Sendable {
    public static let placeholder = "<redacted>"
    private let secrets: [String]

    public init(serial: String?) {
        guard let serial, !serial.isEmpty else { secrets = []; return }
        let normalized = InstallSerials.normalized(serial)
        var forms = [serial, normalized]
        if normalized.count == InstallSerials.expectedLength {
            let groups = stride(from: 0, to: normalized.count, by: InstallSerials.groupLength).map { start -> String in
                let begin = normalized.index(normalized.startIndex, offsetBy: start)
                return String(normalized[begin..<normalized.index(begin, offsetBy: InstallSerials.groupLength)])
            }
            forms += [groups.joined(separator: "-"), groups.joined(separator: " ")]
        }
        secrets = Array(Set(forms.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
    }

    public func scrub(_ text: String) -> String {
        var result = text
        // MSI property dumps look like `SOLIDWORKSSERIALNUMBER=…` or `Property(S): SERVERLIST = …`.
        for pattern in [#"([A-Za-z_]*SERIALNUMBER)\s*[=:]\s*[^\s,;]+"#, #"([A-Za-z_]*SERVERLIST)\s*[=:]\s*[^\s,;]+"#] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1=\(Self.placeholder)",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: Self.placeholder, options: .caseInsensitive)
        }
        return result
    }
}

/// Configures a BootstrapStore from the options, runs the pipeline and reports one line per step change.
@MainActor
public enum HeadlessInstaller {
    public static func run(
        arguments: [String],
        paths: AppPaths,
        output: @escaping (String) -> Void
    ) async -> Int32 {
        let options: HeadlessInstallOptions
        do {
            options = try HeadlessInstallOptions.parse(arguments)
        } catch {
            output("error: \(error.localizedDescription)")
            output(HeadlessInstallOptions.usage)
            return 64
        }
        let serial: String
        do {
            serial = try HeadlessSerialFile.read(options.serialFile)
        } catch {
            output("error: \(error.localizedDescription)")
            return 66
        }
        let redactor = HeadlessRedactor(serial: serial)
        let logURL = options.log ?? paths.logs.appendingPathComponent("headless-install.log")
        let log = try? openLog(logURL)
        defer { try? log?.close() }
        let emit: (String) -> Void = { line in
            let clean = redactor.scrub(line)
            output(clean)
            let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(clean)\n"
            try? log?.write(contentsOf: Data(stamped.utf8))
        }
        return await run(options: options, serial: serial, paths: paths, emit: emit)
    }

    static func run(
        options: HeadlessInstallOptions,
        serial: String,
        paths: AppPaths,
        emit: @escaping (String) -> Void
    ) async -> Int32 {
        let language: SolidWorksLanguage?
        do {
            language = try options.language.map(HeadlessInstallOptions.resolveLanguage) ?? nil
        } catch {
            emit("error: \(error.localizedDescription)")
            return 64
        }

        // Process-local override: the saved Settings value is not changed. The environment variable
        // reaches Python/shell launchers started by this process.
        UserDefaults.standard.setVolatileDomain([AppPreferences.wineLocaleKey: options.locale],
                                                forName: UserDefaults.argumentDomain)
        setenv("MACSW_WINE_LOCALE", options.locale, 1)

        let store = BootstrapStore(paths: paths)
        store.selectMedia(options.media)
        guard store.resolvedMedia != nil else {
            emit("error: \(store.statusMessage)")
            return 66
        }
        if options.language != nil { store.selectedLanguage = language }
        store.silentInstall = true
        store.cleanInstall = false
        store.windowsVersion = options.windowsVersion
        store.serialSolidWorks = serial
        switch options.license {
        case .standalone:
            store.licenseMode = .unconfigured
        case .server(let address):
            store.licenseMode = .remoteServer
            store.licenseServerAddress = address
        }
        store.addLocalOverride = options.addLocal
        store.hardenForHeadless = true
        if store.replacesFailedBottle { emit(CoreInstallRetry.freshBottleNote) }

        let steps = InstallationStep.allCases.count
        store.progressHandler = { step, status, detail in
            emit("[\(step.rawValue)/\(steps)] \(step.title): \(status.rawValue) - \(detail)")
        }
        emit("MacSW headless install: media \(options.media.path), language \(store.selectedLanguage?.directoryName ?? "english"), Windows version \(options.windowsVersion?.rawValue ?? "Wine default"), license \(options.license == .standalone ? "standalone" : "server").")

        guard let finalState = await store.runUntilFinished() else {
            emit("error: \(store.startHint ?? store.statusMessage)")
            return 64
        }
        switch finalState {
        case .completed:
            emit("Installation succeeded: post-install checks passed.")
            return 0
        case .cancelled:
            emit("error: \(store.statusMessage)")
            return 130
        default:
            emit("error: \(store.statusMessage)")
            return 1
        }
    }

    private static func openLog(_ url: URL) throws -> FileHandle {
        try LogFiles.prepare(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
