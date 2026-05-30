import XCTest
@testable import HarnessDaemonCore

/// `wait-for` channel semantics — pure, fd-based (no sockets), so fully unit-testable.
final class WaitForRegistryTests: XCTestCase {
    func testSignalWakesAllWaiters() {
        let r = WaitForRegistry()
        r.wait(channel: "ch", fd: 3)
        r.wait(channel: "ch", fd: 4)
        XCTAssertEqual(Set(r.signal(channel: "ch")), [3, 4], "signal wakes every waiter")
        XCTAssertEqual(r.signal(channel: "ch"), [], "a second signal has no waiters (not latched)")
    }

    func testSignalUnknownChannelIsNoOp() {
        let r = WaitForRegistry()
        XCTAssertEqual(r.signal(channel: "nope"), [])
    }

    func testLockMutexSemantics() {
        let r = WaitForRegistry()
        XCTAssertTrue(r.lock(channel: "m", fd: 1), "first lock acquires immediately")
        XCTAssertFalse(r.lock(channel: "m", fd: 2), "second lock defers while held")
        XCTAssertEqual(r.unlock(channel: "m"), 2, "unlock hands the lock to the queued waiter")
        XCTAssertNil(r.unlock(channel: "m"), "unlock with no waiters releases and returns nil")
        XCTAssertTrue(r.lock(channel: "m", fd: 5), "lock acquires again after full release")
    }

    func testRemoveDropsWaiterAndLockWaiter() {
        let r = WaitForRegistry()
        r.wait(channel: "ch", fd: 7)
        r.remove(fd: 7)
        XCTAssertEqual(r.signal(channel: "ch"), [], "a removed (disconnected) fd is not woken")

        XCTAssertTrue(r.lock(channel: "m", fd: 1))
        XCTAssertFalse(r.lock(channel: "m", fd: 2))
        r.remove(fd: 2)
        XCTAssertNil(r.unlock(channel: "m"), "a removed lock-waiter isn't granted the lock")
    }
}
