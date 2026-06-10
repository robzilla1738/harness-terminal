import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Drives `SurfaceRegistry.handle(_:)` directly (no socket). Each test runs against an
/// isolated `HARNESS_HOME` temp dir so it never touches real session state. Creating a
/// registry forks the default snapshot's shell; tests don't depend on shell output.
final class SurfaceRegistryTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var previousShell: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        previousShell = getenv("SHELL").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let previousShell { setenv("SHELL", previousShell, 1) } else { unsetenv("SHELL") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPingReturnsPong() {
        guard case .pong = SurfaceRegistry().handle(.ping) else { return XCTFail("expected pong") }
    }

    /// tmux `show-messages`: display-message lines accumulate in a capped ring.
    func testShowMessagesReturnsCappedLog() {
        let registry = SurfaceRegistry()
        guard case let .text(empty) = registry.handle(.showMessages) else { return XCTFail("expected text") }
        XCTAssertTrue(empty.isEmpty)
        for index in 0 ..< 55 {
            _ = registry.handle(.displayMessage(format: "msg-\(index)", print: false))
        }
        guard case let .text(log) = registry.handle(.showMessages) else { return XCTFail("expected text") }
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 50, "ring caps at 50")
        XCTAssertTrue(lines.last?.contains("msg-54") ?? false, "most recent last")
        XCTAssertFalse(log.contains("msg-0"), "oldest evicted")
    }

    /// `remain-on-exit` (default on): a naturally exited pane is retained, but its
    /// live-looking metadata must be cleared — waiting status/notification reset, agent
    /// cleared, exit status recorded — and a revival via `ensureSurface` clears the exit
    /// status again. Regression for the exit path unregistering detector state without
    /// ever touching the snapshot (stale agent/notification on a dead pane; exitStatus
    /// was dead code).
    func testRetainedDeadPaneClearsMetadataAndRecordsExitStatus() throws {
        try skipUnlessLiveDaemonTests() // depends on the spawned shell executing `exit 3`
        let registry = SurfaceRegistry()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces), let target = initial.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID

        func tab() -> Tab? {
            registry.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
                .first { $0.rootPane.allSurfaceIDs().map(\.uuidString).contains(sid) }
        }

        // Put live-looking metadata on the tab, as an agent flow would.
        _ = registry.handle(.notify(surfaceID: sid, title: "Agent", body: "Needs approval"))
        XCTAssertEqual(tab()?.status, .waiting)
        XCTAssertNotNil(tab()?.notificationText)

        // Let the shell come up, then exit with a known code.
        usleep(400_000)
        _ = registry.handle(.sendData(surfaceID: sid, data: Data("exit 3\n".utf8)))
        waitUntil(timeout: 12) { tab()?.exitStatus != nil }
        let dead = try XCTUnwrap(tab(), "retained pane should record an exit status")
        XCTAssertEqual(dead.exitStatus, 3)
        XCTAssertEqual(dead.status, .idle, "waiting status must not survive the pane's death")
        XCTAssertNil(dead.notificationText, "notification must not survive the pane's death")
        XCTAssertNil(dead.agent, "agent metadata must not survive the pane's death")

        // Revival clears the exit status.
        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: sid, cwd: NSTemporaryDirectory(), shell: nil, rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("expected ensureSurface to revive the pane") }
        XCTAssertNil(tab()?.exitStatus, "revival must clear the recorded exit status")
    }

    /// Regression (BH-009): `respawn-pane` is the canonical verb for reviving a dead
    /// `remain-on-exit` pane, but it used to hard-fail "Surface not found" because the RealPty was
    /// already dropped from `sessions` on the natural exit. It must instead recreate the surface.
    func testRespawnPaneRevivesNaturallyExitedRemainOnExitPane() throws {
        try skipUnlessLiveDaemonTests() // depends on the spawned shell executing `exit`
        let registry = SurfaceRegistry()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces), let target = initial.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID
        func tab() -> Tab? {
            registry.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
                .first { $0.rootPane.allSurfaceIDs().map(\.uuidString).contains(sid) }
        }

        func killAndAwaitDeath() -> Bool {
            usleep(400_000)
            _ = registry.handle(.sendData(surfaceID: sid, data: Data("exit 5\n".utf8)))
            return waitUntil(timeout: 12) { tab()?.exitStatus != nil }
        }

        XCTAssertTrue(killAndAwaitDeath(), "the pane must be retained with an exit status")

        // Dead-revive, keep-history path: must succeed and clear the exit status (not "Surface not found").
        guard case .ok = registry.handle(.respawnPane(surfaceID: sid, keepHistory: true)) else {
            return XCTFail("respawn-pane must revive a dead remain-on-exit pane")
        }
        XCTAssertNil(tab()?.exitStatus, "respawn revival must clear the recorded exit status")

        // Kill it again, then exercise the dead-revive `-k` (clear-history) branch specifically.
        XCTAssertTrue(killAndAwaitDeath(), "the revived pane must die again on a second exit")
        guard case .ok = registry.handle(.respawnPane(surfaceID: sid, keepHistory: false)) else {
            return XCTFail("respawn-pane -k must revive a dead pane (clearing history)")
        }
        XCTAssertNil(tab()?.exitStatus, "respawn -k revival must clear the recorded exit status")
    }

    /// Scoped option reads resolve by exact target (falling back only toward broader scopes),
    /// so a nil-target non-global option is stored but unreachable by every read path. The
    /// daemon must reject it rather than persist a dead entry.
    func testScopedSetOptionWithoutTargetIsRejected() {
        let registry = SurfaceRegistry()
        guard case .error = registry.handle(.setOption(scope: "tab", target: nil, key: "status", rawValue: "off")) else {
            return XCTFail("expected error for a nil-target scoped option")
        }
        // Global without a target and scoped WITH a target both remain accepted.
        guard case .ok = registry.handle(.setOption(scope: "global", target: nil, key: "status", rawValue: "off")) else {
            return XCTFail("expected ok for a global option")
        }
        guard case .ok = registry.handle(.setOption(scope: "tab", target: UUID().uuidString, key: "status", rawValue: "off")) else {
            return XCTFail("expected ok for a targeted tab option")
        }
    }

    func testRevisionMatchesSnapshotAndAdvancesOnMutation() {
        let registry = SurfaceRegistry()
        // The lightweight accessor must agree with the full snapshot's revision...
        XCTAssertEqual(registry.revision, registry.snapshot.revision)
        let before = registry.revision
        let wsID = registry.snapshot.activeWorkspaceID!
        guard case .tabID = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }
        // ...and advance after a mutating commit, still matching the snapshot.
        XCTAssertGreaterThan(registry.revision, before)
        XCTAssertEqual(registry.revision, registry.snapshot.revision)
    }

    func testSurfaceTelemetryMatchesListSurfacesAndTracksNewSurfaces() {
        let registry = SurfaceRegistry()
        guard case let .surfaces(before) = registry.handle(.listSurfaces) else {
            return XCTFail("expected surfaces")
        }
        // surfaceCount (summed off-lock after a ref snapshot) agrees with listSurfaces;
        // scrollback bytes are a non-negative aggregate.
        XCTAssertEqual(registry.surfaceTelemetry.surfaceCount, before.count)
        XCTAssertGreaterThanOrEqual(registry.surfaceTelemetry.scrollbackBytes, 0)

        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))
        guard case let .surfaces(after) = registry.handle(.listSurfaces) else {
            return XCTFail("expected surfaces")
        }
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(registry.surfaceTelemetry.surfaceCount, after.count)
    }

    /// A surface created via `ensureSurface` — the path the quick-terminal dropdown (and any
    /// host-driven reserved surface) uses — must be LIVE (capturable, counted in `listSurfaces`)
    /// yet stay entirely OUT of the persisted workspace→session→tab→pane layout, and must NOT
    /// bump the layout revision. The quick terminal reuses a fixed reserved ID it never attaches
    /// to a tab; were `ensureSurface` to insert it into the layout it would leak into the sidebar
    /// and, never attached, never be reaped. (Invariant salvaged from the abandoned pr21b
    /// explicit-IPC branch, adapted to main's host-internal `ensureSurface` mechanism.)
    func testEnsureSurfaceCreatesLiveSurfaceOutsideTheLayout() {
        let registry = SurfaceRegistry()
        let reserved = "00000000-0000-0000-0000-000000000021"
        let revisionBefore = registry.revision

        guard case .ok = registry.handle(.ensureSurface(
            surfaceID: reserved, cwd: "/tmp", shell: nil, rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface should report ok") }

        // Live: the daemon holds a PTY session for it (capture reads the `sessions` map and
        // returns text, not "Surface not found"), even though it is absent from the
        // layout-derived `listSurfaces`/`SurfaceSummary` view.
        guard case .text = registry.handle(.capturePane(surfaceID: reserved, includeScrollback: false)) else {
            return XCTFail("the ensured surface must be live/capturable")
        }

        // Out of layout: it appears in no pane of any workspace/session/tab.
        let layoutSurfaceIDs = registry.snapshot.workspaces
            .flatMap(\.sessions)
            .flatMap(\.tabs)
            .flatMap { $0.rootPane.allSurfaceIDs() }
            .map(\.uuidString)
        XCTAssertFalse(layoutSurfaceIDs.contains(reserved),
                       "the ensured surface must never enter the persisted layout")

        // A layout-detached ensure is not a layout mutation → it must not bump the revision
        // (distinguishing it from newTab/newSplit, which do).
        XCTAssertEqual(registry.revision, revisionBefore,
                       "ensureSurface of a detached surface must not bump the layout revision")
    }

    func testNewWorkspaceTabAndSelectMutateSnapshotAndBumpRevision() {
        let registry = SurfaceRegistry()
        let startRevision = registry.snapshot.revision

        guard case let .workspaceID(wsID) = registry.handle(.newWorkspace(name: "api")) else {
            return XCTFail("expected workspaceID")
        }
        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp")) else {
            return XCTFail("expected tabID")
        }
        guard case .ok = registry.handle(.selectTab(workspaceID: wsID, tabID: tabID)) else {
            return XCTFail("expected ok")
        }

        XCTAssertTrue(registry.snapshot.workspaces.contains { $0.id == wsID })
        XCTAssertEqual(registry.snapshot.activeWorkspaceID, wsID)
        XCTAssertGreaterThan(registry.snapshot.revision, startRevision)
    }

    /// Layout writes are now debounced (off the per-mutation critical path), so a graceful shutdown
    /// must flush the latest snapshot synchronously — otherwise the last debounce window of layout
    /// changes would be lost on restart. `flushSnapshot()` is the path `DaemonServer.stop()` calls.
    func testFlushSnapshotPersistsLatestLayoutSynchronously() {
        let registry = SurfaceRegistry()
        guard case let .workspaceID(wsID) = registry.handle(.newWorkspace(name: "flush-me")) else {
            return XCTFail("expected workspaceID")
        }
        registry.flushSnapshot()
        let reloaded = SessionStore().load()
        XCTAssertTrue(reloaded.workspaces.contains { $0.id == wsID && $0.name == "flush-me" },
                      "flushSnapshot must persist the latest layout for a graceful restart")
    }

    func testNewTabUsesConfiguredShellWhenProvided() throws {
        let registry = SurfaceRegistry()
        let fish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        let wsID = registry.snapshot.activeWorkspaceID!

        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp", shell: fish.path)) else {
            return XCTFail("expected tabID")
        }

        let surfaceID = try XCTUnwrap(firstSurfaceID(for: tabID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), fish.path)
        XCTAssertEqual(ShellLaunchProfile.make(shell: fish.path).arguments, ["--features=no-query-term", "-l"])
    }

    func testNewSessionUsesConfiguredShellWhenProvided() throws {
        let registry = SurfaceRegistry()
        let fish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        let wsID = registry.snapshot.activeWorkspaceID!

        guard case let .sessionID(sessionID) = registry.handle(.newSession(workspaceID: wsID, cwd: "/tmp", name: "fish", shell: fish.path)) else {
            return XCTFail("expected sessionID")
        }

        let surfaceID = try XCTUnwrap(firstSurfaceID(forSession: sessionID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), fish.path)
        XCTAssertEqual(ShellLaunchProfile.make(shell: fish.path).arguments, ["--features=no-query-term", "-l"])
    }

    func testNewTabInWorkspaceUsesConfiguredShellWhenProvided() throws {
        let registry = SurfaceRegistry()
        let fish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        let workspaceName = try XCTUnwrap(registry.snapshot.activeWorkspace?.name)

        guard case let .tabID(tabID) = registry.handle(.newTabInWorkspace(named: workspaceName, cwd: "/tmp", shell: fish.path)) else {
            return XCTFail("expected tabID")
        }

        let surfaceID = try XCTUnwrap(firstSurfaceID(for: tabID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), fish.path)
        XCTAssertEqual(ShellLaunchProfile.make(shell: fish.path).arguments, ["--features=no-query-term", "-l"])
    }

    func testNewSplitUsesConfiguredShellWhenProvided() throws {
        let registry = SurfaceRegistry()
        let fish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        let tab = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        let paneID = try XCTUnwrap(tab.rootPane.allPaneIDs().first)

        guard case let .paneID(newPaneID) = registry.handle(.newSplit(tabID: tab.id, paneID: paneID, direction: .vertical, shell: fish.path)) else {
            return XCTFail("expected paneID")
        }

        let surfaceID = try XCTUnwrap(surfaceID(forPaneID: newPaneID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), fish.path)
        XCTAssertEqual(ShellLaunchProfile.make(shell: fish.path).arguments, ["--features=no-query-term", "-l"])
    }

    func testInvalidConfiguredSplitShellFallsBackToExecutableShell() throws {
        let registry = SurfaceRegistry()
        let invalidShell = "/tmp/harness-missing-split-shell-\(UUID().uuidString)"
        let tab = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        let paneID = try XCTUnwrap(tab.rootPane.allPaneIDs().first)

        guard case let .paneID(newPaneID) = registry.handle(.newSplit(tabID: tab.id, paneID: paneID, direction: .vertical, shell: invalidShell)) else {
            return XCTFail("expected paneID")
        }

        let surfaceID = try XCTUnwrap(surfaceID(forPaneID: newPaneID, in: registry.snapshot))
        let launchedShell = try XCTUnwrap(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString))
        XCTAssertNotEqual(launchedShell, invalidShell)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launchedShell))
    }

    func testInvalidConfiguredShellFallsBackToExecutableShell() throws {
        let registry = SurfaceRegistry()
        let invalidShell = "/tmp/harness-missing-shell-\(UUID().uuidString)"
        let wsID = registry.snapshot.activeWorkspaceID!

        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp", shell: invalidShell)) else {
            return XCTFail("expected tabID")
        }

        let surfaceID = try XCTUnwrap(firstSurfaceID(for: tabID, in: registry.snapshot))
        let launchedShell = try XCTUnwrap(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString))
        XCTAssertNotEqual(launchedShell, invalidShell)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launchedShell))
    }

    func testColdStartUsesPersistedDefaultShellBeforeDaemonShell() throws {
        let daemonShell = try makeExecutable(named: "daemon-zsh", contents: "#!/bin/sh\nsleep 2\n")
        let defaultFish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        setenv("SHELL", daemonShell.path, 1)
        try saveSettings(defaultShell: defaultFish.path)

        let registry = SurfaceRegistry()

        let surfaceID = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs().first)
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), defaultFish.path)
    }

    func testNilAndEmptyShellIPCSurfacesUsePersistedDefaultShell() throws {
        let daemonShell = try makeExecutable(named: "daemon-zsh", contents: "#!/bin/sh\nsleep 2\n")
        let defaultFish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        setenv("SHELL", daemonShell.path, 1)
        try saveSettings(defaultShell: defaultFish.path)
        let registry = SurfaceRegistry()

        guard case let .surfaceID(nilShellSurfaceID) = registry.handle(.createSurface(cwd: "/tmp", shell: nil)) else {
            return XCTFail("expected surfaceID")
        }
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: nilShellSurfaceID), defaultFish.path)

        let emptyShellSurfaceID = UUID().uuidString
        guard case .ok = registry.handle(.ensureSurface(surfaceID: emptyShellSurfaceID, cwd: "/tmp", shell: "", rows: 24, cols: 80, scrollbackBytes: nil)) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: emptyShellSurfaceID), defaultFish.path)
    }

    func testRestoredSnapshotSurfacesUsePersistedDefaultShell() throws {
        let daemonShell = try makeExecutable(named: "daemon-zsh", contents: "#!/bin/sh\nsleep 2\n")
        let defaultFish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        setenv("SHELL", daemonShell.path, 1)
        try saveSettings(defaultShell: defaultFish.path)

        let firstTab = Tab(cwd: "/tmp")
        let secondTab = Tab(cwd: "/tmp")
        let session = SessionGroup(tabs: [firstTab, secondTab], activeTabID: firstTab.id)
        let workspace = Workspace(name: "restored", sessions: [session], activeSessionID: session.id)
        try SessionStore().saveImmediately(SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id))

        let registry = SurfaceRegistry()

        for surfaceID in [firstTab, secondTab].flatMap({ $0.rootPane.allSurfaceIDs() }) {
            XCTAssertEqual(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString), defaultFish.path)
        }
    }

    func testExplicitShellIPCSurfacesAreNotReplacedByPersistedDefaultShell() throws {
        let daemonShell = try makeExecutable(named: "daemon-zsh", contents: "#!/bin/sh\nsleep 2\n")
        let defaultFish = try makeExecutable(named: "fish", contents: "#!/bin/sh\nsleep 2\n")
        let explicitShell = try makeExecutable(named: "explicit-shell", contents: "#!/bin/sh\nsleep 2\n")
        setenv("SHELL", daemonShell.path, 1)
        try saveSettings(defaultShell: defaultFish.path)
        let registry = SurfaceRegistry()
        let wsID = try XCTUnwrap(registry.snapshot.activeWorkspaceID)

        guard case let .tabID(tabID) = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp", shell: explicitShell.path)) else {
            return XCTFail("expected tabID")
        }
        let tabSurfaceID = try XCTUnwrap(firstSurfaceID(for: tabID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: tabSurfaceID.uuidString), explicitShell.path)

        guard case let .sessionID(sessionID) = registry.handle(.newSession(workspaceID: wsID, cwd: "/tmp", name: "explicit", shell: explicitShell.path)) else {
            return XCTFail("expected sessionID")
        }
        let sessionSurfaceID = try XCTUnwrap(firstSurfaceID(forSession: sessionID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: sessionSurfaceID.uuidString), explicitShell.path)

        let tab = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab)
        let paneID = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        guard case let .paneID(newPaneID) = registry.handle(.newSplit(tabID: tab.id, paneID: paneID, direction: .vertical, shell: explicitShell.path)) else {
            return XCTFail("expected paneID")
        }
        let splitSurfaceID = try XCTUnwrap(surfaceID(forPaneID: newPaneID, in: registry.snapshot))
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: splitSurfaceID.uuidString), explicitShell.path)

        guard case let .surfaceID(createdSurfaceID) = registry.handle(.createSurface(cwd: "/tmp", shell: explicitShell.path)) else {
            return XCTFail("expected surfaceID")
        }
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: createdSurfaceID), explicitShell.path)

        let ensuredSurfaceID = UUID().uuidString
        guard case .ok = registry.handle(.ensureSurface(surfaceID: ensuredSurfaceID, cwd: "/tmp", shell: explicitShell.path, rows: 24, cols: 80, scrollbackBytes: nil)) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(registry.launchedShellForTesting(surfaceID: ensuredSurfaceID), explicitShell.path)
    }

    func testInvalidPersistedDefaultShellFallsBackToDaemonShellForColdStart() throws {
        let daemonShell = try makeExecutable(named: "daemon-zsh", contents: "#!/bin/sh\nsleep 2\n")
        let invalidDefaultShell = try XCTUnwrap(root).appendingPathComponent("missing-default-shell")
        setenv("SHELL", daemonShell.path, 1)
        try saveSettings(defaultShell: invalidDefaultShell.path)

        let registry = SurfaceRegistry()

        let surfaceID = try XCTUnwrap(registry.snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs().first)
        let launchedShell = try XCTUnwrap(registry.launchedShellForTesting(surfaceID: surfaceID.uuidString))
        XCTAssertEqual(launchedShell, daemonShell.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launchedShell))
    }

    func testNotifyMarksExactlyOneTabWaiting() {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp"))

        guard case let .surfaces(surfaces) = registry.handle(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected at least one surface")
        }
        guard case .ok = registry.handle(.notify(surfaceID: target.surfaceID, title: "Agent", body: "Approve?")) else {
            return XCTFail("expected ok")
        }

        let waiting = registry.snapshot.workspaces
            .flatMap { $0.sessions.flatMap(\.tabs) }
            .filter { $0.status == .waiting }
        XCTAssertEqual(waiting.count, 1, "notify must mark exactly the one matching tab")
    }

    private func makeExecutable(named name: String, contents: String) throws -> URL {
        let directory = try XCTUnwrap(root).appendingPathComponent("bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func saveSettings(defaultShell: String) throws {
        var settings = HarnessSettings(defaultShell: defaultShell)
        settings.customBackgroundHex = "#000000"
        settings.importedConfigSignature = TerminalConfigImporter.load()?.signature
        try settings.save()
    }

    private func surfaceID(forPaneID paneID: PaneID, in snapshot: SessionSnapshot) -> SurfaceID? {
        snapshot.workspaces
            .flatMap { $0.sessions.flatMap(\.tabs) }
            .flatMap { $0.rootPane.allLeaves() }
            .first { $0.id == paneID }?
            .surfaceID
    }

    private func firstSurfaceID(for tabID: TabID, in snapshot: SessionSnapshot) -> SurfaceID? {
        snapshot.workspaces
            .flatMap { $0.sessions.flatMap(\.tabs) }
            .first { $0.id == tabID }?
            .rootPane
            .allSurfaceIDs()
            .first
    }

    private func firstSurfaceID(forSession sessionID: SessionID, in snapshot: SessionSnapshot) -> SurfaceID? {
        snapshot.workspaces
            .flatMap(\.sessions)
            .first { $0.id == sessionID }?
            .tabs
            .first?
            .rootPane
            .allSurfaceIDs()
            .first
    }

    func testReorderTabViaHandleReordersWithinSession() {
        let registry = SurfaceRegistry()
        let wsID = registry.snapshot.activeWorkspaceID!
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp/a"))
        _ = registry.handle(.newTab(workspaceID: wsID, cwd: "/tmp/b"))

        let tabs = registry.snapshot.activeWorkspace!.activeSession!.tabs
        XCTAssertEqual(tabs.count, 3)
        let firstID = tabs[0].id

        guard case .ok = registry.handle(.reorderTab(workspaceID: wsID, tabID: firstID, toIndex: 2)) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(registry.snapshot.activeWorkspace?.activeSession?.tabs.last?.id, firstID)
    }

    func testUnknownTabReturnsError() {
        guard case .error = SurfaceRegistry().handle(.selectTab(workspaceID: UUID(), tabID: UUID())) else {
            return XCTFail("expected error for unknown tab")
        }
    }

    func testListSurfacesMapsSnapshot() {
        let registry = SurfaceRegistry()
        guard case let .surfaces(surfaces) = registry.handle(.listSurfaces) else {
            return XCTFail("expected surfaces")
        }
        XCTAssertFalse(surfaces.isEmpty)
        let snapshotSurfaces = registry.snapshot.workspaces
            .flatMap { $0.sessions.flatMap { $0.tabs.flatMap { $0.rootPane.allSurfaceIDs() } } }
            .map(\.uuidString)
        XCTAssertEqual(Set(surfaces.map(\.surfaceID)), Set(snapshotSurfaces))
    }

    // MARK: - list-agents request/response

    func testListAgentsIsEmptyUntilAnAgentIsDetected() {
        let registry = SurfaceRegistry()
        guard case let .agents(agents) = registry.handle(.listAgents) else {
            return XCTFail("expected agents")
        }
        XCTAssertTrue(agents.isEmpty, "no agents until the scanner reports one")
    }

    func testListAgentsReflectsAppliedAgentChange() {
        let registry = SurfaceRegistry()
        guard case let .surfaces(surfaces) = registry.handle(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        // Drive the same path the AgentScanner uses to write agent state into the snapshot.
        registry.applyAgentChanges([
            target.surfaceID: AgentSnapshot(kind: .claudeCode, executable: "/bin/claude", pid: 99, activity: .working),
        ])

        guard case let .agents(agents) = registry.handle(.listAgents) else {
            return XCTFail("expected agents")
        }
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].kind, .claudeCode)
        XCTAssertEqual(agents[0].activity, .working)
        XCTAssertEqual(agents[0].surfaceID, target.surfaceID)
        XCTAssertFalse(agents[0].waiting, "a working agent that hasn't notified is not waiting")
    }

    func testNotifyFlipsAgentWaitingInListAgents() {
        let registry = SurfaceRegistry()
        guard case let .surfaces(surfaces) = registry.handle(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        registry.applyAgentChanges([
            target.surfaceID: AgentSnapshot(kind: .codex, executable: "/bin/codex", pid: 7, activity: .awaiting),
        ])
        guard case .ok = registry.handle(.notify(surfaceID: target.surfaceID, title: "Codex", body: "Approve?")) else {
            return XCTFail("expected ok")
        }

        guard case let .agents(agents) = registry.handle(.listAgents) else {
            return XCTFail("expected agents")
        }
        XCTAssertEqual(agents.count, 1)
        XCTAssertTrue(agents[0].waiting, "notify marks the tab .waiting, which must surface as waiting")
        XCTAssertEqual(agents[0].notificationText, "Approve?")
    }

    func testTransitionToWorkingClearsStaleWaitingStatus() {
        let registry = SurfaceRegistry()
        guard case let .surfaces(surfaces) = registry.handle(.listSurfaces), let target = surfaces.first else {
            return XCTFail("expected a default surface")
        }
        // Agent stops and notifies → tab goes .waiting (the stop-hook path).
        registry.applyAgentChanges([
            target.surfaceID: AgentSnapshot(kind: .codex, executable: "/bin/codex", pid: 7, activity: .idle),
        ])
        guard case .ok = registry.handle(.notify(surfaceID: target.surfaceID, title: "Codex", body: "Done")) else {
            return XCTFail("expected ok")
        }
        XCTAssertEqual(statusOfTab(backing: target.surfaceID, in: registry), .waiting)

        // The agent starts a new turn (idle → working): the stale waiting must clear,
        // otherwise it suppresses the tab's working indicator for the whole turn.
        registry.applyAgentChanges([
            target.surfaceID: AgentSnapshot(kind: .codex, executable: "/bin/codex", pid: 7, activity: .working),
        ])
        XCTAssertEqual(statusOfTab(backing: target.surfaceID, in: registry), .idle)

        // A steady working stream must not keep rewriting the status.
        registry.applyAgentChanges([
            target.surfaceID: AgentSnapshot(kind: .codex, executable: "/bin/codex", pid: 7, activity: .working),
        ])
        XCTAssertEqual(statusOfTab(backing: target.surfaceID, in: registry), .idle)
    }

    private func statusOfTab(backing surfaceID: String, in registry: SurfaceRegistry) -> TabStatus? {
        guard let uuid = UUID(uuidString: surfaceID) else { return nil }
        return registry.snapshot.workspaces
            .flatMap { $0.sessions.flatMap(\.tabs) }
            .first { $0.rootPane.allSurfaceIDs().contains(uuid) }?
            .status
    }

    // MARK: - Off-lock metadata refresh (item 3)

    /// After moving the cwd probe off the registry lock, `refreshSurfaceMetadata` must still
    /// update a tab's cwd to the live shell's working directory. Live-gated: it needs the
    /// spawned shell to actually `cd` and `proc_pidinfo` to read its cwd.
    func testRefreshSurfaceMetadataUpdatesTabCwd() throws {
        try skipUnlessLiveDaemonTests()
        let registry = SurfaceRegistry()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces), let target = initial.first else {
            return XCTFail("expected a default surface")
        }
        let sid = target.surfaceID

        func tabCwd() -> String? {
            registry.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
                .first { $0.rootPane.allSurfaceIDs().map(\.uuidString).contains(sid) }?
                .cwd
        }

        // Drive the live shell into a known directory, then refresh and observe the new cwd.
        let dest = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true
        )
        defer { try? FileManager.default.removeItem(at: dest) }
        let canonicalDest = dest.resolvingSymlinksInPath().path
        usleep(400_000) // let the shell come up
        // Single-quote the path: on Linux, corelibs-foundation's itemReplacementDirectory is named
        // "(A Document Being Saved By …)" — spaces and parens are a bash syntax error unquoted.
        _ = registry.handle(.sendData(surfaceID: sid, data: Data("cd '\(canonicalDest)'\n".utf8)))

        let updated = waitUntil(timeout: 10) {
            registry.refreshSurfaceMetadata()
            return tabCwd().map { ($0 as NSString).resolvingSymlinksInPath } == canonicalDest
        }
        XCTAssertTrue(updated, "off-lock refresh must still propagate the live shell's cwd to the tab")
    }

    /// Closing a session must drop its per-session environment so entries don't accumulate in
    /// environment.json forever. Regression for the close paths never calling `clearSession`.
    func testCloseSessionClearsPerSessionEnvironment() throws {
        let registry = SurfaceRegistry()
        let wsID = try XCTUnwrap(registry.snapshot.activeWorkspaceID)
        guard case let .sessionID(sessionID) = registry.handle(
            .newSession(workspaceID: wsID, cwd: "/tmp", name: "env-test", shell: nil)
        ) else { return XCTFail("expected a new session") }

        // Seed a per-session variable.
        guard case .ok = registry.handle(.setEnvironment(sessionID: sessionID, key: "API_KEY", value: "secret")) else {
            return XCTFail("expected set-environment to succeed")
        }
        XCTAssertEqual(registry.environmentStore.resolved(sessionID: sessionID.uuidString)["API_KEY"], "secret")

        // Closing the session must clear its map.
        guard case .ok = registry.handle(.closeSession(sessionID: sessionID)) else {
            return XCTFail("expected close-session to succeed")
        }
        XCTAssertNil(
            registry.environmentStore.resolved(sessionID: sessionID.uuidString)["API_KEY"],
            "a closed session's per-session env must not survive in environment.json"
        )
        XCTAssertTrue(
            registry.environmentStore.entries(sessionID: sessionID.uuidString)
                .allSatisfy { $0.scope != "session" },
            "no per-session entries should remain after the session is closed"
        )
    }

    /// Closing a workspace must clear the per-session environment of every session it held.
    func testCloseWorkspaceClearsPerSessionEnvironment() throws {
        let registry = SurfaceRegistry()
        guard case let .workspaceID(wsID) = registry.handle(.newWorkspace(name: "Env WS")) else {
            return XCTFail("expected a new workspace")
        }
        guard case let .sessionID(sessionID) = registry.handle(
            .newSession(workspaceID: wsID, cwd: "/tmp", name: "ws-env", shell: nil)
        ) else { return XCTFail("expected a new session") }

        guard case .ok = registry.handle(.setEnvironment(sessionID: sessionID, key: "WS_VAR", value: "v")) else {
            return XCTFail("expected set-environment to succeed")
        }
        XCTAssertEqual(registry.environmentStore.resolved(sessionID: sessionID.uuidString)["WS_VAR"], "v")

        guard case .ok = registry.handle(.closeWorkspace(id: wsID)) else {
            return XCTFail("expected close-workspace to succeed")
        }
        XCTAssertNil(
            registry.environmentStore.resolved(sessionID: sessionID.uuidString)["WS_VAR"],
            "closing a workspace must clear every member session's per-session env"
        )
    }

    // MARK: - Orphan-scrollback sweep safety (item 5)

    /// On startup the sweep must keep a `.scroll` file whose surface is referenced by the layout
    /// (even one whose PTY failed to spawn) and delete a `.scroll` whose UUID isn't in the layout.
    func testScrollbackSweepKeepsReferencedDeletesOrphan() throws {
        // Seed a layout that references one surface, plus an unrelated orphan UUID.
        let referencedSurface = UUID()
        let leaf = PaneLeaf(surfaceID: referencedSurface)
        let tab = Tab(rootPane: .leaf(leaf))
        let snapshot = SessionSnapshot(workspaces: [Workspace(sessions: [SessionGroup(tabs: [tab])])])
        try SessionStore().saveImmediately(snapshot)

        // Write a scroll file for the referenced surface AND a genuine orphan.
        let referencedFile = HarnessPaths.scrollbackFileURL(forSurfaceID: referencedSurface.uuidString)
        let orphanFile = HarnessPaths.scrollbackFileURL(forSurfaceID: UUID().uuidString)
        try Data("history".utf8).write(to: referencedFile)
        try Data("orphan".utf8).write(to: orphanFile)

        // Constructing the registry runs `cleanupOrphanScrollbackFiles` in init.
        let registry = SurfaceRegistry()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: referencedFile.path),
            "a layout-referenced surface's scrollback must survive the startup sweep"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanFile.path),
            "a scrollback file for a UUID absent from the layout is a genuine orphan and must be deleted"
        )

        // The live set must include the layout-referenced surface via the snapshot half of the
        // union — the property that protects a failed-to-spawn surface (in layout, not in sessions).
        XCTAssertTrue(registry.scrollbackLiveSurfaceKeys().contains(referencedSurface.uuidString))
    }

    // MARK: - Monitor tick idle precheck (idle efficiency)

    /// A quiet monitor tick (no fresh output/bell, silence disarmed) must skip the full pass —
    /// no registry lock, no option reads. Ticks are driven by hand after cancelling the real
    /// timer; counts are compared relatively so an in-flight timer tick can't skew them (it
    /// would be a quiet tick itself and is skipped identically).
    func testQuietMonitorTickSkipsFullPass() throws {
        let registry = SurfaceRegistry()
        registry.stopMonitoring()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces),
              let target = initial.first else { return XCTFail("expected a default surface") }

        // Fresh output: the tick takes the full pass (drain + registry lock).
        registry.noteSurfaceOutputForTesting(surfaceKey: target.surfaceID, data: Data("hello".utf8))
        registry.processMonitorsForTesting()
        let afterFresh = registry.monitorFullPassCountForTesting
        XCTAssertGreaterThanOrEqual(afterFresh, 1, "a tick with fresh output must process")

        // Quiet ticks: skipped entirely, even though the monitor entry persists.
        registry.processMonitorsForTesting()
        registry.processMonitorsForTesting()
        XCTAssertEqual(registry.monitorFullPassCountForTesting, afterFresh,
                       "quiet ticks must not take the full pass")
        XCTAssertTrue(registry.monitorEntryKeysForTesting.contains(target.surfaceID),
                      "the persistent per-surface entry alone must not force full passes")
    }

    /// Arming `monitor-silence` via the real `setOption` path must restore per-tick full
    /// passes (silence needs idle evaluation with no fresh output); disarming stops them.
    func testSilenceArmedTransitionGatesFullPasses() throws {
        let registry = SurfaceRegistry()
        registry.stopMonitoring()
        guard case let .surfaces(initial) = registry.handle(.listSurfaces),
              initial.first != nil else { return XCTFail("expected a default surface") }

        registry.processMonitorsForTesting()
        let base = registry.monitorFullPassCountForTesting

        guard case .ok = registry.handle(.setOption(scope: "global", target: nil, key: "monitor-silence", rawValue: "5"))
        else { return XCTFail("setOption failed") }
        registry.processMonitorsForTesting()
        XCTAssertEqual(registry.monitorFullPassCountForTesting, base + 1,
                       "an armed silence monitor needs the full pass every tick")

        guard case .ok = registry.handle(.setOption(scope: "global", target: nil, key: "monitor-silence", rawValue: "0"))
        else { return XCTFail("setOption failed") }
        registry.processMonitorsForTesting()
        XCTAssertEqual(registry.monitorFullPassCountForTesting, base + 1,
                       "disarming must return quiet ticks to the skip path")
    }

    /// The orphan sweep survives the precheck: an entry recreated by a PTY read racing a
    /// close is born with `sawOutput = true`, so the very next tick takes the full pass and
    /// evicts it — `monitors` can't accumulate dead-surface keys.
    func testOrphanMonitorEntryIsSweptDespitePrecheck() throws {
        let registry = SurfaceRegistry()
        registry.stopMonitoring()
        let deadKey = UUID().uuidString // no tab anywhere for this key
        registry.noteSurfaceOutputForTesting(surfaceKey: deadKey, data: Data("x".utf8))
        XCTAssertTrue(registry.monitorEntryKeysForTesting.contains(deadKey))

        registry.processMonitorsForTesting() // fresh flag → full pass → sweep
        XCTAssertFalse(registry.monitorEntryKeysForTesting.contains(deadKey),
                       "the racing-read orphan must be evicted on the next tick")
    }
}
