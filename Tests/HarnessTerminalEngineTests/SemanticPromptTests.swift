import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// OSC 133 shell integration: prompt marks (A), command-finished exit status (D), and survival
/// of the marks across scrollback and reflow. All headless.
final class SemanticPromptTests: XCTestCase {
    private let esc = "\u{1b}"
    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

    func testPromptStartMarksCursorRow() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(osc133("A") + "user@host$ ")
        XCTAssertEqual(term.promptRows, [0], "the prompt row is the cursor's row")
        XCTAssertNotNil(term.readGrid().marks[0], "live snapshot carries the prompt mark")
        XCTAssertNil(term.readGrid().marks[0]?.exit, "exit is unknown until OSC 133;D")
    }

    func testNoMarksWithoutShellIntegration() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("plain output\r\nmore\r\n")
        XCTAssertTrue(term.promptRows.isEmpty)
        XCTAssertTrue(term.readGrid().marks.isEmpty)
    }

    func testExitStatusRecordedOnPromptRow() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        // Prompt on row 0, command runs, then finishes with a non-zero status while the cursor
        // sits below the prompt (mid-output).
        term.feed(osc133("A") + "$ false\r\n")
        term.feed(osc133("B") + osc133("C") + "\r\n")
        term.feed(osc133("D") + ";1")
        XCTAssertEqual(term.mark(atBufferLine: 0)?.exit, 1, "exit lands on the active command's prompt")
    }

    func testExitStatusZeroIsSuccess() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        term.feed(osc133("A") + "$ true\r\n" + osc133("D") + ";0")
        XCTAssertEqual(term.mark(atBufferLine: 0)?.exit, 0)
    }

    func testMarkSurvivesScrollIntoHistory() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(osc133("A") + "$ prompt")
        // Push the prompt row off the top into scrollback.
        for _ in 0 ..< 6 { term.feed("\r\nline") }
        XCTAssertGreaterThan(term.historyCount, 0)
        // Exactly one prompt mark, now living in history.
        XCTAssertEqual(term.promptRows.count, 1)
        let promptIdx = term.promptRows[0]
        XCTAssertLessThan(promptIdx, term.historyCount, "the prompt scrolled into history")
        XCTAssertNotNil(term.mark(atBufferLine: promptIdx))
        // It's no longer in the live viewport, but a scrolled-back snapshot shows it.
        XCTAssertTrue(term.readGrid().marks.isEmpty)
        let back = term.readGrid(scrollbackOffset: term.historyCount)
        XCTAssertTrue(back.marks.values.contains { _ in true }, "a scrollback view surfaces the mark")
    }

    func testMarkSurvivesReflow() {
        let term = TerminalEmulator(cols: 10, rows: 4)
        // A prompt followed by a long line that soft-wraps at width 10.
        term.feed(osc133("A") + "0123456789ABCDEF")
        XCTAssertEqual(term.promptRows.count, 1)
        // Widen: the wrapped line re-joins; the prompt mark must follow its logical line.
        term.resize(cols: 20, rows: 4)
        XCTAssertEqual(term.promptRows.count, 1, "reflow preserves exactly one prompt mark")
        // Narrow again.
        term.resize(cols: 6, rows: 4)
        XCTAssertEqual(term.promptRows.count, 1)
    }

    func testFullResetClearsMarks() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(osc133("A") + "$ ")
        XCTAssertEqual(term.promptRows.count, 1)
        term.feed("\u{1b}c") // RIS — full reset
        XCTAssertTrue(term.promptRows.isEmpty)
    }

    func testEraseScreenClearsMarks() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(osc133("A") + "$ cmd\r\n")
        XCTAssertEqual(term.promptRows.count, 1)
        term.feed("\u{1b}[2J") // ED 2 — clear screen
        XCTAssertTrue(term.promptRows.isEmpty)
    }
}
