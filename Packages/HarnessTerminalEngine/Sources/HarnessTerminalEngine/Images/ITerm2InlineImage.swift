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
        parse(payload[...])
    }

    /// Bytewise: the base64 body is the overwhelming bulk of the payload (megabytes for a real
    /// image) and goes straight into `Data(base64Encoded:)` — only the short `key=value` args
    /// segment is ever materialized as a String.
    public static func parse(_ payload: ArraySlice<UInt8>) -> ITerm2InlineImage? {
        let filePrefix: [UInt8] = Array("File=".utf8)
        guard payload.starts(with: filePrefix) else { return nil }
        // Split args (before the first ':') from the base64 image data (after it).
        guard let colon = payload.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        guard let argsPart = String(bytes: payload[(payload.startIndex + filePrefix.count) ..< colon],
                                    encoding: .utf8) else { return nil }
        guard let raw = Data(base64Encoded: Data(payload[(colon + 1)...]), options: [.ignoreUnknownCharacters]),
              let image = ImageDecoder.decode(raw) else { return nil }
        var keys: [String: String] = [:]
        for pair in argsPart.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { keys[String(kv[0])] = String(kv[1]) }
        }
        return ITerm2InlineImage(keys: keys, image: image)
    }
}
