#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Pure, deterministic coverage for the daemon bootstrap lifecycle decisions. No live daemon
/// or sockets — `DaemonLifecycle` is intentionally probe-injectable so these stay fast.
final class DaemonLifecycleTests: XCTestCase {
    // MARK: - PID-reuse identity gate (item 1)

    /// A live, same-user process that is NOT a HarnessDaemon (a recycled PID after `kill -9`)
    /// must NOT make a fresh daemon refuse to start — that's the loop the fix prevents.
    func testLiveNonDaemonPIDIsTreatedAsStale() {
        let decision = DaemonLifecycle.priorInstanceDecision(
            priorPID: 4242,
            ownPID: 1,
            isAlive: { _ in true },
            executablePath: { _ in "/bin/zsh" }
        )
        XCTAssertEqual(decision, .stale, "a recycled non-daemon PID must be reclaimed, not refused")
    }

    /// A PID with no live process (the previous daemon is gone) is stale → remove and proceed.
    func testDeadPIDIsStale() {
        let decision = DaemonLifecycle.priorInstanceDecision(
            priorPID: 4242,
            ownPID: 1,
            isAlive: { _ in false },
            executablePath: { _ in XCTFail("must not probe path for a dead PID"); return nil }
        )
        XCTAssertEqual(decision, .stale)
    }

    /// A live process whose executable IS a HarnessDaemon is the genuine "already running" case.
    func testLiveHarnessDaemonRefuses() {
        let decision = DaemonLifecycle.priorInstanceDecision(
            priorPID: 4242,
            ownPID: 1,
            isAlive: { _ in true },
            executablePath: { _ in "/usr/local/bin/HarnessDaemon" }
        )
        XCTAssertEqual(decision, .refuse)
    }

    /// Alive but path unresolvable (e.g. EPERM on a foreign-owned PID) is treated as not-ours.
    func testLiveButUnresolvablePathIsStale() {
        let decision = DaemonLifecycle.priorInstanceDecision(
            priorPID: 4242,
            ownPID: 1,
            isAlive: { _ in true },
            executablePath: { _ in nil }
        )
        XCTAssertEqual(decision, .stale)
    }

    /// Our own PID in the file is never a competing instance.
    func testOwnPIDProceeds() {
        let decision = DaemonLifecycle.priorInstanceDecision(
            priorPID: 99,
            ownPID: 99,
            isAlive: { _ in XCTFail("own PID must short-circuit before the liveness probe"); return true },
            executablePath: { _ in nil }
        )
        XCTAssertEqual(decision, .proceed)
    }

    /// The production `processIsAlive` probe agrees with reality for the running test process
    /// and a definitely-dead PID.
    func testProcessIsAliveMatchesReality() {
        XCTAssertTrue(DaemonLifecycle.processIsAlive(getpid()), "the test process is alive")
        // PID 2^31-2 is well above pid_max; never a live process.
        XCTAssertFalse(DaemonLifecycle.processIsAlive(pid_t(Int32.max - 1)))
    }

    /// The production `executablePath` resolves the running test binary (non-empty path).
    func testExecutablePathResolvesSelf() throws {
        let path = try XCTUnwrap(DaemonLifecycle.executablePath(of: getpid()))
        XCTAssertFalse(path.isEmpty)
    }

    // MARK: - Owner-checked PID-file removal (item 7)

    private func tempPIDFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-pidfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daemon.pid")
    }

    /// A PID file recording a FOREIGN pid (the bind winner's, from the loser's cleanup path)
    /// must survive the owner-checked removal.
    func testForeignPIDFileSurvivesGuardedRemoval() throws {
        let url = try tempPIDFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "98765\n".write(to: url, atomically: true, encoding: .utf8)

        let removed = DaemonLifecycle.removeOwnedPIDFile(at: url, ownPID: 1234)
        XCTAssertFalse(removed, "must not remove a file we don't own")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the winner's PID file must survive")
    }

    /// Our own PID file is removed by the guarded path (normal shutdown / atexit).
    func testOwnPIDFileIsRemoved() throws {
        let url = try tempPIDFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "1234\n".write(to: url, atomically: true, encoding: .utf8)

        let removed = DaemonLifecycle.removeOwnedPIDFile(at: url, ownPID: 1234)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A missing file is a no-op (no crash, returns false).
    func testMissingPIDFileIsNoop() throws {
        let url = try tempPIDFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertFalse(DaemonLifecycle.removeOwnedPIDFile(at: url, ownPID: 1234))
    }
}
