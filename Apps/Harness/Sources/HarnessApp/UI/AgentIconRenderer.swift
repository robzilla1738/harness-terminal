import AppKit
import HarnessCore

/// Minimal SVG path-data → `CGPath` parser, covering the subset the brand icons use
/// (`M m L l H h V v C c S s Q q T t A a Z z`) and tolerant of SVG's number quirks:
/// implicit separators, numbers packed against signs/dots, and arc flags packed
/// against the following number. Pure CoreGraphics — no external dependency, crisp
/// at any size (same "draw the geometry, don't rasterize a font" approach as the
/// terminal's procedural box-drawing).
enum SVGPathParser {
    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }
        static let seps: Set<Character> = [" ", ",", "\t", "\n", "\r"]
        static let cmds: Set<Character> = Set("MmLlHhVvCcSsQqTtAaZz")
        var atEnd: Bool { i >= chars.count }
        mutating func skipSeparators() { while i < chars.count, Scanner.seps.contains(chars[i]) { i += 1 } }
        func peekCommand() -> Character? {
            var j = i
            while j < chars.count, Scanner.seps.contains(chars[j]) { j += 1 }
            guard j < chars.count, Scanner.cmds.contains(chars[j]) else { return nil }
            return chars[j]
        }
        mutating func consumeCommand() { skipSeparators(); if i < chars.count { i += 1 } }
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count else { return nil }
            switch chars[i] {
            case "0": i += 1; return false
            case "1": i += 1; return true
            default: return nil
            }
        }
        mutating func number() -> CGFloat? {
            skipSeparators()
            let n = chars.count
            var j = i
            func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
            if j < n, chars[j] == "-" || chars[j] == "+" { j += 1 }
            var seenDigit = false
            var seenDot = false
            while j < n {
                let c = chars[j]
                if isDigit(c) { seenDigit = true; j += 1 }
                else if c == "." && !seenDot { seenDot = true; j += 1 }
                else if (c == "e" || c == "E") && seenDigit {
                    j += 1
                    if j < n, chars[j] == "-" || chars[j] == "+" { j += 1 }
                    while j < n, isDigit(chars[j]) { j += 1 }
                    break
                } else { break }
            }
            guard seenDigit else { return nil }
            let str = String(chars[i..<j])
            i = j
            return CGFloat(Double(str) ?? 0)
        }
    }

    static func path(from d: String) -> CGPath {
        let path = CGMutablePath()
        var sc = Scanner(d)
        var cmd: Character = " "
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var ctrl = CGPoint.zero
        var prev: Character = " "

        func abs(_ x: CGFloat, _ y: CGFloat, _ rel: Bool) -> CGPoint {
            rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }
        func reflected() -> CGPoint { CGPoint(x: 2 * cur.x - ctrl.x, y: 2 * cur.y - ctrl.y) }

        while true {
            sc.skipSeparators()
            if sc.atEnd { break }
            if let c = sc.peekCommand() {
                sc.consumeCommand()
                cmd = c
            } else if cmd == " " {
                break
            }

            switch cmd {
            case "M", "m":
                guard let x = sc.number(), let y = sc.number() else { return path }
                cur = abs(x, y, cmd == "m"); path.move(to: cur); start = cur
                cmd = cmd == "m" ? "l" : "L"; prev = "M"
            case "L", "l":
                guard let x = sc.number(), let y = sc.number() else { return path }
                cur = abs(x, y, cmd == "l"); path.addLine(to: cur); prev = "L"
            case "H", "h":
                guard let x = sc.number() else { return path }
                cur = CGPoint(x: cmd == "h" ? cur.x + x : x, y: cur.y); path.addLine(to: cur); prev = "H"
            case "V", "v":
                guard let y = sc.number() else { return path }
                cur = CGPoint(x: cur.x, y: cmd == "v" ? cur.y + y : y); path.addLine(to: cur); prev = "V"
            case "C", "c":
                guard let a = sc.number(), let b = sc.number(), let cx = sc.number(),
                      let cy = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                let rel = cmd == "c"
                let c1 = abs(a, b, rel), c2 = abs(cx, cy, rel)
                cur = abs(x, y, rel); path.addCurve(to: cur, control1: c1, control2: c2)
                ctrl = c2; prev = "C"
            case "S", "s":
                guard let cx = sc.number(), let cy = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                let rel = cmd == "s"
                let c1 = (prev == "C" || prev == "S") ? reflected() : cur
                let c2 = abs(cx, cy, rel)
                cur = abs(x, y, rel); path.addCurve(to: cur, control1: c1, control2: c2)
                ctrl = c2; prev = "S"
            case "Q", "q":
                guard let cx = sc.number(), let cy = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                let rel = cmd == "q"
                let cp = abs(cx, cy, rel)
                cur = abs(x, y, rel); path.addQuadCurve(to: cur, control: cp)
                ctrl = cp; prev = "Q"
            case "T", "t":
                guard let x = sc.number(), let y = sc.number() else { return path }
                let cp = (prev == "Q" || prev == "T") ? reflected() : cur
                cur = abs(x, y, cmd == "t"); path.addQuadCurve(to: cur, control: cp)
                ctrl = cp; prev = "T"
            case "A", "a":
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let laf = sc.flag(), let sf = sc.flag(), let x = sc.number(), let y = sc.number() else { return path }
                let end = abs(x, y, cmd == "a")
                appendArc(path, from: cur, to: end, rx: rx, ry: ry, xRotDeg: rot, largeArc: laf, sweep: sf)
                cur = end; prev = "A"
            case "Z", "z":
                path.closeSubpath(); cur = start; prev = "Z"
            default:
                return path
            }
        }
        return path
    }

    /// Endpoint-parameterization elliptical arc → cubic béziers (SVG implementation
    /// notes F.6). Splits into ≤90° segments for accuracy.
    private static func appendArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, xRotDeg: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        var rx = Swift.abs(rxIn), ry = Swift.abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = xRotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        // Correct out-of-range radii.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let rx2 = rx * rx, ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(num / den)
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(1, Int(ceil(Swift.abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var ang = theta1
        for _ in 0..<segments {
            let cos1 = cos(ang), sin1 = sin(ang)
            let cos2 = cos(ang + delta), sin2 = sin(ang + delta)
            func pt(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + cosP * rx * c - sinP * ry * s,
                        y: cy + sinP * rx * c + cosP * ry * s)
            }
            let e1 = pt(cos1, sin1)
            let e2 = pt(cos2, sin2)
            let c1 = CGPoint(x: e1.x + (-cosP * rx * sin1 - sinP * ry * cos1) * t,
                             y: e1.y + (-sinP * rx * sin1 + cosP * ry * cos1) * t)
            let c2 = CGPoint(x: e2.x - (-cosP * rx * sin2 - sinP * ry * cos2) * t,
                             y: e2.y - (-sinP * rx * sin2 + cosP * ry * cos2) * t)
            path.addCurve(to: e2, control1: c1, control2: c2)
            ang += delta
        }
    }
}

/// Renders agent brand icons (from `AgentIconArt`) as resolution-independent
/// `NSImage`s — a tintable template (`templateImage`) or a baked-color variant
/// (`coloredImage`). Both are memoized in `cache`, keyed by kind+size (+color).
@MainActor
enum AgentIconRenderer {
    private static var cache: [String: NSImage] = [:]

    /// Whether a brand mark exists for this agent (else callers fall back to text).
    static func hasIcon(for kind: AgentKind) -> Bool {
        AgentIconArt.icons[kind.rawValue] != nil
    }

    /// A brand-colored (non-template) icon, baked to `color`. For contexts that can't
    /// tint a template at draw time (e.g. `NSMenuItem.image`, which would otherwise
    /// recolor it to the menu's label color). Cached per kind+size+color.
    static func coloredImage(for kind: AgentKind, size: CGFloat, color: NSColor) -> NSImage? {
        guard let template = templateImage(for: kind, size: size) else { return nil }
        // Key on the actual sRGB components, not `color.hashValue` — a hash collision
        // would hand back an icon baked in the wrong color. A semantic/system color that
        // can't resolve to sRGB falls back to its hash (rare; never crashes).
        let colorKey: String
        if let rgb = color.usingColorSpace(.sRGB) {
            colorKey = String(format: "%.3f,%.3f,%.3f,%.3f",
                              rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        } else {
            colorKey = String(color.hashValue)
        }
        let key = "\(kind.rawValue)@\(Int(size.rounded()))#\(colorKey)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            template.draw(in: rect)              // white silhouette (alpha = shape)
            color.set()
            rect.fill(using: .sourceAtop)        // recolor the silhouette to `color`
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    /// A tintable template for an agent that has no vector brand mark (e.g. Aider): its
    /// short `chip` monogram drawn as a silhouette (alpha = glyph coverage), so an icon
    /// slot stays visually uniform and recolors via `contentTintColor` like the real marks.
    static func monogramTemplate(_ text: String, size: CGFloat) -> NSImage {
        let key = "mono:\(text)@\(Int(size.rounded()))"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: size * 0.46, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: text, attributes: attrs)
            let b = str.size()
            str.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2))
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// A template image (alpha = silhouette) for the agent, or nil if none exists.
    /// Set `contentTintColor` on the hosting `NSImageView` to color it.
    static func templateImage(for kind: AgentKind, size: CGFloat) -> NSImage? {
        guard let art = AgentIconArt.icons[kind.rawValue] else { return nil }
        let key = "\(kind.rawValue)@\(Int(size.rounded()))"
        if let cached = cache[key] { return cached }
        let paths = art.subpaths.map { SVGPathParser.path(from: $0) }
        let vb = art.viewBox
        let rule: CGPathFillRule = art.evenOdd ? .evenOdd : .winding
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext, vb.width > 0, vb.height > 0 else { return false }
            // Aspect-fit the viewBox into rect, flipping SVG's y-down to the y-up context.
            let s = min(rect.width / vb.width, rect.height / vb.height)
            let tx = rect.minX + (rect.width - vb.width * s) / 2
            let ty = rect.minY + (rect.height - vb.height * s) / 2
            var transform = CGAffineTransform(translationX: tx, y: ty)
                .scaledBy(x: s, y: s)
                .translatedBy(x: 0, y: vb.height)
                .scaledBy(x: 1, y: -1)
            ctx.setFillColor(NSColor.white.cgColor)
            for sub in paths {
                if let t = sub.copy(using: &transform) {
                    ctx.addPath(t)
                    ctx.fillPath(using: rule)
                }
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}
