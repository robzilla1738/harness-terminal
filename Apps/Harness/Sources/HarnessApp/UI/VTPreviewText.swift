import AppKit
import HarnessCore

/// A pane's screen in color for previews (Overview tiles, tab peek): the daemon's `vt`
/// capture, its SGR runs turned into attributes. One path for every pane, mounted or not,
/// local or remote. Palette colors come from the current theme; default text uses the
/// preview's own color so it reads on the chrome behind it.
@MainActor
enum VTPreviewText {
    /// The last `count` lines with something visible on them.
    static func lastLines(_ vt: String, _ count: Int) -> [Substring] {
        var rows = vt.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = rows.last, plain(last).trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return Array(rows.suffix(count))
    }

    static func attributed(_ vt: String, font: NSFont, foreground: NSColor) -> NSAttributedString {
        let palette = (ThemeLibrary.currentDocument(named: "preview")?.colors.palette ?? []).map {
            NSColor(srgbRed: CGFloat($0.red) / 255, green: CGFloat($0.green) / 255, blue: CGFloat($0.blue) / 255, alpha: 1)
        }
        let out = NSMutableAttributedString()
        var style = Style()
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            out.append(NSAttributedString(string: text, attributes: style.attributes(font: font, foreground: foreground, palette: palette)))
            text = ""
        }
        var scalars = vt.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1b}" else { text.unicodeScalars.append(scalar); continue }
            guard scalars.next() == "[" else { continue }
            var params = ""
            var final: Unicode.Scalar?
            while let next = scalars.next() {
                if next.value >= 0x40, next.value <= 0x7e { final = next; break }
                params.unicodeScalars.append(next)
            }
            guard final == "m" else { continue }
            flush()
            style.apply(params)
        }
        flush()
        return out
    }

    static func plain(_ vt: Substring) -> String {
        String(vt).replacingOccurrences(of: "\u{1b}\\[[0-9;:]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private enum Color: Equatable {
        case index(Int)
        case rgb(Int, Int, Int)
    }

    private struct Style {
        var foreground: Color?
        var background: Color?
        var bold = false
        var faint = false
        var italic = false
        var underline = false
        var strike = false
        var inverse = false

        mutating func apply(_ params: String) {
            var codes = params.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
            if codes.isEmpty || codes == [""] { codes = ["0"] }
            var index = 0
            func extended() -> Color? {
                guard index + 1 < codes.count else { return nil }
                if codes[index + 1] == "5", index + 2 < codes.count, let n = Int(codes[index + 2]) {
                    index += 2
                    return .index(n)
                }
                if codes[index + 1] == "2", index + 4 < codes.count,
                   let r = Int(codes[index + 2]), let g = Int(codes[index + 3]), let b = Int(codes[index + 4]) {
                    index += 4
                    return .rgb(r, g, b)
                }
                return nil
            }
            while index < codes.count {
                let code = codes[index]
                let number = Int(code.split(separator: ":").first ?? "") ?? 0
                switch number {
                case 0: self = Style()
                case 1: bold = true
                case 2: faint = true
                case 3: italic = true
                case 4: underline = !code.hasSuffix(":0")
                case 7: inverse = true
                case 9: strike = true
                case 22: bold = false; faint = false
                case 23: italic = false
                case 24: underline = false
                case 27: inverse = false
                case 29: strike = false
                case 30 ... 37: foreground = .index(number - 30)
                case 38: foreground = extended()
                case 39: foreground = nil
                case 40 ... 47: background = .index(number - 40)
                case 48: background = extended()
                case 49: background = nil
                case 58: _ = extended() // underline color: not drawn in previews, but its
                                        // parameters must not be read as more codes
                case 59: break
                case 90 ... 97: foreground = .index(number - 90 + 8)
                case 100 ... 107: background = .index(number - 100 + 8)
                default: break
                }
                index += 1
            }
        }

        func attributes(font: NSFont, foreground defaultColor: NSColor, palette: [NSColor]) -> [NSAttributedString.Key: Any] {
            func resolve(_ color: Color?) -> NSColor? {
                switch color {
                case let .index(n) where n < palette.count: return palette[n]
                case let .index(n) where n >= 16 && n < 232:
                    let cube = n - 16
                    let level = { (v: Int) in CGFloat(v == 0 ? 0 : 55 + v * 40) / 255 }
                    return NSColor(srgbRed: level(cube / 36), green: level(cube / 6 % 6), blue: level(cube % 6), alpha: 1)
                case let .index(n) where n >= 232:
                    let gray = CGFloat(8 + (n - 232) * 10) / 255
                    return NSColor(white: gray, alpha: 1)
                case let .rgb(r, g, b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
                default: return nil
                }
            }
            var text = resolve(foreground) ?? defaultColor
            var fill = resolve(background)
            if inverse { (text, fill) = (fill ?? NSColor(white: 0.1, alpha: 1), text) }
            if faint { text = text.withAlphaComponent(0.6) }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let styled = traits.isEmpty ? font : (NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font)
            var attributes: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: text]
            if let fill { attributes[.backgroundColor] = fill }
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }
    }
}
