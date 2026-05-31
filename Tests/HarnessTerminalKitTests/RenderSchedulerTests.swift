import XCTest
@testable import HarnessTerminalKit

/// The render scheduler's coalescing / hold / force logic, tested in isolation (no window, no GPU):
/// it injects a counter as the `render` callback and drives the scheduler the way the surface view
/// does (markDirty from output, tick at display cadence, forceRender for resize/timeout).
final class RenderSchedulerTests: XCTestCase {
    /// Builds a scheduler whose `render` bumps a shared counter, so tests assert *how many* presents
    /// happened. Started by default (in a window); pass `started: false` for the detached case.
    private func makeScheduler(started: Bool = true) -> (RenderScheduler, () -> Int) {
        var count = 0
        let sched = RenderScheduler(render: { count += 1 })
        if started { sched.start() }
        return (sched, { count })
    }

    func testMarkDirtyOnceRendersOnce() {
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        XCTAssertTrue(sched.tick(), "a dirty tick renders")
        XCTAssertEqual(renders(), 1)
        // A second tick with nothing new must not render.
        XCTAssertFalse(sched.tick(), "a clean tick is a no-op")
        XCTAssertEqual(renders(), 1)
    }

    func testMultipleMarksBeforeTickRenderOnce() {
        let (sched, renders) = makeScheduler()
        for _ in 0 ..< 100 { sched.markDirty() } // a burst of PTY output between two display ticks
        sched.tick()
        XCTAssertEqual(renders(), 1, "a burst coalesces to one present per tick")
    }

    func testNoRenderWhenClean() {
        let (sched, renders) = makeScheduler()
        XCTAssertFalse(sched.tick())
        XCTAssertEqual(renders(), 0, "nothing dirty → nothing presented")
    }

    func testForceRenderBypassesCoalescing() {
        let (sched, renders) = makeScheduler()
        sched.forceRender()
        XCTAssertEqual(renders(), 1, "force presents immediately, no tick needed")
        // It cleared the dirty flag, so a following tick doesn't double-present.
        XCTAssertFalse(sched.tick())
        XCTAssertEqual(renders(), 1)
    }

    func testForceRenderBypassesSynchronizedHold() {
        let (sched, renders) = makeScheduler()
        sched.setSynchronized(true)
        sched.markDirty()
        XCTAssertFalse(sched.tick(), "synchronized output holds the tick")
        XCTAssertEqual(renders(), 0)
        sched.forceRender() // the 2026 timeout safety valve
        XCTAssertEqual(renders(), 1, "force presents past the hold")
    }

    func testSynchronizedHoldsThenReleasePresents() {
        let (sched, renders) = makeScheduler()
        sched.setSynchronized(true)
        sched.markDirty()
        sched.tick(); sched.tick()
        XCTAssertEqual(renders(), 0, "no frame escapes mid-batch")
        sched.setSynchronized(false) // program cleared 2026
        XCTAssertTrue(sched.hasPendingWork, "releasing 2026 re-arms a paint")
        sched.tick()
        XCTAssertEqual(renders(), 1, "the batched frame presents atomically after release")
    }

    func testStopCancelsPendingWork() {
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        sched.stop()
        XCTAssertFalse(sched.hasPendingWork)
        XCTAssertFalse(sched.tick(), "a stopped scheduler never presents")
        XCTAssertEqual(renders(), 0)
    }

    func testTickInertWhenNotStarted() {
        let (sched, renders) = makeScheduler(started: false)
        sched.markDirty()
        XCTAssertFalse(sched.tick(), "not in a window → no display-cadence renders")
        XCTAssertEqual(renders(), 0)
    }

    func testHasPendingWorkReflectsState() {
        let (sched, _) = makeScheduler()
        XCTAssertFalse(sched.hasPendingWork, "clean + running")
        sched.markDirty()
        XCTAssertTrue(sched.hasPendingWork, "dirty + running")
        sched.setSynchronized(true)
        XCTAssertFalse(sched.hasPendingWork, "dirty but held by 2026")
        sched.setSynchronized(false)
        XCTAssertTrue(sched.hasPendingWork, "released → pending again")
        sched.tick()
        XCTAssertFalse(sched.hasPendingWork, "presented → idle")
    }
}
