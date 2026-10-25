import Foundation
import XCTest
@testable import MacSWCore

final class SWCLIDaemonServiceTests: XCTestCase {
    private func health(connected: Bool = true, worker: Bool = true, recovery: Bool = false,
                        host: String = #"{"platform":"macos-wine"}"#,
                        protocols: String = #"["swcli/v1"]"#) -> Data {
        Data("""
        {"success":true,"result":{"protocol_versions":\(protocols),"host_connected":\(connected),
        "worker_alive":\(worker),"recovery_required":\(recovery),"host":\(host),
        "recovery_error":\(recovery ? #"{"code":"HostDisconnected","message":"COM host disconnected"}"# : "null")}}
        """.utf8)
    }

    func testReadyRequiresConnectedWorkerAndHost() throws {
        XCTAssertEqual(try SWCLIDaemonService.decodeHealth(health()), .ready)
        for payload in [health(connected: false), health(worker: false), health(recovery: true), health(host: "null")] {
            guard case .needsRecovery = try SWCLIDaemonService.decodeHealth(payload) else {
                return XCTFail("An open endpoint alone must not mean ready")
            }
        }
    }

    func testDisconnectedHostPreservesReasonAndSelectsRestart() throws {
        let state = try SWCLIDaemonService.decodeHealth(health(connected: false, worker: false, recovery: true, host: "null"))
        XCTAssertEqual(state, .needsRecovery("COM host disconnected"))
        let arguments = try XCTUnwrap(SWCLIDaemonService.startArguments(state: state, solidWorksRunning: true))
        XCTAssertEqual(arguments, ["daemon", "restart", "--startup-timeout", "600", "--json", "--attach-existing"])
        XCTAssertFalse(arguments.contains("--visible"))
    }

    func testColdStartIsHiddenAndExistingHostIsStrictlyAttached() throws {
        let cold = try XCTUnwrap(SWCLIDaemonService.startArguments(state: .stopped, solidWorksRunning: false))
        XCTAssertEqual(cold, ["daemon", "start", "--startup-timeout", "600", "--json"])
        let shared = try XCTUnwrap(SWCLIDaemonService.startArguments(state: .stopped, solidWorksRunning: true))
        XCTAssertTrue(shared.contains("--attach-existing"))
        XCTAssertFalse(shared.contains("--visible"))
        XCTAssertNil(try SWCLIDaemonService.startArguments(state: .ready, solidWorksRunning: false))
    }

    func testRefusedConnectionIsStoppedButTimeoutIsNot() throws {
        let refused = Data(#"{"success":false,"error":{"code":"ConnectionRefusedError","message":"refused"}}"#.utf8)
        XCTAssertEqual(try SWCLIDaemonService.decodeHealth(refused), .stopped)
        let timeout = Data(#"{"success":false,"error":{"code":"TimeoutError","message":"timed out"}}"#.utf8)
        let state = try SWCLIDaemonService.decodeHealth(timeout)
        XCTAssertEqual(state, .failed("timed out"))
        XCTAssertThrowsError(try SWCLIDaemonService.startArguments(state: state, solidWorksRunning: false))
    }

    func testForeignProtocolAndPlatformAreNotRestarted() throws {
        for payload in [health(protocols: #"["other/v1"]"#), health(host: #"{"platform":"windows"}"#)] {
            let state = try SWCLIDaemonService.decodeHealth(payload)
            guard case .failed = state else { return XCTFail("Foreign daemon must be rejected") }
            XCTAssertThrowsError(try SWCLIDaemonService.startArguments(state: state, solidWorksRunning: true))
        }
        XCTAssertThrowsError(try SWCLIDaemonService.decodeHealth(Data(#"{"success":true,"result":{}}"#.utf8)))
    }

    func testStatusProbeOnlyUsesReadOnlyNativeHealth() {
        XCTAssertTrue(SWCLIDaemonService.probeScript.contains("call_daemon('daemon.health'"))
        XCTAssertTrue(SWCLIDaemonService.probeScript.contains("signal.alarm(2)"))
        XCTAssertFalse(SWCLIDaemonService.probeScript.contains("subprocess"))
        XCTAssertFalse(SWCLIDaemonService.probeScript.contains("daemon.start"))
        XCTAssertFalse(SWCLIDaemonService.probeScript.contains("daemon.shutdown"))
    }

    func testWrapperPreflightFailureRetainsReadableDiagnostic() throws {
        XCTAssertThrowsError(try SWCLIDaemonService.validateStartResponse(status: 1, standardOutput: "", standardError: "backend synchronization failed\n")) {
            XCTAssertEqual($0.localizedDescription, "backend synchronization failed")
        }
        XCTAssertThrowsError(try SWCLIDaemonService.validateStartResponse(status: 0, standardOutput: "not JSON", standardError: ""))
        try SWCLIDaemonService.validateStartResponse(status: 0, standardOutput: #"{"success":true}"#, standardError: "")
    }
}

@MainActor
final class SWCLIDaemonStoreTests: XCTestCase {
    private actor Backend {
        var state: SWCLIDaemonState
        var arguments: [[String]] = []
        var delay: UInt64 = 0
        init(_ state: SWCLIDaemonState) { self.state = state }
        func probe() -> SWCLIDaemonState { state }
        func set(_ state: SWCLIDaemonState) { self.state = state }
        func delayStart(_ value: UInt64) { delay = value }
        func start(_ arguments: [String]) async throws {
            self.arguments.append(arguments)
            try await Task.sleep(nanoseconds: delay)
            state = .ready
        }
    }
    private func store(_ backend: Backend) -> SWCLIDaemonStore {
        SWCLIDaemonStore(probe: { await backend.probe() }, startCommand: { try await backend.start($0) })
    }

    func testHealthyDaemonIsReusedWithoutPreparationOrLaunch() async {
        let backend = Backend(.ready)
        let daemon = store(backend)
        daemon.start { _ in XCTFail("must reuse the connected host"); return false }
        await daemon.waitForOperation()
        let calls = await backend.arguments
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(daemon.state, .ready)
    }

    func testRefreshFollowsExternalStartDisconnectAndStopWithoutLaunching() async {
        let backend = Backend(.stopped)
        let daemon = store(backend)
        for observed in [SWCLIDaemonState.stopped, .ready, .needsRecovery("external host exited"), .stopped] {
            await backend.set(observed)
            await daemon.refresh()
            XCTAssertEqual(daemon.state, observed)
        }
        let calls = await backend.arguments
        XCTAssertTrue(calls.isEmpty)
    }

    func testAttachRecoveryAndColdStart() async {
        for observed in [SWCLIDaemonState.stopped, .needsRecovery("lost host")] {
            let backend = Backend(observed)
            let daemon = store(backend)
            daemon.start { state in XCTAssertEqual(state, observed); return true }
            await daemon.waitForOperation()
            let calls = await backend.arguments
            XCTAssertEqual(calls.count, 1)
            XCTAssertTrue(calls[0].contains("--attach-existing"))
            XCTAssertEqual(calls[0][1], observed == .stopped ? "start" : "restart")
            XCTAssertEqual(daemon.state, .ready)
        }
    }

    func testRecoveryByOtherClientDuringPreparationIsNotRestarted() async {
        let backend = Backend(.needsRecovery("lost"))
        let daemon = store(backend)
        daemon.start { _ in await backend.set(.ready); return true }
        await daemon.waitForOperation()
        let calls = await backend.arguments
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(daemon.state, .ready)
    }

    func testRepeatedClickAndPollDoNotOverwriteStartingIntent() async {
        let backend = Backend(.stopped)
        await backend.delayStart(40_000_000)
        let daemon = store(backend)
        daemon.start { _ in false }
        daemon.start { _ in XCTFail("duplicate click"); return false }
        await daemon.refresh()
        XCTAssertEqual(daemon.state, .starting)
        await daemon.waitForOperation()
        let calls = await backend.arguments
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(daemon.state, .ready)
    }

    func testProbeFailureDoesNotTouchHostAndStartupFailureIsVisible() async {
        let backend = Backend(.failed("endpoint busy"))
        let daemon = store(backend)
        daemon.start { _ in XCTFail("unknown endpoint must not be touched"); return false }
        await daemon.waitForOperation()
        XCTAssertEqual(daemon.state, .failed("endpoint busy"))
        XCTAssertEqual(daemon.failureMessage, "endpoint busy")
        let calls = await backend.arguments
        XCTAssertTrue(calls.isEmpty)
    }

    func testSuccessfulCommandDoesNotMeanConnectedHost() async {
        let daemon = SWCLIDaemonStore(probe: { .stopped }, startCommand: { _ in })
        daemon.start { _ in false }
        await daemon.waitForOperation()
        XCTAssertNotNil(daemon.failureMessage)
        XCTAssertFalse(daemon.state.isReady)
    }
}
