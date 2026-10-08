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

    func testForceRenderUsesSynchronousRendererWhenProvided() {
        // The off-main pipeline distinguishes the async present (`render`, used by tick/presentNow)
        // from a synchronous present (`renderSynchronously`, used only by forceRender so resize /
        // first-paint land on screen inside the CATransaction). Verify forceRender routes to the
        // synchronous closure while the cadence paths route to the async one.
        var asyncCount = 0
        var syncCount = 0
        let sched = RenderScheduler(render: { asyncCount += 1 }, renderSynchronously: { syncCount += 1 })
        sched.start()

        sched.forceRender()
        XCTAssertEqual(syncCount, 1, "forceRender presents synchronously")
        XCTAssertEqual(asyncCount, 0, "forceRender must not take the async path")

        sched.markDirty()
        XCTAssertTrue(sched.tick(), "a dirty tick renders")
        XCTAssertEqual(asyncCount, 1, "tick presents via the async renderer")
        XCTAssertEqual(syncCount, 1, "tick must not take the synchronous path")
    }

    func testForceRenderFallsBackToRenderWhenNoSynchronousRenderer() {
        // Owners (and most tests) that don't distinguish the two get the async closure for both, so
        // forceRender still presents exactly once.
        var count = 0
        let sched = RenderScheduler(render: { count += 1 })
        sched.start()
        sched.forceRender()
        XCTAssertEqual(count, 1, "forceRender falls back to `render` when no synchronous closure is supplied")
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
        XCTAssertTrue(sched.hasPendingWork(), "releasing 2026 re-arms a paint")
        sched.tick()
        XCTAssertEqual(renders(), 1, "the batched frame presents atomically after release")
    }

    func testStopCancelsPendingWork() {
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        sched.stop()
        XCTAssertFalse(sched.hasPendingWork())
        XCTAssertFalse(sched.tick(), "a stopped scheduler never presents")
        XCTAssertEqual(renders(), 0)
    }

    func testTickInertWhenNotStarted() {
        let (sched, renders) = makeScheduler(started: false)
        sched.markDirty()
        XCTAssertFalse(sched.tick(), "not in a window → no display-cadence renders")
        XCTAssertEqual(renders(), 0)
    }

    // MARK: - presentNow (low-latency echo)

    func testPresentNowFlushesFirstPaintImmediately() {
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        XCTAssertTrue(sched.presentNow(), "first dirty paint flushes immediately")
        XCTAssertEqual(renders(), 1)
        // It cleared the dirty flag, so the following display tick doesn't double-present.
        XCTAssertFalse(sched.tick())
        XCTAssertEqual(renders(), 1)
    }

    func testPresentNowNoOpWhenClean() {
        let (sched, renders) = makeScheduler()
        XCTAssertFalse(sched.presentNow(), "nothing dirty → nothing to flush")
        XCTAssertEqual(renders(), 0)
    }

    func testPresentNowSuppressedSecondTimeWithinInterval() {
        // First byte flushes; subsequent bytes in the same interval coalesce (no per-chunk present).
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        XCTAssertTrue(sched.presentNow())
        sched.markDirty() // more output arrives before the next tick
        XCTAssertFalse(sched.presentNow(), "already presented this interval → coalesce, don't re-present")
        XCTAssertEqual(renders(), 1)
        // The coalesced paint lands at the tick.
        XCTAssertTrue(sched.tick())
        XCTAssertEqual(renders(), 2)
    }

    func testPresentNowReopensAfterIdleTick() {
        // After the burst drains, an idle tick ends the interval and reopens immediate presents.
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        XCTAssertTrue(sched.presentNow())          // interval 1: immediate
        XCTAssertFalse(sched.tick(), "nothing left to draw → idle tick")
        sched.markDirty()
        XCTAssertTrue(sched.presentNow(), "new interval after the idle tick → immediate again")
        XCTAssertEqual(renders(), 2)
    }

    func testPresentNowStaysCoalescedAcrossBusyTicks() {
        // A sustained burst: every tick has work, so presentedThisInterval never resets and the
        // immediate path stays suppressed — one present per tick, not per chunk.
        let (sched, renders) = makeScheduler()
        sched.markDirty()
        XCTAssertTrue(sched.presentNow())          // 1 (first paint)
        for _ in 0 ..< 5 {
            sched.markDirty()                       // output keeps streaming
            XCTAssertFalse(sched.presentNow(), "burst stays coalesced")
            XCTAssertTrue(sched.tick())             // one present per interval
        }
        XCTAssertEqual(renders(), 6, "1 immediate + 5 tick presents — never per-chunk")
    }

    func testLinkPauseReopensImmediatePresentAfterBurstEndsOnTick() {
        // Two chunks land in one interval: the first flushes immediately, the second coalesces into
        // the tick. That presenting tick leaves the gate closed — but when the view pauses the link
        // (nothing left to draw) it calls linkDidPause, which must reopen the immediate path so the
        // *next* keystroke after the gap is not delayed a frame.
        let (sched, renders) = makeScheduler()
        sched.markDirty(); XCTAssertTrue(sched.presentNow())   // 1: immediate
        sched.markDirty(); XCTAssertFalse(sched.presentNow())  // coalesced into the tick
        XCTAssertTrue(sched.tick())                            // 2: presenting tick, gate stays set
        XCTAssertFalse(sched.hasPendingWork())
        sched.linkDidPause()                                   // the view pauses the link
        sched.markDirty()
        XCTAssertTrue(sched.presentNow(), "first paint after the link paused is immediate")
        XCTAssertEqual(renders(), 3)
    }

    func testPresentNowRespectsSynchronizedHold() {
        let (sched, renders) = makeScheduler()
        sched.setSynchronized(true)
        sched.markDirty()
        XCTAssertFalse(sched.presentNow(), "2026 hold suppresses the immediate present too")
        XCTAssertEqual(renders(), 0)
    }

    func testPresentNowInertWhenNotStarted() {
        let (sched, renders) = makeScheduler(started: false)
        sched.markDirty()
        XCTAssertFalse(sched.presentNow(), "not in a window → no presents")
        XCTAssertEqual(renders(), 0)
    }

    func testHasPendingWorkReflectsState() {
        let (sched, _) = makeScheduler()
        XCTAssertFalse(sched.hasPendingWork(), "clean + running")
        sched.markDirty()
        XCTAssertTrue(sched.hasPendingWork(), "dirty + running")
        sched.setSynchronized(true)
        XCTAssertFalse(sched.hasPendingWork(), "dirty but held by 2026")
        sched.setSynchronized(false)
        XCTAssertTrue(sched.hasPendingWork(), "released → pending again")
        sched.tick()
        XCTAssertFalse(sched.hasPendingWork(), "presented → idle")
    }

    // MARK: - Occlusion (covered / minimized windows present nothing)

    func testOccludedSuppressesTickAndPresentNow() {
        let (sched, renders) = makeScheduler()
        sched.setOccluded(true)
        sched.markDirty() // output keeps flowing into the covered pane
        XCTAssertFalse(sched.hasPendingWork(), "occluded → the display link can pause")
        XCTAssertFalse(sched.tick(), "no present for an invisible window")
        XCTAssertFalse(sched.presentNow(), "echo flush holds too")
        XCTAssertEqual(renders(), 0)
    }

    func testDirtyMarksAccumulateWhileOccludedAndPresentOnUnocclusion() {
        let (sched, renders) = makeScheduler()
        sched.setOccluded(true)
        for _ in 0 ..< 50 { sched.markDirty() } // a build streaming into a covered window
        XCTAssertEqual(renders(), 0)
        sched.setOccluded(false)
        XCTAssertTrue(sched.hasPendingWork(), "accumulated marks surface once visible")
        XCTAssertTrue(sched.tick(), "the first visible tick presents the fresh frame")
        XCTAssertEqual(renders(), 1, "the covered burst coalesces to one present")
    }

    func testForceRenderIgnoresOcclusion() {
        // Resize/first-paint forces are rare while covered and must stay deterministic.
        let (sched, renders) = makeScheduler()
        sched.setOccluded(true)
        sched.forceRender()
        XCTAssertEqual(renders(), 1)
    }

    func testStopResetsOcclusion() {
        // Occlusion described the departed window; a re-hosted view seeds it afresh.
        let (sched, _) = makeScheduler()
        sched.setOccluded(true)
        sched.stop()
        sched.start()
        XCTAssertFalse(sched.isOccluded)
    }

    // MARK: - Kitty animation (the link times the next frame of what's on screen)

    func testNearAnimationDeadlineKeepsTheLinkAwakeAndPresentsOnceDue() {
        let (sched, renders) = makeScheduler()
        sched.setAnimationDeadline(1_000)
        XCTAssertTrue(sched.hasPendingWork(now: 0), "the link stays awake to time the frame")
        XCTAssertNil(sched.animationWake(now: 0), "near → no separate wake")
        XCTAssertFalse(sched.tick(now: 999), "not due yet → no present")
        XCTAssertTrue(sched.hasPendingWork(now: 999))
        XCTAssertTrue(sched.tick(now: 1_000), "due → one present")
        XCTAssertEqual(renders(), 1)
        XCTAssertFalse(sched.hasPendingWork(now: 1_000), "the present reports the next deadline, if any")
    }

    func testFarAnimationDeadlinePausesTheLinkUntilItsWake() {
        let (sched, renders) = makeScheduler()
        let window = RenderScheduler.linkTimedAnimationWindow
        let deadline: UInt64 = 1_000_000_000 // a 1 s frame gap
        sched.setAnimationDeadline(deadline)
        XCTAssertFalse(sched.hasPendingWork(now: 0), "far off → the link pauses")
        XCTAssertEqual(sched.animationWake(now: 0), deadline, "…and wakes once, at the deadline")
        XCTAssertFalse(sched.tick(now: 0))
        XCTAssertFalse(sched.hasPendingWork(now: deadline - window - 1))
        XCTAssertTrue(sched.hasPendingWork(now: deadline - window), "within two frames → the link times it")
        XCTAssertNil(sched.animationWake(now: deadline - window))
        XCTAssertTrue(sched.tick(now: deadline))
        XCTAssertEqual(renders(), 1)
        XCTAssertNil(sched.animationWake(now: deadline), "presented → nothing left to wake for")
    }

    func testFarAnimationDeadlineHasNoWakeWhenNothingWouldPresent() {
        let (sched, _) = makeScheduler()
        sched.setAnimationDeadline(1_000_000_000)
        sched.setOccluded(true)
        XCTAssertNil(sched.animationWake(now: 0), "covered")
        sched.setOccluded(false)
        sched.setSynchronized(true)
        XCTAssertNil(sched.animationWake(now: 0), "held by 2026")
        sched.setSynchronized(false)
        sched.stop()
        XCTAssertNil(sched.animationWake(now: 0), "detached")
    }

    func testAnimationDeadlineHoldsWhileOccludedAndClearsOnStop() {
        let (sched, renders) = makeScheduler()
        sched.setAnimationDeadline(1_000)
        sched.setOccluded(true)
        XCTAssertFalse(sched.hasPendingWork(now: 1_000), "a covered window animates nothing")
        XCTAssertFalse(sched.tick(now: 2_000))
        XCTAssertEqual(renders(), 0)
        sched.setAnimationDeadline(1_000)
        sched.stop()
        sched.start()
        XCTAssertNil(sched.animationDeadline, "a detached view forgets its animations")
        XCTAssertFalse(sched.tick(now: 2_000))
    }
}
