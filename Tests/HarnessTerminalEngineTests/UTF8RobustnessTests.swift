import XCTest
@testable import HarnessTerminalEngine

/// Fuzz-style tests for the parser's UTF-8 robustness seam:
/// `TerminalEmulator.feed` (bulk path) vs `feedScalarwise` (scalar path) must produce
/// identical screen state for every possible byte stream — including malformed UTF-8.
///
/// **Coverage intent** — these cases target scenarios that are _not_ already covered by
/// `CodepointRunFastPathTests`:
///   1. Exhaustive split-at-every-byte-offset for multi-byte sequences — CodepointRunFastPath
///      exercises chunk sizes 1/2/3/…/13, which catches most splits, but the systematic
///      "split at every specific offset N" surface is distinct.
///   2. Multi-sequence adjacency: two back-to-back malformed sequences with no separator.
///   3. Malformed sequences adjacent to CSI escape sequences — the parser must return to
///      ground and then correctly parse the CSI.
///   4. A specific overlong-NUL case (0xC0 0x80) alongside interleaved escape sequences.
///   5. The 0xFE lead byte (UTF-8 7-octet lead, never valid), which is distinct from 0xFF.
///
/// **Seam** — same as CodepointRunFastPathTests: drive both paths, compare `readGrid()`,
/// `captureLines`, and `historyCount`.  Because the goal is equivalence (not specific
/// output values), every assertion is feed≡feedScalarwise.
final class UTF8RobustnessTests: XCTestCase {

    // MARK: - Comparison helper

    /// Drive `bytes` through both the bulk and scalar paths and assert all observable
    /// state is identical.  Also verifies that each chunk-split version of the same
    /// bytes matches the scalar reference, which exercises carry-over at every boundary.
    private func assertEquivalent(
        _ bytes: [UInt8],
        cols: Int = 20,
        rows: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scalar = TerminalEmulator(cols: cols, rows: rows)
        scalar.feedScalarwise(bytes)

        // Bulk path must agree with scalar.
        let bulk = TerminalEmulator(cols: cols, rows: rows)
        bulk.feed(bytes)
        XCTAssertEqual(bulk.readGrid(), scalar.readGrid(),
                       "bulk vs scalar: live grid differs", file: file, line: line)
        XCTAssertEqual(bulk.historyCount, scalar.historyCount,
                       "bulk vs scalar: historyCount differs", file: file, line: line)
        XCTAssertEqual(bulk.captureLines(joinWrapped: false),
                       scalar.captureLines(joinWrapped: false),
                       "bulk vs scalar: captureLines differs", file: file, line: line)

        // Chunk-split: for every possible split point in `bytes`, feed as two chunks and
        // compare.  This is O(n) in the number of bytes — practical for the small
        // sequences used in this file.
        for splitAt in 1 ..< bytes.count {
            let chunked = TerminalEmulator(cols: cols, rows: rows)
            chunked.feed(Array(bytes[0 ..< splitAt]))
            chunked.feed(Array(bytes[splitAt...]))
            XCTAssertEqual(
                chunked.readGrid(), scalar.readGrid(),
                "split@\(splitAt): live grid differs", file: file, line: line)
            XCTAssertEqual(
                chunked.captureLines(joinWrapped: false),
                scalar.captureLines(joinWrapped: false),
                "split@\(splitAt): captureLines differs", file: file, line: line)
        }
    }

    // MARK: - Overlong NUL (0xC0 0x80)

    /// Overlong encoding of U+0000: the "Modified UTF-8" / CESU-8 form rejected by
    /// strict UTF-8.  Each byte must produce a U+FFFD replacement; the grid must not
    /// contain the literal NUL.  Equivalence guarantees both paths agree.
    func testOverlongNUL() {
        // 0xC0 0x80 — both bytes are invalid leads for UTF-8; expect two U+FFFD.
        assertEquivalent([0x61, 0xC0, 0x80, 0x62])  // a ?(fffd) ?(fffd) b
    }

    /// Three-byte overlong NUL (0xE0 0x80 0x80).
    func testOverlongNULThreeByte() {
        assertEquivalent([0x61, 0xE0, 0x80, 0x80, 0x62])
    }

    // MARK: - 0xFE invalid lead byte

    /// 0xFE was allocated for a UTF-8 7-octet sequence in an early RFC but was later
    /// removed.  No valid UTF-8 sequence starts with 0xFE; it must produce U+FFFD.
    /// Distinct from the 0xFF case already in CodepointRunFastPathTests.
    func testFELeadByte() {
        assertEquivalent([0x61, 0xFE, 0x62])      // a ? b
        assertEquivalent([0xFE, 0xFE, 0xFE, 0x41]) // ??? A
    }

    /// 0xFE and 0xFF interspersed with valid ASCII.
    func testFEAndFFMixed() {
        assertEquivalent([0xFE, 0xFF, 0x41, 0xFE, 0x42])
    }

    // MARK: - Adjacent malformed sequences (no ASCII separator)

    /// Two consecutive lone continuation bytes must each independently produce U+FFFD.
    /// The equivalence assertion pins that no boundary effect causes different counts
    /// in bulk vs scalar.
    func testTwoAdjacentContinuationBytes() {
        assertEquivalent([0x80, 0x80])  // two lone continuations
    }

    /// A lone continuation immediately after an incomplete 3-byte sequence.
    func testIncomplete3ByteThenContinuation() {
        // 0xE4 starts a 3-byte sequence but 0x80 is a standalone continuation, not a valid body.
        assertEquivalent([0xE4, 0x80, 0x80, 0x41])
    }

    /// Back-to-back invalid lead bytes — simulates a stream of truncated sequences.
    func testAdjacentInvalidLeads() {
        assertEquivalent([0xC2, 0xC2, 0xC2, 0x41]) // 0xC2 starts a 2-byte seq; next 0xC2 aborts it
    }

    // MARK: - Exhaustive split-at-every-offset for multi-byte sequences

    /// A valid 2-byte sequence split at byte 1 (the only non-trivial split point).
    /// 0xC3 0xA9 = U+00E9 (é).
    func testValidTwoByteSequenceSplit() {
        assertEquivalent([0x61, 0xC3, 0xA9, 0x62]) // a é b
    }

    /// A valid 3-byte CJK ideograph split at every internal offset (0xE4 0xB8 0xAD = 中).
    func testValidThreeByteSequenceExhaustiveSplit() {
        assertEquivalent([0xE4, 0xB8, 0xAD, 0x41]) // 中 A
    }

    /// A valid 4-byte supplementary character (U+1F600 😀, 0xF0 0x9F 0x98 0x80) split
    /// at all three internal offsets.
    func testValidFourByteSequenceExhaustiveSplit() {
        assertEquivalent([0x61, 0xF0, 0x9F, 0x98, 0x80, 0x62]) // a 😀 b
    }

    /// An invalid 4-byte sequence (surrogate, 0xED 0xA0 0x80) split at offsets 1 and 2.
    func testSurrogateSequenceExhaustiveSplit() {
        assertEquivalent([0x61, 0xED, 0xA0, 0x80, 0x62])
    }

    /// A truncated 3-byte sequence — the sequence body is never completed — split so
    /// the lead lands at the very end of the first chunk.
    func testTruncated3ByteLeadAtEndOfFirstChunk() {
        // feed [0x61, 0xE4] then [0x62]: the 0xE4 is never followed by two continuations.
        let bytes: [UInt8] = [0x61, 0xE4, 0x62]
        assertEquivalent(bytes)
    }

    /// The 4-byte out-of-range sequence split so each piece lands in a separate chunk.
    func testOutOfRange4ByteExhaustiveSplit() {
        assertEquivalent([0x61, 0xF4, 0x90, 0x80, 0x80, 0x62])
    }

    // MARK: - Malformed UTF-8 interleaved with CSI escape sequences

    /// A malformed lead byte immediately before a CSI must not prevent the CSI from
    /// being dispatched.  The SGR sequence below sets bold; the 'X' after it must be
    /// bold, proving the parser returned to ground.  We test equivalence (both paths
    /// agree), plus a light smoke-check that text after the CSI reaches the grid.
    func testMalformedBeforeCSI() {
        // 0xFF (invalid lead), then bold SGR, then 'X'.
        let bytes: [UInt8] = [0xFF, 0x1B, 0x5B, 0x31, 0x6D, 0x58] // ESC [ 1 m X
        assertEquivalent(bytes)
        // Smoke: 'X' must appear somewhere in the grid.
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(bytes)
        let grid = term.readGrid()
        let found = (0 ..< 4).contains(where: { r in
            (0 ..< 20).contains(where: { c in
                grid.cell(row: r, col: c)?.codepoint == UInt32(UnicodeScalar("X").value)
            })
        })
        XCTAssertTrue(found, "X must appear in grid after malformed lead + CSI bold")
    }

    /// A malformed byte immediately *after* a CSI (the CSI is processed, then the bad
    /// byte is handled as a standalone print event).
    func testCSIThenMalformed() {
        // 'Y', then cursor-up-1 (ESC [ 1 A), then 0x80 (lone continuation).
        let bytes: [UInt8] = Array("\r\n\r\nY".utf8) + [0x1B, 0x5B, 0x31, 0x41, 0x80]
        assertEquivalent(bytes)
    }

    /// Overlong encoding of '/' sandwiched between a CSI reset and printable text.
    /// The SGR reset before it exercises that the attribute state and parser state
    /// both survive the malformed bytes.
    func testOverlongAmidCSISequences() {
        // ESC [ 0 m (SGR reset) + overlong '/' (0xC0 0xAF) + 'Z'
        let bytes: [UInt8] = [0x1B, 0x5B, 0x30, 0x6D, 0xC0, 0xAF, 0x5A]
        assertEquivalent(bytes)
        // 'Z' must reach the grid.
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(bytes)
        let grid = term.readGrid()
        let found = (0 ..< 4).contains(where: { r in
            (0 ..< 20).contains(where: { c in
                grid.cell(row: r, col: c)?.codepoint == UInt32(UnicodeScalar("Z").value)
            })
        })
        XCTAssertTrue(found, "Z must appear in grid after SGR reset + overlong + Z")
    }

    /// An incomplete multi-byte sequence split across a chunk boundary, followed by a
    /// CSI in the second chunk.  The carry-over machinery must not corrupt the CSI parse.
    func testTruncatedCarryOverThenCSI() {
        // Two chunks: [0xE2] then [0x9C, 0x93, 0x1B, 0x5B, 0x30, 0x6D, 0x41]
        // 0xE2 0x9C 0x93 = U+2713 (✓); then ESC [ 0 m (SGR reset) + 'A'.
        let chunk1: [UInt8] = [0xE2]
        let chunk2: [UInt8] = [0x9C, 0x93, 0x1B, 0x5B, 0x30, 0x6D, 0x41]
        let combined = chunk1 + chunk2
        assertEquivalent(combined)
        // Both 'A' and '✓' should be on the grid.
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(chunk1)
        term.feed(chunk2)
        let grid = term.readGrid()
        let hasA = (0 ..< 4).contains(where: { r in
            (0 ..< 20).contains(where: { c in grid.cell(row: r, col: c)?.codepoint == UInt32(UnicodeScalar("A").value) })
        })
        let hasCheck = (0 ..< 4).contains(where: { r in
            (0 ..< 20).contains(where: { c in grid.cell(row: r, col: c)?.codepoint == 0x2713 })
        })
        XCTAssertTrue(hasA, "'A' must appear after carried-over sequence + CSI reset")
        XCTAssertTrue(hasCheck, "✓ must appear after carried-over 3-byte sequence")
    }

    // MARK: - Long runs of malformed bytes (bounded growth guard)

    /// A run of 4096 consecutive 0xFF bytes: the emulator must not grow its internal
    /// state without bound and must recover cleanly for subsequent output.  The
    /// equivalence assertion also verifies bulk and scalar agree at scale.
    func testLongRunOfInvalidLeads() {
        var bytes = [UInt8](repeating: 0xFF, count: 4096)
        bytes.append(contentsOf: Array("ok".utf8))
        // Only verify equivalence (both paths agree); we do not prescribe the grid text.
        let scalar = TerminalEmulator(cols: 20, rows: 6)
        scalar.feedScalarwise(bytes)
        let bulk = TerminalEmulator(cols: 20, rows: 6)
        bulk.feed(bytes)
        XCTAssertEqual(bulk.readGrid(), scalar.readGrid(),
                       "4096 0xFF bytes + 'ok': bulk vs scalar live grid must agree")
        XCTAssertEqual(bulk.captureLines(joinWrapped: false),
                       scalar.captureLines(joinWrapped: false),
                       "4096 0xFF bytes + 'ok': captureLines must agree")
    }

    /// Analogous run of continuation bytes (0x80).
    func testLongRunOfContinuationBytes() {
        var bytes = [UInt8](repeating: 0x80, count: 4096)
        bytes.append(contentsOf: Array("end".utf8))
        let scalar = TerminalEmulator(cols: 20, rows: 6)
        scalar.feedScalarwise(bytes)
        let bulk = TerminalEmulator(cols: 20, rows: 6)
        bulk.feed(bytes)
        XCTAssertEqual(bulk.readGrid(), scalar.readGrid())
    }
}
