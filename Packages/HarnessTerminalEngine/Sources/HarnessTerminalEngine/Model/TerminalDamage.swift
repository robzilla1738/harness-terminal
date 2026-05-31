import Foundation

/// Which viewport rows changed since the last `consumeDamage()`, so a renderer can rebuild only
/// what moved instead of walking every cell each frame.
///
/// Rows are viewport-relative (`0 ..< rows`), matching `TerminalGridSnapshot`. Over-reporting is
/// safe (extra rows are merely rebuilt); under-reporting would leave stale pixels, so the screen
/// marks conservatively.
public struct TerminalDamage: Equatable, Sendable {
    /// Dirty viewport rows. When `full` is true this is the whole grid (`0 ..< rows`).
    public var rows: IndexSet
    /// The whole screen changed (clear, resize/reflow, full reset, alternate-screen switch) and
    /// must be rebuilt in its entirety.
    public var full: Bool
    /// The only change since the last consume was the cursor moving — no cell content changed.
    /// A hint for consumers that want to do the minimum; `rows` still lists the cursor's old and
    /// new rows so a correct redraw needs nothing more.
    public var cursorOnly: Bool

    public init(rows: IndexSet = [], full: Bool = false, cursorOnly: Bool = false) {
        self.rows = rows
        self.full = full
        self.cursorOnly = cursorOnly
    }
}
