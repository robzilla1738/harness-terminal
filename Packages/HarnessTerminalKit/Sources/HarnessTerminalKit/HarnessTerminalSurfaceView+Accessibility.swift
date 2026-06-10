import AppKit
import HarnessTerminalEngine

/// VoiceOver support for the terminal grid. The surface view is a `CAMetalLayer`-backed custom view
/// that draws glyphs itself, so without this it is invisible to VoiceOver — a categorical exclusion
/// from the product's core surface. Conform to the AppKit static-text accessibility protocol so the
/// screen reader can read the buffer and navigate it by line/character. The fiddly UTF-16 offset
/// math lives in the pure, unit-tested `TerminalAccessibilityText`; these overrides are a thin shell
/// that snapshots the current text + cursor and delegates.
extension HarnessTerminalSurfaceView {
    private func accessibilityText() -> TerminalAccessibilityText {
        TerminalAccessibilityText(lines: accessibilitySnapshot().lines)
    }

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityLabel() -> String? { "Terminal" }

    /// The full buffer text (scrollback + screen) — what VoiceOver reads and scrubs.
    public override func accessibilityValue() -> Any? { accessibilityText().value }

    public override func accessibilityNumberOfCharacters() -> Int { accessibilityText().length }

    public override func accessibilityString(for range: NSRange) -> String? {
        accessibilityText().string(forRange: range)
    }

    public override func accessibilityLine(for index: Int) -> Int {
        accessibilityText().line(forCharacterIndex: index)
    }

    public override func accessibilityRange(forLine line: Int) -> NSRange {
        accessibilityText().characterRange(forLine: line) ?? NSRange(location: 0, length: 0)
    }

    public override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityText().length)
    }

    /// The cursor's line (in full-buffer coordinates), so VoiceOver announces where typing lands.
    public override func accessibilityInsertionPointLineNumber() -> Int {
        let snapshot = accessibilitySnapshot()
        guard !snapshot.lines.isEmpty else { return 0 }
        return min(max(0, snapshot.cursorLine), snapshot.lines.count - 1)
    }
}
