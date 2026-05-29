import XCTest
@testable import HarnessCore

/// The shared `Command` → `[IPCRequest]` mapping. The split-direction inversion
/// is the correctness-critical bit (a divider-orientation `Command.SplitDirection`
/// vs. the layout `SplitDirection` the daemon stores) — a regression here silently
/// rotated GUI splits 90°, so it is pinned by tests.
final class CommandIPCTranslatorTests: XCTestCase {
    /// Build a one-workspace/one-session/one-tab snapshot with a known active pane.
    private func makeTarget(splitOnce: Bool = false) throws -> (CommandTarget, TabID, PaneID) {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        var tab = try XCTUnwrap(ws.activeTab)
        var activePane = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        if splitOnce {
            activePane = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: activePane, direction: .horizontal))
            tab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        }
        let target = CommandTarget(snapshot: editor.snapshot)
        return (target, tab.id, activePane)
    }

    func testSplitDirectionIsInverted() throws {
        // `.vertical` command (a vertical divider → side by side) must map to the
        // layout `.horizontal`; `.horizontal` command → layout `.vertical`.
        XCTAssertEqual(CommandIPCTranslator.layoutDirection(for: .vertical), .horizontal)
        XCTAssertEqual(CommandIPCTranslator.layoutDirection(for: .horizontal), .vertical)

        let (target, tabID, paneID) = try makeTarget()
        guard case let .requests(requests) = CommandIPCTranslator.translate(.splitWindow(direction: .vertical), target: target),
              case let .newSplit(reqTab, reqPane, direction) = requests.first
        else { return XCTFail("expected a newSplit request") }
        XCTAssertEqual(reqTab, tabID)
        XCTAssertEqual(reqPane, paneID)
        XCTAssertEqual(direction, .horizontal, "side-by-side command splits side-by-side in the layout")
    }

    func testTargetlessKillResolvesActivePane() throws {
        let (target, _, paneID) = try makeTarget()
        guard case let .requests(requests) = CommandIPCTranslator.translate(.killPane, target: target),
              case let .killPane(reqPane) = requests.first
        else { return XCTFail("expected killPane") }
        XCTAssertEqual(reqPane, paneID)
    }

    func testSelectPaneNextResolvesToSibling() throws {
        let (target, tabID, activePane) = try makeTarget(splitOnce: true)
        // After one split the focused pane is the new one; `next` selects the other.
        guard case let .requests(requests) = CommandIPCTranslator.translate(.selectPane(target: .next), target: target),
              case let .selectPane(reqTab, reqPane) = requests.first
        else { return XCTFail("expected selectPane") }
        XCTAssertEqual(reqTab, tabID)
        XCTAssertNotEqual(reqPane, activePane, "next moves off the active pane")
        XCTAssertTrue(target.paneOrder.contains(reqPane), "selects a real pane in the tab")
    }

    func testDirectionalSelectIsSingleRequest() throws {
        let (target, _, paneID) = try makeTarget(splitOnce: true)
        guard case let .requests(requests) = CommandIPCTranslator.translate(.selectPane(target: .left), target: target),
              case let .selectPaneDirectional(current, axis) = requests.first
        else { return XCTFail("expected selectPaneDirectional") }
        XCTAssertEqual(current, paneID == target.paneID ? paneID : target.paneID)
        XCTAssertEqual(axis, .left)
    }

    func testJoinPaneRequiresMarkedPane() throws {
        let (target, _, _) = try makeTarget(splitOnce: true)
        // No marked pane → unresolved.
        if case .unresolved = CommandIPCTranslator.translate(.joinPane(direction: .vertical), target: target) {
            // expected
        } else {
            XCTFail("join-pane with no marked pane should be unresolved")
        }
    }

    func testClientLocalVerbsAreNotIPC() throws {
        let (target, _, _) = try makeTarget()
        for command: Command in [.copyMode, .detachClient, .displayPanes, .showCheatsheet] {
            guard case .clientLocal = CommandIPCTranslator.translate(command, target: target) else {
                return XCTFail("\(command.shortDescription) should be client-local")
            }
        }
    }
}
