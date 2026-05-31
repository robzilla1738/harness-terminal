import Darwin
import XCTest
@testable import HarnessCore

final class DaemonClientTests: XCTestCase {
    func testRequestTimesOutWhenSocketAcceptsButDoesNotReply() throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Keep the root short: the macOS temp dir + a full UUID pushes harness.sock past the
        // 104-byte sun_path limit (which the daemon/client now reject outright), so use /tmp + a
        // truncated UUID to stay well within it.
        let root = URL(fileURLWithPath: "/tmp/hc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("HARNESS_HOME", root.path, 1)
        defer {
            if let previousHome {
                setenv("HARNESS_HOME", previousHome, 1)
            } else {
                unsetenv("HARNESS_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }

        try HarnessPaths.ensureDirectories()
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { close(serverFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        HarnessPaths.socketURL.path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, 104)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(serverFD, 1), 0)

        let accepted = expectation(description: "accepted client")
        DispatchQueue.global().async {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                accepted.fulfill()
                usleep(300_000)
                close(clientFD)
            }
        }

        XCTAssertThrowsError(try DaemonClient().request(.ping, timeout: 0.1)) { error in
            guard case DaemonClientError.timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
        wait(for: [accepted], timeout: 1)
    }

    /// Regression: closing a tab/pane deinits its `TerminalHostView`, which calls
    /// `DaemonSubscription.cancel()` on the main thread. The read loop parks a blocking
    /// `read()` for the subscription's lifetime; if `cancel()` funnels through the same
    /// queue it waits behind that read forever and the app freezes. `cancel()` must return
    /// promptly and wake the read loop instead.
    func testSubscriptionCancelDoesNotDeadlockWhileReadLoopBlocked() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]
        // peerEnd stays open and silent, so read(localEnd) blocks exactly like an idle daemon.
        defer { close(peerEnd) }

        let readLoopEnded = expectation(description: "read loop exited")
        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: { _, _ in }, onEnd: { readLoopEnded.fulfill() })

        // Let the read loop reach its blocking read() before we cancel.
        Thread.sleep(forTimeInterval: 0.05)

        let cancelReturned = expectation(description: "cancel returned")
        DispatchQueue.global().async {
            subscription.cancel()   // pre-fix: deadlocks here forever
            cancelReturned.fulfill()
        }
        wait(for: [cancelReturned], timeout: 2)

        // shutdown() inside cancel() must wake the blocked read so the loop exits.
        wait(for: [readLoopEnded], timeout: 2)
    }
}
