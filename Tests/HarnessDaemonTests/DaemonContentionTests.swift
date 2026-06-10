import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Concurrency/lock-pressure regression tests: many subscribers, disconnect and
/// surface-close racing live output, and `daemon-stats` consistency under load.
/// These exercise the real socket + PTY path, so they're gated like the other live
/// daemon tests (`HARNESS_LIVE_DAEMON_TESTS=1`).
/// Thread-safe collector for subscriptions created concurrently across dispatch queues
/// (mirrors `OutputAccumulator`/`AtomicCounter` in TestSupport).
private final class SubscriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DaemonSubscription] = []
    func add(_ s: DaemonSubscription) { lock.lock(); items.append(s); lock.unlock() }
    func all() -> [DaemonSubscription] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

/// Thread-safe set of subscriber indices that have observed the fan-out marker.
private final class ConcurrentIndexSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items = Set<Int>()
    func insert(_ i: Int) { lock.lock(); items.insert(i); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

final class DaemonContentionTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Short root so the Unix socket path fits in sun_path (104 chars).
        let dir = URL(fileURLWithPath: "/tmp/hct-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
        server = DaemonServer()
        try server.start()
        try waitForDaemonReady()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitForDaemonReady() throws {
        let client = DaemonClient()
        let ready = waitUntil(timeout: 10) {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return true }
            return false
        }
        if !ready { XCTFail("daemon did not become ready") }
    }

    private func firstSurfaceID(_ client: DaemonClient) throws -> String {
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces),
              let target = surfaces.first else {
            throw XCTSkip("no default surface")
        }
        return target.surfaceID
    }

    // MARK: - Concurrent subscriptions

    /// Many subscribers attach to one surface concurrently, then a single write must
    /// fan out to all of them — no deadlock, no dropped subscriber.
    func testManyConcurrentSubscribersAllReceiveOutput() throws {
        let client = DaemonClient()
        let surfaceID = try firstSurfaceID(client)

        let marker = "HARNESS_FANOUT_OK"
        let count = 12
        let box = SubscriptionBox()
        let received = ConcurrentIndexSet()
        let accs = (0 ..< count).map { _ in OutputAccumulator() }
        let group = DispatchGroup()

        for i in 0 ..< count {
            group.enter()
            DispatchQueue.global().async {
                // Each client connection is independent; assert every concurrent subscribe
                // succeeds (no orphaned expectation to mask a connect failure).
                guard let sub = try? client.subscribeSurfaceOutput(surfaceID: surfaceID, label: "sub-\(i)", onData: { d, _ in
                    if accs[i].appendAndContains(String(decoding: d, as: UTF8.self), marker: marker) { received.insert(i) }
                }) else { group.leave(); return }
                box.add(sub)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 8), .success, "all subscribe calls returned")
        defer { box.all().forEach { $0.cancel() } }
        XCTAssertEqual(box.count, count, "all \(count) concurrent subscribes succeeded")

        // Drive the marker repeatedly (subscribe returns before the daemon finishes registering
        // the socket, so a one-shot echo could race a slow registration) until every subscriber
        // has seen it. Asserts fan-out completeness, not single-shot timing.
        usleep(200_000)
        let deadline = Date().addingTimeInterval(15)
        while received.count < box.count, Date() < deadline {
            _ = try client.request(.sendData(surfaceID: surfaceID, data: Data("echo \(marker)\n".utf8)))
            usleep(200_000)
        }
        XCTAssertEqual(received.count, box.count, "every subscriber received the fan-out marker")
    }

    // MARK: - Disconnect during output

    /// Dropping one subscriber mid-stream releases only itself; the other keeps
    /// receiving and the daemon stays responsive.
    func testClientDisconnectDuringOutputLeavesDaemonHealthy() throws {
        let client = DaemonClient()
        let surfaceID = try firstSurfaceID(client)

        let after = "HARNESS_SURVIVES_DISCONNECT"
        let survivorGot = expectation(description: "surviving subscriber receives post-disconnect output")
        survivorGot.assertForOverFulfill = false
        let accSurvivor = OutputAccumulator()

        let doomed = try client.subscribeSurfaceOutput(surfaceID: surfaceID, label: "doomed") { _, _ in }
        let survivor = try client.subscribeSurfaceOutput(surfaceID: surfaceID, label: "survivor") { d, _ in
            if accSurvivor.appendAndContains(String(decoding: d, as: UTF8.self), marker: after) { survivorGot.fulfill() }
        }
        defer { survivor.cancel() }

        // Drive output while we tear the doomed subscriber down — the cancel races live bytes.
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while stop.wait(timeout: .now()) == .timedOut {
                _ = try? client.request(.sendData(surfaceID: surfaceID, data: Data("echo busy\n".utf8)))
                usleep(20_000)
            }
        }
        usleep(150_000)
        doomed.cancel() // disconnect mid-stream
        usleep(150_000)
        _ = try client.request(.sendData(surfaceID: surfaceID, data: Data("echo \(after)\n".utf8)))
        wait(for: [survivorGot], timeout: 12)
        stop.signal()

        // Daemon still answers after the racy disconnect.
        if case .pong = try client.request(.ping, timeout: 1) {} else { XCTFail("daemon unresponsive after disconnect") }
    }

    // MARK: - Close surface during output

    /// Closing a surface while output is arriving must not crash and must leave the
    /// rest of the daemon healthy (remaining surfaces intact, stats still answerable).
    func testCloseSurfaceDuringOutputDoesNotCrash() throws {
        let client = DaemonClient()
        guard case let .snapshot(snap) = try client.request(.getSnapshot),
              let ws = snap.activeWorkspace else { return XCTFail("no workspace") }
        guard case let .surfaces(before) = try client.request(.listSurfaces) else { return XCTFail("no surfaces") }
        let beforeIDs = Set(before.map(\.surfaceID))

        // Fresh tab → fresh surface, so we never close the default one out from under the suite.
        guard case let .tabID(tabID) = try client.request(.newTab(workspaceID: ws.id, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }
        guard case let .surfaces(after) = try client.request(.listSurfaces),
              let fresh = after.map(\.surfaceID).first(where: { !beforeIDs.contains($0) }) else {
            return XCTFail("new surface not found")
        }

        let sub = try client.subscribeSurfaceOutput(surfaceID: fresh, label: "closing") { _, _ in }
        defer { sub.cancel() }

        // Drive output to the fresh surface while we close its tab — the close races live bytes.
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while stop.wait(timeout: .now()) == .timedOut {
                _ = try? client.request(.sendData(surfaceID: fresh, data: Data("echo busy\n".utf8)))
                usleep(10_000)
            }
        }
        usleep(150_000)
        _ = try client.request(.closeTab(tabID: tabID)) // close while output is in flight
        usleep(150_000)
        stop.signal()

        // No crash; daemon healthy; the closed surface is gone, the originals remain.
        if case .pong = try client.request(.ping, timeout: 1) {} else { XCTFail("daemon unresponsive after close") }
        guard case let .surfaces(remaining) = try client.request(.listSurfaces) else { return XCTFail("no surfaces") }
        let remainingIDs = Set(remaining.map(\.surfaceID))
        XCTAssertFalse(remainingIDs.contains(fresh), "closed surface should be gone")
        XCTAssertTrue(beforeIDs.isSubset(of: remainingIDs), "pre-existing surfaces should be unaffected")
    }

    // MARK: - daemon-stats consistency under load

    /// Under concurrent output and a live subscription, `daemon-stats` must stay
    /// internally consistent and never deadlock/crash across repeated reads. Guards the
    /// `surfaceTelemetry` (snapshot-refs-then-sum-off-lock) refactor.
    func testDaemonStatsConsistentUnderConcurrentOutput() throws {
        let client = DaemonClient()
        let surfaceID = try firstSurfaceID(client)
        let sub = try client.subscribeSurfaceOutput(surfaceID: surfaceID, label: "stats-watcher") { _, _ in }
        defer { sub.cancel() }

        // Background load: hammer output while we poll stats from the main thread.
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while stop.wait(timeout: .now()) == .timedOut {
                _ = try? client.request(.sendData(surfaceID: surfaceID, data: Data("echo load\n".utf8)))
                usleep(5_000)
            }
        }
        defer { stop.signal() }

        for _ in 0 ..< 25 {
            guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 2) else {
                return XCTFail("expected daemonStats")
            }
            guard case let .surfaces(surfaces) = try client.request(.listSurfaces, timeout: 2) else {
                return XCTFail("expected surfaces")
            }
            XCTAssertEqual(stats.surfaceCount, surfaces.count, "surfaceCount must match listSurfaces")
            XCTAssertGreaterThanOrEqual(stats.totalScrollbackBytes, 0)
            XCTAssertGreaterThanOrEqual(stats.subscriberCount, 1, "our subscription should be counted")
            XCTAssertGreaterThanOrEqual(stats.snapshotRevision, 0)
            usleep(20_000)
        }
    }
}
