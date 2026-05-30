import Foundation

/// Decodes a Sixel image (the payload of a `DCS … q … ST` sequence, introducer already stripped
/// by the parser) into RGBA8. Supports the common subset emitted by `img2sixel`, `chafa`, and
/// libsixel: raster attributes (`"`), RGB/HLS color definitions (`#`), repeat (`!`), carriage
/// return (`$`), line feed (`-`), and the sixel data bytes `?`–`~` (six vertical pixels each).
public enum SixelDecoder {
    public static func decode(_ payload: [UInt8]) -> DecodedImage? {
        // Skip the DCS parameters up to the `q` that begins the Sixel data.
        guard let q = payload.firstIndex(of: 0x71) else { return nil }
        let data = Array(payload[payload.index(after: q)...])

        // First pass: discover dimensions (honors `"` raster attrs; otherwise measures extent).
        guard let (width, height) = measure(data), width > 0, height > 0,
              ImageLimits.withinPixelCap(width: width, height: height)
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var palette = Self.defaultPalette
        var color = 0
        var x = 0
        var band = 0   // each band is 6 pixels tall, starting at y = band*6
        var i = 0
        let n = data.count

        func plot(_ sixelBits: Int) {
            let rgb = palette[color] ?? (0, 0, 0)
            for bit in 0 ..< 6 where (sixelBits & (1 << bit)) != 0 {
                let y = band * 6 + bit
                guard x < width, y < height else { continue }
                let o = (y * width + x) * 4
                rgba[o] = rgb.0; rgba[o + 1] = rgb.1; rgba[o + 2] = rgb.2; rgba[o + 3] = 255
            }
        }

        while i < n {
            let b = data[i]
            switch b {
            case 0x21: // '!' repeat: !Pn <sixel>
                i += 1
                let (count, next) = readInt(data, i)
                i = next
                if i < n, data[i] >= 0x3F, data[i] <= 0x7E {
                    let bits = Int(data[i]) - 0x3F
                    for _ in 0 ..< max(1, count) { plot(bits); x += 1 }
                    i += 1
                }
            case 0x23: // '#' color: #Pc  or  #Pc;Pu;Px;Py;Pz
                i += 1
                let (reg, after) = readInt(data, i)
                i = after
                if i < n, data[i] == 0x3B { // a definition follows
                    i += 1
                    let (space, a1) = readInt(data, i); i = a1
                    var comps: [Int] = []
                    while i < n, data[i] == 0x3B {
                        i += 1
                        let (v, a) = readInt(data, i); i = a
                        comps.append(v)
                    }
                    palette[reg] = colorFrom(space: space, comps: comps)
                }
                color = reg
            case 0x24: // '$' carriage return — back to x=0 in the same band
                x = 0; i += 1
            case 0x2D: // '-' line feed — next band
                band += 1; x = 0; i += 1
            case 0x3F ... 0x7E: // sixel data byte
                plot(Int(b) - 0x3F); x += 1; i += 1
            default:
                i += 1 // ignore unknown / whitespace
            }
        }
        return DecodedImage(rgba: rgba, pixelWidth: width, pixelHeight: height)
    }

    /// Measure the pixel extent. Uses `"Pan;Pad;Ph;Pv` raster attributes when present (the common
    /// case); otherwise walks the stream tracking the max column and band reached.
    private static func measure(_ data: [UInt8]) -> (Int, Int)? {
        var maxX = 0, x = 0, band = 0, i = 0
        let n = data.count
        while i < n {
            let b = data[i]
            switch b {
            case 0x22: // '"' raster attributes
                i += 1
                let (_, a1) = readInt(data, i); i = a1            // Pan
                i = skipSemiInt(data, i)                          // Pad
                let (ph, a3) = readSemiInt(data, i); i = a3       // Ph (width)
                let (pv, a4) = readSemiInt(data, i); i = a4       // Pv (height)
                if ph > 0, pv > 0 { return (ph, pv) }
            case 0x21: // '!' repeat
                i += 1
                let (count, next) = readInt(data, i); i = next
                if i < n, data[i] >= 0x3F, data[i] <= 0x7E { x += max(1, count); i += 1 }
            case 0x23: // '#' color — skip its numeric run
                i += 1
                i = skipNumericRun(data, i)
            case 0x24: maxX = max(maxX, x); x = 0; i += 1
            case 0x2D: maxX = max(maxX, x); x = 0; band += 1; i += 1
            case 0x3F ... 0x7E: x += 1; i += 1
            default: i += 1
            }
        }
        maxX = max(maxX, x)
        let height = (band + 1) * 6
        return maxX > 0 ? (maxX, height) : nil
    }

    // MARK: - Number parsing helpers

    private static func readInt(_ data: [UInt8], _ start: Int) -> (Int, Int) {
        var i = start, value = 0, any = false
        while i < data.count, data[i] >= 0x30, data[i] <= 0x39 {
            value = value * 10 + Int(data[i] - 0x30); i += 1; any = true
            if value > 1_000_000 { break }
        }
        return (any ? value : 0, i)
    }

    /// Read `;<int>` returning the int (0 if the separator/number is absent) and the new index.
    private static func readSemiInt(_ data: [UInt8], _ start: Int) -> (Int, Int) {
        guard start < data.count, data[start] == 0x3B else { return (0, start) }
        return readInt(data, start + 1)
    }

    private static func skipSemiInt(_ data: [UInt8], _ start: Int) -> Int {
        readSemiInt(data, start).1
    }

    private static func skipNumericRun(_ data: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < data.count, (data[i] >= 0x30 && data[i] <= 0x39) || data[i] == 0x3B { i += 1 }
        return i
    }

    /// Convert a color definition. Space 2 = RGB (each 0–100%); space 1 = HLS. Values clamp.
    private static func colorFrom(space: Int, comps: [Int]) -> (UInt8, UInt8, UInt8) {
        func pct(_ v: Int) -> UInt8 { UInt8(clamping: Int((Double(max(0, min(100, v))) / 100.0 * 255.0).rounded())) }
        if space == 1, comps.count >= 3 { // HLS (H 0–360, L 0–100, S 0–100)
            let (r, g, b) = hlsToRGB(h: comps[0], l: comps[1], s: comps[2])
            return (r, g, b)
        }
        guard comps.count >= 3 else { return (0, 0, 0) }
        return (pct(comps[0]), pct(comps[1]), pct(comps[2]))
    }

    private static func hlsToRGB(h: Int, l: Int, s: Int) -> (UInt8, UInt8, UInt8) {
        let hue = Double((h % 360 + 360) % 360) / 360.0
        let light = Double(max(0, min(100, l))) / 100.0
        let sat = Double(max(0, min(100, s))) / 100.0
        func hue2rgb(_ p: Double, _ qq: Double, _ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (qq - p) * 6 * t }
            if t < 1.0 / 2 { return qq }
            if t < 2.0 / 3 { return p + (qq - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if sat == 0 {
            let v = UInt8(clamping: Int((light * 255).rounded()))
            return (v, v, v)
        }
        let qq = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
        let p = 2 * light - qq
        func c(_ t: Double) -> UInt8 { UInt8(clamping: Int((hue2rgb(p, qq, t) * 255).rounded())) }
        return (c(hue + 1.0 / 3), c(hue), c(hue - 1.0 / 3))
    }

    /// VT340-style default 16-color palette (percent-based, converted to 8-bit).
    private static let defaultPalette: [Int: (UInt8, UInt8, UInt8)] = {
        let pct: [(Int, Int, Int)] = [
            (0, 0, 0), (20, 20, 80), (80, 13, 13), (20, 80, 20),
            (80, 20, 80), (20, 80, 80), (80, 80, 20), (53, 53, 53),
            (26, 26, 26), (33, 33, 60), (60, 26, 26), (33, 60, 33),
            (60, 33, 60), (33, 60, 60), (60, 60, 33), (80, 80, 80),
        ]
        var p: [Int: (UInt8, UInt8, UInt8)] = [:]
        for (i, c) in pct.enumerated() {
            func b(_ v: Int) -> UInt8 { UInt8(clamping: Int((Double(v) / 100.0 * 255).rounded())) }
            p[i] = (b(c.0), b(c.1), b(c.2))
        }
        return p
    }()
}
