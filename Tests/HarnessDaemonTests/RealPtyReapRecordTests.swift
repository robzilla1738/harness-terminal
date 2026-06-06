import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Deterministic (no fork, no live gate) coverage for the reap-generation bookkeeping that the
/// SIGKILL escalation consults. The old code answered "was generation N reaped?" from a SINGLE
/// slot (`reapedExit`) that every later reap overwrites, so a respawn-then-both-die-within-grace
/// sequence could wrongly conclude an already-reaped generation was NOT reaped and fall through to
/// `kill(pid, …)` on a possibly-recycled PID. These tests pin the Set-based answer.
final class RealPtyReapRecordTests: XCTestCase {
    func testLaterReapDoesNotMaskAnEarlierReap() {
        let pty = RealPty(forTesting: ())

        // gen 5 is SIGTERM'd, escalation scheduled. gen 5 exits on its own → reaped.
        pty.recordReapedGenerationForTesting(5, status: 0)
        XCTAssertTrue(pty.wasGenerationReapedForTesting(5))

        // Respawn → gen 6; gen 6 also dies within gen 5's grace window. With a single slot this
        // overwrites the record so a query for gen 5 would wrongly say "not reaped".
        pty.recordReapedGenerationForTesting(6, status: 0)

        // The escalation for the OLD generation must still see it as reaped (so it won't signal a
        // recycled PID), AND the new generation is tracked too.
        XCTAssertTrue(pty.wasGenerationReapedForTesting(5), "earlier reap must survive a later reap")
        XCTAssertTrue(pty.wasGenerationReapedForTesting(6))
    }

    func testUnreapedGenerationReportsNotReaped() {
        let pty = RealPty(forTesting: ())
        pty.recordReapedGenerationForTesting(10, status: 0)
        // A generation whose watcher never returned (e.g. a child still being killed) must report
        // not-reaped, so the escalation proceeds to deliver SIGKILL.
        XCTAssertFalse(pty.wasGenerationReapedForTesting(11))
    }

    func testReapRecordPrunesToBoundKeepingNewestGenerations() {
        let pty = RealPty(forTesting: ())
        // Record far more than the cap; generations are monotonic.
        let recorded = 200
        for gen in 1 ... recorded {
            pty.recordReapedGenerationForTesting(UInt64(gen))
        }
        // Bounded.
        XCTAssertLessThanOrEqual(pty.reapedGenerationCountForTesting, 64)
        XCTAssertGreaterThan(pty.reapedGenerationCountForTesting, 0)
        // Newest generations (the only ones with a possible live escalation) are retained; the
        // oldest are evicted. The most recent must always be present.
        XCTAssertTrue(pty.wasGenerationReapedForTesting(UInt64(recorded)))
        XCTAssertTrue(pty.wasGenerationReapedForTesting(UInt64(recorded - 1)))
        // The very oldest must have been pruned.
        XCTAssertFalse(pty.wasGenerationReapedForTesting(1))
    }

    /// The set is held at EXACTLY the 32-generation cap and eviction always drops the LOWEST, so the
    /// surviving window is the newest 32 contiguous generations. (`wasGenerationReapedForTesting` is
    /// the same pure answer the SIGKILL escalation consults via `reapedGenerations.contains`.)
    func testReapRecordHoldsExactCapAndEvictsLowest() {
        let pty = RealPty(forTesting: ())
        let cap = 32
        let recorded = 100
        for gen in 1 ... recorded { pty.recordReapedGenerationForTesting(UInt64(gen)) }

        // Held at exactly the cap once enough generations are recorded.
        XCTAssertEqual(pty.reapedGenerationCountForTesting, cap, "set is pinned at the 32-generation cap")

        // The surviving window is the newest `cap` generations, contiguous; everything older is gone.
        let lowestKept = recorded - cap + 1 // 69
        XCTAssertTrue(pty.wasGenerationReapedForTesting(UInt64(lowestKept)), "lowest survivor is retained")
        XCTAssertFalse(pty.wasGenerationReapedForTesting(UInt64(lowestKept - 1)), "the next-lower generation is evicted")
        for gen in lowestKept ... recorded {
            XCTAssertTrue(pty.wasGenerationReapedForTesting(UInt64(gen)), "every newest-\(cap) generation survives")
        }
    }

    /// An EVICTED reap-generation must read back exactly like one that was NEVER recorded: not
    /// reaped. That is the SIGKILL-relevant fact — the escalation only suppresses a kill when the
    /// generation is still in the set, so an evicted (old) generation falls through to deliver
    /// SIGKILL just as an unknown generation does. Pins that eviction can't masquerade as a record.
    func testEvictedGenerationReadsAsNeverRecorded() {
        let pty = RealPty(forTesting: ())
        // Record gen 1, then push it out by recording well past the cap of newer generations.
        pty.recordReapedGenerationForTesting(1)
        XCTAssertTrue(pty.wasGenerationReapedForTesting(1))
        for gen in 2 ... 40 { pty.recordReapedGenerationForTesting(UInt64(gen)) } // 39 newer ⇒ gen 1 evicted

        let evictedAnswer = pty.wasGenerationReapedForTesting(1)
        let neverRecordedAnswer = pty.wasGenerationReapedForTesting(9999)
        XCTAssertFalse(evictedAnswer, "an evicted generation reports not-reaped")
        XCTAssertEqual(evictedAnswer, neverRecordedAnswer,
                       "an evicted generation is indistinguishable from one never recorded")
    }
}
