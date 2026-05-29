import Foundation

/// A platform-independent 24-bit color with optional alpha. The theme layer stays free
/// of AppKit/CoreGraphics so it can be unit-tested without a GUI and reused by the
/// engine, the renderer, and the chrome. Conversion to `NSColor`/`CGColor` lives in the
/// app/kit layer.
///
/// JSON form is the conventional `#rrggbb` (or `#rrggbbaa`) hex string, so `.harnesstheme`
/// files are human-readable and diff-friendly.
public struct RGBColor: Equatable, Sendable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    /// 0–255; 255 = fully opaque. Most theme colors are opaque; alpha is preserved for
    /// completeness (e.g. selection tints).
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parse `#rgb`, `#rrggbb`, or `#rrggbbaa` (leading `#` optional, case-insensitive).
    /// Returns nil for malformed input.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch s.count {
        case 3: // #rgb shorthand
            let chars = Array(s)
            guard
                let r = UInt8(String([chars[0], chars[0]]), radix: 16),
                let g = UInt8(String([chars[1], chars[1]]), radix: 16),
                let b = UInt8(String([chars[2], chars[2]]), radix: 16)
            else { return nil }
            self.init(red: r, green: g, blue: b)
        case 6:
            guard let value = UInt32(s, radix: 16) else { return nil }
            self.init(
                red: UInt8((value >> 16) & 0xFF),
                green: UInt8((value >> 8) & 0xFF),
                blue: UInt8(value & 0xFF)
            )
        case 8:
            guard let value = UInt32(s, radix: 16) else { return nil }
            self.init(
                red: UInt8((value >> 24) & 0xFF),
                green: UInt8((value >> 16) & 0xFF),
                blue: UInt8((value >> 8) & 0xFF),
                alpha: UInt8(value & 0xFF)
            )
        default:
            return nil
        }
    }

    /// Lowercase `#rrggbb`, or `#rrggbbaa` when not fully opaque.
    public var hexString: String {
        let base = String(format: "#%02x%02x%02x", red, green, blue)
        return alpha == 255 ? base : base + String(format: "%02x", alpha)
    }

    /// Perceived brightness (0–1) via the Rec. 601 luma weights — used to classify a
    /// theme as light or dark so chrome can pick legible foregrounds.
    public var perceivedBrightness: Double {
        (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255.0
    }

    public var isDark: Bool { perceivedBrightness < 0.5 }
}

extension RGBColor: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let parsed = RGBColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid color hex string: \(hex)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
