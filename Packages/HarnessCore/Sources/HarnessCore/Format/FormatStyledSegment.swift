import Foundation

/// A renderer-agnostic color for `#[fg=…,bg=…]` style spans. HarnessCore stays engine-free,
/// so this mirrors the engine's color shape; the GUI maps it to `NSColor` and the compositor
/// to an SGR palette/truecolor code. `none` = the surface default.
public enum FormatColor: Equatable, Sendable {
    case none
    case palette(Int)
    case rgb(r: UInt8, g: UInt8, b: UInt8)

    private static let ansiColorNames: [String: Int] = [
        "black": 0, "red": 1, "green": 2, "yellow": 3, "blue": 4, "magenta": 5, "cyan": 6, "white": 7,
        "brightblack": 8, "brightred": 9, "brightgreen": 10, "brightyellow": 11,
        "brightblue": 12, "brightmagenta": 13, "brightcyan": 14, "brightwhite": 15,
    ]

    /// Parse a tmux/`#[…]` color token: `default`/`none`, an ANSI name (`red`, `brightblue`),
    /// `colour245`/`color245`, a bare palette index, or `#rrggbb`. Returns nil for an
    /// unrecognized non-empty token. The single color parser shared by `#[fg=…]` status
    /// spans and `window-style`/`pane-style` (`PaneStyle`).
    public static func parse(_ raw: String) -> FormatColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }
        // Explicit `default` → `.some(FormatColor.none)` (NOT `Optional.none`/nil): a set-but-
        // default value, distinct from "unset", so it can cancel a more general style.
        if s == "default" || s == "none" { return FormatColor.none }
        if let idx = ansiColorNames[s] { return .palette(idx) }
        if s.hasPrefix("#"), s.count == 7 {
            let hex = s.dropFirst()
            guard let r = UInt8(hex.prefix(2), radix: 16),
                  let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
                  let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16) else { return nil }
            return .rgb(r: r, g: g, b: b)
        }
        if s.hasPrefix("colour"), let n = Int(s.dropFirst(6)) { return .palette(n) }
        if s.hasPrefix("color"), let n = Int(s.dropFirst(5)) { return .palette(n) }
        if let n = Int(s) { return .palette(n) }
        return nil
    }

    /// Resolve to 8-bit RGB via the standard xterm-256 palette (16 base + 6×6×6 cube + 24
    /// greys). `.none` (the surface default) returns nil so callers keep their own default.
    /// Used by the GUI to map a parsed `window-style` color to an `RGBColor`.
    public func rgbComponents() -> (r: UInt8, g: UInt8, b: UInt8)? {
        switch self {
        case .none:
            return nil
        case let .rgb(r, g, b):
            return (r, g, b)
        case let .palette(index):
            return Self.xterm256[safe: index]
        }
    }

    /// xterm-256 → RGB. Built once; indexes 0...255.
    private static let xterm256: [(r: UInt8, g: UInt8, b: UInt8)] = {
        let base16: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        var out: [(UInt8, UInt8, UInt8)] = base16.map { (UInt8($0.0), UInt8($0.1), UInt8($0.2)) }
        func level(_ v: Int) -> Int { v == 0 ? 0 : 55 + v * 40 }
        for i in 0 ..< 216 {
            out.append((UInt8(level(i / 36)), UInt8(level((i / 6) % 6)), UInt8(level(i % 6))))
        }
        for i in 0 ..< 24 { let v = UInt8(8 + i * 10); out.append((v, v, v)) }
        return out
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One run of status text plus the style established by the `#[…]` directives in effect. The
/// single intermediate both status renderers consume: the GUI builds an `NSAttributedString`
/// from these, the compositor emits one SGR run per segment — so styling lives in one place.
public struct StyledSegment: Equatable, Sendable {
    public var text: String
    public var fg: FormatColor?
    public var bg: FormatColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var reverse: Bool
    public var dim: Bool

    public init(
        text: String,
        fg: FormatColor? = nil,
        bg: FormatColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        reverse: Bool = false,
        dim: Bool = false
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.reverse = reverse
        self.dim = dim
    }
}
