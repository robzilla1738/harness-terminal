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
        pty.onExit = { exited.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            pty.write("exit\n")
        }
        wait(for: [exited], timeout: 8)
    }

    func testCloseIsIdempotent() throws {
        let pty = try makePty()
        pty.close()
        pty.close() // must not crash or hang on a second close
    }
}
