import Foundation

/// Finds clickable URLs in a line of terminal text — the fallback when a cell carries no OSC 8
/// hyperlink, so plain `https://…` output is still ⌘-clickable (like Ghostty / Terminal.app).
/// Pure and Foundation-only (uses `NSDataDetector`), so it's unit-testable off the GUI.
public enum URLDetection {
    /// The URL covering character offset `column` in `line`, or nil. `NSDataDetector` handles
    /// scheme detection and trims trailing punctuation. Callers should build `line` as one
    /// character per cell (so `column` is the clicked grid column); URLs are ASCII, so wide
    /// chars don't shift the mapping.
    public static func url(in line: String, at column: Int) -> String? {
        guard !line.isEmpty, column >= 0,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let full = NSRange(line.startIndex ..< line.endIndex, in: line)
        var result: String?
        detector.enumerateMatches(in: line, options: [], range: full) { match, _, stop in
            guard let match, let r = Range(match.range, in: line) else { return }
            let lower = line.distance(from: line.startIndex, to: r.lowerBound)
            let upper = line.distance(from: line.startIndex, to: r.upperBound)
            if column >= lower, column < upper {
                result = match.url?.absoluteString ?? String(line[r])
                stop.pointee = true
            }
        }
        return result
    }
}
