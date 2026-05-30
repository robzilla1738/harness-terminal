import Foundation

/// A parsed SGR (1006) mouse report: `CSI < b ; x ; y (M|m)`. Neutral data (no engine
/// types) so it stays in HarnessCore and is unit-testable; the compositor maps it to the
/// engine's mouse encoding when forwarding to a pane.
public struct SGRMouseEvent: Equatable, Sendable {
    /// The button index after stripping modifier/motion/wheel bits (0=left, 1=middle, 2=right).
    public var button: Int
    /// 1-based terminal column / row from the report.
    public var column: Int
    public var row: Int
    /// `m` = release, `M` = press.
    public var release: Bool
    /// Bit 5 (32): a motion/drag report.
    public var motion: Bool
    /// Bit 6 (64): a wheel event (button 0/1 = up/down).
    public var wheel: Bool
    public var shift: Bool   // bit 2 (4)
    public var meta: Bool    // bit 3 (8)
    public var control: Bool // bit 4 (16)

    public init(button: Int, column: Int, row: Int, release: Bool, motion: Bool, wheel: Bool, shift: Bool, meta: Bool, control: Bool) {
        self.button = button
        self.column = column
        self.row = row
        self.release = release
        self.motion = motion
        self.wheel = wheel
        self.shift = shift
        self.meta = meta
        self.control = control
    }
}

/// Parsing + pane-routing for SGR-1006 mouse input arriving on a client's stdin (the
/// compositor). Pure and testable; the wiring (encode + forward) lives in the attach client.
public enum SGRMouse {
    /// The SGR mouse prefix `ESC [ <` as bytes — the recognizer that gates the parser.
    public static let prefix: [UInt8] = [0x1B, 0x5B, 0x3C]

    /// Parse a full `ESC [ < b ; x ; y (M|m)` sequence. Returns nil if it isn't one.
    public static func parse(_ bytes: [UInt8]) -> SGRMouseEvent? {
        guard bytes.count >= prefix.count + 4, Array(bytes.prefix(3)) == prefix else { return nil }
        let finalByte = bytes[bytes.count - 1]
        guard finalByte == UInt8(ascii: "M") || finalByte == UInt8(ascii: "m") else { return nil }
        let body = bytes[prefix.count..<(bytes.count - 1)] // between "<" and the final byte
        let parts = body.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard parts.count == 3,
              let b = Int(decimal: parts[0]),
              let x = Int(decimal: parts[1]),
              let y = Int(decimal: parts[2])
        else { return nil }
        return SGRMouseEvent(
            button: b & 0b11,
            column: x,
            row: y,
            release: finalByte == UInt8(ascii: "m"),
            motion: (b & 32) != 0,
            wheel: (b & 64) != 0,
            shift: (b & 4) != 0,
            meta: (b & 8) != 0,
            control: (b & 16) != 0
        )
    }

    /// Map a 1-based terminal position to the pane that contains it, returning the pane index
    /// in `rects` and the **pane-local** 0-based coordinates (re-based so the pane sees the
    /// click at its own origin). Returns nil for clicks on borders / status / no pane.
    public static func route(column: Int, row: Int, rects: [PaneRect]) -> (index: Int, localColumn: Int, localRow: Int)? {
        let col0 = column - 1
        let row0 = row - 1
        for (i, rect) in rects.enumerated() {
            if col0 >= rect.x, col0 < rect.x + rect.cols, row0 >= rect.y, row0 < rect.y + rect.rows {
                return (i, col0 - rect.x, row0 - rect.y)
            }
        }
        return nil
    }
}

private extension Int {
    /// Decimal parse of an ASCII byte slice (the SGR params are plain base-10).
    init?<S: Sequence>(decimal bytes: S) where S.Element == UInt8 {
        var value = 0
        var any = false
        for b in bytes {
            guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(b - UInt8(ascii: "0"))
            any = true
        }
        guard any else { return nil }
        self = value
    }
}
