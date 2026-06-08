// swift-format-ignore-file
import SwiftUI
import AppKit
import CoreGraphics

/// Crisp, resolution-independent agent brand marks rendered as `Shape`s from raw SVG
/// geometry — no bundled raster assets. Self-contained port of the main Harness app's
/// `AgentIconArt` + `AgentIconRenderer` (`SVGPathParser`), keyed by a plain string so
/// there's no dependency on HarnessCore.
///
/// Marks: codex, claude-code, cursor, gemini, opencode (Lobe Icons, MIT). Agents without
/// a vector mark fall back to a two-letter monogram. Tinted at draw time — monochrome
/// white in this wizard.

struct AgentVectorIcon {
    let viewBox: CGSize
    let evenOdd: Bool
    let subpaths: [String]
}

enum AgentArt {
    static let icons: [String: AgentVectorIcon] = [
        "codex": AgentVectorIcon(
            viewBox: CGSize(width: 24, height: 24), evenOdd: true, subpaths: [
            "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"
            ]),
        "claude-code": AgentVectorIcon(
            viewBox: CGSize(width: 24, height: 24), evenOdd: true, subpaths: [
            "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
            ]),
        "cursor": AgentVectorIcon(
            viewBox: CGSize(width: 24, height: 24), evenOdd: true, subpaths: [
            "M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.064-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c.264 0 .428.286.296.514z"
            ]),
        "gemini": AgentVectorIcon(
            viewBox: CGSize(width: 24, height: 24), evenOdd: true, subpaths: [
            "M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z"
            ]),
        "opencode": AgentVectorIcon(
            viewBox: CGSize(width: 24, height: 24), evenOdd: true, subpaths: [
            "M16 6H8v12h8V6zm4 16H4V2h16v20z"
            ]),
    ]
}

/// Minimal SVG path-data → `Path` parser (subset `M m L l H h V v C c S s Q q T t A a Z z`),
/// a direct port of the main app's `SVGPathParser` retargeted to SwiftUI `Path`.
enum SVGPath {
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

    static func path(from d: String) -> Path {
        var path = Path()
        var sc = Scanner(d)
        var cmd: Character = " "
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var ctrl = CGPoint.zero
        var prev: Character = " "

        func absPt(_ x: CGFloat, _ y: CGFloat, _ rel: Bool) -> CGPoint {
            rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }
        func reflected() -> CGPoint { CGPoint(x: 2 * cur.x - ctrl.x, y: 2 * cur.y - ctrl.y) }

        while true {
            sc.skipSeparators()
            if sc.atEnd { break }
            if let c = sc.peekCommand() {
                sc.consumeCommand(); cmd = c
            } else if cmd == " " { break }

            switch cmd {
            case "M", "m":
                guard let x = sc.number(), let y = sc.number() else { return path }
                cur = absPt(x, y, cmd == "m"); path.move(to: cur); start = cur
                cmd = cmd == "m" ? "l" : "L"; prev = "M"
            case "L", "l":
                guard let x = sc.number(), let y = sc.number() else { return path }
                cur = absPt(x, y, cmd == "l"); path.addLine(to: cur); prev = "L"
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
                let c1 = absPt(a, b, rel), c2 = absPt(cx, cy, rel)
                cur = absPt(x, y, rel); path.addCurve(to: cur, control1: c1, control2: c2)
                ctrl = c2; prev = "C"
            case "S", "s":
                guard let cx = sc.number(), let cy = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                let rel = cmd == "s"
                let c1 = (prev == "C" || prev == "S") ? reflected() : cur
                let c2 = absPt(cx, cy, rel)
                cur = absPt(x, y, rel); path.addCurve(to: cur, control1: c1, control2: c2)
                ctrl = c2; prev = "S"
            case "Q", "q":
                guard let cx = sc.number(), let cy = sc.number(), let x = sc.number(), let y = sc.number() else { return path }
                let rel = cmd == "q"
                let cp = absPt(cx, cy, rel)
                cur = absPt(x, y, rel); path.addQuadCurve(to: cur, control: cp)
                ctrl = cp; prev = "Q"
            case "T", "t":
                guard let x = sc.number(), let y = sc.number() else { return path }
                let cp = (prev == "Q" || prev == "T") ? reflected() : cur
                cur = absPt(x, y, cmd == "t"); path.addQuadCurve(to: cur, control: cp)
                ctrl = cp; prev = "T"
            case "A", "a":
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let laf = sc.flag(), let sf = sc.flag(), let x = sc.number(), let y = sc.number() else { return path }
                let end = absPt(x, y, cmd == "a")
                appendArc(&path, from: cur, to: end, rx: rx, ry: ry, xRotDeg: rot, largeArc: laf, sweep: sf)
                cur = end; prev = "A"
            case "Z", "z":
                path.closeSubpath(); cur = start; prev = "Z"
            default:
                return path
            }
        }
        return path
    }

    private static func appendArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat, xRotDeg: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        var rx = Swift.abs(rxIn), ry = Swift.abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = xRotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
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
            let e2 = pt(cos2, sin2)
            let e1 = pt(cos1, sin1)
            let c1 = CGPoint(x: e1.x + (-cosP * rx * sin1 - sinP * ry * cos1) * t,
                             y: e1.y + (-sinP * rx * sin1 + cosP * ry * cos1) * t)
            let c2 = CGPoint(x: e2.x - (-cosP * rx * sin2 - sinP * ry * cos2) * t,
                             y: e2.y - (-sinP * rx * sin2 + cosP * ry * cos2) * t)
            path.addCurve(to: e2, control1: c1, control2: c2)
            ang += delta
        }
    }
}

/// A SwiftUI `Shape` that aspect-fits an agent's SVG geometry into its frame, flipping
/// SVG's y-down to SwiftUI's y-up. Fill/tint it like any shape (monochrome here).
struct AgentMarkShape: Shape {
    let icon: AgentVectorIcon

    func path(in rect: CGRect) -> Path {
        let vb = icon.viewBox
        guard vb.width > 0, vb.height > 0 else { return Path() }
        let s = min(rect.width / vb.width, rect.height / vb.height)
        let tx = rect.minX + (rect.width - vb.width * s) / 2
        let ty = rect.minY + (rect.height - vb.height * s) / 2
        // y-down (SVG) -> y-up: translate to bottom then flip.
        let transform = CGAffineTransform(translationX: tx, y: ty)
            .scaledBy(x: s, y: s)
        var combined = Path()
        for sub in icon.subpaths {
            combined.addPath(SVGPath.path(from: sub))
        }
        return combined.applying(transform)
    }
}

/// Convenience view: renders an agent mark by key, or a monogram fallback. Monochrome.
struct AgentMark: View {
    let key: String
    var size: CGFloat = 28
    var monogram: String = "?"
    var color: Color = ImmersivePalette.SUI.textPrimary

    var body: some View {
        Group {
            if let icon = AgentArt.icons[key] {
                AgentMarkShape(icon: icon)
                    .fill(color, style: FillStyle(eoFill: icon.evenOdd))
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}
