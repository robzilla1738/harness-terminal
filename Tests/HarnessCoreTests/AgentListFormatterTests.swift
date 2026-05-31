import XCTest
@testable import HarnessCore

final class AgentListFormatterTests: XCTestCase {
    private func summary(
        session: String = "alpha",
        tab: String = "claude",
        kind: AgentKind = .claudeCode,
        activity: AgentActivity = .working,
        waiting: Bool = false,
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AgentSessionSummary {
        AgentSessionSummary(
            workspaceName: "Default",
            sessionID: UUID(),
            sessionName: session,
            tabID: UUID(),
            tabTitle: tab,
            surfaceID: "SURFACE-1",
            paneID: "PANE-1",
            kind: kind,
            activity: activity,
            waiting: waiting,
            lastActivityAt: lastActivityAt
        )
    }

    // MARK: - Text formatting

    func testTextColumnsAndOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 5)
        let lines = AgentListFormatter.text([summary(lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000))], now: now)
        XCTAssertEqual(lines.count, 1)
        let cols = lines[0].components(separatedBy: "\t")
        XCTAssertEqual(cols.count, 5)
        XCTAssertEqual(cols[0], "SURFACE-1")
        XCTAssertEqual(cols[1], "Default/alpha/claude")
        XCTAssertEqual(cols[2], "Claude Code")
        XCTAssertEqual(cols[3], "working")
        XCTAssertEqual(cols[4], "5s")
    }

    func testWaitingOverridesActivityInStateColumn() {
        let line = AgentListFormatter.text([summary(activity: .working, waiting: true)]).first!
        let state = line.components(separatedBy: "\t")[3]
        XCTAssertEqual(state, "waiting", "the waiting signal must take precedence over activity")
    }

    func testEmptySessionNameAndTabFallBackToDash() {
        let line = AgentListFormatter.text([summary(session: "", tab: "")]).first!
        XCTAssertEqual(line.components(separatedBy: "\t")[1], "Default/-/-")
    }

    func testAgeBuckets() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AgentListFormatter.age(from: base, to: base.addingTimeInterval(5)), "5s")
        XCTAssertEqual(AgentListFormatter.age(from: base, to: base.addingTimeInterval(180)), "3m")
        XCTAssertEqual(AgentListFormatter.age(from: base, to: base.addingTimeInterval(2 * 3600)), "2h")
        XCTAssertEqual(AgentListFormatter.age(from: base, to: base.addingTimeInterval(4 * 86400)), "4d")
        // Clock skew clamps to 0s rather than going negative.
        XCTAssertEqual(AgentListFormatter.age(from: base, to: base.addingTimeInterval(-30)), "0s")
    }

    // MARK: - JSON formatting

    func testJSONRoundTripsAndIsMachineReadable() throws {
        let agents = [
            summary(session: "alpha", waiting: true),
            summary(session: "beta", kind: .codex, activity: .idle),
        ]
        let json = try AgentListFormatter.json(agents)

        // Valid JSON array.
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertTrue(object is [Any])

        // Decodes back to the same value via the matching decoder.
        let decoded = try AgentListFormatter.decodeJSON(json)
        XCTAssertEqual(decoded, agents)
    }
}
