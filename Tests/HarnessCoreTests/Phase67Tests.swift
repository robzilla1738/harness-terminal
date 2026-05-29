import XCTest
@testable import HarnessCore

/// Phase 6/7: new command verbs + aliases, link-window sharing semantics.
final class Phase67Tests: XCTestCase {
    func testNewVerbsParse() throws {
        XCTAssertEqual(try CommandParser.parse("last-window"), .lastWindow)
        XCTAssertEqual(try CommandParser.parse("send-prefix"), .sendPrefix)
        XCTAssertEqual(try CommandParser.parse("clock-mode"), .clockMode)
        XCTAssertEqual(try CommandParser.parse("unlink-window"), .unlinkWindow)
        if case let .choose(scope) = try CommandParser.parse("choose-tree") {
            XCTAssertEqual(scope, .tree)
        } else { XCTFail("expected choose") }
        if case let .pipePane(cmd) = try CommandParser.parse("pipe-pane 'cat > /tmp/log'") {
            XCTAssertEqual(cmd, "cat > /tmp/log")
        } else { XCTFail("expected pipe-pane") }
        if case let .linkWindow(target) = try CommandParser.parse("link-window -t api") {
            XCTAssertEqual(target, "api")
        } else { XCTFail("expected link-window") }
    }

    func testCommandAliasesResolve() throws {
        XCTAssertEqual(try CommandParser.parse("neww"), .newWindow)
        XCTAssertEqual(try CommandParser.parse("killp"), .killPane)
        // splitw with no flag → side-by-side (Command .vertical).
        XCTAssertEqual(try CommandParser.parse("splitw"), .splitWindow(direction: .vertical))
    }

    func testLinkWindowSharesSurfacesWithFreshPaneIDs() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let sourceSession = try XCTUnwrap(ws.activeSessionID)
        let tab = try XCTUnwrap(ws.activeTab)
        let targetSession = try XCTUnwrap(editor.addSession(to: ws.id, cwd: "/tmp", name: "target"))

        let linkedID = try XCTUnwrap(editor.linkWindow(tab.id, toSessionID: targetSession))
        let target = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.first { $0.id == targetSession })
        let linked = try XCTUnwrap(target.tabs.first { $0.id == linkedID })

        XCTAssertEqual(Set(linked.rootPane.allSurfaceIDs()), Set(tab.rootPane.allSurfaceIDs()),
                       "linked window shares the source's surfaces (live PTYs)")
        XCTAssertTrue(Set(linked.rootPane.allPaneIDs()).isDisjoint(with: Set(tab.rootPane.allPaneIDs())),
                      "linked window gets fresh pane IDs")
        _ = sourceSession

        // unlink-window removes the linked copy (it shares surfaces, so it's a link).
        XCTAssertTrue(editor.unlinkWindow(linkedID))
        let afterTarget = editor.snapshot.activeWorkspace?.sessions.first { $0.id == targetSession }
        XCTAssertNil(afterTarget?.tabs.first { $0.id == linkedID })
    }

    func testUnlinkWindowRejectsNonLinkedTab() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        // A plain tab shares no surfaces with another tab → not a link.
        XCTAssertFalse(editor.unlinkWindow(tab.id))
    }
}
