import XCTest
@testable import HarnessTerminalEngine

/// Resize/reflow correctness net. The stated top priority is "reformat *perfectly* while resizing"
/// — a correctness claim — so every reflow change (the width-unchanged fast path, off-main commit,
/// and the logical-line history-model rewrite) is gated by this file. Two layers:
///
///   1. **Golden corpus** — a representative set of inputs reflowed across a width/height sweep, with
///      the resulting `[history ++ viewport]` layout + cursor + marks serialized to committed
///      `.golden` files (`ReflowGolden/`). This catches *drift*: a refactor that intends to be
///      byte-identical must reproduce these exactly. Regenerate intentionally with
///      `HARNESS_UPDATE_GOLDEN=1 swift test --filter ReflowCorpus`.
///   2. **Properties** — invariants reflow must hold at *any* width, asserted at test time (no
///      committed reference): content preservation, wide-char integrity (no orphaned spacer / split
///      wide glyph), attribute preservation, and shrink↔grow round-trip stability. These assert
///      correctness rather than "matches last run," so they also surface genuine bugs in the current
///      reflow, independent of any refactor.
final class ReflowCorpusTests: XCTestCase {
    // MARK: Corpus

    private struct Case {
        let name: String
        let cols: Int
        let rows: Int
        let feed: String
    }

    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

    private var corpus: [Case] {
        let prose = "the quick brown fox jumps over the lazy dog and then keeps on running far past the edge of the visible viewport so this line must soft-wrap several times"
        return [
            Case(name: "prose_softwrap", cols: 40, rows: 6,
                 feed: prose + "\r\n" + "second paragraph also long enough to wrap across the narrow width more than once for good measure\r\n"),
            Case(name: "hard_short", cols: 20, rows: 5,
                 feed: (0 ..< 12).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n"),
            Case(name: "wide_cjk", cols: 11, rows: 5,
                 feed: "宽字符测试一二三四五六七八九十\r\n漢字テストの行が折り返す\r\nmixed 宽 ascii 字 here\r\n"),
            Case(name: "emoji_mixed", cols: 9, rows: 4,
                 feed: "hi ☕📦🚀 ok done\r\nascii then 🎯🔥 tail\r\n"),
            Case(name: "prompt_marks", cols: 16, rows: 5,
                 feed: osc133("A") + "$ first command here\r\noutput line one wrapping\r\n" + osc133("A") + "$ second\r\nmore output\r\n"),
            Case(name: "cursor_midscreen", cols: 18, rows: 5,
                 feed: "line one content\r\nline two content\r\nline three\u{1b}[2;6Hmid"),
            // A soft-wrapped logical line with an INTERIOR erased gap: write a 30-char line that wraps
            // across rows at width 12, move the cursor back onto the first (still soft-wrapped) row and
            // erase to end-of-line (EL-0). The 6 erased trailing cells on that wrapped row are real
            // content (a hole inside the logical line), NOT the wide-deferral wrap padding — reflow and
            // capture must preserve them. Regression guard for the over-greedy gap-trim.
            Case(name: "erased_gap_wrapped", cols: 12, rows: 5,
                 feed: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123\u{1b}[1;7H\u{1b}[0K"),
        ]
    }

    /// Target geometries every corpus case is reflowed to: a very narrow width (heavy re-wrap), an
    /// odd width (wide-char boundary stress), a couple of moderate widths, and height-only changes.
    private let sweep: [(cols: Int, rows: Int)] = [
        (5, 5), (7, 6), (13, 5), (24, 6), (48, 4), (16, 12), (16, 3),
    ]

    // MARK: Serialization

    /// A deterministic, human-auditable fingerprint of the full buffer (`[history ++ viewport]`)
    /// after reflow: geometry + cursor, then each physical row's visible text (wide-char tails
    /// dropped, trailing blanks trimmed) and any OSC-133 mark. Reflow only *relocates* cells (never
    /// alters their attributes), so codepoint + width + position + cursor + marks captures all
    /// reflow-relevant state; attribute integrity is checked separately by `testAttributesPreserved`.
    private func serialize(_ term: TerminalEmulator) -> String {
        let cur = term.readGrid().cursor
        var out = "cols=\(term.cols) rows=\(term.rows) history=\(term.historyCount) "
            + "cursor=(\(cur.row),\(cur.col)) visible=\(cur.visible)\n"
        for i in 0 ..< term.bufferLineCount {
            var line = ""
            for cell in term.bufferLine(i) {
                switch cell.width {
                case .spacerTail:
                    continue // emitted with its wide head
                case .wide, .normal:
                    if cell.codepoint == 0 {
                        line += " "
                    } else if let scalar = Unicode.Scalar(cell.codepoint) {
                        line.unicodeScalars.append(scalar)
                    } else {
                        line += "\u{FFFD}"
                    }
                }
            }
            while line.hasSuffix(" ") { line.removeLast() }
            var tag = ""
            if let mark = term.mark(atBufferLine: i) {
                tag = " <mark exit=\(mark.exit.map(String.init) ?? "nil")>"
            }
            out += String(format: "[%04d] |", i) + line + "|" + tag + "\n"
        }
        return out
    }

    private var goldenDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ReflowGolden")
    }

    // MARK: Golden corpus

    func testReflowGoldenCorpus() throws {
        let update = ProcessInfo.processInfo.environment["HARNESS_UPDATE_GOLDEN"] == "1"
        let fm = FileManager.default
        if update { try fm.createDirectory(at: goldenDir, withIntermediateDirectories: true) }
        var missing: [String] = []
        for c in corpus {
            for target in sweep {
                let term = TerminalEmulator(cols: c.cols, rows: c.rows)
                term.maxScrollbackLines = 10_000
                term.feed(c.feed)
                term.resize(cols: target.cols, rows: target.rows)
                let actual = serialize(term)
                let fileName = "\(c.name)__\(c.cols)x\(c.rows)__to__\(target.cols)x\(target.rows).golden"
                let url = goldenDir.appendingPathComponent(fileName)
                if update {
                    try actual.write(to: url, atomically: true, encoding: .utf8)
                } else if let expected = try? String(contentsOf: url, encoding: .utf8) {
                    XCTAssertEqual(actual, expected, "reflow drift in \(fileName)")
                } else {
                    missing.append(fileName)
                }
            }
        }
        XCTAssertTrue(
            missing.isEmpty || update,
            "Missing \(missing.count) golden file(s); run `HARNESS_UPDATE_GOLDEN=1 swift test --filter ReflowCorpus` to generate. First few: \(missing.prefix(4).joined(separator: ", "))"
        )
    }

    // MARK: Properties (correctness invariants, no committed reference)

    /// Logical content (soft-wrapped rows re-joined) is invariant under any width change — reflow may
    /// re-wrap but must never lose, gain, duplicate, or reorder text.
    func testContentPreservedAcrossWidths() {
        for c in corpus {
            let term = TerminalEmulator(cols: c.cols, rows: c.rows)
            term.maxScrollbackLines = 10_000
            term.feed(c.feed)
            let original = logicalContent(term)
            for target in [5, 7, 13, 24, 48, 80] where target != c.cols {
                term.resize(cols: target, rows: c.rows)
                XCTAssertEqual(
                    logicalContent(term), original,
                    "content changed reflowing \(c.name) to width \(target)"
                )
            }
        }
    }

    /// No reflow at any width may produce an orphaned spacer tail or a wide head without its tail.
    func testWideCharIntegrity() {
        for c in corpus {
            for target in sweep {
                let term = TerminalEmulator(cols: c.cols, rows: c.rows)
                term.maxScrollbackLines = 10_000
                term.feed(c.feed)
                term.resize(cols: target.cols, rows: target.rows)
                for i in 0 ..< term.bufferLineCount {
                    let cells = term.bufferLine(i)
                    for (col, cell) in cells.enumerated() {
                        switch cell.width {
                        case .wide:
                            // A wide head needs room for its tail; it must never sit in the last
                            // column (reflow flushes the row before a wide glyph would straddle).
                            XCTAssertLessThan(col + 1, cells.count, "\(c.name)@\(target): wide head in last column, row \(i)")
                            if col + 1 < cells.count {
                                XCTAssertEqual(cells[col + 1].width, .spacerTail, "\(c.name)@\(target): wide head without spacer tail, row \(i) col \(col)")
                            }
                        case .spacerTail:
                            XCTAssertTrue(col > 0 && cells[col - 1].width == .wide, "\(c.name)@\(target): orphaned spacer tail, row \(i) col \(col)")
                        case .normal:
                            break
                        }
                    }
                }
            }
        }
    }

    /// Shrinking then growing back to the original width restores the original logical content
    /// (no cumulative drift from a re-wrap round trip).
    func testRoundTripStability() {
        for c in corpus {
            let term = TerminalEmulator(cols: c.cols, rows: c.rows)
            term.maxScrollbackLines = 10_000
            term.feed(c.feed)
            let original = logicalContent(term)
            for narrow in [5, 9, 17] where narrow != c.cols {
                term.resize(cols: narrow, rows: c.rows)
                term.resize(cols: c.cols, rows: c.rows)
                XCTAssertEqual(logicalContent(term), original, "\(c.name): width \(c.cols)→\(narrow)→\(c.cols) drifted")
            }
        }
    }

    /// Reflow relocates cells but must never alter their attributes: the multiset of non-blank cells
    /// is invariant under a width change.
    func testAttributesPreserved() {
        let term = TerminalEmulator(cols: 24, rows: 4)
        term.maxScrollbackLines = 10_000
        term.feed("\u{1b}[1;31mbold red text that is long enough to wrap\u{1b}[0m normal \u{1b}[4;32mgreen underline tail\u{1b}[0m\r\n")
        let before = nonBlankCellBag(term)
        for target in [7, 13, 40, 9] {
            term.resize(cols: target, rows: 4)
            XCTAssertEqual(nonBlankCellBag(term), before, "attributes/codepoints changed at width \(target)")
        }
    }

    // MARK: Helpers

    /// Logical lines (soft-wrap re-joined), each trailing-trimmed, with trailing empty lines dropped
    /// — content without padding, so the comparison is about characters, not blank cells.
    private func logicalContent(_ term: TerminalEmulator) -> [String] {
        var lines = term.captureLines(joinWrapped: true).map { line -> String in
            var s = line
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A sorted "bag" of every non-blank cell across the buffer (codepoint + full attributes,
    /// position-independent) so two layouts can be compared for cell-content equality.
    private func nonBlankCellBag(_ term: TerminalEmulator) -> [String] {
        var bag: [String] = []
        for i in 0 ..< term.bufferLineCount {
            for cell in term.bufferLine(i) where cell.width != .spacerTail && cell != .blank {
                bag.append("\(cell.codepoint)|\(cell.width)|b\(cell.bold)|i\(cell.italic)|u\(cell.underline)|fg\(cell.foreground)|bg\(cell.background)")
            }
        }
        return bag.sorted()
    }
}
