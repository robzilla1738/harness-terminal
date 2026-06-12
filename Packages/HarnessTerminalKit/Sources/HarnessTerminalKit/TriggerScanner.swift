import Foundation
import HarnessCore
import HarnessTerminalEngine

/// Compiled output-trigger rules + the line scan. Built once per rules change (cheap, on
/// main), then used from the surface's emulator-confinement domain — immutable after init,
/// so the cross-queue handoff is safe.
///
/// Bounded by design, because the scan sits behind the parse path: at most `maxRules`
/// patterns compile (the rest are dropped with a warning), literal rules compile to escaped
/// regexes (one engine, one code path), and the *caller* budgets how many lines each output
/// batch may scan. First match per rule per line — trigger semantics, not search.
final class TriggerScanner: @unchecked Sendable {
    struct LineMatch: Equatable, Sendable {
        /// Matched span in grid columns (the scan text is built one UTF-16 unit per column).
        let columns: ClosedRange<Int>
        let ruleIndex: Int
    }

    static let maxRules = 32

    let rules: [TriggerRule]
    /// Literal rules match via `NSString.range(of:)` — several times cheaper per line than
    /// the regex engine, and literals are the common case. Regex rules pay the real engine.
    private let literals: [(needle: String, ruleIndex: Int)]
    private let regexes: [(regex: NSRegularExpression, ruleIndex: Int)]
    /// True when any rule wants a notification — lets the caller skip cooldown bookkeeping.
    let hasNotifyRules: Bool

    /// nil when no enabled, non-empty rules survive compilation — callers skip scanning
    /// entirely (the zero-cost default).
    init?(rules allRules: [TriggerRule]) {
        let active = Array(allRules.filter { $0.enabled && !$0.pattern.isEmpty }.prefix(Self.maxRules))
        if allRules.filter({ $0.enabled && !$0.pattern.isEmpty }).count > Self.maxRules {
            fputs("Harness: trigger rules capped at \(Self.maxRules); extra rules ignored\n", harnessStderr)
        }
        var literals: [(String, Int)] = []
        var regexes: [(NSRegularExpression, Int)] = []
        var kept: [TriggerRule] = []
        for rule in active {
            if rule.match == .literal {
                literals.append((rule.pattern, kept.count))
                kept.append(rule)
                continue
            }
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                fputs("Harness: invalid trigger pattern dropped: \(rule.pattern)\n", harnessStderr)
                continue
            }
            regexes.append((regex, kept.count))
            kept.append(rule)
        }
        guard !kept.isEmpty else { return nil }
        self.rules = kept
        self.literals = literals
        self.regexes = regexes
        self.hasNotifyRules = kept.contains { $0.action == .notify }
    }

    /// Scan one completed line (already rendered to scan text — see `scanText(cells:)`).
    /// Returns the first match per rule, in rule order (literals first).
    func scan(_ text: String) -> [LineMatch] {
        guard !text.isEmpty else { return [] }
        var matches: [LineMatch] = []
        let ns = text as NSString
        for (needle, ruleIndex) in literals {
            let r = ns.range(of: needle)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            matches.append(LineMatch(
                columns: r.location ... (r.location + r.length - 1), ruleIndex: ruleIndex
            ))
        }
        guard !regexes.isEmpty else { return matches }
        let full = NSRange(location: 0, length: ns.length)
        for (regex, ruleIndex) in regexes {
            guard let m = regex.firstMatch(in: text, range: full), m.range.length > 0 else { continue }
            matches.append(LineMatch(
                columns: m.range.location ... (m.range.location + m.range.length - 1),
                ruleIndex: ruleIndex
            ))
        }
        return matches
    }

    /// Render one buffer line to scan text with the column == UTF-16-offset invariant the
    /// highlight spans rely on: one unit per grid column — spacer tails and blanks become
    /// spaces, combining marks are dropped (the base matches), and a non-BMP base (emoji)
    /// becomes `·` so it can't shift later columns by its surrogate pair. Trailing
    /// whitespace is trimmed (patterns see the line, not the grid width).
    static func scanText(cells: [TerminalGridCell]) -> String {
        var text = ""
        text.reserveCapacity(cells.count)
        for cell in cells {
            if cell.width == .spacerTail || cell.codepoint == 0 {
                text.append(" ")
            } else if let scalar = Unicode.Scalar(cell.codepoint), scalar.value <= 0xFFFF {
                text.unicodeScalars.append(scalar)
            } else {
                text.append("·")
            }
        }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
