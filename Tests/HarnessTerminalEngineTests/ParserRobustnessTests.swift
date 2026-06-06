import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Hostile / malformed escape-sequence input must never crash, hang, or grow the parser's
/// buffers without bound, and the parser must always recover to ground so legitimate output
/// after the bad sequence still renders. These guard the VTParser caps
/// (`maxOSCBytes`, `maxParams`, `maxIntermediates`) end-to-end through the public emulator.
final class ParserRobustnessTests: XCTestCase {
    func testOversizedOSCPayloadIsBoundedAndRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // OSC 52 clipboard with a 4 MiB body — far past the 1 MiB accumulation cap. The
        // parser keeps consuming but stops growing the buffer, then the ST ends the string.
        var bytes = Array("\u{1b}]52;c;".utf8)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "A"), count: 4 * 1024 * 1024))
        bytes.append(contentsOf: Array("\u{1b}\\".utf8))
        // A plain printable after the monster sequence proves the parser returned to ground.
        bytes.append(contentsOf: Array("ok".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("o").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("k").value))
    }

    func testExcessiveCSIParametersDoNotMisfireAndRecover() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // 5000 semicolon-separated params (well past the 32-param cap) terminated by `m`
        // (SGR). The overflow must suppress the sequence rather than apply garbage, and a
        // subsequent well-formed reset + text must render normally.
        let manyParams = Array(repeating: "1", count: 5000).joined(separator: ";")
        term.feed("\u{1b}[\(manyParams)m")
        term.feed("\u{1b}[0mZ")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("Z").value))
    }

    func testExcessiveIntermediatesAreCappedAndRecover() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // A flood of intermediate bytes (space = 0x20) inside a CSI, capped at 8 internally.
        var bytes = Array("\u{1b}[".utf8)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: " "), count: 1000))
        bytes.append(UInt8(ascii: "q")) // DECSCUSR final — odd with this many intermediates
        bytes.append(contentsOf: Array("hi".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("h").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("i").value))
    }

    func testCANAbortsOSCStringAndRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // VT500 "anywhere" rule: CAN (0x18) aborts an in-progress OSC and returns to
        // ground. Everything after the CAN must render as plain text instead of being
        // swallowed into the (unterminated) OSC payload.
        var bytes = Array("\u{1b}]0;stuck title".utf8)
        bytes.append(0x18) // CAN
        bytes.append(contentsOf: Array("ok".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("o").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("k").value))
    }

    func testSUBAbortsDCSCaptureAndRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // SUB (0x1A) aborts an unterminated DCS capture; without it the parser stays in
        // .stringCapture and silently consumes all subsequent output.
        var bytes = Array("\u{1b}Pq#0;2;0;0;0".utf8) // Sixel-ish DCS payload, never terminated
        bytes.append(0x1A) // SUB
        bytes.append(contentsOf: Array("ok".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("o").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("k").value))
    }

    func testCANAbortsAPCCaptureAndRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        var bytes = Array("\u{1b}_Gf=100,t=d;QUJD".utf8) // Kitty graphics APC, never terminated
        bytes.append(0x18) // CAN
        bytes.append(contentsOf: Array("ok".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("o").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("k").value))
    }

    func testCANAbortsCSIWithoutDispatch() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // Move to row 2 first so an (incorrectly dispatched) cursor-up would be visible.
        term.feed("\r\n\r\n")
        var bytes = Array("\u{1b}[5".utf8) // CSI with a pending parameter…
        bytes.append(0x18) // …aborted by CAN — must NOT dispatch with the next byte as final
        bytes.append(contentsOf: Array("A".utf8)) // would be CSI 5 A (cursor up 5) if mis-dispatched
        term.feed(bytes)
        let grid = term.readGrid()!
        // 'A' must print as a glyph on row 2, not act as a cursor-up final byte.
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, UInt32(UnicodeScalar("A").value))
    }

    func testCSIParamOverflowClampsAndStillDispatches() {
        // `CSI 99999 H` — a single param past the 65535 digit cap. xterm clamps the param and
        // still executes (CUP), so the cursor must land on the last row (clamped by the grid),
        // not be left at home by a dropped sequence.
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        term.feed("\u{1b}[99999H")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 3) // last row of a 4-row grid
        XCTAssertEqual(grid.cursor.col, 0)
    }

    func testCSIParamOverflowDoesNotPoisonSiblingParams() {
        // `CSI 1;99999 H` — one over-large param must not poison the whole CSI. The in-range
        // row (1 -> row 0) still applies; the clamped column lands on the last column.
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        term.feed("\u{1b}[1;99999H")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 19) // last col of a 20-col grid
    }

    func testCSIHomeRegressionStillWorks() {
        // `CSI 0 H` (and the bare `CSI H`) must still home — guards against the clamp change
        // breaking the default-param path.
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        term.feed("\u{1b}[3;5H")   // move away from home first
        term.feed("\u{1b}[0H")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 0)
    }

    func testUnterminatedDCSConsumesWithoutGrowthThenRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // A long DCS payload (consumed, not accumulated) then a proper ST and printable text.
        var bytes = Array("\u{1b}P".utf8)
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: 2 * 1024 * 1024))
        bytes.append(contentsOf: Array("\u{1b}\\done".utf8))
        term.feed(bytes)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("d").value))
    }
}
