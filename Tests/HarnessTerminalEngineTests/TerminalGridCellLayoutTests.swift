import XCTest
@testable import HarnessTerminalEngine

/// Guards the compact `TerminalGridCell` memory layout. The cell is copied per character write,
/// per scroll, per snapshot, and compared per `==` in the compositor diff + renderer damage, so its
/// size is a throughput lever. Packing `TerminalGridColor.palette` into a `UInt8` (rather than an
/// 8-byte `Int`) roughly halved the cell (64 → 32 bytes on arm64). This test fails if a change
/// reintroduces an 8-byte-aligned field (e.g. an `Int`/pointer), so the win can't silently regress.
final class TerminalGridCellLayoutTests: XCTestCase {
    func testCellStaysCompact() {
        // Upper bound, not an exact match, so it is robust across Swift versions / architectures
        // while still catching a regression back toward the old 64-byte layout.
        XCTAssertLessThanOrEqual(
            MemoryLayout<TerminalGridCell>.stride, 40,
            "TerminalGridCell grew — a wide (8-byte) field likely crept back into the per-cell hot path"
        )
    }

    func testColorPayloadFitsInOneWord() {
        XCTAssertLessThanOrEqual(MemoryLayout<TerminalGridColor>.stride, 4)
    }
}
