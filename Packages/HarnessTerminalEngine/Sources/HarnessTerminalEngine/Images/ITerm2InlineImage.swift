import Foundation

/// Parses an iTerm2 inline image — the payload of `OSC 1337 ; File=<key>=<val>;…:<base64> ST`
/// (the `1337;` code already stripped by the OSC dispatcher, so the input begins `File=`).
public struct ITerm2InlineImage: Equatable {
    public var keys: [String: String]
    public var image: DecodedImage

    /// `width` / `height` arguments are cell counts, pixel counts (`Npx`), or percent (`N%`);
    /// `auto`/absent means derive from the image. We surface the raw strings; the placement
    /// layer resolves them against the cell size.
    public var widthArg: String? { keys["width"] }
    public var heightArg: String? { keys["height"] }
    public var preserveAspectRatio: Bool { keys["preserveAspectRatio"] != "0" }

    public static func parse(_ payload: [UInt8]) -> ITerm2InlineImage? {
        payload.withUnsafeBufferPointer { parse($0) }
    }

    public static func parse(_ payload: ArraySlice<UInt8>) -> ITerm2InlineImage? {
        payload.withUnsafeBytes { raw in parse(raw.bindMemory(to: UInt8.self)) }
    }

    /// Bytewise: only the short `key=value` args are a String. The base64 body stays a
    /// pointer. A clean 64-character prefix that is not an image header returns nil
    /// without decoding the rest — OSC 1337 junk must not pay a multi-megabyte decode
    /// plus ImageIO. A short or dirty prefix (a newline, or a non-base64 byte such as
    /// 0xFF) falls through so a real image still decodes.
    static func parse(_ payload: UnsafeBufferPointer<UInt8>) -> ITerm2InlineImage? {
        let prefixCount = 5 // "File="
        guard payload.count >= prefixCount,
              payload[0] == 0x46, payload[1] == 0x69, payload[2] == 0x6C,
              payload[3] == 0x65, payload[4] == 0x3D,
              let colon = payload.firstIndex(of: UInt8(ascii: ":")),
              colon >= prefixCount,
              let base = payload.baseAddress
        else { return nil }
        let args = UnsafeBufferPointer(start: base + prefixCount, count: colon - prefixCount)
        guard let argsPart = String(bytes: args, encoding: .utf8) else { return nil }
        let b64 = UnsafeBufferPointer(start: base + colon + 1, count: payload.count - colon - 1)
        if rejectsNonImagePrefix(b64) { return nil }
        guard let raw = Base64Bytes.decode(b64, options: [.ignoreUnknownCharacters]),
              let image = ImageDecoder.decode(raw) else { return nil }
        var keys: [String: String] = [:]
        for pair in argsPart.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { keys[String(kv[0])] = String(kv[1]) }
        }
        return ITerm2InlineImage(keys: keys, image: image)
    }

    /// 64 base64 characters are one clean quantum (48 decoded bytes). Fewer decoded
    /// bytes means the prefix skipped a non-alphabet byte, so the header may be a real
    /// image with a wrinkle in front of it.
    private static func rejectsNonImagePrefix(_ b64: UnsafeBufferPointer<UInt8>) -> Bool {
        guard b64.count > 64, let base = b64.baseAddress else { return false }
        let prefix = UnsafeBufferPointer(start: base, count: 64)
        guard let head = Base64Bytes.decode(prefix, options: [.ignoreUnknownCharacters]),
              head.count == 48 else { return false }
        return !ImageDecoder.looksLikeImage(head)
    }
}
