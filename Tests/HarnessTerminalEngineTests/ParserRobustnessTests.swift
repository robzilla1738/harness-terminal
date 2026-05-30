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
