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

final class ShellJoinTests: XCTestCase {
    func testQuotesOnlyWordsThatNeedIt() {
        XCTAssertEqual(ControlPlane.shellJoin(["make", "test"]), "make test")
        XCTAssertEqual(ControlPlane.shellJoin(["sh", "-c", "exit 7"]), "sh -c 'exit 7'")
        XCTAssertEqual(ControlPlane.shellJoin(["echo", "it's"]), #"echo 'it'\''s'"#)
    }
}
