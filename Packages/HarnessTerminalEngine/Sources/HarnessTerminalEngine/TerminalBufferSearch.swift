import Foundation

/// One find-in-scrollback hit: a half-open grid-column range on a single buffer line.
public struct TerminalBufferMatch: Equatable, Sendable {
    public let bufferLine: Int
    public let columns: Range<Int>
    public init(bufferLine: Int, columns: Range<Int>) {
        self.bufferLine = bufferLine
        self.columns = columns
    }
}

/// Case-insensitive substring search over the terminal's full buffer (history + viewport).
/// Pure and Foundation-only so it's unit-testable off the GUI; the surface drives it with
/// `TerminalEmulator.bufferLineCount` / `bufferLine(_:)`.
public enum TerminalBufferSearch {
    /// Find every (non-overlapping) match of `query` across lines `0..<lineCount`.
    /// `line(i)` returns the cells for buffer line `i`. Each cell maps to exactly one
    /// character (a wide char's spacer tail and blank cells become a space), so a match's
    /// character offset is the grid column directly.
    public static func matches(query: String, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        let needle: [String] = query.lowercased().map { String($0) }
        guard !needle.isEmpty, lineCount > 0 else { return [] }
        var out: [TerminalBufferMatch] = []
        for i in 0 ..< lineCount {
            let cells = line(i)
            guard cells.count >= needle.count else { continue }
            // One lowercased character per cell, preserving column alignment.
            let hay: [String] = cells.map { cell in
                if cell.width == .spacerTail || cell.codepoint == 0 { return " " }
                return String(Unicode.Scalar(cell.codepoint) ?? " ").lowercased()
            }
            var c = 0
            let last = hay.count - needle.count
            while c <= last {
                var k = 0
                while k < needle.count, hay[c + k] == needle[k] { k += 1 }
                if k == needle.count {
                    out.append(TerminalBufferMatch(bufferLine: i, columns: c ..< (c + needle.count)))
                    c += needle.count // non-overlapping
                } else {
                    c += 1
                }
            }
        }
        return out
    }
}
