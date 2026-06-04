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
    /// `line(i)` returns the cells for buffer line `i`. Each cell maps to exactly one needle unit
    /// (its base scalar plus any combining marks; a wide char's spacer tail and blank cells become a
    /// space), so a match's offset is the grid column directly. Both sides are canonically normalized
    /// (NFC) so a decomposed mark stream (base + combining) matches a precomposed query and vice-versa.
    public static func matches(query: String, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        // Segment the query the SAME way the engine lays out cells: each width>0 scalar starts a new
        // unit; width-0 combining scalars fold onto it. This keeps needle units 1:1 with hay cells
        // even where Swift's grapheme segmentation disagrees with cell layout — e.g. the Thai spacing
        // vowel SARA AM (U+0E33, width 1) is its OWN cell but clusters with its consonant as one
        // Swift Character, so a per-Character split (the old `.map { String($0) }`) made "ทำ"/"นำ"/"คำ"
        // unmatchable. Each unit is then NFC-normalized + lowercased.
        var needleUnits: [String] = []
        for scalar in query.unicodeScalars {
            if CharacterWidth.width(of: scalar.value) == 0, !needleUnits.isEmpty {
                needleUnits[needleUnits.count - 1].unicodeScalars.append(scalar)
            } else {
                needleUnits.append(String(scalar))
            }
        }
        let needle = needleUnits.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        guard !needle.isEmpty, lineCount > 0 else { return [] }
        var out: [TerminalBufferMatch] = []
        for i in 0 ..< lineCount {
            let cells = line(i)
            guard cells.count >= needle.count else { continue }
            // One normalized, lowercased cluster per cell, preserving column alignment. NFC only
            // matters for cells carrying combining marks; a no-mark cell is already one composed
            // scalar, so skip the normalization cost there (this runs over every cell of every line
            // on each keystroke in the find bar).
            let hay: [String] = cells.map { cell in
                if cell.width == .spacerTail || cell.codepoint == 0 { return " " }
                return cell.combining0 == 0
                    ? cell.cluster.lowercased()
                    : cell.cluster.precomposedStringWithCanonicalMapping.lowercased()
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
