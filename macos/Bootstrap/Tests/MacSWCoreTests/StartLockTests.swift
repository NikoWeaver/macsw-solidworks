import Darwin
import Foundation
import XCTest
@testable import MacSWCore

/// Bughunt F4: the bottle's exclusive start lock, shared by MacSW and SOLIDWORKS.app.
final class StartLockTests: XCTestCase {
    private func makeBottle() throws -> URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("MacSW-startlock-\(UUID().uuidString)")
        let prefix = root.appendingPathComponent("bottle")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return prefix
    }

    private func held(_ outcome: StartLock.Outcome) -> StartLock? {
        if case .acquired(let lock) = outcome { return lock }
        return nil
    }

    /// The upgrade state directory would make the bottle managed (and block its launch until a
    /// baseline exists), so an unmanaged bottle keeps the lock next to itself.
    func testUnmanagedBottleKeepsItsLockNextToTheBottleAndStaysUnmanaged() throws {
        let prefix = try makeBottle()
        XCTAssertEqual(StartLock.url(prefix: prefix).path,
                       prefix.deletingLastPathComponent().appendingPathComponent(".bottle.start.lock").path)
        let lock = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: WineRuntimeService.root(prefix: prefix).path))
        XCTAssertFalse(WineRuntimeService.isManaged(prefix: prefix))
    }

    func testManagedBottleKeepsItsLockNextToTheLaunchLock() throws {
        let prefix = try makeBottle()
        let root = WineRuntimeService.root(prefix: prefix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(StartLock.url(prefix: prefix).path, root.appendingPathComponent("start.lock").path)
        let lock = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("start.lock").path))
    }

    func testSecondLockerWaitsUntilTheFirstReleases() throws {
        let prefix = try makeBottle()
        let first = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { first.release() }
        let began = Date()
        let second = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 5)), "the second locker gets it after the release")
        let waited = Date().timeIntervalSince(began)
        second.release()
        XCTAssertTrue(waited >= 0.3, "it waited for the first (\(waited) s)")
        XCTAssertLessThan(waited, 3)
    }

    func testTimeoutReportsBusy() throws {
        let prefix = try makeBottle()
        let first = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        defer { first.release() }
        let began = Date()
        guard case .busy = StartLock.acquire(prefix: prefix, timeout: 0.3) else { return XCTFail("expected busy") }
        XCTAssertTrue(Date().timeIntervalSince(began) >= 0.3)
    }

    func testReleaseIsIdempotent() throws {
        let prefix = try makeBottle()
        let lock = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        lock.release()
        lock.release()
        XCTAssertEqual(lock.fileDescriptor, -1)
        let again = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        again.release()
    }

    /// SOLIDWORKS.app never releases the lock itself: its exec does (close-on-exec). A program
    /// started while the lock is held does not get the descriptor, so it cannot keep the lock.
    func testLockDoesNotSurviveAnExec() throws {
        let prefix = try makeBottle()
        let lock = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        XCTAssertNotEqual(fcntl(lock.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0, "O_CLOEXEC")
        // A plain posix_spawn (no POSIX_SPAWN_CLOEXEC_DEFAULT): only close-on-exec keeps it out.
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ), 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        lock.release()
        // The child still runs. Had it inherited the descriptor, it would still hold the lock.
        let again = try XCTUnwrap(held(StartLock.acquire(prefix: prefix, timeout: 0)))
        again.release()
    }
}
