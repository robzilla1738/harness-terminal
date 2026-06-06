import Foundation
import XCTest
@testable import HarnessApp
import HarnessCore
import HarnessTerminalEngine

/// The OSC 9;4 stale-timeout mechanism: a program that dies without sending the remove report
/// must stop showing the "working" dot once the keep-alive window lapses, and every report must
/// re-arm the window. Uses the injected test seams (short window + captured nudge) so no
/// SessionCoordinator/daemon is touched.
@MainActor
final class SurfaceProgressTrackerTests: XCTestCase {
    private func report(_ state: TerminalProgressReport.State, value: Int? = nil) -> TerminalProgressReport {
        TerminalProgressReport(state: state, value: value)
    }

    func testStaleTimeoutClearsWorkingState() async throws {
        var nudges = 0
        let tracker = SurfaceProgressTracker(staleTimeout: 0.1, onVisibilityChange: { nudges += 1 })
        let id = SurfaceID()
        tracker.update(report(.indeterminate), forSurface: id)
        XCTAssertTrue(tracker.isActive(id))
        XCTAssertEqual(nudges, 1) // became visible
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(tracker.isActive(id), "no keep-alive for > staleTimeout must clear the dot")
        XCTAssertEqual(nudges, 2) // became hidden via the stale sweep
    }

    func testKeepAliveReArmsTheWindow() async throws {
        let tracker = SurfaceProgressTracker(staleTimeout: 0.2, onVisibilityChange: {})
        let id = SurfaceID()
        tracker.update(report(.indeterminate), forSurface: id)
        // Two keep-alives inside the window: the timer must re-arm, not fire from the first arm.
        try await Task.sleep(nanoseconds: 120_000_000)
        tracker.update(report(.indeterminate), forSurface: id)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(tracker.isActive(id), "a fresh report inside the window must keep the dot alive")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(tracker.isActive(id))
    }

    func testRemoveClearsImmediatelyAndErrorIsNotWorking() {
        let tracker = SurfaceProgressTracker(staleTimeout: 10, onVisibilityChange: {})
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
