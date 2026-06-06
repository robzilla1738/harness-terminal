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

    /// Item 2 — `sendInput`'s Bool contract: it returns `false` once the subscription is torn down
    /// (cancelled/finished) so `SurfaceIO.send` can fall back to a one-shot `.sendData` RPC instead
    /// of silently dropping the keystroke into a dead fd.
    func testSendInputReturnsFalseAfterTeardown() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]

        // Drain the peer so a live write succeeds (returns true) before teardown.
        let draining = DispatchQueue(label: "drain")
        draining.async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while sysRead(peerEnd, &buf, buf.count) > 0 {}
        }

        let ended = expectation(description: "read loop ended")
        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: { _, _ in }, onEnd: { ended.fulfill() })

        // While alive and draining, a send flushes fully → true.
        XCTAssertTrue(subscription.sendInput(Data([0x61]), surfaceID: "s"), "live send must report success")

        subscription.cancel()
        wait(for: [ended], timeout: 2)
        sysClose(peerEnd)

        // After teardown every send must report failure so the caller falls back.
        XCTAssertFalse(subscription.sendInput(Data([0x62]), surfaceID: "s"), "send after cancel must report failure")
        XCTAssertFalse(subscription.sendInput(Data([0x63]), surfaceID: "s"), "repeat send after cancel must report failure")
    }

    /// Item 2 — `sendInput` returns `false` when the write hits a closed/hard-errored fd (EPIPE):
    /// the peer is gone but the local guard hasn't flipped yet (the exact window the fallback
    /// covers). `writeFrame` must report the failed flush, not swallow it.
    func testSendInputReturnsFalseOnClosedPeerWrite() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]

        // Match production: `EndpointConnector.connect` sets `SO_NOSIGPIPE`, so a write to a dead
        // peer returns EPIPE instead of raising SIGPIPE. Without it the test process (which doesn't
        // ignore SIGPIPE) dies on the write rather than observing the false return.
        setNoSigPipe(localEnd)
        // Build a subscription WITHOUT starting the read loop, so `finished` never flips — the only
        // way `sendInput` can fail here is the write itself erroring on the dead peer.
        let subscription = DaemonSubscription(fd: localEnd)
        // Close the peer and fill the local send buffer so a subsequent write hits EPIPE rather than
        // buffering. A large-ish payload past the socket buffer guarantees the write reaches the
        // closed peer and returns an error instead of succeeding into kernel buffer space.
        sysClose(peerEnd)
        var sawFailure = false
        for _ in 0 ..< 64 where !sawFailure {
            if !subscription.sendInput(Data(repeating: 0x7a, count: 64 * 1024), surfaceID: "s") {
                sawFailure = true
            }
        }
        XCTAssertTrue(sawFailure, "a write to a closed peer must eventually report failure")
        sysClose(localEnd)
    }

    /// Item 1 — gap-free dedup: with buffering armed, live output frames pushed before the replay
    /// boundary is known are held; `flushBuffered(droppingSequencesBelow:)` then delivers them in
    /// arrival order, dropping exactly the frames already inside the replay (sequence < boundary)
    /// and keeping the rest. Proves union(replay, flushed) has no gap and no duplicate.
    func testBufferedFlushDedupesAgainstReplayBoundary() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]
        defer { sysClose(localEnd); sysClose(peerEnd) }

        // The delivered live frames, captured by the SAME closure the read loop forwards to.
        let delivered = FrameRecorder()
        let onData: @Sendable (Data, UInt64) -> Void = { data, seq in delivered.record(data, seq) }

        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: onData, onEnd: nil, buffered: true)

        // Three live frames arrive while buffering. Sequences 10, 13, 16 (3 bytes each). The replay
        // boundary will be 13 → frame@10 is inside the replay (drop), 13 and 16 are after (keep).
        let frames: [(UInt64, [UInt8])] = [
            (10, Array("aaa".utf8)),
            (13, Array("bbb".utf8)),
            (16, Array("ccc".utf8)),
        ]
        for (seq, bytes) in frames {
            let frame = try IPCCodec.encodeOutputFrame(Data(bytes), sequence: seq)
            writeAllToFD(frame, fd: peerEnd)
        }
        // Wait until all three are buffered (none delivered yet — buffering holds them).
        let buffered = expectation(description: "all live frames buffered")
        DispatchQueue.global().async {
            for _ in 0 ..< 100 {
                if subscription.bufferedFrameCountForTesting() == frames.count { buffered.fulfill(); return }
                usleep(20_000)
            }
        }
        wait(for: [buffered], timeout: 3)
        XCTAssertTrue(delivered.isEmpty, "buffered frames must NOT be delivered before the flush")

        // Flush deduping below sequence 13 — frame@10 is the replay overlap and must be dropped.
        let dropped = subscription.flushBuffered(droppingSequencesBelow: 13, onData: onData)
        XCTAssertEqual(dropped, 1, "exactly the one overlapping frame (seq 10) is a duplicate")
        XCTAssertEqual(delivered.sequences(), [13, 16], "kept frames in order, no gap, no duplicate")
    }

    /// Item 1 — boundary 0 (old-daemon fallback path): no usable replay end, so NOTHING is deduped
    /// and every buffered frame is delivered (replay-then-deliver, never a double-deliver beyond
    /// the replay the caller already wrote — which an old daemon's plain replay doesn't overlap by
    /// sequence). Guards the degraded path the helper takes against an old daemon.
    func testBufferedFlushWithZeroBoundaryDeliversAll() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(makeUnixSocketPair(&fds), 0, "socketpair failed")
        let localEnd = fds[0]
        let peerEnd = fds[1]
        defer { sysClose(localEnd); sysClose(peerEnd) }

        let delivered = FrameRecorder()
        let onData: @Sendable (Data, UInt64) -> Void = { data, seq in delivered.record(data, seq) }
        let subscription = DaemonSubscription(fd: localEnd)
        subscription.start(onData: onData, onEnd: nil, buffered: true)

        for (seq, bytes) in [(UInt64(5), Array("xx".utf8)), (UInt64(7), Array("yy".utf8))] {
            writeAllToFD(try IPCCodec.encodeOutputFrame(Data(bytes), sequence: seq), fd: peerEnd)
        }
        let buffered = expectation(description: "frames buffered")
        DispatchQueue.global().async {
            for _ in 0 ..< 100 {
                if subscription.bufferedFrameCountForTesting() == 2 { buffered.fulfill(); return }
                usleep(20_000)
            }
        }
        wait(for: [buffered], timeout: 3)

        let dropped = subscription.flushBuffered(droppingSequencesBelow: 0, onData: onData)
        XCTAssertEqual(dropped, 0, "boundary 0 drops nothing")
        XCTAssertEqual(delivered.sequences(), [5, 7], "all buffered frames delivered in order")
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

/// Thread-safe recorder for `(data, sequence)` frames delivered to an `onData` closure (which the
/// read loop may invoke off the test thread). Used to assert delivery order and dedup.
private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(Data, UInt64)] = []

    func record(_ data: Data, _ sequence: UInt64) {
        lock.lock(); frames.append((data, sequence)); lock.unlock()
    }

    func sequences() -> [UInt64] {
        lock.lock(); defer { lock.unlock() }; return frames.map(\.1)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }; return frames.isEmpty
    }
}

/// Write every byte of `data` to `fd`, looping past partial/EINTR writes (test helper).
private func writeAllToFD(_ data: Data, fd: Int32) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var off = 0
        while off < raw.count {
            let n = write(fd, base.advanced(by: off), raw.count - off)
            if n > 0 { off += n }
            else if n < 0, errno == EINTR { continue }
            else { return }
        }
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
