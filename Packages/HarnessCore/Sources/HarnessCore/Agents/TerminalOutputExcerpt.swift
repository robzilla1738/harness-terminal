import Foundation

/// A bounded plain-text suffix. Parse the entire retained command span so a
/// truncation inside an OSC/DCS payload cannot expose the payload as ordinary text.
public struct TerminalOutputExcerpt: Sendable {
    private enum Phase: Sendable { case ground, escape, csi, string, stringEscape }
    private var osc = false
    private var phase: Phase = .ground
    private var bytes = Data()
    private let maximumBytes: Int
    public private(set) var truncated = false
    public init(maximumBytes: Int) { self.maximumBytes = max(1, min(65536, maximumBytes)) }
    public mutating func feed(_ data: Data) {
        for byte in data {
            switch phase {
            case .ground:
                if byte == 0x1b { phase = .escape }
                else if byte == 10 || byte == 9 || byte >= 32 && byte != 127 { bytes.append(byte) }
            case .escape:
                switch byte {
                case 0x5b: phase = .csi
                case 0x5d: osc = true; phase = .string
                case 0x50, 0x58, 0x5e, 0x5f: osc = false; phase = .string
                case 0x1b: break
                case 0x20...0x2f: break
                default: phase = .ground
                }
            case .csi:
                if byte == 0x1b { phase = .escape }
                else if (0x40...0x7e).contains(byte) || byte == 0x18 || byte == 0x1a { phase = .ground }
            case .string:
                if byte == 0x1b { phase = .stringEscape }
                else if (osc && byte == 7) || byte == 0x18 || byte == 0x1a { phase = .ground }
            case .stringEscape:
                if byte == 0x5c || (osc && byte == 7) || byte == 0x18 || byte == 0x1a { phase = .ground }
                else if byte != 0x1b { phase = .string }
            }
            if bytes.count > maximumBytes * 2 {
                bytes = Data(bytes.suffix(maximumBytes)); truncated = true
            }
        }
    }
    public var text: String {
        var tail = Data(bytes.suffix(maximumBytes))
        while let byte = tail.first, byte & 0xc0 == 0x80 { tail.removeFirst() }
        let scalars = String(decoding: tail, as: UTF8.self).unicodeScalars.filter { !(0x7f...0x9f).contains($0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
    public var isTruncated: Bool { truncated || bytes.count > maximumBytes }
}
