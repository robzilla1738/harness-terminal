import XCTest
@testable import HarnessCore

final class ProgramStatusAlertsTests: XCTestCase {
    private func tab(_ id: TabID, _ attention: ProgramMark.Attention?, message: String? = nil, real: Bool = true) -> Tab {
        Tab(id: id, programMark: attention.map {
            ProgramMark(attention: $0, kind: nil, message: message, app: nil, progress: nil, fromRealReport: real)
        })
    }

    func testFirstSnapshotOnlyRecords() {
        var alerts = ProgramStatusAlerts()
        let id = UUID()
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked)]), [], "marks already showing at launch don't replay")
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked)]), [], "an unchanged mark stays quiet")
    }

    func testTransitionsMapToEvents() {
        var alerts = ProgramStatusAlerts(cooldown: 0)
        let id = UUID()
        _ = alerts.alerts(for: [tab(id, .working)])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked, message: "Approve rm?")]),
                       [.init(event: .agentWaiting, tabID: id, message: "Approve rm?")])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .error)]).map(\.event), [.failed])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .done)]).map(\.event), [.agentFinished])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .working)]), [], "working never notifies")
    }

    func testDetectorFillsAreIgnored() {
        var alerts = ProgramStatusAlerts()
        let id = UUID()
        _ = alerts.alerts(for: [tab(id, nil)])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .done, real: false)]), [])
    }

    func testCooldownHoldsTheSameKindButNotANewOne() {
        var alerts = ProgramStatusAlerts(cooldown: 15)
        let id = UUID()
        let start = Date()
        _ = alerts.alerts(for: [tab(id, .working)], now: start)
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked, message: "a")], now: start).count, 1)
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked, message: "b")], now: start + 5), [],
                       "a reworded block inside the cooldown is held")
        XCTAssertEqual(alerts.alerts(for: [tab(id, .error)], now: start + 6).map(\.event), [.failed])
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked, message: "c")], now: start + 30).count, 1)
    }

    func testNewTabAfterLaunchAlerts() {
        var alerts = ProgramStatusAlerts()
        _ = alerts.alerts(for: [])
        let id = UUID()
        XCTAssertEqual(alerts.alerts(for: [tab(id, .blocked)]).map(\.event), [.agentWaiting])
    }

    func testSummaryPutsTheMostUrgentFirst() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let summary = ProgramStatusAlerts.summary(of: [
            .init(event: .agentFinished, tabID: a, message: nil),
            .init(event: .agentWaiting, tabID: b, message: nil),
            .init(event: .failed, tabID: c, message: nil),
            .init(event: .agentFinished, tabID: d, message: nil),
        ])
        XCTAssertEqual(summary, "1 needs you · 1 failed · 2 finished")
    }
}
