import XCTest
@testable import HarnessTerminalEngine

/// Thai vowels/tones (and Latin diacritics) are zero-width combining marks. They must attach to
/// the preceding base cell rather than being dropped, and must never advance the cursor.
final class CombiningMarkTests: XCTestCase {
    private func feed(_ s: String, cols: Int = 20, rows: Int = 3) -> TerminalGridSnapshot {
        let emu = TerminalEmulator(cols: cols, rows: rows)
        emu.feed(Array(s.utf8))
        return emu.readGrid()
    }

    func testThaiVowelAndToneAttachToBase() {
        // "ที่" = ท(U+0E17) + ี(U+0E35) + ่(U+0E48): one base, two marks.
        let g = feed("ที่")
        let base = g.cell(row: 0, col: 0)
        XCTAssertEqual(base?.codepoint, 0x0E17)
        XCTAssertEqual(base?.marks ?? [], [0x0E35, 0x0E48])
        // The marks consumed no columns: the next cell is blank.
        XCTAssertEqual(g.cell(row: 0, col: 1)?.codepoint ?? 0, 0)
    }

    func testLatinDiacriticAttachesToBase() {
        // "e" + U+0301 (combining acute) → é
        let g = feed("e\u{0301}")
        XCTAssertEqual(g.cell(row: 0, col: 0)?.codepoint, 0x65)
        XCTAssertEqual(g.cell(row: 0, col: 0)?.marks ?? [], [0x0301])
    }

    func testCombiningMarkAtLineStartIsDropped() {
        // A combining mark with no base (column 0, nothing printed) is dropped, no crash.
        let g = feed("\u{0301}abc")
        XCTAssertEqual(g.cell(row: 0, col: 0)?.codepoint, 0x61) // 'a' — the mark did not occupy col 0
        XCTAssertNil(g.cell(row: 0, col: 0)?.marks)
    }
}
