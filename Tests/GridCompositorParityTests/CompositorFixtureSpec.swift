// The single documented fixture spec both halves of the drift canary build from. Kept
// model-type-free (plain Ints/Strings/tuples) so it can be shared by LiveCompositorFixture
// (real models) and PortCompositorFixture (onboarding's inlined models) without importing
// either module's colliding type names.
//
// Frame: 20 cols × 8 rows. The bottom row is a 1-line status band; the top 7 rows are a
// horizontal split — pane A (left, "AB" on its first row) and pane B (right, "XY", active so
// it owns the cursor) — with a 1-cell vertical border between them. The status band carries a
// bold styled segment followed by a plain segment, so the inverse-fill path is exercised too.
enum CompositorFixtureSpec {
    static let cols = 20
    static let rows = 8
    // Pane interiors after the border solve (stated explicitly so both halves agree exactly).
    static let leftRect = (x: 0, y: 0, cols: 9, rows: 7)
    static let rightRect = (x: 10, y: 0, cols: 10, rows: 7)
    static let statusText = "left"      // bold styled segment
    static let statusPlain = " · right" // plain segment → inverse fill to the row end
}
