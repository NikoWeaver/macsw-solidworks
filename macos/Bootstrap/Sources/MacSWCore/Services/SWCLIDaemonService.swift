import Foundation

public enum SWCLIDaemonState: Equatable, Sendable {
    case unknown, stopped, starting, ready
    case needsRecovery(String)
    case failed(String)

    public var isReady: Bool { self == .ready }
    public var title: String {
        switch self {
        case .unknown: return "SWCLI not checked"
        case .stopped: return "SWCLI stopped"
        case .starting: return "SWCLI starting"
        case .ready: return "SWCLI ready"
        case .needsRecovery: return "SWCLI needs recovery"
        case .failed: return "SWCLI error"
        }
    }
    public var reason: String? {
        switch self {
        case .needsRecovery(let reason), .failed(let reason): return reason
        default: return nil
        }
    }
}

/// Status uses the bundled native client, never the Windows lifecycle wrapper.
/// Only an explicit menu action invokes sw-cli daemon start/restart.
public struct SWCLIDaemonService: Sendable {
    public let bundleURL: URL
    public let paths: AppPaths
    public let endpoint: String

    public init(bundleURL: URL, paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.bundleURL = bundleURL
        self.paths = paths
        endpoint = AIConnectionInfo(bundleURL: bundleURL, paths: paths, environment: environment).endpoint
    }

    // The protocol client waits an additional transport grace period. Bound the
    // read-only RPC to two seconds, and omit the large operation schemas.
    static let probeScript = """
    import json, signal, sys
    from swcli.daemon.client import call_daemon
    def expired(*args):
        raise TimeoutError('SWCLI health probe timed out')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(2)
    try:
        response = call_daemon('daemon.health', endpoint=sys.argv[1], timeout_seconds=1, connect_timeout_seconds=0.5)
        if response.get('success'):
            health = response.get('result') or {}
            response = {'success': True, 'result': {key: health.get(key) for key in
                ('protocol_versions', 'worker_alive', 'host_connected', 'recovery_required', 'recovery_error', 'host')}}
    except Exception as error:
        response = {'success': False, 'error': {'code': type(error).__name__, 'message': str(error)}}
    finally:
        signal.alarm(0)
    print(json.dumps(response))
    """

    public func probe() async -> SWCLIDaemonState {
        do {
            try validateEndpoint()
            let process = Process()
            process.executableURL = bundleURL.appendingPathComponent("Contents/Resources/SWCLI/runtime/PythonNative/bin/python3")
            process.arguments = ["-c", Self.probeScript, endpoint]
            var environment = ProcessInfo.processInfo.environment
            // Native health checks must not acquire a Wine launch lock or write
            // bytecode into the signed App's resources.
            environment.removeValue(forKey: "WINEPREFIX")
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PYTHONPATH"] = bundleURL.appendingPathComponent("Contents/Resources/SWCLI/runtime/PythonNative/lib/python3.11/site-packages").path
            process.environment = environment
            let output = try await WineService.shared.capturePairCancellable(process)
            guard output.status == 0 else { return .failed(output.standardError) }
            return try Self.decodeHealth(Data(output.standardOutput.utf8))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func start(arguments: [String]) async throws {
        try validateEndpoint()
        let process = Process()
        process.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/sw-cli")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MACSW_WINEPREFIX"] = paths.bottle.path
        environment["SWCLI_ENDPOINT"] = endpoint
        environment.removeValue(forKey: "WINEPREFIX") // wrapper sets the exact active prefix
        process.environment = environment
        CoreInstallRetry.noteSolidWorksMayStart(prefix: paths.bottle)  // the daemon can start SOLIDWORKS through COM
        let output = try await WineService.shared.capturePairCancellable(process)
        try Self.validateStartResponse(status: output.status, standardOutput: output.standardOutput,
                                       standardError: output.standardError)
    }

    private func validateEndpoint() throws {
        let components = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2, ["127.0.0.1", "localhost"].contains(String(components[0])),
              let port = UInt16(components[1]), port > 0 else {
            throw MacSWError.make("The menu only manages loopback SWCLI endpoints on this Mac: \(endpoint)", domain: "MacSW.SWCLI")
        }
    }

    struct CommandResponse: Decodable {
        let success: Bool
        let error: Failure?
    }
    struct Failure: Decodable {
        let code: String
        let message: String
    }
    private struct HealthResponse: Decodable {
        let success: Bool
        let result: Health?
        let error: Failure?
    }
    private struct Health: Decodable {
        let protocol_versions: [String]
        let worker_alive: Bool
        let host_connected: Bool
        let recovery_required: Bool
        let recovery_error: Failure?
        let host: Host?
    }
    private struct Host: Decodable { let platform: String }

    static func validateStartResponse(status: Int32, standardOutput: String, standardError: String) throws {
        let response = try? JSONDecoder().decode(CommandResponse.self, from: Data(standardOutput.utf8))
        guard status == 0, response?.success == true else {
            let stderr = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = response?.error?.message ?? (stderr.isEmpty ? "SWCLI did not return a valid start-success response (exit code \(status))." : String(stderr.prefix(2000)))
            throw MacSWError.make(reason, domain: "MacSW.SWCLI")
        }
    }

    static func decodeHealth(_ data: Data) throws -> SWCLIDaemonState {
        let response = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard response.success, let health = response.result else {
            if response.error?.code == "ConnectionRefusedError" { return .stopped }
            return .failed(response.error?.message ?? "Invalid SWCLI status response.")
        }
        guard health.protocol_versions.contains("swcli/v1") else { return .failed("Incompatible SWCLI protocol version.") }
        if let host = health.host, host.platform != "macos-wine" {
            return .failed("The endpoint is not a MacSW Wine daemon; it was left unchanged.")
        }
        if health.recovery_required || !health.host_connected || !health.worker_alive || health.host == nil {
            return .needsRecovery(health.recovery_error?.message ?? "The SOLIDWORKS COM host is not ready; the daemon needs recovery.")
        }
        return .ready
    }

    /// No --visible: a new owned host is hidden. Strict attach never falls back
    /// to launching another host if the observed interactive instance disappears.
    static func startArguments(state: SWCLIDaemonState, solidWorksRunning: Bool) throws -> [String]? {
        let command: String
        switch state {
        case .ready: return nil
        case .stopped: command = "start"
        case .needsRecovery: command = "restart"
        default: throw MacSWError.make(state.reason ?? "Could not confirm the daemon state; nothing was started or restarted.", domain: "MacSW.SWCLI")
        }
        var arguments = ["daemon", command, "--startup-timeout", "600", "--json"]
        if solidWorksRunning { arguments.append("--attach-existing") }
        return arguments
    }
}
