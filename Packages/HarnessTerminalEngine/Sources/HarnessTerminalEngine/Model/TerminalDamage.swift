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
    /// Whole-viewport scroll hint, purely additive: when non-zero, the viewport's content moved
    /// by `scroll` rows since the last consume (negative = up, the streaming-output direction),
    /// and every row in `scrolledRows` is byte-identical to the *previous* frame's row at
    /// `row - scroll`. A scroll-aware consumer may shift-copy those rows instead of re-resolving
    /// them; `rows` still lists every changed row (the moved band INCLUDED), so consumers that
    /// ignore the hint redraw exactly what they would have before the hint existed. Zero whenever
    /// the window's events weren't one clean whole-viewport scroll sequence (sub-region scrolls,
    /// `full`, or an accumulated shift that covered the whole grid).
    public var scroll: Int
    /// Rows reconstructible from the previous frame via `scroll` (a subset of `rows`); empty
    /// whenever `scroll == 0`.
    public var scrolledRows: IndexSet

    public init(
        rows: IndexSet = [], full: Bool = false, cursorOnly: Bool = false,
        scroll: Int = 0, scrolledRows: IndexSet = []
    ) {
        self.rows = rows
        self.full = full
        self.cursorOnly = cursorOnly
        self.scroll = scroll
        self.scrolledRows = scrolledRows
    }
}
