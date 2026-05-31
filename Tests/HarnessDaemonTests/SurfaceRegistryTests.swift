import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Drives `SurfaceRegistry.handle(_:)` directly (no socket). Each test runs against an
/// isolated `HARNESS_HOME` temp dir so it never touches real session state. Creating a
/// registry forks the default snapshot's shell; tests don't depend on shell output.
final class SurfaceRegistryTests: XCTestCase {
    private var root: URL?
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPingReturnsPong() {
        guard case .pong = SurfaceRegistry().handle(.ping) else { return XCTFail("expected pong") }
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
}
