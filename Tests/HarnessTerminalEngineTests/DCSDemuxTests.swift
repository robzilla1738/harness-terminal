import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Conformance for roadmap PR-6: demuxing DCS device-control strings instead of feeding any DCS
/// that happens to contain a 'q' into the Sixel decoder. Verifies Sixel still routes, DECRQSS and
/// XTGETTCAP queries are answered (no longer swallowed), tmux passthrough is recognized, and DA1
/// advertises Sixel (`;4`).
final class DCSDemuxTests: XCTestCase {
    private func make(cols: Int = 80, rows: Int = 24) -> (HarnessGridTerminal, () -> String) {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        var responses = Data()
        term.onResponse = { responses.append($0) }
        return (term, { String(decoding: responses, as: UTF8.self) })
    }

    // MARK: - DECRQSS (request selection or setting)

    func testDECRQSSReportsCursorStyle() {
        let (term, reply) = make()
        term.feed("\u{1b}[3 q")          // DECSCUSR → underline blinking (Ps 3)
        term.feed("\u{1b}P$q q\u{1b}\\") // DECRQSS for DECSCUSR (Pt = " q")
        XCTAssertEqual(reply(), "\u{1b}P1$r3 q\u{1b}\\")
    }

    func testDECRQSSReportsScrollRegion() {
        let (term, reply) = make(cols: 80, rows: 24)
        term.feed("\u{1b}[3;10r")        // DECSTBM rows 3..10 (1-based)
        term.feed("\u{1b}P$qr\u{1b}\\")  // DECRQSS for DECSTBM (Pt = "r")
        XCTAssertEqual(reply(), "\u{1b}P1$r3;10r\u{1b}\\")
    }

    func testDECRQSSUnknownSettingRepliesInvalid() {
        let (term, reply) = make()
        // SGR ("m") is not serialized → the "invalid request" reply form (Ps 0), not silence,
        // and crucially not a misrouted Sixel decode.
        term.feed("\u{1b}P$qm\u{1b}\\")
        XCTAssertEqual(reply(), "\u{1b}P0$rm\u{1b}\\")
    }

    // MARK: - XTGETTCAP (terminfo capability query)

    func testXTGETTCAPReportsColorCount() {
        let (term, reply) = make()
        // "Co" = 436f; reply value "256" = 323536.
        term.feed("\u{1b}P+q436f\u{1b}\\")
        XCTAssertEqual(reply(), "\u{1b}P1+r436f=323536\u{1b}\\")
    }

    func testXTGETTCAPUnknownCapabilityRepliesNegative() {
        let (term, reply) = make()
        // "XX" = 5858, unknown → negative reply (Ps 0), no value.
        term.feed("\u{1b}P+q5858\u{1b}\\")
        XCTAssertEqual(reply(), "\u{1b}P0+r5858\u{1b}\\")
    }

    // MARK: - tmux passthrough + Sixel routing

    func testTmuxPassthroughIsRecognizedAndNotMisrouted() {
        let (term, reply) = make(cols: 10, rows: 2)
        term.feed("\u{1b}Ptmux;hello\u{1b}\\") // tmux control-mode passthrough (not driven here)
        term.feed("OK")                         // subsequent output still renders normally
        XCTAssertEqual(reply(), "", "passthrough produces no PTY reply")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, "O".unicodeScalars.first!.value)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, "K".unicodeScalars.first!.value)
    }

    func testSixelStillPlacesAnImage() {
        let term = HarnessGridTerminal(cols: 10, rows: 4)!
        term.feed("\u{1b}Pq#0;2;100;0;0~\u{1b}\\")
        XCTAssertFalse(term.readGrid()!.images.isEmpty, "a real Sixel DCS (no intermediate, final 'q') still decodes")
    }

    func testDECRQSSIsNotDecodedAsSixel() {
        // A DECRQSS request contains 'q' but must not place an image (the old contains('q') bug).
        let term = HarnessGridTerminal(cols: 10, rows: 4)!
        term.feed("\u{1b}P$qm\u{1b}\\")
        XCTAssertTrue(term.readGrid()!.images.isEmpty, "DECRQSS must not be decoded as a Sixel image")
    }

    // MARK: - DA1 Sixel advertisement

    func testPrimaryDeviceAttributesAdvertisesSixel() {
        let (term, reply) = make()
        term.feed("\u{1b}[c")
        XCTAssertEqual(reply(), "\u{1b}[?62;4;22c")
        XCTAssertTrue(reply().contains("4"), "DA1 advertises Sixel via feature code 4")
    }
}
