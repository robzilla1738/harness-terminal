import Foundation

/// Parses one Kitty graphics protocol command — the payload of an `APC G … ST` sequence (the
/// `G` is the first byte). Format: `key=value,key=value,…;<base64-payload>`. The emulator handles
/// chunk reassembly (`m=1`) and placement; this type only structures the control + payload.
public struct KittyGraphicsCommand: Equatable {
    public var keys: [String: String]
    public var payload: [UInt8]   // raw bytes after the `;` (still base64 unless empty)

    /// `a` — action: `t` transmit, `T` transmit+display, `p` put/display, `d` delete, `q` query,
    /// `f` an animation frame, `a` animation control, `c` compose frames.
    public var action: Character { keys["a"].flatMap(\.first) ?? "t" }
    /// `f` — format: 24 RGB, 32 RGBA, 100 PNG (default 32 per spec).
    public var format: Int { keys["f"].flatMap { Int($0) } ?? 32 }
    /// `m` — 1 if more chunks follow, 0/absent for the final chunk.
    public var moreChunks: Bool { keys["m"] == "1" }
    /// `i` — image id (for transmit-once / place-many + chunk reassembly).
    public var imageID: Int { keys["i"].flatMap { Int($0) } ?? 0 }
    /// `I` — image number, an alternative client-assigned handle echoed back in the ack.
    public var imageNumber: Int { keys["I"].flatMap { Int($0) } ?? 0 }
    /// `q` — quietness: 0 = report OK + errors, 1 = suppress OK (errors only), 2 = suppress both.
    public var quietness: Int { keys["q"].flatMap { Int($0) } ?? 0 }
    /// `d` — for `a=d`: which images to delete. `a`/`A` = all, `i`/`I` = by image id (`i=`).
    /// Defaults to `a` (delete all) per the Kitty spec when `a=d` carries no `d` key.
    public var deleteTarget: Character { keys["d"].flatMap(\.first) ?? "a" }
    /// `s` / `v` — pixel width/height for raw RGB/RGBA payloads.
    public var pixelWidth: Int { keys["s"].flatMap { Int($0) } ?? 0 }
    public var pixelHeight: Int { keys["v"].flatMap { Int($0) } ?? 0 }
    /// `c` / `r` — display size in cells (0 = derive from the image).
    public var cols: Int { keys["c"].flatMap { Int($0) } ?? 0 }
    public var rows: Int { keys["r"].flatMap { Int($0) } ?? 0 }
    /// `z` — z-index; negative draws below text, >=0 above the background. For `a=f` and `a=a`,
    /// a frame's gap in milliseconds instead.
    public var z: Int { keys["z"].flatMap { Int($0) } ?? 0 }
    /// `U=1` — a virtual placement shown through Unicode placeholder cells, not drawn here.
    public var unicodePlaceholder: Bool { keys["U"] == "1" }
    /// `t` — transmission medium: `d` direct (the payload), `f` a file, `t` a temp file to
    /// delete after reading, `s` shared memory. The payload names the file for `f`/`t`.
    public var medium: Character { keys["t"].flatMap(\.first) ?? "d" }
    /// `S` / `O` — bytes to read from a file, and where to start (0: the whole file).
    public var dataSize: Int { keys["S"].flatMap { Int($0) } ?? 0 }
    public var dataOffset: Int { keys["O"].flatMap { Int($0) } ?? 0 }
    /// `x` / `y` — for `a=d`: the cell (1-based) or column / row, or the id range for `d=r`. For
    /// `a=f` and `a=c`: the pixel where the new pixels land in the frame.
    public var x: Int { keys["x"].flatMap { Int($0) } ?? 0 }
    public var y: Int { keys["y"].flatMap { Int($0) } ?? 0 }

    // Animation (`a=f`, `a=a`, `a=c`). Frames are numbered from 1, the root frame.
    /// `r` — the frame to edit (`a=f`), retime (`a=a`), or compose from (`a=c`).
    public var frameNumber: Int { keys["r"].flatMap { Int($0) } ?? 0 }
    /// `c` — the base frame (`a=f`), the frame to show (`a=a`), or the one to compose onto (`a=c`).
    public var otherFrameNumber: Int { keys["c"].flatMap { Int($0) } ?? 0 }
    /// `X=1` (`a=f`) / `C=1` (`a=c`) — replace pixels instead of alpha blending them.
    public var overwrites: Bool { keys[action == "c" ? "C" : "X"] == "1" }
    /// `Y` — for `a=f`: the RGBA color a frame starts from when it has no base frame.
    public var backgroundColor: UInt32 { keys["Y"].flatMap { UInt32($0) } ?? 0 }
    /// `X` / `Y` / `w` / `h` — for `a=c`: the source rectangle's corner, and its size (0: to the
    /// image's edge).
    public var sourceX: Int { keys["X"].flatMap { Int($0) } ?? 0 }
    public var sourceY: Int { keys["Y"].flatMap { Int($0) } ?? 0 }
    public var width: Int { keys["w"].flatMap { Int($0) } ?? 0 }
    public var height: Int { keys["h"].flatMap { Int($0) } ?? 0 }
    /// `s` — for `a=a`: 1 stops, 2 plays and waits at the last frame for more, 3 plays and loops.
    public var animationState: Int { keys["s"].flatMap { Int($0) } ?? 0 }
    /// `v` — for `a=a`: 1 loops forever, n plays n − 1 loops, 0 leaves the count alone.
    public var loopCount: Int { keys["v"].flatMap { Int($0) } ?? 0 }

    public static func parse(_ apc: [UInt8]) -> KittyGraphicsCommand? {
        guard let first = apc.first, first == 0x47 else { return nil } // 'G'
        let body = Array(apc.dropFirst())
        // Split control (before ';') from payload (after the first ';').
        let control: [UInt8]
        let payload: [UInt8]
        if let semi = body.firstIndex(of: 0x3B) {
            control = Array(body[..<semi])
            payload = Array(body[body.index(after: semi)...])
        } else {
            control = body
            payload = []
        }
        guard let controlStr = String(bytes: control, encoding: .utf8) else { return nil }
        var keys: [String: String] = [:]
        for pair in controlStr.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { keys[String(kv[0])] = String(kv[1]) }
        }
        return KittyGraphicsCommand(keys: keys, payload: payload)
    }

    /// Decode the (already-reassembled) payload bytes into RGBA8 per the declared format.
    /// `base64Payload` is the concatenation of every chunk's payload.
    public func decode(base64Payload: [UInt8]) -> DecodedImage? {
        guard let raw = Data(base64Encoded: Data(base64Payload), options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return decode(raw: raw)
    }

    /// Image bytes in the declared format: PNG (or any ImageIO format), or raw RGB / RGBA.
    public func decode(raw: Data) -> DecodedImage? {
        switch format {
        case 100: // PNG (or any ImageIO format)
            return ImageDecoder.decode(raw)
        case 24, 32: // raw RGB / RGBA
            guard pixelWidth > 0, pixelHeight > 0,
                  ImageLimits.withinPixelCap(width: pixelWidth, height: pixelHeight) else { return nil }
            return Self.rasterPixels(raw, width: pixelWidth, height: pixelHeight, hasAlpha: format == 32)
        default:
            return nil
        }
    }

    private static func rasterPixels(_ raw: Data, width: Int, height: Int, hasAlpha: Bool) -> DecodedImage? {
        let stride = hasAlpha ? 4 : 3
        guard raw.count >= width * height * stride else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for p in 0 ..< (width * height) {
                let s = p * stride, d = p * 4
                rgba[d] = src[s]; rgba[d + 1] = src[s + 1]; rgba[d + 2] = src[s + 2]
                rgba[d + 3] = hasAlpha ? src[s + 3] : 255
            }
        }
        return DecodedImage(rgba: rgba, pixelWidth: width, pixelHeight: height)
    }
}
