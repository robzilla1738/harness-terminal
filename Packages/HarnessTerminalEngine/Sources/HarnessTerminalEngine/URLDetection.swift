import Foundation

/// Finds clickable URLs in a line of terminal text — the fallback when a cell carries no OSC 8
/// hyperlink, so plain `https://...` output is still command-clickable.
/// Pure and Foundation-only (uses `NSDataDetector` on Darwin), so it's unit-testable off the GUI.
public enum URLDetection {
    /// The URL covering character offset `column` in `line`, or nil. Callers should build `line`
    /// as one character per cell (so `column` is the clicked grid column); URLs are ASCII, so wide
    /// chars don't shift the mapping.
    public static func url(in line: String, at column: Int) -> String? {
        match(in: line, at: column)?.url
    }

    /// As `url(in:at:)`, but also returns the matched span as a half-open column range,
    /// so callers can underline the link on hover. `columns` uses the same one-character-
    /// per-cell convention as the input `line`.
    public static func match(in line: String, at column: Int) -> (url: String, columns: Range<Int>)? {
        guard !line.isEmpty, column >= 0 else { return nil }
        #if canImport(Darwin)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let full = NSRange(line.startIndex ..< line.endIndex, in: line)
        var result: (url: String, columns: Range<Int>)?
        detector.enumerateMatches(in: line, options: [], range: full) { match, _, stop in
            guard let match, let r = Range(match.range, in: line) else { return }
            let lower = line.distance(from: line.startIndex, to: r.lowerBound)
            let upper = line.distance(from: line.startIndex, to: r.upperBound)
            if column >= lower, column < upper {
                result = (match.url?.absoluteString ?? String(line[r]), lower ..< upper)
                stop.pointee = true
            }
        }
        return result
        #else
        // `NSDataDetector` isn't implemented in swift-corelibs-foundation (Linux). Fall back to a
        // whitespace-delimited token scan: the token covering `column` is a URL if it carries a
        // `scheme://`. Sufficient for the headless build (URL clicking is a GUI affordance).
        return tokenMatch(in: line, at: column)
        #endif
    }

    #if !canImport(Darwin)
    private static func tokenMatch(in line: String, at column: Int) -> (url: String, columns: Range<Int>)? {
        let chars = Array(line)
        guard column < chars.count else { return nil }
        func isBoundary(_ c: Character) -> Bool { c == " " || c == "\t" }
        guard !isBoundary(chars[column]) else { return nil }
        var lo = column
        var hi = column
        while lo > 0, !isBoundary(chars[lo - 1]) { lo -= 1 }
        while hi + 1 < chars.count, !isBoundary(chars[hi + 1]) { hi += 1 }
        var token = String(chars[lo ... hi])
        while let last = token.last, ").,;:!?'\\\"]>".contains(last) { token.removeLast() }
        guard let schemeEnd = token.range(of: "://"),
              token[token.startIndex ..< schemeEnd.lowerBound].allSatisfy({ $0.isLetter }),
              schemeEnd.lowerBound != token.startIndex
        else { return nil }
        return (token, lo ..< (lo + token.count))
    }
    #endif
}
