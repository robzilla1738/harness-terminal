import XCTest
@testable import HarnessCore

/// tmux grouped sessions (`new-session -t <session>`): one shared window list, linked
/// windows (shared surfaces), independent active windows per member.
final class GroupedSessionTests: XCTestCase {
    private func surfaceSets(_ session: SessionGroup) -> [Set<SurfaceID>] {
        session.tabs.map { Set($0.rootPane.allSurfaceIDs()) }
    }

    func testAddGroupedSessionSharesWindowListWithOwnFocus() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        _ = try XCTUnwrap(editor.addTab(to: ws.id))  // original now has 2 windows

        let memberID = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id, name: "mirror"))
        let sessions = editor.snapshot.workspaces[0].sessions
        let target = try XCTUnwrap(sessions.first { $0.id == original.id })
        let member = try XCTUnwrap(sessions.first { $0.id == memberID })

        // Both stamped with the same group; window lists share surfaces pairwise.
        XCTAssertNotNil(target.groupID)
        XCTAssertEqual(target.groupID, member.groupID)
        XCTAssertEqual(member.tabs.count, target.tabs.count)
        XCTAssertEqual(surfaceSets(member), surfaceSets(target), "linked copies share surfaces")
        // Distinct tab/pane identities, own focus.
        XCTAssertTrue(Set(member.tabs.map(\.id)).isDisjoint(with: Set(target.tabs.map(\.id))))
        XCTAssertNotNil(member.activeTabID)
        XCTAssertNotEqual(member.activeTabID, target.activeTabID)
    }

    func testNewTabPropagatesToPeersWithoutStealingFocus() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        let memberID = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id))

        // Focus back to the original, create a window there, propagate.
        _ = editor.selectSession(workspaceID: ws.id, sessionID: original.id)
        let newTab = try XCTUnwrap(editor.addTab(to: ws.id))
        editor.propagateNewTabToGroup(newTab)

        let sessions = editor.snapshot.workspaces[0].sessions
        let target = try XCTUnwrap(sessions.first { $0.id == original.id })
        let member = try XCTUnwrap(sessions.first { $0.id == memberID })
        XCTAssertEqual(member.tabs.count, target.tabs.count, "new window appears in every member")
        XCTAssertEqual(surfaceSets(member).last, surfaceSets(target).last)
        // The peer's focus is untouched (tmux: focus changes only where created).
        XCTAssertNotEqual(member.activeTabID, member.tabs.last?.id)
    }

    func testGroupCounterpartsFindPeerCopiesOfTheSameWindow() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        let memberID = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id))

        let target = try XCTUnwrap(editor.snapshot.workspaces[0].sessions.first { $0.id == original.id })
        let firstWindow = try XCTUnwrap(target.tabs.first)
        let counterparts = editor.groupCounterparts(of: firstWindow.id)
        XCTAssertEqual(counterparts.count, 1)
        let member = try XCTUnwrap(editor.snapshot.workspaces[0].sessions.first { $0.id == memberID })
        XCTAssertTrue(member.tabs.map(\.id).contains(try XCTUnwrap(counterparts.first)))
        // An ungrouped session has none.
        let plain = SessionEditor()
        let plainTab = try XCTUnwrap(plain.snapshot.activeWorkspace?.activeTab)
        XCTAssertTrue(plain.groupCounterparts(of: plainTab.id).isEmpty)
    }

    /// tmux: a new grouped session starts on the group's CURRENT window (then focus
    /// diverges per member) — not unconditionally on the first window.
    func testGroupedSessionStartsOnTargetsCurrentWindow() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        _ = try XCTUnwrap(editor.addTab(to: ws.id)) // focus moves to window 2 of 2

        let memberID = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id))
        let sessions = editor.snapshot.workspaces[0].sessions
        let target = try XCTUnwrap(sessions.first { $0.id == original.id })
        let member = try XCTUnwrap(sessions.first { $0.id == memberID })
        let targetActiveIndex = try XCTUnwrap(target.tabs.firstIndex { $0.id == target.activeTabID })
        XCTAssertEqual(targetActiveIndex, 1)
        XCTAssertEqual(member.activeTabID, member.tabs[targetActiveIndex].id,
                       "member starts on the linked copy of the target's current window")
    }

    /// Kill propagation survives layout divergence: a local split adds a surface to
    /// ONE member's copy, and the group-wide kill must still find the peers (overlap
    /// matching, not set equality) — tmux removes a killed window from every member.
    func testGroupedKillPropagatesAfterLocalSplitDivergence() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        let memberID = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id))

        // Diverge: split the ORIGINAL's first window locally (peer copy untouched).
        let target = try XCTUnwrap(editor.snapshot.workspaces[0].sessions.first { $0.id == original.id })
        let window = try XCTUnwrap(target.tabs.first)
        let pane = try XCTUnwrap(window.rootPane.allPaneIDs().first)
        _ = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: window.id, paneID: pane, direction: .horizontal))

        // The diverged window still maps to its peer copy…
        let counterparts = editor.groupCounterparts(of: window.id)
        XCTAssertEqual(counterparts.count, 1, "divergence must not break kill propagation")
        // …and the daemon's close order removes the window from every member.
        for counterpart in counterparts { _ = editor.closeTab(counterpart) }
        _ = editor.closeTab(window.id)
        let member = try XCTUnwrap(editor.snapshot.workspaces[0].sessions.first { $0.id == memberID })
        XCTAssertFalse(member.tabs.map(\.id).contains(counterparts[0]), "peer copy closed")
    }

    func testGroupNameAndDecodeCompatibility() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let original = try XCTUnwrap(ws.activeSession)
        _ = editor.renameSession(original.id, name: "main")
        _ = try XCTUnwrap(editor.addGroupedSession(groupWith: original.id, name: "mirror"))
        let snapshot = editor.snapshot
        let member = try XCTUnwrap(snapshot.workspaces[0].sessions.first { $0.name == "mirror" })
        XCTAssertEqual(snapshot.groupName(of: member), "main", "group is named after its first member")
        let ungrouped = SessionGroup()
        XCTAssertNil(snapshot.groupName(of: ungrouped))

        // Round-trip: groupID survives encode/decode; a pre-feature snapshot (no key)
        // decodes to nil via decodeIfPresent.
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(
            decoded.workspaces[0].sessions.compactMap(\.groupID).count, 2,
            "both members keep their groupID across a round-trip"
        )
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"old","tabs":[]}"#
        let decodedLegacy = try JSONDecoder().decode(SessionGroup.self, from: Data(legacy.utf8))
        XCTAssertNil(decodedLegacy.groupID)
    }
}
