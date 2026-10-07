import XCTest
@testable import HarnessCore

final class TargetResolverTests: XCTestCase {
    private func fixture() -> (SessionSnapshot, SessionGroup, SessionGroup, Tab) {
        let left = PaneLeaf(surfaceID: UUID(uuidString: "AAAA1111-0000-0000-0000-00000000ABCD")!)
        let right = PaneLeaf(surfaceID: UUID(uuidString: "AAAA2222-0000-0000-0000-00000000EF01")!)
        let split = Tab(title: "edit", rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right)))
        let logs = Tab(title: "logs")
        let work = SessionGroup(name: "Work", tabs: [split, logs], activeTabID: split.id)
        let demo = SessionGroup(name: "Demo", tabs: [Tab(title: "btop")])
        let workspace = Workspace(sessions: [work, demo], activeSessionID: work.id)
        return (SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id), work, demo, split)
    }

    func testIDLabelPositionAndFragment() {
        let (snapshot, work, demo, split) = fixture()
        XCTAssertEqual(TargetResolver.resolve(work.id.uuidString.lowercased(), kind: .session, in: snapshot), .resolved(work.id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("demo", kind: .session, in: snapshot), .resolved(demo.id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("2", kind: .session, in: snapshot), .resolved(demo.id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("LOGS", kind: .tab, in: snapshot), .resolved(work.tabs[1].id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("1", kind: .tab, in: snapshot), .resolved(split.id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("2", kind: .surface, in: snapshot), .resolved("AAAA2222-0000-0000-0000-00000000EF01"))
        XCTAssertEqual(TargetResolver.resolve("aaaa1", kind: .surface, in: snapshot), .resolved("AAAA1111-0000-0000-0000-00000000ABCD"))
        XCTAssertEqual(TargetResolver.resolve("ef01", kind: .surface, in: snapshot), .resolved("AAAA2222-0000-0000-0000-00000000EF01"))
    }

    func testMissesAndAmbiguityAreReported() {
        let (snapshot, _, _, _) = fixture()
        guard case .notFound = TargetResolver.resolve("nope", kind: .session, in: snapshot) else { return XCTFail() }
        guard case .notFound = TargetResolver.resolve("9", kind: .session, in: snapshot) else { return XCTFail() }
        guard case .notFound = TargetResolver.resolve("abc", kind: .surface, in: snapshot) else { return XCTFail("fragments need 4 chars") }
        guard case let .ambiguous(_, matches) = TargetResolver.resolve("aaaa", kind: .surface, in: snapshot) else { return XCTFail() }
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(CLIExit.targetNotFound, Int32(APIExit.ambiguous.rawValue))
    }
}

final class TargetContextTests: XCTestCase {
    private let left = PaneLeaf(surfaceID: UUID(uuidString: "AAAA1111-0000-0000-0000-00000000ABCD")!)
    private let right = PaneLeaf(surfaceID: UUID(uuidString: "AAAA2222-0000-0000-0000-00000000EF01")!)

    private func fixture() -> (SessionSnapshot, SessionGroup, SessionGroup) {
        let split = Tab(title: "edit", rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right)))
        let work = SessionGroup(name: "Work", tabs: [split, Tab(title: "logs")], activeTabID: split.id)
        let demo = SessionGroup(name: "", tabs: [Tab(title: "btop"), Tab(title: "top")])
        let workspace = Workspace(sessions: [work, demo], activeSessionID: work.id)
        return (SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id), work, demo)
    }

    func testCallerContextBeatsTheActiveWindowAndPositionsFollowIt() {
        let (snapshot, work, demo) = fixture()
        XCTAssertEqual(TargetContext.current(in: snapshot, environment: nil).session?.id, work.id, "no context: the active session")
        let here = TargetContext.current(in: snapshot, environment: ["HARNESS_SESSION": demo.id.uuidString])
        XCTAssertEqual(here.session?.id, demo.id)
        XCTAssertEqual(TargetResolver.resolve("2", kind: .tab, in: snapshot, context: here), .resolved(demo.tabs[1].id.uuidString))
        XCTAssertEqual(TargetResolver.resolve("Session 2", kind: .session, in: snapshot), .resolved(demo.id.uuidString))
        let pane = TargetContext.current(in: snapshot, environment: ["HARNESS_SURFACE": right.surfaceID.uuidString.lowercased()])
        XCTAssertEqual(pane.pane?.id, right.id)
        XCTAssertEqual(TargetContext.of(surface: left.id.uuidString, in: snapshot)?.pane?.surfaceID, left.surfaceID, "a pane id finds it too")
    }

    func testShortFlagsYieldToTmuxFlagsAndText() {
        XCTAssertEqual(CLIArguments.normalize(["zoom-pane", "-b", "2"], command: "zoom-pane"), ["zoom-pane", "--pane", "2"])
        XCTAssertEqual(CLIArguments.normalize(["ls", "-S", "mini"], command: "ls"), ["ls", "--host", "mini"])
        XCTAssertEqual(CLIArguments.normalize(["capture-pane", "-S", "-10"], command: "capture-pane"), ["capture-pane", "-S", "-10"])
        XCTAssertEqual(CLIArguments.normalize(["set-option", "-s", "work", "k", "v"], command: "set-option").first { $0 == "-s" }, "-s")
        XCTAssertEqual(CLIArguments.normalize(["send", "--text", "-s"], command: "send"), ["send", "--text", "-s"])
        XCTAssertEqual(CLIArguments.normalize(["run", "--", "grep", "-s"], command: "run"), ["run", "--", "grep", "-s"])
        XCTAssertEqual(CLIArguments.normalize(["inspect", "logs", "--json"], command: "inspect"), ["inspect", "--surface", "logs", "--json"])
    }

    func testPaneCommandsGetTheContextPane() {
        let (snapshot, _, _) = fixture()
        let context = TargetContext.current(in: snapshot, environment: ["HARNESS_SURFACE": right.surfaceID.uuidString])
        XCTAssertEqual(CLIArguments.withDefaultTarget(["kill-pane"], command: "kill-pane", snapshot: snapshot, context: context),
                       ["kill-pane", "--pane", right.id.uuidString])
        XCTAssertEqual(CLIArguments.withDefaultTarget(["send-keys", "--keys", "q"], command: "send-keys", snapshot: snapshot, context: context),
                       ["send-keys", "--surface", right.surfaceID.uuidString, "--keys", "q"])
        XCTAssertEqual(CLIArguments.withDefaultTarget(["zoom-pane", "--surface", left.surfaceID.uuidString], command: "zoom-pane", snapshot: snapshot, context: context),
                       ["zoom-pane", "--pane", left.id.uuidString, "--surface", left.surfaceID.uuidString], "--surface names the pane")
        XCTAssertEqual(CLIArguments.withDefaultTarget(["list-hooks"], command: "list-hooks", snapshot: snapshot, context: context), ["list-hooks"])
    }

    func testTreeMarksActiveAndCallerPanes() {
        let (snapshot, _, _) = fixture()
        let context = TargetContext.current(in: snapshot, environment: ["HARNESS_SURFACE": right.surfaceID.uuidString])
        let tree = SessionTree.build(snapshot, context: context, callerInside: true)
        XCTAssertEqual(tree.sessions.map(\.label), ["Work", "Session 2"])
        XCTAssertEqual(tree.sessions[0].tabs[0].panes.map(\.caller), [false, true])
        let text = tree.text()
        XCTAssertTrue(text.hasPrefix("* Work"))
        XCTAssertTrue(text.contains("  * 1 edit"))
        XCTAssertTrue(text.contains("aaaa2222  ← here"))
    }

    func testDurationsAndTables() {
        XCTAssertEqual(CLIDuration.seconds("90"), 90)
        XCTAssertEqual(CLIDuration.seconds("10m"), 600)
        XCTAssertEqual(CLIDuration.seconds("1.5h"), 5400)
        XCTAssertNil(CLIDuration.seconds("soon"))
        XCTAssertNil(CLIDuration.seconds("-1"))
        XCTAssertEqual(TextTable.render(["KEY", "ACTION"], [["C-a", "zoom"], ["prefix %", "split-window"]]),
                       "KEY       ACTION\nC-a       zoom\nprefix %  split-window")
    }

    func testKeymapMergesTablesAndLuaLayers() {
        let manifest = ScriptManifest(generation: 1, hash: "h", actions: [], bindingCount: 2, bindings: [
            ScriptBindingRecord(spec: "cmd+k", action: "clear", layer: ScriptLayer.configFile.rawValue, source: "init.lua"),
            ScriptBindingRecord(spec: "cmd+r", enter: "resize", layer: ScriptLayer.recorder.rawValue, source: "app"),
        ])
        let rows = KeymapRow.rows(tables: KeyTableSet(tables: []), manifest: manifest)
        XCTAssertEqual(rows, [
            KeymapRow(key: "cmd+k", action: "clear", args: "", source: "config"),
            KeymapRow(key: "cmd+r", action: "enter-mode", args: "resize", source: "app"),
        ])
    }
}

final class ShellJoinTests: XCTestCase {
    func testQuotesOnlyWordsThatNeedIt() {
        XCTAssertEqual(ControlPlane.shellJoin(["make", "test"]), "make test")
        XCTAssertEqual(ControlPlane.shellJoin(["sh", "-c", "exit 7"]), "sh -c 'exit 7'")
        XCTAssertEqual(ControlPlane.shellJoin(["echo", "it's"]), #"echo 'it'\''s'"#)
    }
}
