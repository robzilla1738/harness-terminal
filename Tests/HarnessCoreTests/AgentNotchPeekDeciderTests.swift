import XCTest
@testable import HarnessCore

final class AgentNotchPeekDeciderTests: XCTestCase {
    func testInitialSeedProducesNoEvents() {
        let rows = [row(id: "a", activity: .working, waiting: true)]
        let (events, next) = AgentNotchPeekDecider.decide(previous: nil, rows: rows)
        XCTAssertTrue(events.isEmpty, "launch backlog must not peek-storm")
        XCTAssertEqual(next["a"], .init(activity: .working, waiting: true))
    }

    func testWaitingTransitionFiresNeedsInput() {
        let prev = ["a": AgentNotchPeekDecider.RowState(activity: .working, waiting: false)]
        let (events, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "a", activity: .working, waiting: true)]
        )
        XCTAssertEqual(events.map(\.reason), [.needsInput])
    }

    func testStillWaitingDoesNotRefire() {
        let prev = ["a": AgentNotchPeekDecider.RowState(activity: .working, waiting: true)]
        let (events, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "a", activity: .working, waiting: true)]
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testWorkingToIdleFiresFinishedUnlessWaiting() {
        let prev = ["a": AgentNotchPeekDecider.RowState(activity: .working, waiting: false)]
        let (finished, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "a", activity: .idle, waiting: false)]
        )
        XCTAssertEqual(finished.map(\.reason), [.finished])

        // Waiting wins over finished — it's the same refresh, one event, highest priority.
        let (blocked, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "a", activity: .idle, waiting: true)]
        )
        XCTAssertEqual(blocked.map(\.reason), [.needsInput])
    }

    func testErrorTransitionFires() {
        let prev = ["a": AgentNotchPeekDecider.RowState(activity: .working, waiting: false)]
        let (events, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "a", activity: .errored, waiting: false)]
        )
        XCTAssertEqual(events.map(\.reason), [.errored])
    }

    func testNewAgentRowPeeksOnlyWhenAlreadyBlocked() {
        let prev: [String: AgentNotchPeekDecider.RowState] = [:]
        let (blocked, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "new", activity: .working, waiting: true)]
        )
        XCTAssertEqual(blocked.map(\.reason), [.needsInput])

        let (calm, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [row(id: "new2", activity: .working, waiting: false)]
        )
        XCTAssertTrue(calm.isEmpty)
    }

    func testSessionRowsNeverPeek() {
        let prev = ["s": AgentNotchPeekDecider.RowState(activity: nil, waiting: false)]
        var sessionRow = row(id: "s", activity: nil, waiting: true)
        sessionRow.agentKind = nil
        let (events, _) = AgentNotchPeekDecider.decide(previous: prev, rows: [sessionRow])
        XCTAssertTrue(events.isEmpty)
    }

    func testPriorityAndRecencyOrdering() {
        let prev = [
            "fin": AgentNotchPeekDecider.RowState(activity: .working, waiting: false),
            "blk": AgentNotchPeekDecider.RowState(activity: .working, waiting: false),
        ]
        let (events, _) = AgentNotchPeekDecider.decide(
            previous: prev,
            rows: [
                row(id: "fin", activity: .idle, waiting: false),
                row(id: "blk", activity: .working, waiting: true),
            ]
        )
        XCTAssertEqual(events.map(\.reason), [.needsInput, .finished], "needs-input outranks finished")
    }

    private func row(id: String, activity: AgentActivity?, waiting: Bool) -> AgentNotchRowSummary {
        AgentNotchRowSummary(
            id: id,
            rowKind: .agent,
            workspaceID: UUID(),
            workspaceName: "Default",
            sessionID: UUID(),
            sessionName: "session",
            tabID: UUID(),
            title: "Claude Code",
            detail: "api · Default",
            tabCount: 1,
            waitingCount: waiting ? 1 : 0,
            agentKind: .claudeCode,
            agentActivity: activity,
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
    }
}
