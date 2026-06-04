import XCTest
@testable import HarnessTerminalEngine

/// Correctness lock for the O(1) table-driven `CharacterWidth.width(of:)`.
///
/// The table (`CharacterWidthTable`, produced by `Scripts/generate-width-table.swift`) is proven
/// **byte-identical** to the canonical linear-scan `referenceWidth` for **every** scalar
/// `0x0…0x10FFFF`. This is the single guarantee that makes the fast path safe: if anyone edits the
/// canonical ranges without regenerating the table (or vice-versa), `testWidthMatchesReferenceForAllScalars`
/// fails. Tier A1 may not change the width path without this test staying green.
final class CharacterWidthTests: XCTestCase {

    /// THE safety net: the generated table must agree with the canonical oracle on every scalar.
    func testWidthMatchesReferenceForAllScalars() {
        var firstMismatch: UInt32? = nil
        for cp in UInt32(0) ... 0x10FFFF {
            if CharacterWidth.width(of: cp) != CharacterWidth.referenceWidth(of: cp) {
                firstMismatch = cp
                break
            }
        }
        XCTAssertNil(
            firstMismatch.map { String(format: "U+%04X", $0) },
            "table-driven width diverges from referenceWidth at this scalar"
        )
    }

    /// Spot checks at the boundaries that matter for terminal layout — these are what a regression
    /// in the trie packing or astral search would most plausibly break.
    func testWidthSpotChecks() {
        // Controls & DEL & C1 → zero-width.
        XCTAssertEqual(CharacterWidth.width(of: 0x00), 0)
        XCTAssertEqual(CharacterWidth.width(of: 0x07), 0) // BEL
        XCTAssertEqual(CharacterWidth.width(of: 0x1B), 0) // ESC
        XCTAssertEqual(CharacterWidth.width(of: 0x7F), 0) // DEL
        XCTAssertEqual(CharacterWidth.width(of: 0x9F), 0) // C1 end

        // ASCII / Latin-1 / Greek / Cyrillic / symbols → single width (the unicode_mixed payload).
        XCTAssertEqual(CharacterWidth.width(of: 0x20), 1) // space
        XCTAssertEqual(CharacterWidth.width(of: 0x41), 1) // 'A'
        XCTAssertEqual(CharacterWidth.width(of: 0xA0), 1) // NBSP
        XCTAssertEqual(CharacterWidth.width(of: 0x00E9), 1) // 'é'
        XCTAssertEqual(CharacterWidth.width(of: 0x03A9), 1) // 'Ω'
        XCTAssertEqual(CharacterWidth.width(of: 0x03BB), 1) // 'λ'
        XCTAssertEqual(CharacterWidth.width(of: 0x0416), 1) // 'Ж'
        XCTAssertEqual(CharacterWidth.width(of: 0x2713), 1) // '✓'

        // Zero-width combining marks.
        XCTAssertEqual(CharacterWidth.width(of: 0x0301), 0) // combining acute
        XCTAssertEqual(CharacterWidth.width(of: 0x036F), 0) // end of combining block
        XCTAssertEqual(CharacterWidth.width(of: 0x200D), 0) // ZWJ
        XCTAssertEqual(CharacterWidth.width(of: 0xFE0F), 0) // variation selector-16
        XCTAssertEqual(CharacterWidth.width(of: 0xE0100), 0) // astral variation selector

        // Wide / fullwidth (CJK, Hangul, fullwidth forms, emoji).
        XCTAssertEqual(CharacterWidth.width(of: 0x4E16), 2) // '世'
        XCTAssertEqual(CharacterWidth.width(of: 0x4E2D), 2) // '中'
        XCTAssertEqual(CharacterWidth.width(of: 0x6F22), 2) // '漢'
        XCTAssertEqual(CharacterWidth.width(of: 0x5B57), 2) // '字'
        XCTAssertEqual(CharacterWidth.width(of: 0x1100), 2) // Hangul Jamo (boundary)
        XCTAssertEqual(CharacterWidth.width(of: 0xAC00), 2) // Hangul syllable
        XCTAssertEqual(CharacterWidth.width(of: 0xFF21), 2) // fullwidth 'A'
        XCTAssertEqual(CharacterWidth.width(of: 0x1F600), 2) // 😀 emoji
        XCTAssertEqual(CharacterWidth.width(of: 0x20000), 2) // CJK Ext B
    }

    /// Range edges: the cell just outside each canonical wide/zero-width block must NOT inherit the
    /// block's width — proves the trie/astral boundaries are exact.
    func testWidthBoundariesAreExact() {
        XCTAssertEqual(CharacterWidth.width(of: 0x02FF), 1) // just below first combining block
        XCTAssertEqual(CharacterWidth.width(of: 0x0300), 0) // first combining mark
        XCTAssertEqual(CharacterWidth.width(of: 0x10FF), 1) // just below Hangul Jamo
        XCTAssertEqual(CharacterWidth.width(of: 0x115F), 2) // last Hangul Jamo
        XCTAssertEqual(CharacterWidth.width(of: 0x1160), 1) // just above
        XCTAssertEqual(CharacterWidth.width(of: 0x9FFF), 2) // last CJK Unified
        XCTAssertEqual(CharacterWidth.width(of: 0xA000), 2) // Yi starts (adjacent wide block)
        XCTAssertEqual(CharacterWidth.width(of: 0x1F64F), 2) // last of emoticons run
        XCTAssertEqual(CharacterWidth.width(of: 0x1F650), 1) // just above
        XCTAssertEqual(CharacterWidth.width(of: 0x10FFFF), 1) // top of Unicode
    }

    /// Thai combining marks must ALL be zero-width. The upper/lower vowels (0x0E31, 0x0E34–0x0E3A)
    /// were already correct; the tone-mark run 0x0E47–0x0E4E was missing from the table, so each
    /// tone mark wrongly consumed its own grid column ("สระไทยระเบิด"). Boundaries on either side
    /// stay single-width.
    func testThaiCombiningMarkWidths() {
        // The newly-added tone-mark run — every one is a nonspacing mark (Mn).
        XCTAssertEqual(CharacterWidth.width(of: 0x0E47), 0) // ◌็ MAITAIKHU
        XCTAssertEqual(CharacterWidth.width(of: 0x0E48), 0) // ◌่ MAI EK
        XCTAssertEqual(CharacterWidth.width(of: 0x0E49), 0) // ◌้ MAI THO
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4A), 0) // ◌๊ MAI TRI
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4B), 0) // ◌๋ MAI CHATTAWA
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4C), 0) // ◌์ THANTHAKHAT
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4D), 0) // ◌ํ NIKHAHIT
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4E), 0) // ◌๎ YAMAKKAN

        // Regression: the upper/lower vowels that were already in the table stay zero-width.
        XCTAssertEqual(CharacterWidth.width(of: 0x0E31), 0) // ◌ั MAI HAN-AKAT
        XCTAssertEqual(CharacterWidth.width(of: 0x0E34), 0) // ◌ิ SARA I (run start)
        XCTAssertEqual(CharacterWidth.width(of: 0x0E3A), 0) // ◌ฺ PHINTHU (run end)

        // Boundaries: spacing characters around the run keep single width.
        XCTAssertEqual(CharacterWidth.width(of: 0x0E46), 1) // ๆ MAIYAMOK (spacing)
        XCTAssertEqual(CharacterWidth.width(of: 0x0E3F), 1) // ฿ BAHT SIGN
        XCTAssertEqual(CharacterWidth.width(of: 0x0E4F), 1) // ๏ FONGMAN (spacing)
        XCTAssertEqual(CharacterWidth.width(of: 0x0E33), 1) // ำ SARA AM (spacing)
    }
}
