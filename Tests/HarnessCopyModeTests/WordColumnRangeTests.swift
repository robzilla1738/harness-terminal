import HarnessCore
import HarnessTerminalEngine
import XCTest
@testable import HarnessCopyMode

/// A one-line literal grid for exercising `wordColumnRange` (shared by copy mode and the GUI's
/// mouse double-click word selection) with no platform dependencies.
private struct TextGrid: CopyModeGridSource {
    let lines: [String]
    let columns: Int
    var viewportRows: Int { lines.count }
    var totalLines: Int { lines.count }

    init(_ line: String, columns: Int? = nil) {
        self.lines = [line]
        self.columns = columns ?? line.count
    }

    func line(_ index: Int) -> [TerminalGridCell] {
        var cells = Array(repeating: TerminalGridCell.blank, count: columns)
        guard index >= 0, index < lines.count else { return cells }
        for (i, scalar) in lines[index].unicodeScalars.enumerated() where i < columns {
            cells[i] = TerminalGridCell(codepoint: scalar.value)
        }
        return cells
    }
}

final class WordColumnRangeTests: XCTestCase {
    func testWordInMiddleExpandsToWordBounds() {
        let grid = TextGrid("foo bar baz") // "bar" = columns 4...6
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 4), 4 ... 6)
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 5), 4 ... 6)
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 6), 4 ... 6)
    }

    func testFirstAndLastWords() {
        let grid = TextGrid("foo bar baz")
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 0), 0 ... 2)  // foo
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 10), 8 ... 10) // baz
    }

    func testWhitespaceReturnsSingleColumn() {
        let grid = TextGrid("foo  bar") // two spaces at columns 3,4
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 3), 3 ... 3)
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 4), 4 ... 4)
    }

    func testColumnPastContentReturnsItself() {
        let grid = TextGrid("hi", columns: 10) // content only in columns 0,1
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 5), 5 ... 5)
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 0), 0 ... 1) // "hi"
    }

    func testPunctuationIsPartOfWord() {
        // Only space/tab separate (matches copy-mode word motion), so a path stays one word.
        let grid = TextGrid("cd /usr/local")
        XCTAssertEqual(grid.wordColumnRange(line: 0, column: 6), 3 ... 12) // /usr/local
    }
}
