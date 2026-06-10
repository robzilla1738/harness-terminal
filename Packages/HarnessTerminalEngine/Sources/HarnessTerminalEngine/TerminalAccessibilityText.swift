import Foundation

/// Pure text-geometry model backing the terminal surface's VoiceOver support (the AppKit
/// `NSAccessibilityNavigableStaticText` / text-area protocol). Given the on-screen lines, it
/// answers the line / character / range questions the accessibility protocol asks — in **UTF-16**
/// offsets, matching AppKit/NSString semantics — so the AppKit view is a thin delegating shell and
/// the fiddly offset math is unit-tested headlessly (no GUI).
public struct TerminalAccessibilityText: Equatable, Sendable {
    /// The accessible lines, top to bottom.
    public let lines: [String]
    /// The full accessible value: lines joined by "\n".
    public let value: String
    /// UTF-16 length of `value` (NSString length).
    public let length: Int

    // UTF-16 start offset of each line within `value`, and each line's own UTF-16 length (the
    // newline separator is not part of any line's length).
    private let lineStarts: [Int]
    private let lineLengths: [Int]

    public init(lines: [String]) {
        self.lines = lines
        self.value = lines.joined(separator: "\n")
        self.length = value.utf16.count
        var starts: [Int] = []
        var lengths: [Int] = []
        starts.reserveCapacity(lines.count)
        lengths.reserveCapacity(lines.count)
        var offset = 0
        for (index, line) in lines.enumerated() {
            starts.append(offset)
            let len = line.utf16.count
            lengths.append(len)
            offset += len
            if index < lines.count - 1 { offset += 1 } // the "\n" separator between lines
        }
        lineStarts = starts
        lineLengths = lengths
    }

    public var lineCount: Int { lines.count }

    /// The 0-based line containing UTF-16 character `index`. A newline belongs to the line it
    /// terminates, so an index at end-of-line maps to that line, not the next. Clamped to a valid
    /// line (0 when empty).
    public func line(forCharacterIndex index: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let clamped = max(0, min(index, length))
        // Last line whose start offset is <= clamped (binary search; starts are ascending).
        var lo = 0
        var hi = lineStarts.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= clamped {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return result
    }

    /// The UTF-16 range of `line`'s text (excluding the trailing newline); nil if out of range.
    public func characterRange(forLine line: Int) -> NSRange? {
        guard line >= 0, line < lines.count else { return nil }
        return NSRange(location: lineStarts[line], length: lineLengths[line])
    }

    /// The substring covered by a UTF-16 range; nil if the range falls outside the value.
    public func string(forRange range: NSRange) -> String? {
        // Overflow-safe bounds check: `location + length` could trap on a pathological range
        // (e.g. location near Int.max), so validate via subtraction once both are known
        // non-negative and location is within the value.
        guard range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location else { return nil }
        return (value as NSString).substring(with: range)
    }

    /// The UTF-16 character index of the cursor at (`line`, `column`), where `column` is a cell
    /// column. Clamped into the line, so a cursor parked past end-of-text lands at the line end.
    /// (Cell-to-character mapping is approximate for wide glyphs, which is acceptable for an
    /// insertion-point hint.)
    public func characterIndex(line: Int, column: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        let clampedLine = max(0, min(line, lines.count - 1))
        let col = max(0, min(column, lineLengths[clampedLine]))
        return lineStarts[clampedLine] + col
    }
}
