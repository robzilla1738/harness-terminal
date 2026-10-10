import Foundation
import HarnessCore
import XCTest
@testable import HarnessDaemonCore

final class IsolatedRegexTests: XCTestCase {
    func testRealWorkerMatchingInvalidPatternCancellationAndBacktrackingDeadline() throws {
        guard let directory = ProcessInfo.processInfo.environment["HARNESS_TEST_PRODUCTS"] else { throw XCTSkip("Set HARNESS_TEST_PRODUCTS to the built daemon product directory for the process fixture") }
        let executable = URL(fileURLWithPath: directory).appendingPathComponent("HarnessDaemon")
        let result = try IsolatedRegex.matches(RegexBatch(pattern: "^build.*(passed|failed)$", caseSensitive: false, lines: ["BUILD tests passed", "other", "build failed"]), executable: executable, timeout: 1, cancelled: { false })
        XCTAssertEqual(result, [true, false, true])
        let spans = try IsolatedRegex.matchSpans(RegexBatch(pattern: "passed|failed", caseSensitive: true, lines: ["✓ 😀 passed", "other"]), executable: executable, timeout: 1, cancelled: { false })
        XCTAssertEqual(spans[0], OutputSearchSpan(location: 5, length: 6)); XCTAssertNil(spans[1])
        XCTAssertThrowsError(try IsolatedRegex.matches(RegexBatch(pattern: "[", caseSensitive: true, lines: ["fixture"]), executable: executable, timeout: 1, cancelled: { false }))
        XCTAssertThrowsError(try IsolatedRegex.matches(RegexBatch(pattern: "fixture", caseSensitive: true, lines: ["fixture"]), executable: executable, timeout: 1, cancelled: { true }))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try IsolatedRegex.matches(RegexBatch(pattern: "(a+)+$", caseSensitive: true, lines: [String(repeating: "a", count: 50000) + "!"]), executable: executable, timeout: 0.15, cancelled: { false }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "An uncancellable ICU match cannot hold the daemon worker indefinitely")
    }
}
