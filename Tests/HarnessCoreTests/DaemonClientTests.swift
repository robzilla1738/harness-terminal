#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
        let serverFD = makeUnixStreamSocket()
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { sysClose(serverFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        HarnessPaths.socketURL.path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(dest, cstr, sunPathCapacity - 1)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                posixBind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(posixListen(serverFD, 1), 0)

        let accepted = expectation(description: "accepted client")
        DispatchQueue.global().async {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD >= 0 {
                accepted.fulfill()
                usleep(300_000)
                sysClose(clientFD)
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
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]
        // peerEnd stays open and silent, so read(localEnd) blocks exactly like an idle daemon.
        defer { sysClose(peerEnd) }

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

    /// Regression: a write that loses the race to the read loop's teardown must not touch the
    /// closed (and possibly recycled) fd. Once the loop closes `fd` it sets `finished` under
    /// `writeLock`, so `writeFrame` bails instead of writing into a stale descriptor.
    func testSendInputAfterReadLoopCloseBails() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]

        let ended = expectation(description: "read loop ended")
        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: { _, _ in }, onEnd: { ended.fulfill() })

        // Closing the peer makes read(localEnd) return EOF → the loop sets `finished` and closes
        // localEnd (under writeLock) → onEnd fires.
        sysClose(peerEnd)
        wait(for: [ended], timeout: 2)

        // The fd is now closed; these writes must bail on `finished`, never touch the descriptor.
        for _ in 0 ..< 100 { subscription.sendInput(Data([0x61]), surfaceID: "surface") }
        // Reaching here without a crash is the assertion.
    }

    /// Stress: concurrent `sendInput` while `cancel()`/teardown runs must not crash or deadlock.
    /// A background reader drains the peer so the blocking writes never wedge.
    func testConcurrentSendInputDuringCancelIsSafe() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]
        DispatchQueue(label: "drain").async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while sysRead(peerEnd, &buf, buf.count) > 0 {}
            sysClose(peerEnd) // peer hits EOF once localEnd closes; own its close here
        }

        let ended = expectation(description: "read loop ended")
        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: { _, _ in }, onEnd: { ended.fulfill() })

        let writersDone = expectation(description: "writers done")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0 ..< 200 { subscription.sendInput(Data([0x78]), surfaceID: "s") }
            }
            writersDone.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.01) // let some writes start, then tear down mid-flight
        subscription.cancel()
        wait(for: [writersDone, ended], timeout: 5)
    }
}

private func posixBind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(fd, addr, len)
    #else
    Glibc.bind(fd, addr, len)
    #endif
}

private func posixListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(fd, backlog)
    #else
    Glibc.listen(fd, backlog)
    #endif
}

private func makeUnixSocketPair(_ fds: inout [Int32]) -> Int32 {
    #if canImport(Darwin)
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
}
