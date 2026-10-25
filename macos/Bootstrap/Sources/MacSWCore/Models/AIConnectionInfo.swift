import Foundation

/// 随当前 App 生成的本机接入说明；只拼接路径和文字，不查询或启动任何进程。
public struct AIConnectionInfo: Sendable {
    public static let defaultEndpoint = "127.0.0.1:18495"

    public let app: URL
    public let cli: URL
    public let skillDirectory: URL
    public let skillEntry: URL
    public let usageGuide: URL
    public let pathHelper: URL
    public let paths: AppPaths
    public let endpoint: String

    public init(bundleURL: URL, paths: AppPaths, environment: [String: String] = [:]) {
        app = bundleURL.standardizedFileURL
        cli = app.appendingPathComponent("Contents/MacOS/sw-cli")
        let resources = app.appendingPathComponent("Contents/Resources/SWCLI", isDirectory: true)
        skillDirectory = resources.appendingPathComponent(
            "runtime/PythonNative/lib/python3.11/site-packages/swcli/skills/swcli",
            isDirectory: true
        )
        skillEntry = skillDirectory.appendingPathComponent("SKILL.md")
        usageGuide = skillDirectory.appendingPathComponent("references/usage.md")
        pathHelper = resources.appendingPathComponent("bin/swcli-path")
        self.paths = paths
        let configuredEndpoint = environment["SWCLI_ENDPOINT"] ?? ""
        endpoint = configuredEndpoint.isEmpty ? Self.defaultEndpoint : configuredEndpoint
    }

    public var discoveryCommands: [String] {
        let command = [
            "env",
            "MACSW_WINEPREFIX=\(Self.shellQuote(paths.bottle.path))",
            "SWCLI_ENDPOINT=\(Self.shellQuote(endpoint))",
            Self.shellQuote(cli.path)
        ].joined(separator: " ")
        return ["version --json", "daemon status --json", "capabilities --json"].map {
            "\(command) \($0)"
        }
    }

    public var text: String {
        """
        Operate SOLIDWORKS through the SWCLI built into the local MacSW.
        The paths and settings below do not mean the daemon or SOLIDWORKS is running; no check command was run when this was copied.

        MacSW App: \(app.path)
        SWCLI: \(cli.path)
        Full skill folder: \(skillDirectory.path)
        Skill entry: \(skillEntry.path)
        Usage guide: \(usageGuide.path)
        MacSW bottle: \(paths.bottle.path)
        Host directory of the bottle's C: drive: \(paths.bottle.appendingPathComponent("drive_c").path)
        Host path conversion tool: \(pathHelper.path)
        Log directory: \(paths.logs.path)
        Daemon endpoint: \(endpoint) (run state not probed)

        First read the SKILL.md and usage guide above in full. If the skill needs to be installed, install the whole skill folder (keeping references) using your agent's mechanism and the user's authorization; do not modify resources inside the App.

        Run the following check commands in a terminal, in order; reuse the bottle and endpoint settings from these commands in later operations:
        \(discoveryCommands.joined(separator: "\n"))

        Actual capabilities are defined by the current daemon's capabilities output; do not guess commands from newer online documentation.
        A reachable endpoint does not mean SOLIDWORKS is operable: continue with document or modeling operations only when host_connected=true, worker_alive=true, recovery_required=false and host is non-empty. Summarize only the status, errors and operation list from the check output; do not paste the full schema into the conversation.
        Document and modeling commands do not start the daemon implicitly. If it is not running or the host is disconnected, explain the situation first and preferably ask the user to click "Start SWCLI daemon" in the MacSW menu ("Recover SWCLI daemon" when disconnected), then rerun the checks above after "SWCLI ready" appears. With an existing SOLIDWORKS the menu attaches to it; otherwise it starts one hidden. The menu status does not replace the check commands.
        If the agent needs to start or recover the daemon, run lifecycle commands only with the user's explicit authorization; copying this connection info is not authorization to start, restart, stop or install the skill. For an existing instance, explicitly use --attach-existing and never force-quit the user's instance; a new host is hidden by default and --visible is used only when the user explicitly asks for it. When the host is disconnected but the daemon is still reachable, a plain daemon start may just return the existing service; recovery must explicitly use daemon restart.
        If a permission layer blocks a lifecycle command, the command has not run: stop retrying, ask the user to act through the MacSW menu or to confirm explicitly via the agent's approval mechanism, and do not switch to other commands to bypass approval.
        Use typed SWCLI commands and verify native geometry, dimensions and save results; do not treat screenshots or a successful command exit as verification. A failed operation may leave partial changes, so do not retry blindly.
        Convert file paths using the current bottle's actual mapping and do not assume Z: exists; saving, overwriting or closing existing documents must stay within the authorization of the user's task.
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
