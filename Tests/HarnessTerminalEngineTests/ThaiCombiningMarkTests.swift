import XCTest
@testable import HarnessTerminalEngine

/// Thai (and any combining-mark script) must stack zero-width marks onto the preceding base cell
/// instead of dropping them or letting them consume their own column. These tests drive the engine
/// through `TerminalEmulator.feed` (the bulk codepoint-run path) and assert the resulting grid,
/// then re-check the scalar-by-scalar path agrees.
///
/// See `Harness-Thai-Combining-Fix-Design.md` for the full design; this is the engine slice
/// (width table + cell storage + attach-instead-of-drop).
final class ThaiCombiningMarkTests: XCTestCase {
    private func term(_ cols: Int = 12, _ rows: Int = 4) -> TerminalEmulator {
        TerminalEmulator(cols: cols, rows: rows)
    }

    private func cell(_ snap: TerminalGridSnapshot, _ row: Int, _ col: Int) -> TerminalGridCell {
        snap.cells[row * snap.cols + col]
    }

    // MARK: - The core fix

    /// "ที่" = ท(0E17) + ◌ี(0E35, upper vowel) + ◌่(0E48, tone). Both marks are width 0 and must
    /// stack onto the single base cell; the cursor advances exactly once.
    func testThaiSyllableStacksIntoOneCell() {
        let t = term()
        t.feed("ที่")
        let g = t.readGrid()

        let base = cell(g, 0, 0)
        XCTAssertEqual(base.codepoint, 0x0E17, "base consonant ท")
        XCTAssertEqual(base.combining0, 0x0E35, "upper vowel ◌ี in slot 0")
        XCTAssertEqual(base.combining1, 0x0E48, "tone ◌่ in slot 1")
        XCTAssertEqual(base.cluster, "ที่", "cluster reconstructs the full syllable")

        XCTAssertEqual(g.cursor.col, 1, "two width-0 marks must not advance the cursor")
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0, "the next cell stays blank — no explosion")
    }

    /// "รีวิว" = ร ◌ี ว ◌ิ ว. The two upper vowels were already width 0 but used to be DROPPED;
    /// they must now survive on their base cells, and nothing explodes.
    func testReviewWordNeitherDropsNorExplodes() {
        let t = term()
        t.feed("รีวิว")
        let g = t.readGrid()

        // รีวิว = ร ◌ี ว ◌ิ ว → 3 base cells, each upper vowel folded onto its base.
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E23) // ร
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0E35) // ◌ี on ร
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0x0E27) // ว
        XCTAssertEqual(cell(g, 0, 1).combining0, 0x0E34) // ◌ิ on the 1st ว
        XCTAssertEqual(cell(g, 0, 2).codepoint, 0x0E27) // ว
        XCTAssertEqual(cell(g, 0, 2).combining0, 0, "the 2nd ว carries no mark")

        XCTAssertEqual(g.cursor.col, 3, "3 base cells (the two vowels add no columns)")

        let reconstructed = (0 ..< 3).map { cell(g, 0, $0).cluster }.joined()
        XCTAssertEqual(reconstructed, "รีวิว")
    }

    /// SARA AM (◌ำ, 0x0E33) is decomposed on input (issue #66) into its canonical-compatibility
    /// pair: the NIKHAHIT (0x0E4D, an above-base combining mark) folds onto the current base, and
    /// the SARA AA (0x0E32, a width-1 spacing vowel) takes the next cell. The syllable still spans
    /// two columns (one base cell + one spacing cell), but the above-base piece now rides the base's
    /// cluster bitmap so a marked base no longer orphans a lone SARA AM cell into a dotted circle.
    func testSaraAmDecomposesOntoMarkedBase() {
        let t = term()
        t.feed("ก่ำ") // ก(0E01) + ◌่(0E48, tone) + ◌ำ(0E33) → ก + ◌่ + ◌ํ, then า

        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E01) // ก
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0E48) // tone stacks on ก
        XCTAssertEqual(cell(g, 0, 0).combining1, 0x0E4D) // SARA AM's NIKHAHIT folds on as the 2nd mark
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0x0E32, "SARA AM's SARA AA takes its own spacing cell")
        XCTAssertEqual(cell(g, 0, 1).combining0, 0, "the spacing vowel carries no mark of its own")
        XCTAssertEqual(g.cursor.col, 2, "two columns: marked base + spacing vowel")
    }

    /// SARA AM after an UNMARKED base: the NIKHAHIT folds onto the base (now its first mark) and the
    /// SARA AA takes the next cell. `ทำ` and `รำ` already rendered fine pre-fix (base + SARA AM
    /// shared one CoreText run); the decomposition keeps them a two-column base+vowel pair and folds
    /// search/copy onto the same scalars as the marked case.
    func testSaraAmDecomposesOntoUnmarkedBase() {
        let t = term()
        t.feed("ทำ") // ท(0E17) + ◌ำ(0E33) → ท + ◌ํ, then า
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E17) // ท
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0E4D, "NIKHAHIT folds onto the unmarked base")
        XCTAssertEqual(cell(g, 0, 0).combining1, 0, "only one mark on the base")
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0x0E32, "SARA AA in its own cell")
        XCTAssertEqual(g.cursor.col, 2)
    }

    /// SARA AM with NO attachable base (orphan at column 0) keeps the FAITHFUL original U+0E33 cell
    /// rather than silently dropping its NIKHAHIT and emitting a bare SARA AA. The split only fires
    /// when the NIKHAHIT actually folds onto a base, so this degenerate input round-trips losslessly.
    func testOrphanSaraAmKeepsOriginalScalar() {
        let t = term()
        t.feed("ำ") // SARA AM at column 0, no preceding base
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E33, "orphan SARA AM stays its own faithful cell")
        XCTAssertEqual(cell(g, 0, 0).combining0, 0)
        XCTAssertEqual(g.cursor.col, 1)
    }

    /// SARA AM after a base whose two inline mark slots are ALREADY full (a 2-mark cluster) cannot
    /// fold its NIKHAHIT, so it keeps the faithful original U+0E33 cell instead of dropping the mark.
    func testSaraAmAfterFullClusterKeepsOriginalScalar() {
        let t = term()
        t.feed("ที่ำ") // ท + ◌ี + ◌่ (both slots full), then SARA AM
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E17)
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0E35)
        XCTAssertEqual(cell(g, 0, 0).combining1, 0x0E48, "base already carries two marks")
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0x0E33, "SARA AM stays faithful (NIKHAHIT couldn't attach)")
        XCTAssertEqual(g.cursor.col, 2)
    }

    /// `น้ำ` (the headline #66 word: base + tone + SARA AM) lays out as exactly two columns —
    /// `น + ้ + ํ` (base + tone + NIKHAHIT) then `า` (SARA AA) — and the cursor advances by two.
    func testNamWaterLaysOutAsTwoColumns() {
        let t = term()
        t.feed("น้ำ") // น(0E19) + ◌้(0E49, tone) + ◌ำ(0E33)
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x0E19) // น
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0E49) // tone ◌้
        XCTAssertEqual(cell(g, 0, 0).combining1, 0x0E4D) // SARA AM's NIKHAHIT (fits the 2-mark cap)
        XCTAssertEqual(cell(g, 0, 1).codepoint, 0x0E32) // SARA AA
        XCTAssertEqual(cell(g, 0, 1).combining0, 0)
        XCTAssertEqual(cell(g, 0, 2).codepoint, 0, "no third column — SARA AM never explodes to a mark cell")
        XCTAssertEqual(g.cursor.col, 2, "น้ำ occupies exactly two columns")
    }

    // MARK: - Edge cases

    /// A combining mark over a wide (double-width) base attaches to the `.wide` head, never the
    /// reserved `.spacerTail`.
    func testMarkAfterWideBaseAttachesToHead() {
        let t = term()
        t.feed("世\u{0301}") // wide CJK + combining acute
        let g = t.readGrid()

        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x4E16)
        XCTAssertEqual(cell(g, 0, 0).width, .wide)
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0301, "mark lands on the wide head")
        XCTAssertEqual(cell(g, 0, 1).width, .spacerTail)
        XCTAssertEqual(cell(g, 0, 1).combining0, 0, "spacer tail is never decorated")
    }

    /// A combining mark over a real space (0x20) attaches; over blank padding (codepoint 0) it is
    /// dropped so padding never becomes non-blank.
    func testMarkOverSpaceAttachesButNotOverBlank() {
        let t = term()
        t.feed(" \u{0301}") // space then combining acute
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, 0x20)
        XCTAssertEqual(cell(g, 0, 0).combining0, 0x0301, "mark attaches to a real space")

        let t2 = term()
        t2.feed("\u{0301}") // leading mark, no base on a fresh row
        let g2 = t2.readGrid()
        XCTAssertEqual(cell(g2, 0, 0).codepoint, 0, "orphan leading mark is dropped")
        XCTAssertEqual(cell(g2, 0, 0).combining0, 0)
    }

    /// A mark arriving while the cursor is pinned at the last column (pending-wrap armed) attaches
    /// to that last cell and must NOT trigger a wrap; the next BASE glyph still wraps.
    func testMarkWithPendingWrapAttachesAndDoesNotWrap() {
        let t = term(3, 3)
        t.feed("abc")            // fills the row; cursor pinned at col 2, pendingWrap armed
        t.feed("\u{0301}")       // combining acute — must attach to 'c', not wrap
        var g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 2).codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertEqual(cell(g, 0, 2).combining0, 0x0301)
        XCTAssertEqual(g.cursor.col, 2, "mark must not move the cursor or wrap")

        t.feed("d")              // the next base glyph DOES wrap
        g = t.readGrid()
        XCTAssertEqual(cell(g, 1, 0).codepoint, UInt32(UnicodeScalar("d").value), "base wraps to next row")
    }

    /// Writing a new base over a cell that carried marks clears the stale marks (fresh cell).
    func testOverwriteClearsStaleMarks() {
        let t = term()
        t.feed("ที่")        // cell 0 now has two combining marks
        t.feed("\r")          // carriage return → col 0
        t.feed("x")           // overwrite the base
        let g = t.readGrid()
        XCTAssertEqual(cell(g, 0, 0).codepoint, UInt32(UnicodeScalar("x").value))
        XCTAssertEqual(cell(g, 0, 0).combining0, 0, "overwrite drops stale combining0")
        XCTAssertEqual(cell(g, 0, 0).combining1, 0, "overwrite drops stale combining1")
    }

    /// `appendCombining` fills both inline slots then refuses further marks (MVP caps at 2).
    func testThirdMarkIsDropped() {
        var c = TerminalGridCell(codepoint: 0x0E17)
        XCTAssertTrue(c.appendCombining(0x0E35))
        XCTAssertTrue(c.appendCombining(0x0E48))
        XCTAssertFalse(c.appendCombining(0x0E4C), "third mark exceeds the 2-slot inline bound")
        XCTAssertEqual(c.cluster, "ที่")
    }

    // MARK: - Path parity

    /// The bulk codepoint-run path (`feed`) and the scalar-by-scalar path (`feedScalarwise`) must
    /// land on identical grids for Thai — both route width-0 scalars through `attachCombining`.
    func testBulkAndScalarwisePathsAgree() {
        for s in ["ที่แล้ว", "รีวิว", "ก่ำ", "ปัญหาที่ยากที่สุด"] {
            let bulk = term(24, 4)
            bulk.feed(Array(s.utf8))
            let scalar = term(24, 4)
            scalar.feedScalarwise(Array(s.utf8))
            XCTAssertEqual(bulk.readGrid(), scalar.readGrid(), "grids differ for \(s)")
        }
    }

    // MARK: - Read surfaces

    /// Capture-pane reconstruction includes the combining marks (the cluster), not just the base.
    func testCaptureReconstructsThaiClusters() {
        let t = term(); t.feed("ที่แล้ว")
        XCTAssertEqual(t.captureLines(joinWrapped: false).first, "ที่แล้ว")
    }

    /// Find-in-buffer matches a Thai cluster at its single grid column (the marks add no columns).
    func testSearchMatchesThaiClusterAtColumn() {
        let t = term(); t.feed("ที่ยาก")
        let cells = (0 ..< t.cols).map { cell(t.readGrid(), 0, $0) }
        let hits = TerminalBufferSearch.matches(query: "ที่", lineCount: 1, line: { _ in cells })
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.columns, 0 ..< 1, "ที่ occupies exactly one column")
    }

    /// Search normalizes both sides (NFC), so a precomposed query matches a decomposed cell stream.
    func testSearchNormalizesNFCvsNFD() {
        let t = term(); t.feed("e\u{0301}f") // decomposed: e + combining acute, then f
        let cells = (0 ..< t.cols).map { cell(t.readGrid(), 0, $0) }
        let hits = TerminalBufferSearch.matches(query: "\u{00E9}", lineCount: 1, line: { _ in cells }) // precomposed é
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.columns, 0 ..< 1)
    }

    /// SARA AM (U+0E33) is a width-1 SPACING vowel stored in its own cell, yet "ทำ" is a single Swift
    /// Character — so a per-Character needle would never match. The needle is segmented like cells
    /// (by scalar width), so SARA AM words match across their two cells.
    func testSearchMatchesSaraAmWords() {
        let t = term(); t.feed("ทำนาย")
        let cells = (0 ..< t.cols).map { cell(t.readGrid(), 0, $0) }
        let hits = TerminalBufferSearch.matches(query: "ทำ", lineCount: 1, line: { _ in cells })
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.columns, 0 ..< 2, "ทำ spans its two cells (consonant + SARA AM)")
    }

    /// #66: SARA AM after a MARKED base still matches. The engine stores `น้ำ` decomposed (base +
    /// tone + NIKHAHIT, then SARA AA), and `TerminalBufferSearch` applies the SAME SARA AM split to
    /// the query — so a precomposed `น้ำ` needle (U+0E33 and all) matches the decomposed cells.
    /// SARA AM has only a COMPATIBILITY decomposition, so NFC alone would NOT reconcile the two; the
    /// query-side split is what keeps this matching.
    func testSearchMatchesSaraAmAfterMarkedBase() {
        for word in ["น้ำ", "ต่ำ", "ซ้ำ", "ค่ำ", "ย้ำ"] {
            let t = term(); t.feed(word + "ใจ")
            let cells = (0 ..< t.cols).map { cell(t.readGrid(), 0, $0) }
            let hits = TerminalBufferSearch.matches(query: word, lineCount: 1, line: { _ in cells })
            XCTAssertEqual(hits.count, 1, "expected one match for \(word)")
            XCTAssertEqual(hits.first?.columns, 0 ..< 2, "\(word) spans two columns")
        }
    }

    /// The query splitter mirrors the engine's SARA AM FALLBACK: a leading `ำ` query keeps U+0E33,
    /// so it matches a faithful orphan SARA AM cell and does NOT false-match a plain SARA AA cell.
    func testSearchLeadingSaraAmMatchesFaithfulCellOnly() {
        // A faithful orphan SARA AM cell (engine keeps U+0E33 when it can't attach) IS matched.
        let orphan = [TerminalGridCell(codepoint: 0x0E33)]
        let hit = TerminalBufferSearch.matches(query: "ำ", lineCount: 1, line: { _ in orphan })
        XCTAssertEqual(hit.count, 1, "leading ำ query matches a faithful U+0E33 cell")

        // A plain SARA AA cell (U+0E32) must NOT be matched by a ำ (U+0E33) query.
        let saraAa = [TerminalGridCell(codepoint: 0x0E32)]
        let miss = TerminalBufferSearch.matches(query: "ำ", lineCount: 1, line: { _ in saraAa })
        XCTAssertEqual(miss.count, 0, "ำ must not false-match a bare SARA AA")
    }

    /// A SARA AM query after a unit that already carries two marks keeps U+0E33, matching the
    /// engine's faithful fallback cell for `ที่ำ`-style input.
    func testSearchSaraAmAfterFullClusterMatchesFaithfulCell() {
        let t = term(); t.feed("ที่ำ")
        let cells = (0 ..< t.cols).map { cell(t.readGrid(), 0, $0) }
        let hits = TerminalBufferSearch.matches(query: "ที่ำ", lineCount: 1, line: { _ in cells })
        XCTAssertEqual(hits.count, 1, "ที่ำ matches its two faithful cells")
        XCTAssertEqual(hits.first?.columns, 0 ..< 2)
    }

    /// Copy / capture-pane fidelity is PINNED to the deliberate decomposition (issue #66, approach
    /// A). Capturing `น้ำ` yields `น ้ ํ า` (U+0E19 U+0E49 U+0E4D U+0E32), NOT the original
    /// `น ้ ำ` (…U+0E33). This is the accepted tradeoff: SARA AM's only decomposition is a
    /// COMPATIBILITY one, so the round-trip is not byte-identical, but it is visually faithful and
    /// re-composable via NFKC. If a future change drops the input split, this test must change too.
    func testCaptureReflectsSaraAmDecomposition() {
        let t = term(); t.feed("น้ำ")
        let captured = t.captureLines(joinWrapped: false).first ?? ""
        let scalars = captured.unicodeScalars.map { $0.value }
        XCTAssertEqual(scalars, [0x0E19, 0x0E49, 0x0E4D, 0x0E32],
                       "capture pins the decomposed SARA AM sequence (compatibility-only, by design)")
        // The decomposition is exactly the compatibility decomposition of the original word, so
        // NFKC of the captured text equals NFKC of the original — the loss is canonical-only and the
        // text is still semantically the same word (search reconciles it via the same query split).
        XCTAssertEqual(captured.precomposedStringWithCompatibilityMapping,
                       "น้ำ".precomposedStringWithCompatibilityMapping,
                       "NFKC recovers the original precomposed word — only canonical fidelity is lost")
    }

    // MARK: - Non-combining width-0 scalars

    /// Width-0 FORMAT scalars that are NOT grapheme extenders (ZWSP, BOM, bidi marks, word joiner)
    /// must be DROPPED, not folded onto the base — folding them would make `cluster` span two
    /// grapheme clusters (crashing `Character(cluster)` on the copy-mode path) and is semantically
    /// wrong. True combining marks (grapheme extenders) still fold.
    func testNonExtendingFormatScalarsAreDropped() {
        for fmt in [0x200B, 0xFEFF, 0x200E, 0x2060, 0x202E] as [UInt32] { // ZWSP, BOM, LRM, WJ, RLO
            let t = term()
            t.feed("A"); t.feed(String(UnicodeScalar(fmt)!)); t.feed("B")
            let g = t.readGrid()
            XCTAssertEqual(cell(g, 0, 0).codepoint, 0x41)
            XCTAssertEqual(cell(g, 0, 0).combining0, 0, "U+\(String(fmt, radix: 16)) must not fold onto the base")
            XCTAssertEqual(cell(g, 0, 0).cluster.count, 1, "cluster stays one grapheme")
            XCTAssertEqual(cell(g, 0, 1).codepoint, 0x42, "'B' is not consumed")
        }
    }
}
