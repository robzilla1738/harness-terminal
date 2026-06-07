import XCTest
@testable import HarnessCore

/// Pins the snapshot-derived metadata block shared by the daemon and the attach-client
/// compositor (`FormatContext.applySnapshotMetadata`). PR #113 fixed a `#{pane_active}`
/// bug that existed because three sites computed the same fields independently; this
/// guards the now-unified block so the two callers can't drift apart again.
final class FormatContextSnapshotTests: XCTestCase {
    /// One workspace; "alpha" (the seeded session) grouped with a second member "beta",
    /// and "alpha" given a second tab so window counts are observable.
    private func makeGroupedSnapshot() -> (SessionSnapshot, SessionID) {
        var editor = SessionEditor()
        let ws = editor.snapshot.activeWorkspace!.id
        let alpha = editor.snapshot.activeWorkspace!.sessions[0].id
        _ = editor.renameSession(alpha, name: "alpha")
        _ = editor.addTab(to: ws) // alpha now has two tabs
        _ = editor.addGroupedSession(groupWith: alpha, name: "beta")
        return (editor.snapshot, alpha)
    }

    private func session(_ snap: SessionSnapshot, named name: String) -> SessionGroup {
        snap.workspaces.flatMap(\.sessions).first { $0.name == name }!
    }

    func testFillsSessionAndWindowMetadata() {
        let (snap, _) = makeGroupedSnapshot()
        let alpha = session(snap, named: "alpha")
        let tab = alpha.activeTab!

        var ctx = FormatContext()
        ctx.applySnapshotMetadata(tab: tab, session: alpha, snapshot: snap)

        XCTAssertEqual(ctx.sessionID, alpha.id.uuidString)
        XCTAssertEqual(ctx.windowID, tab.id.uuidString)
        XCTAssertEqual(ctx.sessionWindows, alpha.tabs.count)
        XCTAssertEqual(ctx.sessionWindows, 2)
        XCTAssertEqual(ctx.windowPanes, tab.rootPane.allPaneIDs().count)
        XCTAssertEqual(ctx.paneDead, false, "a live tab is not dead")
        XCTAssertNil(ctx.paneExitStatus)
    }

    func testDeadTabReportsExitStatus() {
        let (snap, _) = makeGroupedSnapshot()
        let alpha = session(snap, named: "alpha")
        var deadTab = alpha.activeTab!
        deadTab.exitStatus = 137

        var ctx = FormatContext()
        ctx.applySnapshotMetadata(tab: deadTab, session: alpha, snapshot: snap)

        XCTAssertEqual(ctx.paneDead, true)
        XCTAssertEqual(ctx.paneExitStatus, 137)
    }

    func testWindowActiveReflectsActiveTab() {
        let (snap, _) = makeGroupedSnapshot()
        let alpha = session(snap, named: "alpha")
        let activeTab = alpha.activeTab!
        let otherTab = alpha.tabs.first { $0.id != activeTab.id }!

        var activeCtx = FormatContext()
        activeCtx.applySnapshotMetadata(tab: activeTab, session: alpha, snapshot: snap)
        XCTAssertEqual(activeCtx.windowActive, true)

        var otherCtx = FormatContext()
        otherCtx.applySnapshotMetadata(tab: otherTab, session: alpha, snapshot: snap)
        XCTAssertEqual(otherCtx.windowActive, false)
    }

    func testSessionGroupResolvedFromSnapshot() {
        let (snap, _) = makeGroupedSnapshot()
        let beta = session(snap, named: "beta")

        var ctx = FormatContext()
        ctx.applySnapshotMetadata(tab: beta.activeTab!, session: beta, snapshot: snap)
        // groupName picks the first member's non-empty name in sort order → "alpha".
        XCTAssertEqual(ctx.sessionGroup, "alpha")
    }

    func testNilSnapshotLeavesSessionGroupUnset() {
        // Preserves the compositor's pre-first-snapshot behavior: no snapshot ⇒ no group,
        // never a synthesized id prefix from an empty snapshot.
        let (snap, _) = makeGroupedSnapshot()
        let beta = session(snap, named: "beta")

        var ctx = FormatContext()
        ctx.applySnapshotMetadata(tab: beta.activeTab!, session: beta, snapshot: nil)
        XCTAssertNil(ctx.sessionGroup)
        // The non-group fields are still filled without a snapshot.
        XCTAssertEqual(ctx.sessionID, beta.id.uuidString)
    }

    func testNilTabLeavesWindowFieldsNil() {
        let (snap, _) = makeGroupedSnapshot()
        let alpha = session(snap, named: "alpha")

        var ctx = FormatContext()
        ctx.applySnapshotMetadata(tab: nil, session: alpha, snapshot: snap)

        XCTAssertNil(ctx.paneDead)
        XCTAssertNil(ctx.windowID)
        XCTAssertNil(ctx.windowPanes)
        XCTAssertNil(ctx.windowActive, "windowActive needs both a tab and a session")
        XCTAssertEqual(ctx.sessionID, alpha.id.uuidString, "session fields still resolve")
        XCTAssertEqual(ctx.sessionWindows, alpha.tabs.count)
    }
}
