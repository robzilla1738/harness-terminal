import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Exercises the real `forkpty(3)` lifecycle with a `/bin/sh` child. These run actual
/// I/O, so timeouts are generous; they assume a normal macOS dev/runner environment.
final class RealPtyLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
    }

    private func makePty() throws -> RealPty {
        try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 24,
            cols: 80,
            scrollbackBytes: 64 * 1024
        )
    }

    func testOutputReachesSubscriberAndScrollback() throws {
        let pty = try makePty()
        defer { pty.close() }

        let marker = "HARNESS_PTY_MARKER"
        let received = expectation(description: "subscriber saw marker")
        received.assertForOverFulfill = false
        let accumulator = OutputAccumulator()
        _ = pty.subscribe { data, _ in
            if accumulator.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) {
                received.fulfill()
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            pty.write("echo \(marker)\n")
        }
        wait(for: [received], timeout: 8)
        XCTAssertTrue(pty.replay(fromSequence: nil).contains(marker), "scrollback should retain output")
    }

    func testOnExitFiresWhenShellExits() throws {
        let pty = try makePty()
        let exited = expectation(description: "child exited")
        pty.onExit = { _ in exited.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            pty.write("exit\n")
        }
        wait(for: [exited], timeout: 8)
    }

    /// The decoded child exit status reaches `onExit` (best-effort: the EOF path reaps with
    /// WNOHANG when it wins the race against the waitpid watcher) so the daemon can record
    /// it on a retained dead pane (`remain-on-exit` → `Tab.exitStatus`).
    func testOnExitCarriesExitStatus() throws {
        let pty = try makePty()
        let exited = expectation(description: "child exited")
        let status = AtomicBox<Int32>()
        pty.onExit = { code in
            status.set(code)
            exited.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            pty.write("exit 3\n")
        }
        wait(for: [exited], timeout: 8)
        XCTAssertEqual(status.value, 3, "decoded exit code must reach onExit")
    }

    func testCloseIsIdempotent() throws {
        let pty = try makePty()
        pty.close()
        pty.close() // must not crash or hang on a second close
    }

    /// Respawn must NOT fire `onExit` (it's a replace, not a death) and must keep the
    /// surface streaming. Regression test for the generation race where the old
    /// child's exit-watcher ran `close()` against the freshly respawned shell.
    func testRespawnDoesNotFireExitAndKeepsStreaming() throws {
        let pty = try makePty()
        defer { pty.close() }
        let exits = AtomicCounter()
        pty.onExit = { _ in exits.increment() }

        Thread.sleep(forTimeInterval: 0.3) // let the first shell come up
        pty.respawn(clearHistory: true)

        let marker = "RESPAWN_OK_MARKER"
        let received = expectation(description: "post-respawn output reaches subscriber")
        received.assertForOverFulfill = false
        let acc = OutputAccumulator()
        _ = pty.subscribe { data, _ in
            if acc.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) {
                received.fulfill()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { pty.write("echo \(marker)\n") }
        wait(for: [received], timeout: 8)

        // The old child's SIGTERM death must not have surfaced as an exit event.
        XCTAssertEqual(exits.value, 0, "respawn must not fire onExit for the replaced shell")
    }

    /// Hammer write/resize concurrently with a respawn; the generation-guarded
    /// lifecycle must neither crash nor double-free.
    func testRespawnUnderConcurrentIODoesNotCrash() throws {
        let pty = try makePty()
        defer { pty.close() }
        let group = DispatchGroup()
        for i in 0 ..< 50 {
            group.enter()
            DispatchQueue.global().async {
                pty.write("echo \(i)\n")
                pty.resize(rows: UInt16(20 + (i % 8)), cols: UInt16(80 + (i % 8)))
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            pty.respawn(clearHistory: false)
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
    }
}
