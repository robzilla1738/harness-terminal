import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Behavioral conformance for control functions beyond the basic read-grid contract:
/// autowrap, scrolling, erase/edit, cursor save/restore, UTF-8, alternate screen, and
/// PTY responses (DSR/DA). These are the correctness surfaces the A/B oracle (vs the
/// the renderer fork) will also exercise during cutover.
final class EngineConformanceTests: XCTestCase {
    private func read(_ bytes: String, cols: Int = 80, rows: Int = 24) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return term.readGrid()!
    }

    private func codepoint(_ literal: String) -> UInt32 {
        literal.unicodeScalars.first!.value
    }

    // MARK: - Harness-owned conformance fixtures

    /// These fixtures are Harness's own conformance suite: small, inline examples that lock
    /// protocol behavior without importing any external terminal test corpus.

    func testHarnessFixtureSGRBasicColors() {
        let grid = read("\u{1b}[31;44mA", cols: 4, rows: 1)
        let cell = grid.cell(row: 0, col: 0)
        XCTAssertEqual(cell?.foreground, .palette(1))
        XCTAssertEqual(cell?.background, .palette(4))
    }

    func testHarnessFixtureSGRTruecolorForegroundAndBackground() {
        let grid = read("\u{1b}[38;2;1;2;3;48;2;4;5;6mT", cols: 4, rows: 1)
        let cell = grid.cell(row: 0, col: 0)
        XCTAssertEqual(cell?.foreground, .rgb(r: 1, g: 2, b: 3))
        XCTAssertEqual(cell?.background, .rgb(r: 4, g: 5, b: 6))
    }

    func testHarnessFixtureTextStyleSGRAttributes() {
        let grid = read("\u{1b}[1;2;3;4mA", cols: 4, rows: 1)
        let cell = grid.cell(row: 0, col: 0)
        XCTAssertEqual(cell?.bold, true)
        XCTAssertEqual(cell?.faint, true)
        XCTAssertEqual(cell?.italic, true)
        XCTAssertEqual(cell?.underline, .single)
    }

    func testHarnessFixtureStrikeOverlineAndResets() {
        let grid = read("\u{1b}[9;53mA\u{1b}[29;55mB", cols: 4, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.strikethrough, true)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.overline, true)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.strikethrough, false)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.overline, false)
    }

    func testHarnessFixtureCursorMovementCUPAndCHA() {
        let grid = read("A\u{1b}[2;4HB\u{1b}[1GC", cols: 6, rows: 3)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("A"))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, codepoint("C"))
        XCTAssertEqual(grid.cell(row: 1, col: 3)?.codepoint, codepoint("B"))
        XCTAssertEqual(grid.cursor.row, 1)
        XCTAssertEqual(grid.cursor.col, 1)
    }

    func testHarnessFixtureEraseInLineModeOneClearsLeftOfCursor() {
        let grid = read("ABCDE\u{1b}[1;3H\u{1b}[1K", cols: 5, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, codepoint("D"))
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, codepoint("E"))
    }

    func testHarnessFixtureEraseInDisplayModeZeroClearsFromCursorForward() {
        let grid = read("AAAA\r\nBBBB\u{1b}[1;3H\u{1b}[J", cols: 4, rows: 2)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("A"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, codepoint("A"))
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, 0)
    }

    func testHarnessFixtureInsertAndDeleteCharactersPreserveAttributes() {
        let grid = read("\u{1b}[31mABCD\u{1b}[1;2H\u{1b}[2@\u{1b}[32mZ\u{1b}[1;1H\u{1b}[1P", cols: 6, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("Z"))
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(2))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, codepoint("B"))
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.foreground, .palette(1))
    }

    func testHarnessFixtureInsertAndDeleteLinesStayInsideScrollRegion() {
        let insert = read("111\r\n222\r\n333\r\n444\u{1b}[2;4r\u{1b}[3;1H\u{1b}[L", cols: 3, rows: 4)
        XCTAssertEqual(insert.cell(row: 0, col: 0)?.codepoint, codepoint("1"))
        XCTAssertEqual(insert.cell(row: 1, col: 0)?.codepoint, codepoint("2"))
        XCTAssertEqual(insert.cell(row: 2, col: 0)?.codepoint, 0)
        XCTAssertEqual(insert.cell(row: 3, col: 0)?.codepoint, codepoint("3"))

        let delete = read("111\r\n222\r\n333\r\n444\u{1b}[2;4r\u{1b}[2;1H\u{1b}[M", cols: 3, rows: 4)
        XCTAssertEqual(delete.cell(row: 0, col: 0)?.codepoint, codepoint("1"))
        XCTAssertEqual(delete.cell(row: 1, col: 0)?.codepoint, codepoint("3"))
        XCTAssertEqual(delete.cell(row: 2, col: 0)?.codepoint, codepoint("4"))
        XCTAssertEqual(delete.cell(row: 3, col: 0)?.codepoint, 0)
    }

    func testHarnessFixtureScrollRegionKeepsOutsideRowsPinned() {
        let grid = read("top\r\n111\r\n222\r\nbot\u{1b}[2;3r\u{1b}[3;1H\n", cols: 4, rows: 4)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("t"))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, codepoint("2"))
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 3, col: 0)?.codepoint, codepoint("b"))
    }

    func testHarnessFixtureAlternateScreenRestoresPrimaryTextAndAttributes() {
        let term = HarnessGridTerminal(cols: 8, rows: 2)!
        term.feed("\u{1b}[31mP")
        term.feed("\u{1b}[?1049h\u{1b}[32mA")
        XCTAssertEqual(term.readGrid()!.cell(row: 0, col: 0)?.foreground, .palette(2))
        term.feed("\u{1b}[?1049l")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("P"))
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(1))
    }

    func testHarnessFixtureAutowrapCanBeDisabledAndReenabled() {
        let grid = read("\u{1b}[?7lABCX\u{1b}[?7hYZ", cols: 3, rows: 2)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, codepoint("Y"))
        XCTAssertEqual(grid.cursor.row, 1)
        XCTAssertEqual(grid.cursor.col, 1)
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, codepoint("Z"))
    }

    func testHarnessFixtureBracketedPasteModeDrivesInputEncoder() {
        let term = HarnessGridTerminal(cols: 8, rows: 1)!
        term.feed("\u{1b}[?2004h")
        XCTAssertTrue(term.modes.bracketedPaste)
        XCTAssertEqual(
            String(decoding: InputEncoder().encodePaste("hi", modes: term.modes), as: UTF8.self),
            "\u{1b}[200~hi\u{1b}[201~"
        )
        term.feed("\u{1b}[?2004l")
        XCTAssertFalse(term.modes.bracketedPaste)
    }

    func testHarnessFixtureOSC8HyperlinksUseStableCellIDs() {
        let term = HarnessGridTerminal(cols: 8, rows: 1)!
        term.feed("\u{1b}]8;;https://one.example\u{1b}\\AB\u{1b}]8;;https://two.example\u{1b}\\C")
        let grid = term.readGrid()!
        let first = grid.cell(row: 0, col: 0)!.hyperlinkID
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.hyperlinkID, first)
        XCTAssertNotEqual(grid.cell(row: 0, col: 2)?.hyperlinkID, first)
        XCTAssertEqual(term.hyperlinkURL(id: first), "https://one.example")
        XCTAssertEqual(term.hyperlinkURL(id: grid.cell(row: 0, col: 2)!.hyperlinkID), "https://two.example")
    }

    func testHarnessFixtureOSC52DecodesUnicodeClipboardPayload() {
        let term = HarnessGridTerminal(cols: 8, rows: 1)!
        var captured: String?
        term.onSetClipboard = { captured = $0 }
        let payload = Data("copy ✓".utf8).base64EncodedString()
        term.feed("\u{1b}]52;c;\(payload)\u{07}")
        XCTAssertEqual(captured, "copy ✓")
    }

    func testHarnessFixtureOSC133MarksCarryExitStatusInSnapshot() {
        let term = HarnessGridTerminal(cols: 12, rows: 2)!
        term.feed("\u{1b}]133;A\u{07}$ false\r\n\u{1b}]133;D;7\u{07}")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.marks[0]?.exit, 7)
        XCTAssertEqual(term.promptRows, [0])
    }

    func testHarnessFixtureDECSpecialGraphicsMapsLineDrawing() {
        let grid = read("\u{1b}(0lqk\u{1b}(Bq", cols: 5, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0x250C)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0x2500)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0x2510)
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, codepoint("q"))
    }

    func testHarnessFixtureWideCharacterMarksTailCell() {
        let grid = read("A界B", cols: 6, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.width, .normal)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, "界".unicodeScalars.first!.value)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.width, .wide)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.width, .spacerTail)
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, codepoint("B"))
    }

    func testHarnessFixtureCombiningMarkStaysOnBaseCell() {
        let grid = read("e\u{0301}x", cols: 4, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("e"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, codepoint("x"))
        XCTAssertEqual(grid.cursor.col, 2)
    }

    func testHarnessFixtureDECSCUSRUnderlineCursorShape() {
        let grid = read("\u{1b}[4 q", cols: 4, rows: 1)
        XCTAssertEqual(grid.cursor.shape, .underline)
        XCTAssertEqual(grid.cursor.blinking, false)
    }

    func testAutowrapToNextLine() {
        let line = String(repeating: "a", count: 80) + "b"
        let grid = read(line, cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 79)?.codepoint, UInt32(UnicodeScalar("a").value))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, UInt32(UnicodeScalar("b").value))
        XCTAssertEqual(grid.cursor.row, 1)
        XCTAssertEqual(grid.cursor.col, 1)
    }

    func testOSC11BackgroundColorQuery() {
        let term = TerminalEmulator(cols: 10, rows: 2)
        var responses = Data()
        term.onResponse = { responses.append($0) }
        term.colorProvider = { role in role == .background ? (0x1e, 0x1e, 0x2e) : nil }
        term.feed(Array("\u{1b}]11;?\u{1b}\\".utf8))
        // 8-bit → 16-bit reply (v*0x101): 0x1e→0x1e1e, 0x2e→0x2e2e.
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}]11;rgb:1e1e/1e1e/2e2e\u{1b}\\")
    }

    func testDECSCUSRCursorShape() {
        let term = HarnessGridTerminal(cols: 10, rows: 2)!
        term.feed("\u{1b}[5 q") // blinking bar
        XCTAssertEqual(term.readGrid()!.cursor.shape, .bar)
        XCTAssertEqual(term.readGrid()!.cursor.blinking, true)
        term.feed("\u{1b}[2 q") // steady block
        XCTAssertEqual(term.readGrid()!.cursor.shape, .block)
        XCTAssertEqual(term.readGrid()!.cursor.blinking, false)
        term.feed("\u{1b}[0 q") // 0 = reset to the user default (Ghostty/kitty/xterm de-facto)
        XCTAssertEqual(term.readGrid()!.cursor.shape, .default)
        XCTAssertNil(term.readGrid()!.cursor.blinking)
        term.feed("\u{1b}[1 q") // 1 = blinking block (explicit, unlike 0)
        XCTAssertEqual(term.readGrid()!.cursor.shape, .block)
        XCTAssertEqual(term.readGrid()!.cursor.blinking, true)
        // The honor-user-setting state is the initial one (before any program sets a shape).
        XCTAssertEqual(HarnessGridTerminal(cols: 4, rows: 1)!.readGrid()!.cursor.shape, .default)
    }

    /// The TUI exit-reset path: a program sets an explicit shape, then resets with `CSI 0 SP q`
    /// (or the parameter-less `CSI SP q`, which parses as 0). Both must return `.default` so the
    /// renderer resolves the user's configured style — a leaked hard block here was permanent,
    /// because attach replays the raw scrollback tail (reset sequence included) at every launch.
    func testDECSCUSRResetReturnsToDefault() {
        let term = HarnessGridTerminal(cols: 10, rows: 2)!
        term.feed("\u{1b}[2 q") // steady block (vim normal mode, etc.)
        XCTAssertEqual(term.readGrid()!.cursor.shape, .block)
        term.feed("\u{1b}[0 q")
        XCTAssertEqual(term.readGrid()!.cursor.shape, .default)
        XCTAssertNil(term.readGrid()!.cursor.blinking)
        term.feed("\u{1b}[5 q") // blinking bar
        XCTAssertEqual(term.readGrid()!.cursor.shape, .bar)
        term.feed("\u{1b}[ q") // bare reset: missing Ps defaults to 0
        XCTAssertEqual(term.readGrid()!.cursor.shape, .default)
        XCTAssertNil(term.readGrid()!.cursor.blinking)
    }

    /// Replay shape: attach does RIS then re-feeds the persisted byte tail. A tail that ends in
    /// the standard exit-reset must leave the cursor on the user default, not a stale program shape.
    func testDECSCUSRReplayedTailEndsOnDefault() {
        let tail = "\u{1b}[2 q" + "some output" + "\u{1b}[0 q"
        let term = HarnessGridTerminal(cols: 20, rows: 2)!
        term.feed(tail)
        XCTAssertEqual(term.readGrid()!.cursor.shape, .default)
        term.feed("\u{1b}c") // RIS (what attach sends before the replay)
        term.feed(tail)      // replayed scrollback bytes
        XCTAssertEqual(term.readGrid()!.cursor.shape, .default)
        XCTAssertNil(term.readGrid()!.cursor.blinking)
    }

    func testOSC8HyperlinkStampsCellsAndSurvivesSGRReset() {
        let term = HarnessGridTerminal(cols: 20, rows: 2)!
        // Open a link, print text (with an SGR reset mid-link), then close it.
        term.feed("\u{1b}]8;;https://example.com\u{1b}\\A\u{1b}[0mB\u{1b}]8;;\u{1b}\\C")
        let grid = term.readGrid()!
        let idA = grid.cell(row: 0, col: 0)!.hyperlinkID
        let idB = grid.cell(row: 0, col: 1)!.hyperlinkID
        XCTAssertNotEqual(idA, 0, "A is inside the link")
        XCTAssertEqual(idB, idA, "SGR reset must NOT clear the OSC 8 link")
        XCTAssertEqual(term.hyperlinkURL(id: idA), "https://example.com")
        XCTAssertEqual(grid.cell(row: 0, col: 2)!.hyperlinkID, 0, "C is after OSC 8 ;; — no link")
    }

    func testURLAutoDetection() {
        let line = "see https://foo.com/x now"
        let start = line.distance(from: line.startIndex, to: line.range(of: "https")!.lowerBound)
        XCTAssertEqual(URLDetection.url(in: line, at: start + 3), "https://foo.com/x")
        XCTAssertNil(URLDetection.url(in: line, at: 0), "the leading 'see' is not a URL")
    }

    func testSynchronizedOutputModeAndDECRQM() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        var responses = Data()
        term.onResponse = { responses.append($0) }
        XCTAssertFalse(term.modes.synchronizedOutput)
        term.feed("\u{1b}[?2026h")
        XCTAssertTrue(term.modes.synchronizedOutput, "CSI ?2026h begins a synchronized frame")
        // DECRQM query while set → reports state 1 (set).
        term.feed("\u{1b}[?2026$p")
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}[?2026;1$y")
        term.feed("\u{1b}[?2026l")
        XCTAssertFalse(term.modes.synchronizedOutput, "CSI ?2026l ends the frame")
    }

    /// A pathological unterminated OSC (and a flood of intermediates) must be bounded by the
    /// parser caps and must not wedge it — normal output after the sequence still renders.
    func testParserBoundsHostileSequencesAndRecovers() {
        let term = HarnessGridTerminal(cols: 20, rows: 4)!
        // 2 MiB OSC payload with no terminator, then a BEL ends it, then real text.
        term.feed("\u{1b}]0;" + String(repeating: "X", count: 2_000_000) + "\u{07}hello")
        // A flood of CSI intermediates, then a final byte, then more text.
        term.feed("\u{1b}[" + String(repeating: " ", count: 100_000) + "mWORLD")
        let grid = term.readGrid()!
        // "hello" landed at the start; the parser recovered from both pathological sequences.
        let row0 = (0 ..< 5).compactMap { grid.cell(row: 0, col: $0)?.codepoint }.compactMap { UnicodeScalar($0).map(Character.init) }
        XCTAssertEqual(String(row0), "hello")
    }

    func testAutowrapDisabledOverwritesLastColumn() {
        // ?7l disables DECAWM; subsequent glyphs pile up on the last column.
        let grid = read("\u{1b}[?7l" + String(repeating: "a", count: 80) + "XY", cols: 80, rows: 24)
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 79)?.codepoint, UInt32(UnicodeScalar("Y").value))
    }

    func testLineFeedScrollsAtBottom() {
        let grid = read("a\r\nb\r\nc\r\nd", cols: 10, rows: 3)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("b").value))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, UInt32(UnicodeScalar("d").value))
    }

    func testEraseInLine() {
        let grid = read("hello\u{1b}[2K", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, 0)
    }

    func testEraseInDisplayClearsEverything() {
        let grid = read("line1\r\nline2\u{1b}[2J", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, 0)
    }

    func testDeleteCharactersShiftsLeft() {
        // "abcdef", home, DCH 2 -> "cdef".
        let grid = read("abcdef\u{1b}[H\u{1b}[2P", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("d").value))
    }

    func testInsertCharactersShiftsRight() {
        // "abc", home, ICH 2 -> "  abc".
        let grid = read("abc\u{1b}[H\u{1b}[2@", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, UInt32(UnicodeScalar("a").value))
    }

    func testSaveRestoreCursor() {
        let grid = read("\u{1b}[5;5H\u{1b}7\u{1b}[10;10H\u{1b}8", cols: 80, rows: 24)
        XCTAssertEqual(grid.cursor.row, 4)
        XCTAssertEqual(grid.cursor.col, 4)
    }

    func testUTF8MultibyteDecoding() {
        // "héllo": é = U+00E9 (2-byte UTF-8).
        let grid = read("héllo", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0x68)   // h
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0xE9)   // é
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0x6C)   // l
    }

    func testCursorVisibilityMode() {
        XCTAssertFalse(read("\u{1b}[?25l").cursor.visible)
        XCTAssertTrue(read("\u{1b}[?25l\u{1b}[?25h").cursor.visible)
    }

    func testResizePreservesTopLeftContent() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        term.feed("hi")
        term.resize(cols: 100, rows: 50)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cols, 100)
        XCTAssertEqual(grid.rows, 50)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("h").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("i").value))
    }

    func testAlternateScreenSwapAndRestore() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        term.feed("primary")
        term.feed("\u{1b}[?1049h") // enter alt + clear
        term.feed("alt")
        var grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("a").value))
        term.feed("\u{1b}[?1049l") // leave alt -> primary restored
        grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("p").value))
    }

    func testDeviceStatusReportRespondsWithCursorPosition() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[3;7H\u{1b}[6n")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[3;7R")
    }

    func testDeviceAttributesResponse() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[c")
        // VT220 class (62) advertising Sixel (4) and ANSI color (22).
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[?62;4;22c")
    }

    func testSecondaryDeviceAttributesResponse() {
        // `CSI > c` — secondary DA. The `>` private marker routes it through handlePrivateMode;
        // it must still produce a `CSI > 1 ; <ver> ; 0 c` identity reply, not be dropped.
        let emu = TerminalEmulator(cols: 80, rows: 24)
        emu.secondaryDAVersion = 110
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[>c")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[>1;110;0c")
    }

    func testXTVersionResponse() {
        // `CSI > q` — XTVERSION. Reply is `DCS > | <name> <version> ST`. Capability-detecting
        // tools (Claude Code) read this to recognize which terminal they're in.
        let emu = TerminalEmulator(cols: 80, rows: 24)
        emu.terminalName = "Harness"
        emu.terminalVersion = "1.1.2"
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[>q")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}P>|Harness 1.1.2\u{1b}\\")
    }

    func testXTVersionUsesCompatibleIdentityWhenSet() {
        // Compatible mode reports `ghostty` so tools enable Kitty-keyboard / Shift+Enter today.
        let emu = TerminalEmulator(cols: 80, rows: 24)
        emu.terminalName = "ghostty"
        emu.terminalVersion = "1.1.2"
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[>q")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}P>|ghostty 1.1.2\u{1b}\\")
    }

    func testTitleOSC() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var title: String?
        emu.onTitleChange = { title = $0 }
        emu.feed("\u{1b}]0;My Title\u{07}")
        XCTAssertEqual(title, "My Title")
    }

    func testBellExecutes() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var rang = false
        emu.onBell = { rang = true }
        emu.feed("\u{07}")
        XCTAssertTrue(rang)
    }

    func testCurlyUnderlineSubparam() {
        // SGR 4:3 = curly underline (colon sub-parameter form).
        let grid = read("\u{1b}[4:3mA")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underline, .curly)
    }

    func testDottedAndDashedUnderlineSubparams() {
        XCTAssertEqual(read("\u{1b}[4:4mA").cell(row: 0, col: 0)?.underline, .dotted)
        XCTAssertEqual(read("\u{1b}[4:5mA").cell(row: 0, col: 0)?.underline, .dashed)
    }

    func testColonForm256Color() {
        let grid = read("\u{1b}[38:5:208mO")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(208))
    }

    func testColonFormTrueColor() {
        // 38:2:r:g:b (no colorspace id slot).
        let grid = read("\u{1b}[38:2:10:20:30mX")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .rgb(r: 10, g: 20, b: 30))
    }

    func testColonFormTrueColorWithColorspaceSlot() {
        // 38:2::r:g:b (empty colorspace id) -> group [38,2,0,10,20,30].
        let grid = read("\u{1b}[38:2::10:20:30mX")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .rgb(r: 10, g: 20, b: 30))
    }

    func testUnderlineColorSemicolon() {
        let grid = read("\u{1b}[4;58;5;9mU")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underline, .single)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underlineColor, .palette(9))
    }

    func testScrollRegionConstrainsLineFeed() {
        // Set region rows 1..2 (1-based 2;3), fill, ensure scroll stays inside region.
        let term = HarnessGridTerminal(cols: 10, rows: 4)!
        term.feed("\u{1b}[2;3r")      // DECSTBM rows 2..3 -> homes cursor
        term.feed("\u{1b}[2;1HA\r\nB\r\nC") // print within region, force a scroll
        let grid = term.readGrid()!
        // Row 0 (outside region) must stay untouched/blank.
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
    }

    func testInvalidDECSTBMIsNoOpAndPreservesRegionAndCursor() {
        // After a valid region (rows 2..3), an invalid DECSTBM must be a complete no-op in
        // xterm/Ghostty: it must NOT reset the region to full screen or home the cursor.
        // `ESC[1;1r` (top==bottom) and `ESC[5;3r` (top>bottom) are both degenerate.
        for bad in ["\u{1b}[1;1r", "\u{1b}[5;3r"] {
            let term = HarnessGridTerminal(cols: 10, rows: 4)!
            term.feed("\u{1b}[2;3r")        // valid region rows 2..3 -> homes cursor
            term.feed("\u{1b}[3;4HX")       // place cursor + a sentinel inside the region
            term.feed(bad)                  // degenerate DECSTBM — must be ignored
            // Force a scroll inside the region; row 0 must stay blank if containment held.
            term.feed("\u{1b}[2;1HA\r\nB\r\nC")
            let grid = term.readGrid()!
            XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0,
                           "region clobbered by invalid DECSTBM \(bad)")
        }
    }

    func testBareDECSTBMResetsToFullScreenAndHomes() {
        // `ESC[r` (params absent) is the legitimate reset: full-screen region + home. The
        // invalid-DECSTBM no-op fix must NOT regress this path.
        let term = HarnessGridTerminal(cols: 10, rows: 4)!
        term.feed("\u{1b}[2;3r")        // shrink region first
        term.feed("\u{1b}[3;5H")        // move cursor away from home
        term.feed("\u{1b}[r")           // reset region -> full screen + home
        var grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 0)
        // Region is now the full screen: place a sentinel on row 0, then scroll the whole
        // screen. The sentinel must move off row 0 (it is no longer pinned outside a region).
        term.feed("\u{1b}[1;1HZ")       // sentinel on row 0
        term.feed("\u{1b}[4;1H\n")      // line feed at bottom -> full-screen scroll up
        grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0,
                       "row 0 should have scrolled when the region is full-screen")
    }

    func testBareDECSTBMHomesOnSingleRowGrid() {
        // Regression: on a 1-row grid the full-screen identity degenerates to top==bottom==0,
        // so a `t < b` guard would silently drop the `ESC[r` cursor-home. 1-row grids are
        // reachable (status-line panes, single-row splits). The reset must still home.
        let term = HarnessGridTerminal(cols: 10, rows: 1)!
        term.feed("\u{1b}[1;5H")        // move cursor to col 4 (1-based col 5)
        var grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.col, 4, "precondition: cursor parked at col 4")
        term.feed("\u{1b}[r")           // bare DECSTBM -> full-screen reset must home
        grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 0, "ESC[r must home the cursor on a 1-row grid")
    }

    func testExplicitDegenerateDECSTBMNoOpsOnSingleRowGrid() {
        // `ESC[2;2r` on a 1-row grid is an explicit degenerate request (top==bottom==row 1),
        // NOT the full-screen identity (which arrives as top=0,bottom=rows-1). It clamps to
        // (0,0) but must still no-op: the cursor must stay put, unlike bare `ESC[r`.
        let term = HarnessGridTerminal(cols: 10, rows: 1)!
        term.feed("\u{1b}[1;5H")        // move cursor to col 4
        term.feed("\u{1b}[2;2r")        // explicit degenerate region -> must be ignored
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 4, "explicit degenerate DECSTBM must not home")
    }

    func testDECRCWithoutPriorSaveRestoresDefaultPen() {
        // `ESC[31m ESC[2;6H ESC8 X` with no prior DECSC: xterm/Ghostty home the cursor AND
        // reset the SGR pen, so X prints at (0,0) with the DEFAULT (no) foreground, not red.
        let grid = read("\u{1b}[31m\u{1b}[2;6H\u{1b}8X", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("X"))
        // Fully qualify: a bare `.none` would resolve to Optional.none, not TerminalGridColor.none.
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, TerminalGridColor.none)
    }

    func testDECRCWithoutPriorSaveClearsBoldPen() {
        // Same no-save path, bold instead of color: the restored default pen must clear bold.
        let grid = read("\u{1b}[1m\u{1b}[2;6H\u{1b}8Y", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("Y"))
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.bold, false)
    }

    func testRISClearsSavedCursor() {
        // `ESC[31m ESC[5;5H ESC7 ESCc ESC8 X`: DECSC saves (4,4)+red, then RIS (ESCc) must
        // drop that save. The following DECRC therefore restores defaults — X prints at (0,0)
        // with the DEFAULT (no) foreground, not back at (4,4) in red.
        let grid = read("\u{1b}[31m\u{1b}[5;5H\u{1b}7\u{1b}c\u{1b}8X", cols: 80, rows: 24)
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 1)   // home + one cell advanced by the printed X
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, codepoint("X"))
        // Fully qualify: a bare `.none` would resolve to Optional.none, not TerminalGridColor.none.
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, TerminalGridColor.none)
    }

    func testDECSTBMInvalidRegionOnTwoRowGrid() {
        // `ESC[2;1r` on a 2-row grid is an explicit inverted request (pre-clamp top=1,bottom=0),
        // NOT the full-screen identity. It must be a complete no-op: region + cursor unchanged.
        // `ESC[r` on the same grid must still home, mirroring the 1-row conformance tests.
        let term = HarnessGridTerminal(cols: 10, rows: 2)!
        term.feed("\u{1b}[2;5H")        // move cursor to row 1, col 4 (1-based 2;5)
        term.feed("\u{1b}[2;1r")        // inverted region -> must be ignored
        var grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 1, "inverted DECSTBM must not home")
        XCTAssertEqual(grid.cursor.col, 4, "inverted DECSTBM must not home")
        // Region untouched: place a sentinel on row 0, scroll the full screen; row 0 must move.
        term.feed("\u{1b}[1;1HZ")       // sentinel on row 0
        term.feed("\u{1b}[2;1H\n")      // line feed at bottom -> full-screen scroll up
        grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0,
                       "region clobbered: row 0 should have scrolled (full-screen region)")
        // Bare `ESC[r` on the 2-row grid still homes.
        term.feed("\u{1b}[2;5H")        // park cursor away from home
        term.feed("\u{1b}[r")           // bare DECSTBM -> full-screen reset must home
        grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 0, "ESC[r must home the cursor on a 2-row grid")
    }
}
