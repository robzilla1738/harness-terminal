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
        guard let text = String(bytes: payload, encoding: .utf8), text.hasPrefix("File=") else { return nil }
        // Split args (before the first ':') from the base64 image data (after it).
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let argsPart = text[text.index(text.startIndex, offsetBy: 5) ..< colon] // after "File="
        let base64 = String(text[text.index(after: colon)...])
        guard let raw = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              let image = ImageDecoder.decode(raw) else { return nil }
        var keys: [String: String] = [:]
        for pair in argsPart.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { keys[String(kv[0])] = String(kv[1]) }
        }
        return ITerm2InlineImage(keys: keys, image: image)
    }
}
