import CoreGraphics

/// Procedural rendering of Unicode box-drawing characters (U+2500–U+257F) into a cell-sized
/// coverage bitmap, the way Ghostty/kitty do it. Drawing the geometry directly — instead of
/// relying on the font's glyphs — guarantees the segments are centered identically in every
/// cell, so lines, corners, junctions and arcs tile seamlessly regardless of the font.
///
/// Coordinates here are top-left origin, y-down (the caller flips the CGContext to match), and
/// in device pixels. Only the uniform-weight line family, rounded corners, half-lines and
/// dashes are drawn; mixed-weight variants, double lines and diagonals fall back to the font
/// (`supported` returns false for them) so we never render a half-finished approximation.
enum BoxDrawing {
    /// Codepoints we render procedurally. Anything outside this set uses the font glyph.
    static func supported(_ cp: UInt32) -> Bool { rects(for: cp) != nil || isRounded(cp) }

    private static func isRounded(_ cp: UInt32) -> Bool { (0x256D ... 0x2570).contains(cp) }

    /// Draw `codepoint` into `ctx` (already flipped to top-left/y-down), filling `width`×`height`
    /// device pixels with white coverage. Returns false if the codepoint isn't handled.
    static func draw(in ctx: CGContext, codepoint cp: UInt32, width: Int, height: Int) -> Bool {
        let W = CGFloat(width), H = CGFloat(height)
        // Stroke weights, snapped to whole pixels. Light ≈ the underline thickness; heavy 2×.
        let light = max(1, (H / 16).rounded())
        let heavy = max(2, (H / 8).rounded())
        let cx = (W / 2).rounded()
        let cy = (H / 2).rounded()

        if isRounded(cp) {
            drawRoundedCorner(ctx, cp: cp, W: W, H: H, cx: cx, cy: cy, t: light)
            return true
        }
        guard let spec = rects(for: cp) else { return false }
        let t = spec.heavy ? heavy : light
        let half = (t / 2).rounded()

        func hbar(_ x0: CGFloat, _ x1: CGFloat) {
            ctx.fill(CGRect(x: x0, y: cy - half, width: max(0, x1 - x0), height: t))
        }
        func vbar(_ y0: CGFloat, _ y1: CGFloat) {
            ctx.fill(CGRect(x: cx - half, y: y0, width: t, height: max(0, y1 - y0)))
        }

        switch spec.kind {
        case .arms:
            // Each present arm runs from its edge to just past the centre, so junctions fill.
            if spec.left { hbar(0, cx + half) }
            if spec.right { hbar(cx - half, W) }
            if spec.up { vbar(0, cy + half) }
            if spec.down { vbar(cy - half, H) }
        case .halfLeft: hbar(0, cx + half)
        case .halfRight: hbar(cx - half, W)
        case .halfUp: vbar(0, cy + half)
        case .halfDown: vbar(cy - half, H)
        case .dashH(let n):
            let u = W / CGFloat(2 * n - 1)
            for i in 0 ..< n { ctx.fill(CGRect(x: CGFloat(i) * 2 * u, y: cy - half, width: u, height: t)) }
        case .dashV(let n):
            let u = H / CGFloat(2 * n - 1)
            for i in 0 ..< n { ctx.fill(CGRect(x: cx - half, y: CGFloat(i) * 2 * u, width: t, height: u)) }
        }
        return true
    }

    private static func drawRoundedCorner(_ ctx: CGContext, cp: UInt32, W: CGFloat, H: CGFloat, cx: CGFloat, cy: CGFloat, t: CGFloat) {
        // Largest radius that fits the corner quadrant.
        let r = max(1, min(min(cx, cy), min(W - cx, H - cy)))
        // (start edge point) → corner (cell centre) → (end edge point). The arc rounds the bend.
        let start: CGPoint, end: CGPoint
        switch cp {
        case 0x256D: start = CGPoint(x: W, y: cy); end = CGPoint(x: cx, y: H)  // ╭ down+right
        case 0x256E: start = CGPoint(x: 0, y: cy); end = CGPoint(x: cx, y: H)  // ╮ down+left
        case 0x256F: start = CGPoint(x: 0, y: cy); end = CGPoint(x: cx, y: 0)  // ╯ up+left
        default:     start = CGPoint(x: W, y: cy); end = CGPoint(x: cx, y: 0)  // ╰ up+right (0x2570)
        }
        let path = CGMutablePath()
        path.move(to: start)
        path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: end, radius: r)
        path.addLine(to: end)
        ctx.setLineWidth(t)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private enum Kind {
        case arms
        case halfLeft, halfRight, halfUp, halfDown
        case dashH(Int), dashV(Int)
    }

    private struct Spec {
        var kind: Kind
        var heavy = false
        var up = false, right = false, down = false, left = false
        init(_ kind: Kind, heavy: Bool = false, up: Bool = false, right: Bool = false, down: Bool = false, left: Bool = false) {
            self.kind = kind; self.heavy = heavy
            self.up = up; self.right = right; self.down = down; self.left = left
        }
    }

    /// Arm/weight/kind spec for a codepoint, or nil if not rendered procedurally. Only
    /// uniform-weight (all-light or all-heavy) line characters are listed.
    private static func rects(for cp: UInt32) -> Spec? {
        switch cp {
        // Lines
        case 0x2500: return Spec(.arms, right: true, left: true)              // ─
        case 0x2501: return Spec(.arms, heavy: true, right: true, left: true) // ━
        case 0x2502: return Spec(.arms, up: true, down: true)                 // │
        case 0x2503: return Spec(.arms, heavy: true, up: true, down: true)    // ┃
        // Light corners
        case 0x250C: return Spec(.arms, right: true, down: true)              // ┌
        case 0x2510: return Spec(.arms, down: true, left: true)               // ┐
        case 0x2514: return Spec(.arms, up: true, right: true)                // └
        case 0x2518: return Spec(.arms, up: true, left: true)                 // ┘
        // Heavy corners
        case 0x250F: return Spec(.arms, heavy: true, right: true, down: true) // ┏
        case 0x2513: return Spec(.arms, heavy: true, down: true, left: true)  // ┓
        case 0x2517: return Spec(.arms, heavy: true, up: true, right: true)   // ┗
        case 0x251B: return Spec(.arms, heavy: true, up: true, left: true)    // ┛
        // Light T-junctions + cross
        case 0x251C: return Spec(.arms, up: true, right: true, down: true)               // ├
        case 0x2524: return Spec(.arms, up: true, down: true, left: true)                // ┤
        case 0x252C: return Spec(.arms, right: true, down: true, left: true)             // ┬
        case 0x2534: return Spec(.arms, up: true, right: true, left: true)               // ┴
        case 0x253C: return Spec(.arms, up: true, right: true, down: true, left: true)   // ┼
        // Heavy T-junctions + cross
        case 0x2523: return Spec(.arms, heavy: true, up: true, right: true, down: true)             // ┣
        case 0x252B: return Spec(.arms, heavy: true, up: true, down: true, left: true)              // ┫
        case 0x2533: return Spec(.arms, heavy: true, right: true, down: true, left: true)           // ┳
        case 0x253B: return Spec(.arms, heavy: true, up: true, right: true, left: true)             // ┻
        case 0x254B: return Spec(.arms, heavy: true, up: true, right: true, down: true, left: true) // ╋
        // Half-lines
        case 0x2574: return Spec(.halfLeft)                  // ╴
        case 0x2575: return Spec(.halfUp)                    // ╵
        case 0x2576: return Spec(.halfRight)                 // ╶
        case 0x2577: return Spec(.halfDown)                  // ╷
        case 0x2578: return Spec(.halfLeft, heavy: true)     // ╸
        case 0x2579: return Spec(.halfUp, heavy: true)       // ╹
        case 0x257A: return Spec(.halfRight, heavy: true)    // ╺
        case 0x257B: return Spec(.halfDown, heavy: true)     // ╻
        // Dashes (light / heavy, triple / quadruple)
        case 0x2504: return Spec(.dashH(3))                  // ┄
        case 0x2505: return Spec(.dashH(3), heavy: true)     // ┅
        case 0x2506: return Spec(.dashV(3))                  // ┆
        case 0x2507: return Spec(.dashV(3), heavy: true)     // ┇
        case 0x2508: return Spec(.dashH(4))                  // ┈
        case 0x2509: return Spec(.dashH(4), heavy: true)     // ┉
        case 0x250A: return Spec(.dashV(4))                  // ┊
        case 0x250B: return Spec(.dashV(4), heavy: true)     // ┋
        default: return nil
        }
    }
}
