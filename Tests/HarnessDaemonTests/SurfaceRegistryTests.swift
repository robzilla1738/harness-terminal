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
        var deadTab: Tab?
        for _ in 0 ..< 100 {
            if let candidate = tab(), candidate.exitStatus != nil { deadTab = candidate; break }
            usleep(100_000)
        }
        let dead = try XCTUnwrap(deadTab, "retained pane should record an exit status")
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
}
