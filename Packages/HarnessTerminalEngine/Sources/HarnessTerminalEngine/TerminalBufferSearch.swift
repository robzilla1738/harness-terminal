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

/// Tunables for a buffer search: plain substring (the default) vs. `NSRegularExpression`, and
/// case-insensitive (the default) vs. case-sensitive. Surfaced as the two find-bar toggles.
public struct TerminalBufferSearchOptions: Equatable, Sendable {
    /// Interpret `query` as an `NSRegularExpression` pattern instead of a literal substring.
    public var isRegex: Bool
    /// Match case exactly. When `false` both query and buffer are case-folded before comparison.
    public var caseSensitive: Bool

    public init(isRegex: Bool = false, caseSensitive: Bool = false) {
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }

    /// The historical behavior: literal substring, case-insensitive.
    public static let `default` = TerminalBufferSearchOptions()
}

/// Substring or regex search over the terminal's full buffer (history + viewport), case-folded
/// unless `caseSensitive`. Pure and Foundation-only so it's unit-testable off the GUI; the surface
/// drives it with `TerminalEmulator.bufferLineCount` / `bufferLine(_:)`.
public enum TerminalBufferSearch {
    /// Find every (non-overlapping) substring match (literal, case-insensitive) — the default path
    /// most callers use. Equivalent to `matches(query:options:lineCount:line:)` with `.default`.
    public static func matches(query: String, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        matches(query: query, options: .default, lineCount: lineCount, line: line)
    }

    /// Find every (non-overlapping) match of `query` across lines `0..<lineCount`, honoring `options`
    /// (regex vs. substring, case-sensitivity). `line(i)` returns the cells for buffer line `i`. Each
    /// cell maps to exactly one column, so a match's offsets are grid columns directly. An invalid
    /// regex yields no matches (the find bar shows 0 results rather than crashing).
    public static func matches(query: String, options: TerminalBufferSearchOptions, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        guard !query.isEmpty, lineCount > 0 else { return [] }
        if options.isRegex {
            return regexMatches(pattern: query, caseSensitive: options.caseSensitive, lineCount: lineCount, line: line)
        }
        return substringMatches(query: query, caseSensitive: options.caseSensitive, lineCount: lineCount, line: line)
    }

    /// Literal substring search. Each cell maps to exactly one needle unit (its base scalar plus any
    /// combining marks; a wide char's spacer tail and blank cells become a space), so a match's
    /// offset is the grid column directly. Both sides are canonically normalized (NFC) so a
    /// decomposed mark stream (base + combining) matches a precomposed query and vice-versa, and
    /// case-folded to lowercase unless `caseSensitive`.
    private static func substringMatches(query: String, caseSensitive: Bool, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        // Case folding is applied AFTER NFC normalization on both the query and each cell. When
        // `caseSensitive` is set this is the identity, so comparison is exact.
        let fold: (String) -> String = caseSensitive ? { $0 } : { $0.lowercased() }
        // Segment the query the SAME way the engine lays out cells: each width>0 scalar starts a new
        // unit; width-0 combining scalars fold onto it. This keeps needle units 1:1 with hay cells
        // even where Swift's grapheme segmentation disagrees with cell layout — e.g. the Thai spacing
        // vowel SARA AM (U+0E33, width 1) is its OWN cell but clusters with its consonant as one
        // Swift Character, so a per-Character split (the old `.map { String($0) }`) made "ทำ"/"นำ"/"คำ"
        // unmatchable. Each unit is then NFC-normalized + lowercased.
        var needleUnits: [String] = []
        for scalar in query.unicodeScalars {
            // Mirror the engine's SARA AM split (`TerminalScreen.saraAm`): the hay cells store
            // U+0E33 decomposed as NIKHAHIT (folds onto the base unit) + SARA AA (its own unit), so
            // the needle must segment the same way or `น้ำ`-class words become unmatchable. But the
            // engine only splits when the NIKHAHIT actually attaches; an orphan SARA AM or one after
            // a full two-mark base is stored as a faithful U+0E33 cell. Match that here: the previous
            // unit can take the NIKHAHIT only if it holds at most a base + one mark (≤ 2 scalars,
            // the engine's two-combining-slot cap). Otherwise keep U+0E33 so a faithful cell — and
            // only a faithful cell — matches.
            if scalar.value == TerminalScreen.saraAm {
                let prevHasRoom = (needleUnits.last?.unicodeScalars.count ?? 0) >= 1
                    && (needleUnits.last?.unicodeScalars.count ?? 0) <= 2
                if prevHasRoom, let nikhahit = Unicode.Scalar(TerminalScreen.nikhahit),
                   let saraAa = Unicode.Scalar(TerminalScreen.saraAa) {
                    needleUnits[needleUnits.count - 1].unicodeScalars.append(nikhahit)
                    needleUnits.append(String(saraAa))
                } else {
                    // No attachable base (leading) or the base is already full → faithful U+0E33.
                    needleUnits.append(String(scalar))
                }
                continue
            }
            if CharacterWidth.width(of: scalar.value) == 0, !needleUnits.isEmpty {
                needleUnits[needleUnits.count - 1].unicodeScalars.append(scalar)
            } else {
                needleUnits.append(String(scalar))
            }
        }
        let needle = needleUnits.map { fold($0.precomposedStringWithCanonicalMapping) }
        guard !needle.isEmpty, lineCount > 0 else { return [] }
        var out: [TerminalBufferMatch] = []
        // One normalized, lowercased cluster per cell, preserving column alignment. This runs
        // over every cell of every line on each keystroke in the find bar, so the per-cell unit
        // comes from `UnitResolver` (ASCII table + codepoint memo — no per-cell String builds)
        // and the hay array is reused across lines instead of reallocated per line.
        var resolver = UnitResolver(caseSensitive: caseSensitive)
        var hay: [String] = []
        for i in 0 ..< lineCount {
            let cells = line(i)
            guard cells.count >= needle.count else { continue }
            hay.removeAll(keepingCapacity: true)
            hay.reserveCapacity(cells.count)
            for cell in cells { hay.append(resolver.unit(for: cell)) }
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

    /// Resolves a cell to its search unit (normalized, optionally case-folded cluster; spacer
    /// tails and blanks become a space) without building a String per cell:
    /// - printable ASCII (the overwhelming majority) indexes a static 128-entry table,
    /// - other no-mark cells memoize by codepoint (box-drawing walls, CJK fills repeat heavily),
    /// - only mark-carrying cells pay the cluster build + NFC normalization, exactly as before.
    private struct UnitResolver {
        let caseSensitive: Bool
        private var memo: [UInt32: String] = [:]

        init(caseSensitive: Bool) { self.caseSensitive = caseSensitive }

        /// One single-character String per printable ASCII byte, exact and folded.
        private static let asciiUnits: [String] = (0 ..< 128).map {
            String(Unicode.Scalar(UInt8($0)))
        }
        private static let asciiFoldedUnits: [String] = asciiUnits.map { $0.lowercased() }

        mutating func unit(for cell: TerminalGridCell) -> String {
            if cell.width == .spacerTail || cell.codepoint == 0 { return " " }
            if cell.combining0 == 0 {
                if cell.codepoint < 0x80 {
                    let i = Int(cell.codepoint)
                    return caseSensitive ? Self.asciiUnits[i] : Self.asciiFoldedUnits[i]
                }
                if let cached = memo[cell.codepoint] { return cached }
                // No combining marks → already one composed scalar; NFC would be the identity.
                let unit = fold(cell.cluster)
                memo[cell.codepoint] = unit
                return unit
            }
            let unit = fold(cell.cluster.precomposedStringWithCanonicalMapping)
            return unit.isEmpty ? " " : unit
        }

        private func fold(_ s: String) -> String { caseSensitive ? s : s.lowercased() }
    }

    /// Regex search via `NSRegularExpression`. Each line is rendered to a string where every cell
    /// contributes exactly one non-empty unit (its cluster; spacer tails / blanks become a space),
    /// so a UTF-16 match range maps cleanly back to a half-open *column* range. Matches are
    /// non-overlapping (NSRegularExpression's default) and zero-width matches (e.g. `a*` against an
    /// empty stretch) are skipped so they neither loop nor produce empty highlights.
    private static func regexMatches(pattern: String, caseSensitive: Bool, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        var regexOptions: NSRegularExpression.Options = []
        if !caseSensitive { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return [] }
        var out: [TerminalBufferMatch] = []
        // Case folding is handled by the regex's `.caseInsensitive` option, so the resolver runs
        // case-sensitive (exact units). Reused across lines: the resolver's memo, and the
        // cellStarts buffer.
        var resolver = UnitResolver(caseSensitive: true)
        var cellStarts: [String.Index] = []
        for i in 0 ..< lineCount {
            let cells = line(i)
            guard !cells.isEmpty else { continue }
            // Build the line text and remember where each cell starts, so a character range maps back
            // to columns. Units are NFC-normalized (only when a cell carries combining marks) so the
            // pattern sees the same composed form the substring path does.
            var hay = ""
            hay.reserveCapacity(cells.count)
            cellStarts.removeAll(keepingCapacity: true)
            cellStarts.reserveCapacity(cells.count)
            for cell in cells {
                cellStarts.append(hay.endIndex)
                hay += resolver.unit(for: cell)
            }
            let fullRange = NSRange(hay.startIndex ..< hay.endIndex, in: hay)
            regex.enumerateMatches(in: hay, options: [], range: fullRange) { result, _, _ in
                guard let result, result.range.length > 0,
                      let charRange = Range(result.range, in: hay) else { return }
                // First column = the cell containing the match start; last column = the cell holding
                // the final matched character. `cellStarts` is strictly increasing (every unit is
                // non-empty), so a simple sweep resolves both unambiguously.
                var firstColumn = 0
                var lastColumn = 0
                for c in cellStarts.indices {
                    if cellStarts[c] <= charRange.lowerBound { firstColumn = c }
                    if cellStarts[c] < charRange.upperBound { lastColumn = c }
                }
                out.append(TerminalBufferMatch(bufferLine: i, columns: firstColumn ..< (lastColumn + 1)))
            }
        }
        return out
    }
}
