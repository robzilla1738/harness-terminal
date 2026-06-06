import Foundation
import XCTest
@testable import HarnessApp
import HarnessCore
import HarnessTerminalEngine

/// The OSC 9;4 stale-timeout mechanism: a program that dies without sending the remove report
/// must stop showing the "working" dot once the keep-alive window lapses, and every report must
/// re-arm the window. Driven deterministically through the injected scheduler seam (captured
/// work items fired by hand, queue cancellation semantics mimicked) — wall-clock sleeps flaked
/// on loaded CI runners — and the captured nudge keeps SessionCoordinator/daemon out of the test.
@MainActor
final class SurfaceProgressTrackerTests: XCTestCase {
    private final class Scheduled {
        var items: [(work: DispatchWorkItem, delay: TimeInterval)] = []
        /// Fire like the main queue would: a cancelled item never runs.
        func fire(_ index: Int) {
            let item = items[index].work
            if !item.isCancelled { item.perform() }
        }
    }

    private final class Counter { var value = 0 }

    private func makeTracker(nudges: Counter = Counter()) -> (SurfaceProgressTracker, Scheduled) {
        let scheduled = Scheduled()
        let tracker = SurfaceProgressTracker(
            staleTimeout: 15,
            onVisibilityChange: { nudges.value += 1 },
            scheduleStale: { work, delay in scheduled.items.append((work, delay)) }
        )
        return (tracker, scheduled)
    }

    private func report(_ state: TerminalProgressReport.State, value: Int? = nil) -> TerminalProgressReport {
        TerminalProgressReport(state: state, value: value)
    }

    func testStaleSweepClearsWorkingState() {
        let nudges = Counter()
        let (tracker, scheduled) = makeTracker(nudges: nudges)
        let id = SurfaceID()
        tracker.update(report(.indeterminate), forSurface: id)
        XCTAssertTrue(tracker.isActive(id))
        XCTAssertEqual(nudges.value, 1) // became visible
        XCTAssertEqual(scheduled.items.count, 1)
        XCTAssertEqual(scheduled.items[0].delay, 15) // armed with the configured window

        scheduled.fire(0) // the keep-alive window lapsed with no further report
        XCTAssertFalse(tracker.isActive(id), "no keep-alive for > staleTimeout must clear the dot")
        XCTAssertEqual(nudges.value, 2) // became hidden via the stale sweep
    }

    func testKeepAliveReArmsTheWindow() {
        let (tracker, scheduled) = makeTracker()
        let id = SurfaceID()
        tracker.update(report(.indeterminate), forSurface: id)
        tracker.update(report(.indeterminate), forSurface: id) // keep-alive re-arms
        XCTAssertEqual(scheduled.items.count, 2)
        XCTAssertTrue(scheduled.items[0].work.isCancelled, "a fresh report cancels the prior sweep")
        XCTAssertFalse(scheduled.items[1].work.isCancelled)

        scheduled.fire(0) // the superseded sweep firing (queue skips cancelled items) is a no-op
        XCTAssertTrue(tracker.isActive(id), "a fresh report inside the window must keep the dot alive")
        scheduled.fire(1) // the live sweep finally lapses
        XCTAssertFalse(tracker.isActive(id))
    }

    func testRemoveClearsImmediatelyAndErrorIsNotWorking() {
        let (tracker, _) = makeTracker()
        let id = SurfaceID()
        tracker.update(report(.set, value: 40), forSurface: id)
        XCTAssertTrue(tracker.isActive(id))
        XCTAssertEqual(tracker.progressPercent(id), 40)
        tracker.update(report(.remove), forSurface: id)
        XCTAssertFalse(tracker.isActive(id))
        // error/paused are live reports but NOT "working" — the dot must not claim progress.
        tracker.update(report(.error), forSurface: id)
        XCTAssertFalse(tracker.isActive(id))
    }
}
