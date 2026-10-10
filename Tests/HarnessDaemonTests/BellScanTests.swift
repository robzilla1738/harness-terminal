import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Pins `SurfaceRegistry.scanForBell` — the parser-aware bell detector that must distinguish a real
/// control BEL from a BEL serving as an OSC String Terminator (the OSC 133 prompt marks shell
/// integration emits on every prompt, which a raw `data.contains(0x07)` misreported as a bell).
final class BellScanTests: XCTestCase {
    private func scan(_ bytes: [UInt8], state: inout SurfaceRegistry.BellScanState) -> Bool {
        SurfaceRegistry.scanForBell(Data(bytes), state: &state)
    }

    func testBareBELIsABell() {
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertTrue(scan([0x41, 0x07, 0x42], state: &s), "a bare \\a in normal text is a real bell")
        XCTAssertEqual(s, .normal)
    }

    func testOSC133PromptTerminatorBELIsNotABell() {
        // ESC ] 1 3 3 ; A BEL  — the exact shape shell integration emits each prompt.
        let esc: UInt8 = 0x1B, bel: UInt8 = 0x07
        let seq = [esc, 0x5D] + Array("133;A".utf8) + [bel]
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertFalse(scan(seq, state: &s), "an OSC-terminator BEL must NOT count as a bell")
        XCTAssertEqual(s, .normal, "OSC string closed")
    }

    func testRealBellAfterAnOSCSequenceStillCounts() {
        let esc: UInt8 = 0x1B, bel: UInt8 = 0x07
        let seq = [esc, 0x5D] + Array("0;title".utf8) + [bel] + [0x07] // OSC...BEL then a real BEL
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertTrue(scan(seq, state: &s), "a genuine BEL after a closed OSC is a bell")
    }

    func testOSCBELSplitAcrossChunksIsNotABell() {
        // The OSC opens in one chunk and its terminating BEL arrives in the next.
        let esc: UInt8 = 0x1B, bel: UInt8 = 0x07
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertFalse(scan([esc, 0x5D] + Array("133;D;0".utf8), state: &s))
        XCTAssertEqual(s, .oscString, "still inside the OSC string across the chunk boundary")
        XCTAssertFalse(scan([bel], state: &s), "the terminator BEL in the next chunk is not a bell")
        XCTAssertEqual(s, .normal)
    }

    func testSTTerminatedOSCThenBellCounts() {
        // ESC ] ... ESC \  (ST-terminated OSC), then a real BEL.
        let esc: UInt8 = 0x1B, bs: UInt8 = 0x5C, bel: UInt8 = 0x07
        let seq = [esc, 0x5D] + Array("52;c;data".utf8) + [esc, bs, bel]
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertTrue(scan(seq, state: &s), "BEL after an ST-terminated OSC is a real bell")
        XCTAssertEqual(s, .normal)
    }

    func testESCRestartsEscapeParsingSoOSCBodyIsNotMisread() {
        // `ESC ESC ] … BEL`: the second ESC restarts escape parsing, so the `]` still opens an OSC
        // and its terminator BEL is NOT misreported as a real bell.
        let esc: UInt8 = 0x1B, bel: UInt8 = 0x07
        let seq = [esc, esc, 0x5D] + Array("0;x".utf8) + [bel]
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertFalse(scan(seq, state: &s), "ESC ESC ] ... BEL must not produce a spurious bell")
        XCTAssertEqual(s, .normal)
    }

    func testUnterminatedStringDoesNotSwallowLaterBells() {
        // A program opens an OSC and dies without terminating it; a later CAN aborts the string, so a
        // subsequent real BEL is still detected (the scanner can't get pinned in `.string` forever).
        let esc: UInt8 = 0x1B, can: UInt8 = 0x18, bel: UInt8 = 0x07
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertFalse(scan([esc, 0x5D] + Array("oops".utf8), state: &s)) // unterminated OSC
        XCTAssertEqual(s, .oscString)
        XCTAssertTrue(scan([can, bel], state: &s), "CAN aborts the string so the next BEL is a real bell")
        XCTAssertEqual(s, .normal)
    }

    func testBELInsideDCSStringIsNotABell() {
        // ESC P (DCS) ... a 0x07 byte in the payload ... ESC \  — the BEL here is data, not a bell.
        let esc: UInt8 = 0x1B, bs: UInt8 = 0x5C, bel: UInt8 = 0x07
        let seq = [esc, 0x50] + Array("q".utf8) + [bel, bel] + [esc, bs]
        var s = SurfaceRegistry.BellScanState.normal
        XCTAssertFalse(scan(seq, state: &s), "a BEL inside a DCS string is not a bell")
        XCTAssertEqual(s, .normal)
    }
}
