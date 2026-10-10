import Foundation
import CoreFoundation

public struct ITermColorProposal: Sendable {
    public var document: ThemeDocument
    public var warnings: [String]
}

public enum ITermColorImport {
    public enum Variant: String, Codable, Sendable { case base, dark, light }
    /// Parses both XML and binary .itermcolors without changing settings or files.
    public static func parse(_ data: Data, name: String, variant: Variant = .base) throws -> ITermColorProposal {
        guard data.count <= 4 << 20, !name.isEmpty, name.count <= 200,
              let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any], root.count <= 512 else { throw ThemeDocumentError.malformed("Invalid or oversized iTerm2 color file") }
        var warnings: [String] = [], consumed: Set<String> = []
        func value(_ key: String, required: Bool = false) throws -> RGBColor? {
            let variantKey = key + (variant == .dark ? " (Dark)" : variant == .light ? " (Light)" : "")
            let chosen = root[variantKey] != nil ? variantKey : key
            guard let raw = root[chosen] else { if required { throw ThemeDocumentError.malformed("Missing " + key + "; select the appropriate base/dark/light variant") }; return nil }
            consumed.insert(chosen)
            guard let color = raw as? [String: Any], color.count <= 16 else { throw ThemeDocumentError.malformed("Invalid " + chosen) }
            func channel(_ key: String, fallback: Double? = nil) throws -> Double {
                if color[key] == nil, let fallback { return fallback }
                guard let number = color[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else { throw ThemeDocumentError.malformed("Invalid " + chosen + " " + key) }
                return number.doubleValue
            }
            var rgb = try [channel("Red Component"), channel("Green Component"), channel("Blue Component")]
            let alpha = try channel("Alpha Component", fallback: 1)
            let space = color["Color Space"] as? String
            switch space {
            case "sRGB": break
            case "P3", "Display P3", "display-p3":
                let converted = p3ToSRGB(rgb)
                if converted.contains(where: { $0 < -0.000001 || $0 > 1.000001 }) { warnings.append(chosen + " was converted from Display P3 and clipped to the existing sRGB theme gamut.") }
                rgb = converted.map { min(1, max(0, $0)) }
            case nil: warnings.append("Legacy colors without a color-space declaration are interpreted as sRGB component values.")
            default: throw ThemeDocumentError.malformed("Unsupported color space for " + chosen + ": " + (space ?? "unknown") + ". Export an sRGB or Display P3 preset.")
            }
            func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
            return RGBColor(red: byte(rgb[0]), green: byte(rgb[1]), blue: byte(rgb[2]), alpha: byte(alpha))
        }
        let background = try value("Background Color", required: true)!, foreground = try value("Foreground Color", required: true)!
        let palette = try (0..<16).map { try value("Ansi \($0) Color", required: true)! }
        let colors = try ThemeDocument.Colors(background: background, foreground: foreground, cursor: value("Cursor Color"), cursorText: value("Cursor Text Color"), selectionBackground: value("Selection Color"), selectionForeground: value("Selected Text Color"), bold: value("Bold Color"), palette: palette)
        let document = ThemeDocument(name: name, colors: colors, appearance: .init(sourceColorSpace: .sRGB))
        try document.validated()
        let ignored = root.keys.filter { !consumed.contains($0) }.sorted()
        if !ignored.isEmpty { warnings.append("Unapplied preset fields and other variants: " + ignored.prefix(64).map { String($0.prefix(100)) }.joined(separator: ", ")) }
        warnings.append("Components use the existing 8-bit Harness theme model. This preview changes no settings.")
        return ITermColorProposal(document: document, warnings: Array(Set(warnings)).sorted())
    }
    /// D65 Display-P3 → XYZ → sRGB, using CSS Color 4's standard matrices and
    /// transfer function. The result is clipped only after conversion, and reported.
    private static func p3ToSRGB(_ rgb: [Double]) -> [Double] {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let p3: [[Double]] = [[608311.0 / 1250200, 189793.0 / 714400, 198249.0 / 1000160], [35783.0 / 156275, 247089.0 / 357200, 198249.0 / 2500400], [0, 32229.0 / 714400, 5220557.0 / 5000800]]
        let srgb: [[Double]] = [[12831.0 / 3959, -329.0 / 214, -1974.0 / 3959], [-851781.0 / 878810, 1648619.0 / 878810, 36519.0 / 878810], [705.0 / 12673, -2585.0 / 12673, 705.0 / 667]]
        func multiply(_ matrix: [[Double]], _ value: [Double]) -> [Double] { matrix.map { zip($0, value).reduce(0) { $0 + $1.0 * $1.1 } } }
        return multiply(srgb, multiply(p3, linear)).map { value in
            let sign = value < 0 ? -1.0 : 1.0, magnitude = abs(value)
            return magnitude <= 0.0031308 ? 12.92 * value : sign * (1.055 * pow(magnitude, 1 / 2.4) - 0.055)
        }
    }
}
