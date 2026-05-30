import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// End-to-end IPC: a real `DaemonServer` on a temp-`HARNESS_HOME` socket, driven by a
/// real `DaemonClient`. Proves the full request/response + output-streaming path.
final class DaemonRoundTripTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    override func setUpWithError() throws {
        try skipUnlessLiveDaemonTests()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Short root: the Unix socket path must fit in sun_path (104 chars), which the
        // long /var/folders temp dir would overflow.
        let dir = URL(fileURLWithPath: "/tmp/hrt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()

        server = DaemonServer()
        // start() resumes the accept DispatchSource on the server's own GCD queue, so
        // the server handles connections without runLoop(). (runLoop() calls
        // dispatchMain(), which would trap inside the XCTest process.)
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
        for _ in 0 ..< 50 {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return }
            usleep(100_000)
        }
        XCTFail("daemon did not become ready")
    }

    func testControlSocketIsOwnerOnly() throws {
        // The control socket drives PTY spawning and hook shell commands — it must be
        // 0o600 so no other local user can connect, even before the peer-cred check.
        let attrs = try FileManager.default.attributesOfItem(atPath: HarnessPaths.socketURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCloseEphemeralSessionsKeepsPinnedClosesRest() throws {
        let client = DaemonClient()
        guard case let .snapshot(initial) = try client.request(.getSnapshot),
              let ws = initial.activeWorkspace else { return XCTFail("no workspace") }

        guard case let .sessionID(pinned) = try client.request(.newSession(workspaceID: ws.id, cwd: nil, name: "pinned")),
              case let .sessionID(throwaway) = try client.request(.newSession(workspaceID: ws.id, cwd: nil, name: "throwaway"))
        else { return XCTFail("expected session IDs") }

        // Plain-mode contract: keep-on-quit off, pin one session, then reap ephemerals.
        _ = try client.request(.setKeepSessionsOnQuit(false))
        _ = try client.request(.setSessionPersistent(sessionID: pinned, persistent: true))
        _ = try client.request(.closeEphemeralSessions)

        guard case let .snapshot(after) = try client.request(.getSnapshot) else { return XCTFail("no snapshot") }
        let ids = after.workspaces.flatMap(\.sessions).map(\.id)
        XCTAssertTrue(ids.contains(pinned), "pinned session must survive a clean quit")
        XCTAssertFalse(ids.contains(throwaway), "unpinned session must be reaped")
    }

    func testPingMutationAndSnapshotRoundTrip() throws {
        let client = DaemonClient()
        guard case .pong = try client.request(.ping) else { return XCTFail("expected pong") }

        guard case let .workspaceID(wsID) = try client.request(.newWorkspace(name: "round-trip")) else {
            return XCTFail("expected workspaceID")
        }
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            return XCTFail("expected snapshot")
        }
        XCTAssertTrue(snapshot.workspaces.contains { $0.id == wsID && $0.name == "round-trip" })
    }

    func testSubscribeReceivesSurfaceOutput() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }

        let marker = "HARNESS_STREAM_OK"
        let streamed = expectation(description: "subscriber received marker")
        streamed.assertForOverFulfill = false
        let accumulator = OutputAccumulator()
        let subscription = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { data, _ in
            if accumulator.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) {
                streamed.fulfill()
            }
        }
        defer { subscription.cancel() }

        // Give the subscription socket a moment to register, then drive output.
        usleep(200_000)
        _ = try client.request(.sendData(surfaceID: target.surfaceID, data: Data("echo \(marker)\n".utf8)))
        wait(for: [streamed], timeout: 8)
    }

    /// Multi-client live mirroring: two independent subscribers on one surface both receive
    /// its output — the foundation that live detach/reattach builds on.
    func testTwoSubscribersBothReceiveOutput() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let marker = "HARNESS_MIRROR_OK"
        let gotA = expectation(description: "subscriber A received marker")
        let gotB = expectation(description: "subscriber B received marker")
        gotA.assertForOverFulfill = false
        gotB.assertForOverFulfill = false
        let accA = OutputAccumulator(), accB = OutputAccumulator()
        let subA = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { d, _ in
            if accA.appendAndContains(String(decoding: d, as: UTF8.self), marker: marker) { gotA.fulfill() }
        }
        let subB = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { d, _ in
            if accB.appendAndContains(String(decoding: d, as: UTF8.self), marker: marker) { gotB.fulfill() }
        }
        defer { subA.cancel(); subB.cancel() }
        usleep(200_000)
        _ = try client.request(.sendData(surfaceID: target.surfaceID, data: Data("echo \(marker)\n".utf8)))
        wait(for: [gotA, gotB], timeout: 8)
    }

    /// Per-client detach: one subscriber calling `detachSurface` releases ONLY itself; the other
    /// keeps receiving. Regression guard for the old bug where `detachSurface` wiped every
    /// subscriber on the surface (it routed to `cancelSubscription(token: nil)`).
    func testDetachSurfaceReleasesOnlyCallingClient() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let after = "HARNESS_AFTER_DETACH"
        let bGotAfter = expectation(description: "surviving subscriber receives post-detach output")
        bGotAfter.assertForOverFulfill = false
        let accA = OutputAccumulator(), accB = OutputAccumulator()
        let subA = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { d, _ in
            _ = accA.appendAndContains(String(decoding: d, as: UTF8.self), marker: after)
        }
        let subB = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { d, _ in
            if accB.appendAndContains(String(decoding: d, as: UTF8.self), marker: after) { bGotAfter.fulfill() }
        }
        defer { subA.cancel(); subB.cancel() }
        usleep(200_000)
        // A releases just this surface but keeps its connection open.
        subA.detachSurface(target.surfaceID)
        usleep(300_000)
        _ = try client.request(.sendData(surfaceID: target.surfaceID, data: Data("echo \(after)\n".utf8)))
        wait(for: [bGotAfter], timeout: 8)
        XCTAssertFalse(accA.contains(after), "a detached client must stop receiving the surface's output")
    }

    /// The `subscribeSnapshot` push: a layout mutation must deliver a `snapshotChanged`
    /// revision to subscribers (replaces the compositor's old 0.5s poll).
    func testSnapshotSubscriptionPushesRevisionOnMutation() throws {
        let client = DaemonClient()
        let pushed = expectation(description: "snapshot revision pushed")
        pushed.assertForOverFulfill = false
        let seen = AtomicCounter()
        let subscription = try client.subscribeSnapshot(label: "test") { _ in
            seen.increment()
            pushed.fulfill()
        }
        defer { subscription.cancel() }

        usleep(200_000) // let the subscription register
        _ = try client.request(.newWorkspace(name: "push"))
        wait(for: [pushed], timeout: 5)
        XCTAssertGreaterThan(seen.value, 0)
    }
}
