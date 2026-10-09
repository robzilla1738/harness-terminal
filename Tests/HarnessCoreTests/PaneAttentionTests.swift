import XCTest
@testable import HarnessCore

final class PaneAttentionTests: XCTestCase {
    func testSplitAttentionKeepsItsSourceAndReadDoesNotResolveIt() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)
        let first = try XCTUnwrap(tab.rootPane.allLeaves().first)
        _ = editor.splitPane(in: workspace.id, tabID: tab.id, paneID: first.id, direction: .horizontal)
        let leaves = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab).rootPane.allLeaves()
        XCTAssertEqual(leaves.count, 2)
        editor.setAgent(AgentSnapshot(kind: .claudeCode, executable: "claude", pid: 1, activity: .working), forSurfaceKey: leaves[0].surfaceID.uuidString)
        editor.updatePaneActivity(surfaceID: leaves[1].surfaceID) {
            $0.notification = "Approve this action"
            $0.unread = true
        }
        let entries = editor.listAttention()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.paneID, leaves[1].id)
        let activityTime = entries.first?.activity.updatedAt
        editor.updatePaneActivity(surfaceID: leaves[1].surfaceID) { $0.unread = false }
        XCTAssertEqual(editor.listAttention().first?.activity.updatedAt, activityTime)
        XCTAssertEqual(editor.listAttention().first?.activity.rank, .waiting)
        editor.clearTabNotification(surfaceID: leaves[0].surfaceID)
        XCTAssertEqual(editor.listAttention().first?.activity.notification, "Approve this action")
    }

    func testSetupRoundTripCreatesFreshIdentitiesWithoutCapturingCommands() throws {
        var leaf = PaneLeaf(cwd: "/tmp", command: "some-agent --secret")
        leaf.shell = "/bin/sh"
        let setup = SavedSetup(name: "Work", tabs: [SetupTab(Tab(rootPane: .leaf(leaf)))])
        let restored = try JSONDecoder().decode(SavedSetup.self, from: JSONEncoder().encode(setup))
        try restored.validate()
        let newLeaf = try XCTUnwrap(restored.tabs[0].layout.makePaneTree().allLeaves().first)
        XCTAssertNotEqual(newLeaf.surfaceID, leaf.surfaceID)
        XCTAssertEqual(newLeaf.cwd, "/tmp")
        XCTAssertEqual(newLeaf.shell, "/bin/sh")
        XCTAssertNil(restored.tabs[0].layout.panes[0].startupCommand)
    }
    func testImportUndoPreservesLaterEditsAndImportsOnlySupportedBindings() throws {
        let config = TerminalConfigImporter.parse("font-family = Test Mono\nbackground-opacity = 0.7\nkeybind = super+shift+t=new_tab\nkeybind = super+r=text:rm -rf /\n")
        XCTAssertEqual(config.paletteShortcuts["action.newTab"], "S-Cmd-t")
        XCTAssertTrue(config.skippedKeys.contains { $0.contains("text:rm") })
        let original = HarnessSettings()
        let patch = try SettingsImport(current: original, imported: config)
        var imported = try patch.applying(to: original, selected: ["fontFamily", "backgroundOpacity"])
        imported.fontFamily = "Later Choice"
        let undone = try patch.undo(in: imported)
        XCTAssertEqual(undone.fontFamily, "Later Choice")
        XCTAssertEqual(undone.backgroundOpacity, original.backgroundOpacity)
    }

    func testPathSearchRanksFuzzyMatchesWithoutShellExpansion() {
        let paths = [PaneDirEntry(name: "src/main.swift", path: "/tmp/src/main.swift", directory: false),
                     PaneDirEntry(name: "README.md", path: "/tmp/README.md", directory: false)]
        XCTAssertEqual(PathSearch.ranked(paths, query: "smsw").map(\.name), ["src/main.swift"])
        XCTAssertTrue(PathSearch.ranked(paths, query: "$(pwd)").isEmpty)
    }

}
