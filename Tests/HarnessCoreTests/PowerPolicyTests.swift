import XCTest
@testable import HarnessCore

final class PowerPolicyTests: XCTestCase {
    func testWorkingGraceOverridesAndBatteryRestrictions() throws {
        let settings = try JSONDecoder().decode(PowerSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.keepWorkingAgentsAwake); XCTAssertFalse(settings.allowOnBattery)
        let start = Date(timeIntervalSince1970: 1000)
        var policy = PowerPolicy()
        XCTAssertTrue(policy.evaluate(settings: settings, mode: .auto, source: .ac, workingAgents: 1, at: start).hold)
        let grace = policy.evaluate(settings: settings, mode: .auto, source: .ac, workingAgents: 0, at: start.addingTimeInterval(10))
        XCTAssertTrue(grace.hold); XCTAssertEqual(grace.graceUntil, start.addingTimeInterval(30))
        XCTAssertFalse(policy.evaluate(settings: settings, mode: .auto, source: .ac, workingAgents: 0, at: start.addingTimeInterval(30)).hold)
        XCTAssertTrue(policy.evaluate(settings: settings, mode: .on, source: .ac, workingAgents: 0, at: start.addingTimeInterval(40)).hold)
        XCTAssertFalse(policy.evaluate(settings: settings, mode: .on, source: .battery, workingAgents: 2, at: start).hold)
        XCTAssertFalse(policy.evaluate(settings: settings, mode: .on, source: .unknown, workingAgents: 2, at: start).hold)
        var battery = settings; battery.allowOnBattery = true
        XCTAssertTrue(policy.evaluate(settings: battery, mode: .on, source: .battery, workingAgents: 0, at: start).hold)
        XCTAssertFalse(policy.evaluate(settings: battery, mode: .off, source: .ac, workingAgents: 2, at: start).hold)
        XCTAssertThrowsError(try JSONDecoder().decode(PowerSettings.self, from: Data("{\"graceSeconds\":-1}".utf8)))
    }
}
