import XCTest
@testable import HarnessCore

final class SidebarOutlineTests: XCTestCase {
    private func session(_ name: String, tabs: [String]) -> SessionGroup {
        let built = tabs.map { Tab(title: $0, cwd: "/\($0)") }
        return SessionGroup(name: name, tabs: built, activeTabID: built.first?.id)
    }

    func testSessionsHeadTheirTabsAndTheActiveTabIsSelected() {
        let demo = session("Demo", tabs: ["btop", "htop"])
        let work = session("Work", tabs: ["shell"])
        let lines = SidebarOutline.lines(
            groups: [DaemonSidebarGroup(id: "local", title: "This Mac", detail: "", local: true, sessions: [])],
            liveOwner: "local", live: [demo, work], activeSessionID: demo.id, sessionTitle: \.name
        )
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], .session(id: demo.id.uuidString, title: "Demo", owner: "local", live: true, current: true))
        XCTAssertEqual(lines[1], .tab(sessionID: demo.id.uuidString, tabID: demo.tabs[0].id.uuidString, selected: true))
        XCTAssertEqual(lines[2], .tab(sessionID: demo.id.uuidString, tabID: demo.tabs[1].id.uuidString, selected: false))
        XCTAssertEqual(lines[4], .tab(sessionID: work.id.uuidString, tabID: work.tabs[0].id.uuidString, selected: false))
        XCTAssertFalse(lines.contains { if case .machine = $0 { return true }; return false })
    }

    func testFilterKeepsMatchingTabsOrAWholeMatchingSession() {
        let demo = session("Demo", tabs: ["btop", "htop"])
        let work = session("Work", tabs: ["shell"])
        let byTab = SidebarOutline.lines(groups: [], liveOwner: "local", live: [demo, work], activeSessionID: nil, query: "htop", sessionTitle: \.name)
        XCTAssertEqual(byTab.count, 2)
        let byName = SidebarOutline.lines(groups: [], liveOwner: "local", live: [demo, work], activeSessionID: nil, query: "work", sessionTitle: \.name)
        XCTAssertEqual(byName.count, 2)
    }

    func testOtherDaemonsAddMachineHeadingsAndSessionOnlyRows() {
        let demo = session("Demo", tabs: ["btop"])
        let groups = DaemonSidebar.groups(
            localTitle: "This Mac",
            sessions: [DaemonSidebarSession(id: "r1", name: "Build", owner: "devbox")],
            remoteHosts: ["devbox"],
            remoteDetail: ""
        )
        let lines = SidebarOutline.lines(groups: groups, liveOwner: "local", live: [demo], activeSessionID: demo.id, sessionTitle: \.name)
        XCTAssertEqual(lines.first, .machine(title: "This Mac", detail: ""))
        XCTAssertTrue(lines.contains(.machine(title: "devbox", detail: "")))
        XCTAssertEqual(lines.last, .session(id: "r1", title: "Build", owner: "devbox", live: false, current: false))
    }
}
