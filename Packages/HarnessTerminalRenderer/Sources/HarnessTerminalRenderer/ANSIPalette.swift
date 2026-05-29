import HarnessTheme

/// The 256-entry ANSI color table used to resolve `palette(n)` cell colors to RGB.
///
/// - 0–15: the theme's 16 base ANSI colors (so palette colors track the active theme).
/// - 16–231: the standard 6×6×6 color cube.
/// - 232–255: the standard 24-step grayscale ramp.
///
/// Indices 16–255 are the xterm-standard values (theme-independent), matching what
/// every mainstream terminal use — this is a load-bearing part of color
/// fidelity for 256-color TUIs.
public struct ANSIPalette: Equatable, Sendable {
    /// Exactly 256 colors, indexable by ANSI palette number.
    public let colors: [RGBColor]

    /// Build the table from a theme's 16 base colors. `base16` must have 16 entries;
    /// if it doesn't, missing slots fall back to black.
    public init(base16: [RGBColor]) {
        var table = [RGBColor]()
        table.reserveCapacity(256)

        // 0–15: theme base colors.
        for i in 0 ..< 16 {
            table.append(i < base16.count ? base16[i] : RGBColor(red: 0, green: 0, blue: 0))
        }

        // 16–231: 6×6×6 cube. Each axis level maps 0→0, then 95,135,175,215,255.
        for r in 0 ..< 6 {
            for g in 0 ..< 6 {
                for b in 0 ..< 6 {
                    table.append(RGBColor(
                        red: Self.cubeLevel(r),
                        green: Self.cubeLevel(g),
                        blue: Self.cubeLevel(b)
                    ))
                }
            }
        }

        // 232–255: grayscale ramp 8, 18, …, 238.
        for i in 0 ..< 24 {
            let v = UInt8(8 + i * 10)
            table.append(RGBColor(red: v, green: v, blue: v))
        }

        colors = table
    }

    /// The RGB for an ANSI palette index, clamped into 0–255.
    public func color(at index: Int) -> RGBColor {
        colors[min(max(index, 0), 255)]
    }

    private static func cubeLevel(_ component: Int) -> UInt8 {
        component == 0 ? 0 : UInt8(55 + component * 40)
    }
}
