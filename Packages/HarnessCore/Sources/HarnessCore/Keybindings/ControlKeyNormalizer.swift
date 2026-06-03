import Foundation

public enum ControlKeyNormalizer {
    public static func normalizedKey(from raw: String, controlPressed: Bool) -> String {
        guard controlPressed,
              raw.count == 1,
              let scalar = raw.unicodeScalars.first,
              scalar.value >= 0x01,
              scalar.value <= 0x1A,
              let normalized = UnicodeScalar(scalar.value + 0x60)
        else { return raw }
        return String(normalized)
    }
}
