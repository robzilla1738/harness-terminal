import XCTest
@testable import HarnessTerminalEngine

/// Guards the compact `TerminalGridCell` memory layout. The cell is copied per character write,
/// per scroll, per snapshot, and compared per `==` in the compositor diff + renderer damage, so its
/// size is a throughput lever. Packing `TerminalGridColor.palette` into a `UInt8` (rather than an
/// 8-byte `Int`) roughly halved the cell (64 → 32 bytes on arm64). This test fails if a change
/// reintroduces an 8-byte-aligned field (e.g. an `Int`/pointer), so the win can't silently regress.
final class TerminalGridCellLayoutTests: XCTestCase {
    func testCellStaysCompact() {
        // The cell is copied per character write, per scroll, per snapshot, and compared per `==`,
        // so its size is a throughput lever (packing colors into UInt8 took it 64 → 32 bytes).
        // The optional `marks` array (combining-mark / grapheme storage, nil in the common case)
        // adds one pointer word. The bound stays tight so a *further* wide field can't creep in.
        XCTAssertLessThanOrEqual(
            MemoryLayout<TerminalGridCell>.stride, 48,
            "TerminalGridCell grew beyond the combining-mark budget — an unexpected wide field crept into the per-cell hot path"
        )
    }

    func testColorPayloadFitsInOneWord() {
        XCTAssertLessThanOrEqual(MemoryLayout<TerminalGridColor>.stride, 4)
    }
}
