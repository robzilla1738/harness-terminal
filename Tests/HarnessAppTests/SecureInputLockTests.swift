import XCTest
@testable import HarnessApp

/// `EnableSecureEventInput` / `DisableSecureEventInput` are process-global and stack-counted, so
/// the lock's enable/disable calls MUST stay balanced — a leaked enable forces secure input on
/// system-wide until the process exits. `SecureInputLock.apply` is the accounting that guarantees
/// it. Counters are injected so the real OS lock is never touched.
final class SecureInputLockTests: XCTestCase {
    func testApplyBalancesAndIsIdempotent() {
        var enables = 0
        var disables = 0
        let lock = SecureInputLock(enable: { enables += 1 }, disable: { disables += 1 })

        // Releasing when not held does nothing.
        lock.apply(shouldHold: false)
        XCTAssertEqual(enables, 0)
        XCTAssertEqual(disables, 0)
        XCTAssertFalse(lock.isHeld)

        // Taking the lock enables exactly once; a redundant take is a no-op (never double-enable).
        lock.apply(shouldHold: true)
        lock.apply(shouldHold: true)
        XCTAssertEqual(enables, 1)
        XCTAssertEqual(disables, 0)
        XCTAssertTrue(lock.isHeld)

        // Releasing disables exactly once; a redundant release is a no-op (never double-disable).
        lock.apply(shouldHold: false)
        lock.apply(shouldHold: false)
        XCTAssertEqual(enables, 1)
        XCTAssertEqual(disables, 1)
        XCTAssertFalse(lock.isHeld)

        // A second take/release cycle stays balanced (net enables == net disables).
        lock.apply(shouldHold: true)
        lock.apply(shouldHold: false)
        XCTAssertEqual(enables, 2)
        XCTAssertEqual(disables, 2)
        XCTAssertFalse(lock.isHeld)
    }

    /// However many transitions occur, every enable is matched by a disable once the lock ends
    /// released — the invariant that keeps the global secure-input count from leaking.
    func testEnableDisableCountsMatchWhenReleased() {
        var enables = 0
        var disables = 0
        let lock = SecureInputLock(enable: { enables += 1 }, disable: { disables += 1 })
        let transitions = [true, true, false, true, false, false, true, true, false]
        for shouldHold in transitions { lock.apply(shouldHold: shouldHold) }
        XCTAssertFalse(lock.isHeld)
        XCTAssertEqual(enables, disables)
    }
}
