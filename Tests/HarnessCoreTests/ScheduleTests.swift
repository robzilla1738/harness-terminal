import Foundation
import XCTest
@testable import HarnessCore

final class ScheduleTests: XCTestCase {
    func testCronTimezoneDSTAndRestrictedDaySemantics() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Chicago")), formatter = ISO8601DateFormatter()
        func date(_ text: String) -> Date { formatter.date(from: text)! }
        let spring = try CronExpression("30 2 * * *").next(after: date("2026-03-08T00:00:00Z"), timezone: zone)
        XCTAssertEqual(spring, date("2026-03-09T07:30:00Z"), "Nonexistent 02:30 is skipped")
        let fall = try CronExpression("30 1 * * *")
        let first = try fall.next(after: date("2026-11-01T00:00:00Z"), timezone: zone)
        XCTAssertEqual(first, date("2026-11-01T06:30:00Z"))
        XCTAssertEqual(try fall.next(after: first, timezone: zone), date("2026-11-02T07:30:00Z"), "Repeated wall time occurs once")
        XCTAssertEqual(try CronExpression("*/15 9-17 * * 1-5").next(after: date("2026-10-09T22:50:00Z"), timezone: zone), date("2026-10-12T14:00:00Z"))
        XCTAssertEqual(try CronExpression("0 9 13 * 1").next(after: date("2026-10-11T15:00:00Z"), timezone: zone), date("2026-10-12T14:00:00Z"), "Restricted DOM/DOW use OR")
        for expression in ["60 * * * *", "* * * *", "*/0 * * * *", "* * 31 2 *", "* 20-3 * * *"] { XCTAssertThrowsError(try CronExpression(expression).next(after: .now, timezone: zone)) }
    }
}
