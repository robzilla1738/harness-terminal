import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// The UTF-16 offset math that backs VoiceOver navigation of the terminal grid. Asserts the
/// expected line/character/range mapping (including a multi-byte / wide-char line) so the AppKit
/// view can delegate to it with confidence.
final class TerminalAccessibilityTextTests: XCTestCase {
    func testValueJoinsLinesWithNewlines() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        XCTAssertEqual(a.value, "abc\nde\nf")
        XCTAssertEqual(a.length, 8)
        XCTAssertEqual(a.lineCount, 3)
    }

    func testCharacterRangeForLine() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        XCTAssertEqual(a.characterRange(forLine: 0), NSRange(location: 0, length: 3))
        XCTAssertEqual(a.characterRange(forLine: 1), NSRange(location: 4, length: 2)) // after "abc\n"
        XCTAssertEqual(a.characterRange(forLine: 2), NSRange(location: 7, length: 1))
        XCTAssertNil(a.characterRange(forLine: 3))
        XCTAssertNil(a.characterRange(forLine: -1))
    }

    func testLineForCharacterIndex() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        XCTAssertEqual(a.line(forCharacterIndex: 0), 0)
        XCTAssertEqual(a.line(forCharacterIndex: 2), 0)
        XCTAssertEqual(a.line(forCharacterIndex: 3), 0, "the newline belongs to the line it ends")
        XCTAssertEqual(a.line(forCharacterIndex: 4), 1, "first char of line 1")
        XCTAssertEqual(a.line(forCharacterIndex: 7), 2)
        XCTAssertEqual(a.line(forCharacterIndex: 999), 2, "past end clamps to the last line")
    }

    func testStringForRange() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        XCTAssertEqual(a.string(forRange: NSRange(location: 0, length: 3)), "abc")
        XCTAssertEqual(a.string(forRange: NSRange(location: 4, length: 2)), "de")
        XCTAssertEqual(a.string(forRange: NSRange(location: 3, length: 1)), "\n")
        XCTAssertNil(a.string(forRange: NSRange(location: 7, length: 5)), "out-of-bounds range is rejected")
    }

    func testInsertionPointCharacterIndexClampsIntoLine() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        XCTAssertEqual(a.characterIndex(line: 0, column: 1), 1)
        XCTAssertEqual(a.characterIndex(line: 1, column: 0), 4)
        XCTAssertEqual(a.characterIndex(line: 1, column: 99), 6, "a cursor past end-of-line lands at the line end")
        XCTAssertEqual(a.characterIndex(line: 5, column: 0), 7, "out-of-range line clamps to the last line")
    }

    func testWideAndMultibyteLineUsesUTF16Offsets() {
        // "café" is 4 UTF-16 units; "日本" is 2 (each CJK char is one UTF-16 unit but two cells).
        let a = TerminalAccessibilityText(lines: ["café", "日本"])
        XCTAssertEqual(a.length, 7) // 4 + newline + 2
        XCTAssertEqual(a.characterRange(forLine: 0), NSRange(location: 0, length: 4))
        XCTAssertEqual(a.characterRange(forLine: 1), NSRange(location: 5, length: 2))
        XCTAssertEqual(a.string(forRange: NSRange(location: 5, length: 2)), "日本")
        XCTAssertEqual(a.line(forCharacterIndex: 6), 1)
    }

    func testStringForRangeRejectsOverflowingRangeWithoutTrapping() {
        let a = TerminalAccessibilityText(lines: ["abc", "de", "f"])
        // A pathological range where location+length would overflow Int must be rejected via the
        // overflow-safe bounds check, not trap on the addition. (AppKit supplies valid ranges, but
        // the guard must never crash on a hostile/corrupt one.)
        XCTAssertNil(a.string(forRange: NSRange(location: Int.max, length: 1)))
        XCTAssertNil(a.string(forRange: NSRange(location: 0, length: Int.max)))
        XCTAssertNil(a.string(forRange: NSRange(location: 5, length: Int.max)))
    }

    func testEmptyIsSafe() {
        let a = TerminalAccessibilityText(lines: [])
        XCTAssertEqual(a.value, "")
        XCTAssertEqual(a.length, 0)
        XCTAssertEqual(a.lineCount, 0)
        XCTAssertEqual(a.line(forCharacterIndex: 0), 0)
        XCTAssertEqual(a.characterIndex(line: 0, column: 0), 0)
        XCTAssertNil(a.characterRange(forLine: 0))
    }
}
