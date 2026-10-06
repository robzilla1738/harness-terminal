import Foundation

/// Oklab components. `L` is lightness, `a`/`b` are the opponent axes.
struct Oklab: Equatable {
    var L: Double
    var a: Double
    var b: Double

    static func from(_ color: RGBColor) -> Oklab {
        func linear(_ channel: UInt8) -> Double {
            let s = Double(channel) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red)
        let g = linear(color.green)
        let b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Oklab(
            L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    func rgb(alpha: UInt8) -> RGBColor {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func encode(_ linear: Double) -> UInt8 {
            let c = min(max(linear, 0), 1)
            let srgb = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8((min(max(srgb, 0), 1) * 255).rounded())
        }
        return RGBColor(red: encode(r), green: encode(g), blue: encode(bLin), alpha: alpha)
    }
}

/// Cached Oklab adjustment of a low-contrast foreground toward a theme color.
/// A repeated (foreground, background, theme) triple returns the stored color
/// and increments `hitCount`. Full-theme recolor is a separate opt-in and does
/// not go through this cache.
public final class ThemeFitCache: @unchecked Sendable {
    private struct Key: Hashable {
        var fg: RGBColor
        var bg: RGBColor
        var theme: RGBColor
    }

    private let lock = NSLock()
    private var store: [Key: RGBColor] = [:]
    public private(set) var hitCount: Int = 0

    public init() {}

    public func adjust(foreground: RGBColor, background: RGBColor, toward theme: RGBColor) -> RGBColor {
        let key = Key(fg: foreground, bg: background, theme: theme)
        lock.lock()
        if let cached = store[key] {
            hitCount += 1
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fitted = Self.fit(foreground: foreground, background: background, toward: theme)
        lock.lock()
        if let cached = store[key] {
            hitCount += 1
            lock.unlock()
            return cached
        }
        store[key] = fitted
        lock.unlock()
        return fitted
    }

    static func fit(foreground: RGBColor, background: RGBColor, toward theme: RGBColor) -> RGBColor {
        let ratio = contrast(foreground, background)
        guard ratio < 4.5 else { return foreground }
        let fg = Oklab.from(foreground)
        let themeLab = Oklab.from(theme)
        let fgHue = atan2(fg.b, fg.a)
        let themeHue = atan2(themeLab.b, themeLab.a)
        var delta = themeHue - fgHue
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let hue = fgHue + delta * 0.55
        let chroma = hypot(fg.a, fg.b)
        let bgL = Oklab.from(background).L
        let lighter = bgL < 0.5
        var lo = fg.L
        var hi = lighter ? 1.0 : 0.0
        var best = foreground
        for _ in 0 ..< 10 {
            let L = (lo + hi) / 2
            let sample = Oklab(L: L, a: chroma * cos(hue), b: chroma * sin(hue)).rgb(alpha: foreground.alpha)
            if contrast(sample, background) >= 4.5 {
                best = sample
                if lighter { hi = L } else { lo = L }
            } else if lighter {
                lo = L
            } else {
                hi = L
            }
        }
        if contrast(best, background) < 4.5 {
            let L = lighter ? 1.0 : 0.0
            best = Oklab(L: L, a: chroma * cos(hue), b: chroma * sin(hue)).rgb(alpha: foreground.alpha)
        }
        return best
    }

    private static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        func lum(_ c: RGBColor) -> Double {
            0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
