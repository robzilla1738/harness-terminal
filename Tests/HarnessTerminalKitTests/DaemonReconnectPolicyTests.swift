import XCTest
@testable import HarnessTerminalKit

/// Pins the shape of the daemon-reconnect backoff (the v1.7 audit found the recovery path had
/// zero unit coverage): ramping delay, exhaustion boundary, and a total automatic recovery
/// window long enough to ride out a launchd daemon respawn before the manual re-grab takes over.
final class DaemonReconnectPolicyTests: XCTestCase {
    func testDelayRampsThenCaps() {
        XCTAssertEqual(DaemonReconnectPolicy.delay(forAttempt: 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(DaemonReconnectPolicy.delay(forAttempt: 4), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DaemonReconnectPolicy.delay(forAttempt: 9), 1.0, accuracy: 0.0001)
        XCTAssertEqual(DaemonReconnectPolicy.delay(forAttempt: 59), 1.0, accuracy: 0.0001)
    }

    func testDelayIsMonotonicallyNonDecreasing() {
        for attempt in 1 ..< DaemonReconnectPolicy.maxAttempts {
            XCTAssertGreaterThanOrEqual(
                DaemonReconnectPolicy.delay(forAttempt: attempt),
                DaemonReconnectPolicy.delay(forAttempt: attempt - 1))
        }
    }

    func testExhaustionBoundaryHandsOffToManualRegrab() {
        XCTAssertFalse(DaemonReconnectPolicy.isExhausted(attempts: 0))
        XCTAssertFalse(DaemonReconnectPolicy.isExhausted(attempts: DaemonReconnectPolicy.maxAttempts - 1))
        XCTAssertTrue(DaemonReconnectPolicy.isExhausted(attempts: DaemonReconnectPolicy.maxAttempts))
    }

    /// The automatic window must comfortably cover a launchd KeepAlive respawn (seconds) without
    /// retrying forever — roughly a minute, then the user-facing overlay owns recovery.
    func testTotalRecoveryWindowIsRoughlyAMinute() {
        let total = (0 ..< DaemonReconnectPolicy.maxAttempts)
            .map(DaemonReconnectPolicy.delay(forAttempt:))
            .reduce(0, +)
        XCTAssertGreaterThan(total, 30)
        XCTAssertLessThan(total, 90)
    }
}
