import AppKit
import Foundation
import XCTest
@testable import HarnessApp

/// `SurfaceShellTracker` idle-efficiency behavior: the proc-scan timer parks while the app
/// is inactive and the cadence relaxes after a stable stretch — asserted through state
/// seams, never wall-clock waits. Uses the shared singleton (the class is a singleton by
/// design); each test restores the stopped state.
@MainActor
final class SurfaceShellTrackerTests: XCTestCase {
    private var tracker: SurfaceShellTracker { SurfaceShellTracker.shared }

    override func tearDown() async throws {
        tracker.stop()
        tracker.noteUserInteraction() // reset cadence for the next test
    }

    func testCadenceRelaxesAfterStableScansAndSnapsBackOnChange() {
        tracker.noteUserInteraction()
        XCTAssertEqual(tracker.currentIntervalForTesting, 0.5)

        // Stable scans relax the cadence…
        for _ in 0 ..< 10 { tracker.noteScanResultForTesting(changedAnything: false) }
        XCTAssertEqual(tracker.currentIntervalForTesting, 2.0, "10 unchanged scans relax to 2 s")

        // …and any change snaps it back.
        tracker.noteScanResultForTesting(changedAnything: true)
        XCTAssertEqual(tracker.currentIntervalForTesting, 0.5, "a cwd change restores the base cadence")
    }

    func testUserInteractionSnapsRelaxedCadenceBack() {
        for _ in 0 ..< 10 { tracker.noteScanResultForTesting(changedAnything: false) }
        XCTAssertEqual(tracker.currentIntervalForTesting, 2.0)
        tracker.noteUserInteraction()
        XCTAssertEqual(tracker.currentIntervalForTesting, 0.5, "focus change predicts cwd movement")
    }

    func testTimerParksOnResignActiveAndResumesOnActivate() {
        tracker.start()
        XCTAssertTrue(tracker.timerIsScheduledForTesting)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(tracker.timerIsScheduledForTesting, "inactive app must not run the proc scan")

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(tracker.timerIsScheduledForTesting, "activate resumes scanning")
    }

    func testActivateDoesNotResurrectAStoppedTracker() {
        tracker.start()
        tracker.stop()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertFalse(tracker.timerIsScheduledForTesting, "stop() must stick across activations")
    }
}
