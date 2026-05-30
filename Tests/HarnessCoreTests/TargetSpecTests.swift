import XCTest
@testable import HarnessCore

final class TargetSpecTests: XCTestCase {
    // MARK: Parsing

    func testParsesSessionWindowPane() {
        let spec = TargetSpec.parse("api:2.1")
        XCTAssertEqual(spec.session, .byName("api"))
        XCTAssertEqual(spec.window, .byIndex(2))
        XCTAssertEqual(spec.pane, .byIndex(1))
        XCTAssertNil(spec.bareToken)
    }

    func testParsesSessionOnly() {
        XCTAssertEqual(TargetSpec.parse("api:").session, .byName("api"))
        XCTAssertNil(TargetSpec.parse("api:").window)
    }

    func testLoneNameIsSession() {
        let spec = TargetSpec.parse("api")
        XCTAssertEqual(spec.session, .byName("api"))
        XCTAssertNil(spec.bareToken)
    }

    func testLoneIndexIsBareAmbiguous() {
        let spec = TargetSpec.parse("3")
        XCTAssertNil(spec.session)
        XCTAssertNil(spec.window)
        XCTAssertNil(spec.pane)
        XCTAssertEqual(spec.bareToken, "3")
    }

    func testRelativeAndSpecialWindowTokens() {
        XCTAssertEqual(TargetSpec.parse("api:+").window, .next)
        XCTAssertEqual(TargetSpec.parse("api:-").window, .previous)
        XCTAssertEqual(TargetSpec.parse("api:!").window, .last)
        XCTAssertEqual(TargetSpec.parse("api:^").window, .first)
        XCTAssertEqual(TargetSpec.parse("api:$").window, .highest)
        XCTAssertEqual(TargetSpec.parse("api:{end}").window, .highest)
    }

    func testPaneMarkers() {
        XCTAssertEqual(TargetSpec.parse("api:1.{top}").pane, .top)
        XCTAssertEqual(TargetSpec.parse("api:1.{right}").pane, .right)
        XCTAssertEqual(TargetSpec.parse("api:1.!").pane, .last)
    }

    func testTypedIDs() {
        let s = UUID(), w = UUID(), p = UUID()
        XCTAssertEqual(TargetSpec.parse("$\(s.uuidString)").session, .byID(s))
        XCTAssertEqual(TargetSpec.parse("@\(w.uuidString)").window, .byID(w))
        XCTAssertEqual(TargetSpec.parse("%\(p.uuidString)").pane, .byID(p))
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(TargetSpec.parse("").isEmpty)
        XCTAssertTrue(TargetSpec.parse("   ").isEmpty)
    }

    // MARK: Resolution

    /// Two sessions; session "api" has 3 tabs, the second tab split into 2 panes.
    private func makeSnapshot() -> (SessionSnapshot, [String: UUID]) {
        var ids: [String: UUID] = [:]
        func id(_ k: String) -> UUID { let v = UUID(); ids[k] = v; return v }

        let p0 = PaneLeaf(id: id("p0"), surfaceID: UUID())
        let p1 = PaneLeaf(id: id("p1"), surfaceID: UUID())
        let p2 = PaneLeaf(id: id("p2"), surfaceID: UUID())
        // tab1: single pane; tab2: side-by-side split (p1 left, p2 right); tab3: single.
        let tab0 = Tab(id: id("t0"), title: "one", rootPane: .leaf(p0), sortOrder: 0)
        let tab1 = Tab(id: id("t1"), title: "two",
                       rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(p1), second: .leaf(p2)),
                       sortOrder: 1, activePaneID: p1.id, lastActivePaneID: p2.id)
        let tab2 = Tab(id: id("t2"), title: "three", rootPane: .leaf(PaneLeaf(id: id("p3"), surfaceID: UUID())), sortOrder: 2)

        let api = SessionGroup(id: id("api"), name: "api", tabs: [tab0, tab1, tab2],
                               activeTabID: tab0.id, lastActiveTabID: tab2.id, sortOrder: 0)
        let other = SessionGroup(id: id("other"), name: "other",
                                 tabs: [Tab(id: id("ot0"), title: "o", sortOrder: 0)], sortOrder: 1)
        let ws = Workspace(id: UUID(), name: "Default", sessions: [api, other], activeSessionID: api.id)
        let snap = SessionSnapshot(workspaces: [ws], activeWorkspaceID: ws.id)
        return (snap, ids)
    }

    func testResolveWindowByIndex() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap, focusedTabID: ids["t0"])
        let r = base.resolving(TargetSpec.parse("api:1"), command: .killWindow)
        XCTAssertEqual(r.tab?.id, ids["t1"])
    }

    func testResolveWindowByIndexHonorsBaseIndex() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap)
        // base-index 1 → window "1" is array position 0.
        let r = base.resolving(TargetSpec.parse("api:1"), command: .killWindow, baseIndex: 1)
        XCTAssertEqual(r.tab?.id, ids["t0"])
    }

    func testResolvePaneByIndex() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap)
        // The split tab is window index 1 (base-index 0); t2 (window 2) is single-pane.
        let r = base.resolving(TargetSpec.parse("api:1.1"), command: .killPane)
        XCTAssertEqual(r.tab?.id, ids["t1"])
        XCTAssertEqual(r.paneID, ids["p2"]) // pane index 1 = second leaf
    }

    func testResolvePaneMarkersLeftRight() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap)
        let left = base.resolving(TargetSpec.parse("api:1.{left}"), command: .killPane)
        XCTAssertEqual(left.paneID, ids["p1"])
        let right = base.resolving(TargetSpec.parse("api:1.{right}"), command: .killPane)
        XCTAssertEqual(right.paneID, ids["p2"])
    }

    func testBareTokenResolvesByCommandLevel() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap, focusedTabID: ids["t1"], focusedPaneID: ids["p1"])
        // For a window command, lone "2" is a window index.
        let win = base.resolving(TargetSpec.parse("2"), command: .killWindow)
        XCTAssertEqual(win.tab?.id, ids["t2"])
        // For a pane command, lone "1" is a pane index within the focused tab (t1).
        let pane = base.resolving(TargetSpec.parse("1"), command: .killPane)
        XCTAssertEqual(pane.paneID, ids["p2"])
    }

    func testResolveSessionByName() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap, focusedTabID: ids["t0"])
        let r = base.resolving(TargetSpec.parse("other:"), command: .killSession)
        XCTAssertEqual(r.session?.id, ids["other"])
    }

    func testWindowLastUsesMRU() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap, focusedTabID: ids["t0"])
        let r = base.resolving(TargetSpec.parse("api:!"), command: .killWindow)
        XCTAssertEqual(r.tab?.id, ids["t2"]) // api.lastActiveTabID
    }

    func testEmptySpecKeepsFocus() {
        let (snap, ids) = makeSnapshot()
        let base = CommandTarget(snapshot: snap, focusedTabID: ids["t1"], focusedPaneID: ids["p2"])
        let r = base.resolving(TargetSpec.parse(""), command: .killPane)
        XCTAssertEqual(r.tab?.id, ids["t1"])
        XCTAssertEqual(r.paneID, ids["p2"])
    }
}
