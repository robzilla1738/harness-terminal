import XCTest
@testable import HarnessTerminalEngine

/// Roadmap PR-14: the Kitty graphics protocol beyond display — ack (`OK`/error gated by quietness),
/// query (`a=q`), transmit-once / place-many (`a=t` then `a=p`, keyed by `i=`), and delete
/// (`a=d` all / by id). Animation (`a=a`) stays deferred.
final class KittyGraphicsProtocolTests: XCTestCase {
    /// A 1×1 RGBA red pixel, base64 — the smallest valid `f=32,s=1,v=1` payload.
    private let pixel = "/wAA/w=="

    private func makeTerm() -> (TerminalEmulator, () -> [String]) {
        let term = TerminalEmulator(cols: 80, rows: 24)
        var responses: [String] = []
        term.onResponse = { responses.append(String(decoding: $0, as: UTF8.self)) }
        return (term, { responses })
    }

    private func placementCount(_ term: TerminalEmulator) -> Int { term.readGrid().images.count }

    func testTransmitAndDisplayAcksOKAndPlaces() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=5;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "a=T places the image")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=5;OK\u{1b}\\"), "transmit+display acks OK echoing i=5")
    }

    func testQueryAcksWithoutPlacing() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=q,f=32,s=1,v=1,i=7;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "a=q never places — it's a capability probe")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=7;OK\u{1b}\\"), "query acks OK so detection succeeds")
    }

    func testQueryFailureAcksErrorEvenWhenOKIsQuiet() {
        let (term, responses) = makeTerm()
        // s=2,v=2 needs 16 bytes but we send 4 → undecodable. q=1 suppresses OK but NOT errors.
        term.feed("\u{1b}_Ga=q,f=32,s=2,v=2,i=3,q=1;\(pixel)\u{1b}\\")
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=3;") && r.contains("EBADF"), "an error still reports under q=1")
    }

    func testQuietnessSuppressesAcks() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=5,q=1;\(pixel)\u{1b}\\") // q=1 → no OK
        XCTAssertEqual(placementCount(term), 1)
        XCTAssertTrue(responses().isEmpty, "q=1 suppresses the OK ack")

        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=6,q=2;\(pixel)\u{1b}\\") // q=2 → nothing at all
        XCTAssertTrue(responses().isEmpty, "q=2 suppresses OK and errors")
    }

    func testNoIDMeansNoAck() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1;\(pixel)\u{1b}\\") // no i= / I= → unaddressable
        XCTAssertEqual(placementCount(term), 1, "still displays")
        XCTAssertTrue(responses().isEmpty, "no id/number → no addressable reply")
    }

    func testTransmitThenPlaceMany() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=t,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\") // transmit only — no placement
        XCTAssertEqual(placementCount(term), 0, "a=t stores without placing")
        XCTAssertTrue(responses().contains("\u{1b}_Gi=9;OK\u{1b}\\"))

        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // place it (no payload needed)
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // place it again — place-many
        XCTAssertEqual(placementCount(term), 2, "a=p re-uses the transmitted image each time")
    }

    func testPlaceUnknownIDErrors() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=p,i=99\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0)
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=99;") && r.contains("ENOENT"), "placing an untransmitted id errors")
    }

    func testDeleteAllRemovesEveryPlacement() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=2;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 2)
        term.feed("\u{1b}_Ga=d,d=a\u{1b}\\")
        XCTAssertEqual(placementCount(term), 0, "d=a clears all placements")
    }

    func testDeleteByIDRemovesOnlyThatImage() {
        let (term, _) = makeTerm()
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=1;\(pixel)\u{1b}\\")
        term.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=2;\(pixel)\u{1b}\\")
        XCTAssertEqual(placementCount(term), 2)
        term.feed("\u{1b}_Ga=d,d=i,i=1\u{1b}\\")
        XCTAssertEqual(placementCount(term), 1, "d=i removes only the matching image id")
    }

    /// RIS (`ESC c`, full reset) must clear the transmitted-image cache, not just placements —
    /// otherwise transmit-once images survive a reset and keep occupying the per-screen byte
    /// budget. Regression for `fullReset()` clearing `kittyPending` but leaking `kittyTransmitted`.
    func testFullResetClearsTransmittedImageCache() {
        let (term, responses) = makeTerm()
        term.feed("\u{1b}_Ga=t,f=32,s=1,v=1,i=9;\(pixel)\u{1b}\\") // transmit (store) i=9
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\")                       // place it → succeeds
        XCTAssertEqual(placementCount(term), 1)

        term.feed("\u{1b}c") // RIS — full reset

        XCTAssertEqual(placementCount(term), 0, "RIS clears placements")
        term.feed("\u{1b}_Ga=p,i=9\u{1b}\\") // the cached image must be gone now
        let r = responses().joined()
        XCTAssertTrue(r.contains("\u{1b}_Gi=9;") && r.contains("ENOENT"),
                      "RIS must clear the transmitted-image cache, so placing i=9 afterward is not found")
    }
}
