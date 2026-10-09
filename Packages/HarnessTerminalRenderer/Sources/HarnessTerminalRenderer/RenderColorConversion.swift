import Darwin
import HarnessTerminalSupport
import HarnessTheme

private enum RenderColorConversion {
    // Vivid mode is intentionally modest: convert into Display-P3 first, then move each
    // channel 8% farther from luma and clamp to the drawable range. It is an opt-in
    // preference, not the default color-accuracy path.
    private static let vividSaturationScale: Float = 1.08

    static func displayP3(_ color: RGBColor) -> SIMD4<Float> {
        let sr = decodeSRGB(Float(color.red) / 255)
        let sg = decodeSRGB(Float(color.green) / 255)
        let sb = decodeSRGB(Float(color.blue) / 255)

        let x = 0.4124564 * sr + 0.3575761 * sg + 0.1804375 * sb
        let y = 0.2126729 * sr + 0.7151522 * sg + 0.0721750 * sb
        let z = 0.0193339 * sr + 0.1191920 * sg + 0.9503041 * sb

        let p3r = 2.4934969 * x - 0.9313836 * y - 0.4027108 * z
        let p3g = -0.8294890 * x + 1.7626641 * y + 0.0236247 * z
        let p3b = 0.0358458 * x - 0.0761724 * y + 0.9568845 * z

        return SIMD4<Float>(
            encodeSRGB(p3r),
            encodeSRGB(p3g),
            encodeSRGB(p3b),
            Float(color.alpha) / 255
        )
    }

    static func vividDisplayP3(_ color: RGBColor) -> SIMD4<Float> {
        let p3 = displayP3(color)
        let lifted = saturate(p3, scale: vividSaturationScale)
        return SIMD4<Float>(lifted.x, lifted.y, lifted.z, p3.w)
    }

    private static func saturate(_ color: SIMD4<Float>, scale: Float) -> SIMD3<Float> {
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        return SIMD3<Float>(
            clamp(luma + (color.x - luma) * scale),
            clamp(luma + (color.y - luma) * scale),
            clamp(luma + (color.z - luma) * scale)
        )
    }

    private static func decodeSRGB(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    private static func encodeSRGB(_ value: Float) -> Float {
        let clamped = clamp(value)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * powf(clamped, 1 / 2.4) - 0.055
    }

    private static func clamp(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}

extension RenderColor {
    public init(_ color: RGBColor, gamut: TerminalColorGamut, alpha: Float? = nil) {
        let resolvedAlpha = alpha ?? Float(color.alpha) / 255
        switch gamut {
        case .displayP3:
            let converted = RenderColorConversion.displayP3(color)
            self.init(red: converted.x, green: converted.y, blue: converted.z, alpha: resolvedAlpha)
        case .sRGB, .auto:
            self.init(color, alpha: resolvedAlpha)
        }
    }

    public init(
        _ color: RGBColor,
        renderingMode: TerminalColorRenderingMode,
        gamut: TerminalColorGamut = .auto,
        alpha: Float? = nil
    ) {
        let resolvedAlpha = alpha ?? Float(color.alpha) / 255
        let resolvedGamut = TerminalColorGamut.resolved(renderingMode: renderingMode, requested: gamut)
        switch (renderingMode, resolvedGamut) {
        case (.accurate, _):
            self.init(color, alpha: resolvedAlpha)
        case (.vivid, .displayP3):
            let converted = RenderColorConversion.vividDisplayP3(color)
            self.init(red: converted.x, green: converted.y, blue: converted.z, alpha: resolvedAlpha)
        case (.vivid, .sRGB), (.vivid, .auto):
            self.init(color, alpha: resolvedAlpha)
        }
    }
}

final class RenderColorConverter {
    private static let maxVividCacheEntries = 512

    private let renderingMode: TerminalColorRenderingMode
    private let gamut: TerminalColorGamut
    private var vividCache: [RGBColor: SIMD4<Float>] = [:]
    private var vividCacheOrder: [RGBColor] = []
    private var vividCacheOrderStart = 0

    init(renderingMode: TerminalColorRenderingMode, gamut: TerminalColorGamut) {
        self.renderingMode = renderingMode
        self.gamut = TerminalColorGamut.resolved(renderingMode: renderingMode, requested: gamut)
    }

    func color(_ rgb: RGBColor) -> RenderColor {
        color(rgb, alpha: Float(rgb.alpha) / 255)
    }

    func color(_ rgb: RGBColor, alpha: Float) -> RenderColor {
        switch renderingMode {
        case .accurate:
            return RenderColor(rgb, alpha: alpha)
        case .vivid:
            let converted = vividColor(for: rgb)
            return RenderColor(red: converted.x, green: converted.y, blue: converted.z, alpha: alpha)
        }
    }

    private func vividColor(for rgb: RGBColor) -> SIMD4<Float> {
        if let cached = vividCache[rgb] { return cached }
        let converted: SIMD4<Float>
        switch gamut {
        case .displayP3:
            converted = RenderColorConversion.vividDisplayP3(rgb)
        case .sRGB, .auto:
            converted = SIMD4<Float>(
                Float(rgb.red) / 255,
                Float(rgb.green) / 255,
                Float(rgb.blue) / 255,
                Float(rgb.alpha) / 255
            )
        }
        if vividCache.count >= Self.maxVividCacheEntries,
           vividCacheOrderStart < vividCacheOrder.count {
            let evicted = vividCacheOrder[vividCacheOrderStart]
            vividCache.removeValue(forKey: evicted)
            vividCacheOrderStart += 1
            compactVividCacheOrderIfNeeded()
        }
        vividCache[rgb] = converted
        vividCacheOrder.append(rgb)
        return converted
    }

    private func compactVividCacheOrderIfNeeded() {
        guard vividCacheOrderStart > 64,
              vividCacheOrderStart * 2 >= vividCacheOrder.count
        else { return }
        vividCacheOrder.removeFirst(vividCacheOrderStart)
        vividCacheOrderStart = 0
    }
}
