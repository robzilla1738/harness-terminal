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

    func testCloseEphemeralSessionsKeepsPinnedTabClosesSibling() throws {
        let client = DaemonClient()
        guard case let .snapshot(initial) = try client.request(.getSnapshot),
              let ws = initial.activeWorkspace else { return XCTFail("no workspace") }

        // A session with two tabs; pin one tab, leave the other ephemeral.
        guard case let .sessionID(mixed) = try client.request(.newSession(workspaceID: ws.id, cwd: nil, name: "mixed"))
        else { return XCTFail("expected session ID") }
        _ = try client.request(.newTab(workspaceID: ws.id, cwd: nil))

        guard case let .snapshot(mid) = try client.request(.getSnapshot) else { return XCTFail("no snapshot") }
        let tabs = mid.workspaces.flatMap(\.sessions).first { $0.id == mixed }?.tabs ?? []
        guard tabs.count >= 2 else { return XCTFail("expected two tabs in the session") }
        let keepTab = tabs[0].id
        let dropTab = tabs[1].id

        _ = try client.request(.setKeepSessionsOnQuit(false))
        _ = try client.request(.setTabPersistent(tabID: keepTab, persistent: true))
        _ = try client.request(.closeEphemeralSessions)

        guard case let .snapshot(end) = try client.request(.getSnapshot) else { return XCTFail("no snapshot") }
        let survivingSession = end.workspaces.flatMap(\.sessions).first { $0.id == mixed }
        XCTAssertNotNil(survivingSession, "a session with a pinned tab survives as its container")
        let survivingTabIDs = survivingSession?.tabs.map(\.id) ?? []
        XCTAssertTrue(survivingTabIDs.contains(keepTab), "pinned tab survives a clean quit")
        XCTAssertFalse(survivingTabIDs.contains(dropTab), "unpinned sibling tab is reaped")
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

    /// Item 1 regression — the attach replay→subscribe gap. Pre-fix, attach did
    /// `replayScrollback` THEN `subscribeSurfaceOutput` on a separate socket; bytes appended
    /// between the replay snapshot and the handler registration were persisted but never delivered
    /// (the daemon does no backfill). This drove the worst case: a tight marker burst lands in that
    /// window, so a re-replay sees them but the live attach stream is missing them.
    ///
    /// `attachReplayingSurfaceOutput` closes it (subscribe-first → buffer → replay → dedup-flush).
    /// The test bursts N distinct markers, attaches gap-free WHILE more markers keep flowing, and
    /// asserts every marker is present in union(replay, live) — i.e. the gap-free attach loses none
    /// of what a fresh full re-replay would show (0 missing). Pre-fix this fails with a gap.
    func testGapFreeAttachLosesNoOutputAcrossReplaySubscribeBoundary() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID

        // Quiet the shell so only our marker output reaches the stream. `stty -echo` stops the PTY
        // echoing input; per-marker complete commands keep the marker tokens off the line editor's
        // syntax-highlighted echo (an interactive shell colorizes a long command as it's "typed",
        // which would split a marker token across SGR escapes and defeat substring matching).
        _ = try client.request(.sendData(surfaceID: sid, data: Data("PS1=''; stty -echo\n".utf8)))
        usleep(300_000)

        let total = 40
        @Sendable func marker(_ i: Int) -> String { "GAPMARK_\(i)_END" }

        // The gap-free attach folds replay AND live frames into one accumulator, in order.
        let combined = OutputAccumulator()
        let burstDone = AtomicBox<Bool>()

        // Stream markers continuously ACROSS the attach handshake. The writer uses its OWN
        // `DaemonClient` so its `sendData` requests don't serialize behind the attach's replay/
        // subscribe round trips on a shared client queue — output must keep flowing during the
        // replay→subscribe window for the no-loss guarantee to mean anything. Each marker is a
        // complete `printf` command so its output token lands clean in scrollback.
        let writerClient = DaemonClient()
        let writer = DispatchQueue(label: "gap-writer")
        writer.async {
            for i in 0 ..< total {
                _ = try? writerClient.request(.sendData(surfaceID: sid, data: Data("printf '\(marker(i))\\n'\n".utf8)))
                usleep(25_000)
            }
            burstDone.set(true)
        }

        // Attach mid-stream, AFTER a few markers have accumulated (non-empty replay) but with the
        // bulk still to come (the gap/live window).
        usleep(200_000)
        let subscription = try client.attachReplayingSurfaceOutput(
            surfaceID: sid,
            label: "gap-test",
            onReplay: { text in _ = combined.appendAndContains(text, marker: "") },
            onData: { data, _ in _ = combined.appendAndContains(String(decoding: data, as: UTF8.self), marker: "") }
        )
        defer { subscription.cancel() }

        // Wait for the burst to finish and the stream to settle.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if burstDone.value == true, combined.contains(marker(total - 1)) { break }
            usleep(50_000)
        }
        usleep(400_000) // let any trailing frames flush before the authoritative re-replay

        // Ground truth: a full re-replay AFTER everything settled is exactly what the surface holds.
        // The gap-free attach must contain every marker ground truth does — anything in the re-replay
        // but missing from the attach stream is output the replay→subscribe boundary dropped.
        // (Comparing against the re-replay, not the absolute 0..<total set, isolates the attach gap
        // from any shell-level loss, which would be absent from BOTH.)
        guard case let .text(fullReplay)? = try? client.request(.replayScrollback(surfaceID: sid, fromSequence: nil), timeout: 5) else {
            return XCTFail("expected a full re-replay")
        }
        let stream = combined.snapshot
        let groundTruth = (0 ..< total).filter { fullReplay.contains(marker($0)) }
        let missing = groundTruth.filter { !stream.contains(marker($0)) }
        XCTAssertFalse(groundTruth.isEmpty, "the surface must actually hold markers to test against")
        XCTAssertEqual(missing, [], "gap-free attach must lose no output the surface holds; missing: \(missing)")
    }

    /// Item 1 — the sequenced replay reports a usable end boundary that advances as output is
    /// appended. The boundary is what the gap-free attach dedupes its buffered live frames against;
    /// a non-advancing or zero boundary would either re-show overlap or (with the old `.text`-only
    /// replay) force the lossy fallback. Proves the new request is wired end to end.
    func testReplayScrollbackSequencedReportsAdvancingEndSequence() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID

        guard case let .replayResult(_, first)? = try? client.request(.replayScrollbackSequenced(surfaceID: sid, fromSequence: nil)) else {
            return XCTFail("expected a replayResult")
        }
        _ = try client.request(.sendData(surfaceID: sid, data: Data("printf 'SEQPROBE\\n'\n".utf8)))
        usleep(400_000)
        guard case let .replayResult(_, second)? = try? client.request(.replayScrollbackSequenced(surfaceID: sid, fromSequence: nil)) else {
            return XCTFail("expected a second replayResult")
        }
        XCTAssertGreaterThan(second, first, "the replay end sequence must advance as output is appended")
    }

    /// Change B: subscribing to a surface that does not exist must NOT hang forever. The daemon
    /// rejects it with `.error("Surface not found")` and leaves the fd open, so the read loop has
    /// to treat that `.error` as fatal and fire `onEnd` — otherwise a GUI reconnect (or CLI attach)
    /// would block on a dead socket and the pane would freeze silently.
    func testSubscribeToMissingSurfaceEndsPromptly() throws {
        let client = DaemonClient()
        let ended = expectation(description: "onEnd fires for a rejected subscription")
        let subscription = try client.subscribeSurfaceOutput(
            surfaceID: UUID().uuidString, // never created — the daemon rejects the subscribe
            onData: { _, _ in },
            onEnd: { ended.fulfill() }
        )
        defer { subscription.cancel() }
        wait(for: [ended], timeout: 5)
    }

    /// Change A/B: input written as a binary frame on the persistent full-duplex subscription
    /// connection (`sendInput`, fire-and-forget — no `.ok` reply) reaches the PTY, and its echo
    /// streams back on that same connection as a binary output frame.
    func testInputFrameOnSubscriptionConnectionReachesPTY() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let marker = "HARNESS_INPUT_FRAME_OK"
        let echoed = expectation(description: "echo of input-frame keystrokes received")
        echoed.assertForOverFulfill = false
        let accumulator = OutputAccumulator()
        let subscription = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID) { data, _ in
            if accumulator.appendAndContains(String(decoding: data, as: UTF8.self), marker: marker) {
                echoed.fulfill()
            }
        }
        defer { subscription.cancel() }

        usleep(200_000)
        // No client.request(.sendData) here — drive input purely over the subscription fd.
        subscription.sendInput(Data("echo \(marker)\n".utf8), surfaceID: target.surfaceID)
        wait(for: [echoed], timeout: 8)
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

    /// Multi-client sizing contract (tmux `window-size smallest`): size votes ride the persistent
    /// subscription connection as binary resize frames, so (1) with two live subscribers the PTY
    /// sizes to the smallest vote, (2) an unrelated one-shot RPC resize cannot leave a stale size
    /// behind when its socket closes, and (3) cancelling the small subscriber drops its vote and
    /// the surface grows back to the remaining client's size. Regression for votes keyed to
    /// short-lived RPC fds, which collapsed the contract to last-resize-wins.
    func testResizeVotesOnSubscriptionsHoldSmallestThenGrowBack() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID
        // The LARGE subscriber doubles as the output capture so it survives the small one's cancel.
        let output = OutputAccumulator()
        let subLarge = try client.subscribeSurfaceOutput(surfaceID: sid) { data, _ in
            _ = output.appendAndContains(String(decoding: data, as: UTF8.self), marker: "")
        }
        let subSmall = try client.subscribeSurfaceOutput(surfaceID: sid) { _, _ in }
        defer { subLarge.cancel(); subSmall.cancel() }
        usleep(200_000)

        subLarge.resize(sid, rows: 50, cols: 200)
        subSmall.resize(sid, rows: 24, cols: 80)
        usleep(300_000)
        var size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 24, "smallest vote across live subscriptions must win (rows)")
        XCTAssertEqual(size?.cols, 80, "smallest vote across live subscriptions must win (cols)")

        // A one-shot RPC resize applies while its socket lives, then the vote dies with the fd —
        // the daemon must re-apply the remaining live votes, not leave the one-shot size behind.
        _ = try client.request(.resizeSurface(surfaceID: sid, rows: 10, cols: 60))
        usleep(300_000)
        size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 24, "a dead one-shot vote must not stick (rows)")
        XCTAssertEqual(size?.cols, 80, "a dead one-shot vote must not stick (cols)")

        // Dropping the small subscriber releases its vote; the surface grows back.
        subSmall.cancel()
        usleep(300_000)
        size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 50, "surface must grow back when the small client detaches (rows)")
        XCTAssertEqual(size?.cols, 200, "surface must grow back when the small client detaches (cols)")
    }

    /// `detachSurface` (per-surface release, connection stays open) must also drop the caller's
    /// size vote so the surface grows back to the remaining clients' smallest size.
    func testDetachSurfaceDropsResizeVote() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID
        let output = OutputAccumulator()
        let subLarge = try client.subscribeSurfaceOutput(surfaceID: sid) { data, _ in
            _ = output.appendAndContains(String(decoding: data, as: UTF8.self), marker: "")
        }
        let subSmall = try client.subscribeSurfaceOutput(surfaceID: sid) { _, _ in }
        defer { subLarge.cancel(); subSmall.cancel() }
        usleep(200_000)

        subLarge.resize(sid, rows: 48, cols: 190)
        subSmall.resize(sid, rows: 30, cols: 100)
        usleep(300_000)
        var size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 30)
        XCTAssertEqual(size?.cols, 100)

        subSmall.detachSurface(sid)
        usleep(300_000)
        size = try queryPTYSize(client, surfaceID: sid, output: output)
        XCTAssertEqual(size?.rows, 48, "detachSurface must release the caller's size vote (rows)")
        XCTAssertEqual(size?.cols, 190, "detachSurface must release the caller's size vote (cols)")
    }

    /// Read the PTY's actual size end-to-end: drive `echo <nonce>; stty size` through the shell
    /// and parse the first "rows cols" line after the nonce's *output* (the echoed command also
    /// contains the nonce, but followed by `;`, never a newline).
    private func queryPTYSize(
        _ client: DaemonClient,
        surfaceID: String,
        output: OutputAccumulator,
        timeout: TimeInterval = 8
    ) throws -> (rows: Int, cols: Int)? {
        let nonce = "SZQ\(UUID().uuidString.prefix(8))"
        _ = try client.request(.sendData(surfaceID: surfaceID, data: Data("echo \(nonce); stty size\n".utf8)))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = output.snapshot
            if let nonceRange = text.range(of: "\(nonce)\r\n") ?? text.range(of: "\(nonce)\n") {
                let after = text[nonceRange.upperBound...]
                // "\r\n" is a single grapheme cluster in Swift, so it must be matched as its own
                // separator Character — `== "\r"` / `== "\n"` alone never split CRLF PTY output.
                for line in after.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                    let parts = line.split(separator: " ")
                    if parts.count == 2, let rows = Int(parts[0]), let cols = Int(parts[1]) {
                        return (rows, cols)
                    }
                }
            }
            usleep(100_000)
        }
        XCTFail("stty size output did not arrive within \(timeout)s — stream so far: \(output.snapshot.suffix(600).debugDescription)")
        return nil
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

    /// Hook symmetry for long-lived subscription clients: registering a subscription must fire
    /// `client-attached`, and its disconnect must fire `client-detached`. Regression for the
    /// attach hook only firing on explicit `identifyClient` — every real client (GUI, attach,
    /// attach-window) subscribed without identifying, producing detached-without-attached.
    func testSubscriptionClientFiresAttachedAndDetachedHooks() throws {
        let client = DaemonClient()
        guard case let .surfaces(surfaces) = try client.request(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        let attachedMarker = "HOOK_CLIENT_ATTACHED_\(UUID().uuidString.prefix(8))"
        let detachedMarker = "HOOK_CLIENT_DETACHED_\(UUID().uuidString.prefix(8))"
        let attached = expectation(description: "client-attached hook fired")
        let detached = expectation(description: "client-detached hook fired")
        attached.assertForOverFulfill = false
        detached.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: NotificationBus.shared.notificationPosted, object: nil, queue: .main
        ) { note in
            guard let n = note.userInfo?["notification"] as? AgentNotification else { return }
            if n.body.contains(attachedMarker) { attached.fulfill() }
            if n.body.contains(detachedMarker) { detached.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        guard case .hookID = try client.request(.bindHook(
            event: "client-attached", source: "display-message \"\(attachedMarker)\"", condition: nil
        )) else { return XCTFail("expected hookID") }
        guard case .hookID = try client.request(.bindHook(
            event: "client-detached", source: "display-message \"\(detachedMarker)\"", condition: nil
        )) else { return XCTFail("expected hookID") }

        let subscription = try client.subscribeSurfaceOutput(surfaceID: target.surfaceID, label: "hook-test") { _, _ in }
        wait(for: [attached], timeout: 5)
        subscription.cancel()
        wait(for: [detached], timeout: 5)
    }

    /// A frame that de-frames cleanly but carries no request (a `{}` / `{"request":null}`
    /// envelope, e.g. from a newer client or schema skew) must get an explicit `.error` reply,
    /// not silence — otherwise the client blocks until its timeout. Regression for the daemon
    /// loop silently `continue`-ing on a nil request.
    func testNilRequestGetsErrorReplyNotHang() throws {
        // A synthesized-Codable optional encodes nil as an omitted key, so this frames as `{}`,
        // which the daemon decodes to `.request(nil)` — exactly the guarded path.
        var envelope = IPCEnvelope(request: .ping)
        envelope.request = nil
        let frame = try IPCCodec.encode(envelope)

        let fd = try connectRawSocket()
        defer { close(fd) }
        try writeAllRaw(frame, to: fd)

        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0 else { continue }
            let n = read(fd, &temp, temp.count)
            if n <= 0 { break }
            buffer.append(contentsOf: temp.prefix(n))
            if let reply = try IPCCodec.decodeReply(from: &buffer) {
                guard case .error = reply.response else {
                    return XCTFail("expected .error for a nil request, got \(reply.response)")
                }
                return
            }
        }
        XCTFail("daemon did not reply to a nil-request frame (silent hang)")
    }

    // MARK: - Raw-socket helpers (for malformed/edge frames the typed DaemonClient can't send)

    private enum RawSocketError: Error { case connectFailed, writeFailed }

    private func connectRawSocket() throws -> Int32 {
        let fd = makeUnixStreamSocket()
        guard fd >= 0 else { throw RawSocketError.connectFailed }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = HarnessPaths.socketURL.path
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    strncpy(dst, src, capacity - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw RawSocketError.connectFailed }
        return fd
    }

    private func writeAllRaw(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = write(fd, base + off, data.count - off)
                if n > 0 { off += n }
                else if n < 0, errno == EINTR || errno == EAGAIN { continue }
                else { throw RawSocketError.writeFailed }
            }
        }
    }
}
