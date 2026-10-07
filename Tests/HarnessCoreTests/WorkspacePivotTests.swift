import XCTest
import HarnessCore

final class WorkspacePivotTests: XCTestCase {
    func testOwnerSizeIgnoresNonOwnerAndTakeHandsOffOnDisconnect() {
        var arbiter = SurfaceSizeArbiter(mode: .owner)
        let owner = arbiter.vote(client: 1, surface: "s", rows: 40, cols: 120)
        XCTAssertEqual(owner, SurfaceSize(rows: 40, cols: 120))

        let viewer = arbiter.vote(client: 2, surface: "s", rows: 10, cols: 40)
        XCTAssertNil(viewer, "a non-owner vote must not resize")
        XCTAssertEqual(arbiter.effectiveSize("s"), SurfaceSize(rows: 40, cols: 120))

        let taken = arbiter.take(client: 2, surface: "s")
        XCTAssertTrue(taken.ownershipChanged)
        XCTAssertEqual(taken.size, SurfaceSize(rows: 10, cols: 40))
        XCTAssertEqual(arbiter.owner(of: "s"), 2)
        XCTAssertFalse(arbiter.take(client: 2, surface: "s").ownershipChanged)

        // Client 1 votes again, so they are the most recent requester, then the owner leaves.
        XCTAssertNil(arbiter.vote(client: 1, surface: "s", rows: 40, cols: 120))
        let handed = arbiter.disconnect(client: 2)
        XCTAssertEqual(handed["s"], SurfaceSize(rows: 40, cols: 120))
        XCTAssertEqual(arbiter.owner(of: "s"), 1)
    }

    func testSmallestClientModeStillWins() {
        var arbiter = SurfaceSizeArbiter(mode: .smallest)
        XCTAssertEqual(arbiter.vote(client: 1, surface: "s", rows: 50, cols: 200), SurfaceSize(rows: 50, cols: 200))
        XCTAssertEqual(arbiter.vote(client: 2, surface: "s", rows: 24, cols: 80), SurfaceSize(rows: 24, cols: 80))
        XCTAssertFalse(arbiter.take(client: 1, surface: "s").ownershipChanged)
        XCTAssertEqual(arbiter.effectiveSize("s"), SurfaceSize(rows: 24, cols: 80))
        let grown = arbiter.disconnect(client: 2)
        XCTAssertEqual(grown["s"], SurfaceSize(rows: 50, cols: 200))
    }

    func testOverviewOpenAndRefreshDoNotResize() {
        let split = PaneNode.branch(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(PaneLeaf()),
            second: .leaf(PaneLeaf())
        )
        let tab = Tab(title: "work", cwd: "/repo", rootPane: split, currentCommand: "claude")
        let session = SessionGroup(name: "dev", tabs: [tab])
        let snapshot = SessionSnapshot(workspaces: [Workspace(name: "Default", sessions: [session])])

        var overview = WorkspaceOverview(rows: 48, cols: 160)
        overview.open(tabs: WorkspaceOverviewBuilder.tabs(from: snapshot))
        overview.refresh(tabs: WorkspaceOverviewBuilder.tabs(from: snapshot))
        WorkspaceOverviewBuilder.toggle(&overview, snapshot: snapshot)

        XCTAssertEqual(overview.resizeCount, 0)
        XCTAssertEqual(overview.rows, 48)
        XCTAssertEqual(overview.cols, 160)
        XCTAssertEqual(overview.tabs.count, 1)
        XCTAssertEqual(overview.tabs[0].panes.count, 2, "split layouts are visible")
        XCTAssertTrue(overview.tabs[0].panes.allSatisfy { $0.liveText.contains("claude") })
    }

    func testNamedLayoutRoundTripAndRestorePlan() throws {
        let split = PaneNode.branch(
            direction: .horizontal,
            ratio: 0.4,
            first: .leaf(PaneLeaf(surfaceID: UUID())),
            second: .leaf(PaneLeaf(surfaceID: UUID()))
        )
        let tab = Tab(title: "edit", cwd: "/work", rootPane: split, currentCommand: "nvim")
        let layout = NamedLayoutStore.capture(name: "Edit", tab: tab, programs: [:])
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try NamedLayoutStore.save(layout, directory: directory)
        let loaded = try NamedLayoutStore.load(name: "Edit", directory: directory)
        XCTAssertEqual(loaded, layout)
        let plan = NamedLayoutStore.restorePlan(loaded)
        XCTAssertEqual(plan.count, 2)
        guard case let .session(_, cwd, program) = plan[0] else { return XCTFail("first step opens the session") }
        XCTAssertEqual(cwd, "/work")
        XCTAssertEqual(program, "nvim")
        guard case let .split(target, direction, ratio, splitCwd, _) = plan[1] else { return XCTFail("second step is a split") }
        XCTAssertEqual(target, 0)
        XCTAssertEqual(direction, .horizontal)
        XCTAssertEqual(ratio, 0.4)
        XCTAssertEqual(splitCwd, "/work")
        try? FileManager.default.removeItem(at: directory)
    }

    func testLayoutApplySendsEachPaneProgramDirectoryAndRatio() throws {
        let first = PaneLeaf()
        let second = PaneLeaf()
        let tab = Tab(
            title: "edit",
            cwd: "/fallback",
            rootPane: .branch(direction: .horizontal, ratio: 0.35, first: .leaf(first), second: .leaf(second)),
            currentCommand: "shell"
        )
        let layout = NamedLayoutStore.capture(
            name: "Edit",
            tab: tab,
            programs: [
                first.surfaceID.uuidString: "nvim",
                second.surfaceID.uuidString: "lazygit",
            ],
            cwds: [
                first.surfaceID.uuidString: "/src",
                second.surfaceID.uuidString: "/tests",
            ]
        )
        let plan = NamedLayoutStore.restorePlan(layout)
        let workspaceID = UUID()
        let sessionID = UUID()
        let tabID = UUID()
        let rootPane = UUID()
        let rootSurface = UUID()
        let newPane = UUID()
        let newSurface = UUID()
        var requests: [IPCRequest] = []
        var created = false
        try LayoutApplication.apply(plan: plan, workspaceID: workspaceID) { request in
            requests.append(request)
            switch request {
            case .newSession:
                return .sessionID(sessionID)
            case .getSnapshot where !created:
                let leaf = PaneLeaf(id: rootPane, surfaceID: rootSurface)
                let snapTab = Tab(id: tabID, cwd: "/src", rootPane: .leaf(leaf))
                let session = SessionGroup(id: sessionID, tabs: [snapTab])
                return .snapshot(SessionSnapshot(workspaces: [Workspace(sessions: [session])]))
            case .newSplit:
                created = true
                return .paneID(newPane)
            case .getSnapshot:
                let root = PaneLeaf(id: rootPane, surfaceID: rootSurface)
                let split = PaneLeaf(id: newPane, surfaceID: newSurface)
                let snapTab = Tab(
                    id: tabID,
                    cwd: "/src",
                    rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(root), second: .leaf(split))
                )
                let session = SessionGroup(id: sessionID, tabs: [snapTab])
                return .snapshot(SessionSnapshot(workspaces: [Workspace(sessions: [session])]))
            default:
                return .ok
            }
        }
        guard case let .newSplit(_, _, direction, _, cwd) = requests.first(where: {
            if case .newSplit = $0 { return true } else { return false }
        }) else { return XCTFail("apply did not split") }
        XCTAssertEqual(direction, .horizontal)
        XCTAssertEqual(cwd, "/tests")
        let sends = requests.compactMap { request -> String? in
            if case let .send(_, text) = request { return text } else { return nil }
        }
        XCTAssertEqual(sends, ["nvim\n", "lazygit\n"])
        guard case let .resizePaneRatio(_, _, _, ratio) = requests.first(where: {
            if case .resizePaneRatio = $0 { return true } else { return false }
        }) else { return XCTFail("apply did not set the split ratio") }
        XCTAssertEqual(ratio, 0.35)
    }

    func testThreePaneTreesKeepEachBranchThroughRestoreAndApply() throws {
        let rightSpine = NamedLayout(
            name: "spine",
            tree: .split(
                direction: .horizontal, ratio: 0.4,
                first: .leaf(program: "nvim", cwd: "/src"),
                second: .split(
                    direction: .vertical, ratio: 0.25,
                    first: .leaf(program: "lazygit", cwd: "/tests"),
                    second: .leaf(program: "btop", cwd: "/logs")
                )
            )
        )
        let rightPlan = NamedLayoutStore.restorePlan(rightSpine)
        XCTAssertEqual(rightPlan, [
            .session(name: "spine", cwd: "/src", program: "nvim"),
            .split(target: 0, direction: .horizontal, ratio: 0.4, cwd: "/tests", program: "lazygit"),
            .split(target: 1, direction: .vertical, ratio: 0.25, cwd: "/logs", program: "btop"),
        ])
        let rightSplits = try splitRequests(from: rightPlan)
        XCTAssertEqual(rightSplits.map(\.targetIsRoot), [true, false])
        XCTAssertEqual(rightSplits.map(\.direction), [.horizontal, .vertical])
        XCTAssertEqual(rightSplits.map(\.ratio), [0.4, 0.25])
        XCTAssertEqual(rightSplits.map(\.cwd), ["/tests", "/logs"])
        XCTAssertEqual(rightSplits.map(\.program), ["lazygit\n", "btop\n"])

        let leftHeavy = NamedLayout(
            name: "left",
            tree: .split(
                direction: .horizontal, ratio: 0.4,
                first: .split(
                    direction: .vertical, ratio: 0.25,
                    first: .leaf(program: "nvim", cwd: "/src"),
                    second: .leaf(program: "lazygit", cwd: "/tests")
                ),
                second: .leaf(program: "btop", cwd: "/logs")
            )
        )
        let leftPlan = NamedLayoutStore.restorePlan(leftHeavy)
        XCTAssertEqual(leftPlan, [
            .session(name: "left", cwd: "/src", program: "nvim"),
            .split(target: 0, direction: .horizontal, ratio: 0.4, cwd: "/logs", program: "btop"),
            .split(target: 0, direction: .vertical, ratio: 0.25, cwd: "/tests", program: "lazygit"),
        ])
        let leftSplits = try splitRequests(from: leftPlan)
        XCTAssertEqual(leftSplits.map(\.targetIsRoot), [true, true])
        XCTAssertEqual(leftSplits.map(\.direction), [.horizontal, .vertical])
        XCTAssertEqual(leftSplits.map(\.ratio), [0.4, 0.25])
        XCTAssertEqual(leftSplits.map(\.cwd), ["/logs", "/tests"])
    }

    private struct AppliedSplit {
        var targetIsRoot: Bool
        var direction: SplitDirection
        var ratio: Double
        var cwd: String?
        var program: String
    }

    /// Drives `LayoutApplication.apply` and records each split the way the CLI sends it.
    private func splitRequests(from plan: [LayoutAction]) throws -> [AppliedSplit] {
        let workspaceID = UUID()
        let sessionID = UUID()
        let tabID = UUID()
        let rootPane = UUID()
        let rootSurface = UUID()
        var panes: [(id: UUID, surface: UUID)] = [(rootPane, rootSurface)]
        var splits: [AppliedSplit] = []
        func snapshot() -> SessionSnapshot {
            var node = PaneNode.leaf(PaneLeaf(id: panes[0].id, surfaceID: panes[0].surface))
            for pane in panes.dropFirst() {
                node = .branch(
                    direction: .vertical, ratio: 0.5,
                    first: node,
                    second: .leaf(PaneLeaf(id: pane.id, surfaceID: pane.surface))
                )
            }
            let tab = Tab(id: tabID, cwd: "/src", rootPane: node)
            return SessionSnapshot(workspaces: [Workspace(sessions: [SessionGroup(id: sessionID, tabs: [tab])])])
        }
        try LayoutApplication.apply(plan: plan, workspaceID: workspaceID) { request in
            switch request {
            case .newSession:
                return .sessionID(sessionID)
            case .getSnapshot:
                return .snapshot(snapshot())
            case let .newSplit(_, paneID, direction, _, cwd):
                let created = UUID()
                let surface = UUID()
                splits.append(AppliedSplit(
                    targetIsRoot: paneID == rootPane,
                    direction: direction,
                    ratio: 0,
                    cwd: cwd,
                    program: ""
                ))
                panes.append((created, surface))
                return .paneID(created)
            case let .send(_, text):
                if !splits.isEmpty { splits[splits.count - 1].program = text }
                return .ok
            case let .resizePaneRatio(_, _, _, ratio):
                if !splits.isEmpty { splits[splits.count - 1].ratio = ratio }
                return .ok
            default:
                return .ok
            }
        }
        return splits
    }

    func testEventsProcessLookupAndCopy() throws {
        let tab = Tab(title: "shell", cwd: "/src", currentCommand: "zsh")
        let session = SessionGroup(name: "main", tabs: [tab])
        let snapshot = SessionSnapshot(workspaces: [Workspace(sessions: [session])])
        let agent = AgentSessionSummary(
            workspaceName: "Default",
            sessionID: session.id,
            sessionName: "main",
            tabID: tab.id,
            tabTitle: "shell",
            surfaceID: "surface-1",
            paneID: nil,
            kind: .claudeCode,
            activity: .working,
            waiting: true,
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let lines = try ControlPlane.events(snapshot: snapshot, agents: [agent]).map { try $0.jsonLine() }
        XCTAssertTrue(lines.contains { $0.contains("\"kind\":\"session\"") })
        XCTAssertTrue(lines.contains { $0.contains("\"kind\":\"pane\"") })
        XCTAssertTrue(lines.contains { $0.contains("\"kind\":\"agent\"") && $0.contains("waiting") })

        let record = ControlPlane.processJSON(pid: 4242, executable: "zsh")
        XCTAssertTrue(record.contains("\"pid\":4242"))
        XCTAssertTrue(record.contains("\"executable\":\"zsh\""))

        let hits = ControlPlane.lookup(query: "Read", entries: ["/a/readme.md", "/a/notes.txt"])
        XCTAssertEqual(hits, ["/a/readme.md"])

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("from.txt")
        let pushed = directory.appendingPathComponent("pushed.txt")
        let pulled = directory.appendingPathComponent("pulled.txt")
        try Data("same-bytes".utf8).write(to: source)
        try ControlPlane.copy(from: source.path, to: pushed.path, read: ControlPlane.localRead, write: ControlPlane.localWrite)
        try ControlPlane.copy(from: pushed.path, to: pulled.path, read: ControlPlane.localRead, write: ControlPlane.localWrite)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: pushed))
        XCTAssertEqual(try Data(contentsOf: pushed), try Data(contentsOf: pulled))

        let ssh = ControlPlane.sshReadArguments(target: "me@box", extra: ["-p", "22"], path: "/tmp/a")
        XCTAssertEqual(ssh.first, "ssh")
        XCTAssertTrue(ssh.contains("me@box"))
        let write = ControlPlane.sshWriteArguments(target: "me@box", extra: [], path: "/tmp/b")
        XCTAssertTrue(write.joined(separator: " ").contains("/tmp/b"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testIdleGridParksAndRestoreDoesNotClaimTheProcess() {
        var grid = IdleGrid(live: ["prompt", "ls"], presentsProcessAsRunning: true)
        grid.tick(secondsSincePTYRead: 59)
        XCTAssertFalse(grid.parked)
        XCTAssertEqual(grid.live, ["prompt", "ls"])
        grid.tick(secondsSincePTYRead: 60)
        XCTAssertTrue(grid.parked)
        XCTAssertTrue(grid.live.isEmpty, "the live grid is dropped")
        XCTAssertEqual(grid.history, ["prompt", "ls"])
        XCTAssertTrue(grid.presentsProcessAsRunning, "parking does not reap the child")
        grid.restore()
        XCTAssertEqual(grid.live, ["prompt", "ls"])
        XCTAssertFalse(grid.parked)
        XCTAssertTrue(grid.presentsProcessAsRunning)
    }

    func testPaneDensityBorder() {
        XCTAssertEqual(PaneDensity.comfortable.borderPoints, 8)
        XCTAssertTrue(PaneDensity.comfortable.separatedIslands)
        XCTAssertEqual(PaneDensity.comfortable.splitDividerPoints, 0)
        XCTAssertEqual(PaneDensity.compact.borderPoints, 1)
        XCTAssertFalse(PaneDensity.compact.separatedIslands)
        XCTAssertEqual(PaneDensity.compact.splitDividerPoints, 1)
    }
}

final class OverviewOrderTests: XCTestCase {
    func testWaitingTabsLeadAndFilterMatchesTitleSessionOrDirectory() {
        let a = OverviewTab(id: "a", title: "~/api › nvim", panes: [OverviewPane(program: "nvim", cwd: "/api", liveText: "")], sessionName: "Work")
        let b = OverviewTab(id: "b", title: "~ › claude", panes: [], sessionName: "Demo", agent: .claudeCode, needsYou: true)
        let c = OverviewTab(id: "c", title: "~/web", panes: [OverviewPane(program: "shell", cwd: "/web", liveText: "")], sessionName: "Work")
        XCTAssertEqual(WorkspaceOverviewBuilder.ordered([a, b, c]).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(WorkspaceOverviewBuilder.ordered([a, b, c], query: "work").map(\.id), ["a", "c"])
        XCTAssertEqual(WorkspaceOverviewBuilder.ordered([a, b, c], query: "/web").map(\.id), ["c"])
        XCTAssertEqual(WorkspaceOverviewBuilder.move(from: 0, by: 3, count: 5), 3)
        XCTAssertEqual(WorkspaceOverviewBuilder.move(from: 4, by: 3, count: 5), 4)
        XCTAssertEqual(WorkspaceOverviewBuilder.move(from: 0, by: -1, count: 5), 0)
    }
}
