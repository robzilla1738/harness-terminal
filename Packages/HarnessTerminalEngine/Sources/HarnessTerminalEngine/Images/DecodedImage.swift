import Foundation
import Synchronization

/// A decoded raster image (RGBA8, premultiplied not assumed) ready for placement + GPU upload.
/// The common output of every image protocol decoder (Sixel, Kitty graphics, iTerm2).
public struct DecodedImage: Sendable, Equatable, Codable {
    public var rgba: [UInt8]      // width*height*4, row-major, R,G,B,A
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(rgba: [UInt8], pixelWidth: Int, pixelHeight: Int) {
        self.rgba = rgba
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Decoded byte size (for per-pane memory budgeting).
    public var byteCount: Int { rgba.count }
}

/// Hard limits so hostile/oversized image output can't exhaust memory. Enforced before
/// allocation where possible (dimensions are validated before the pixel buffer is built).
public enum ImageLimits {
    /// Largest single image, in pixels (≈ 4K²). Decoders reject anything larger.
    public static let maxPixels = 4096 * 4096
    /// Per-screen budget for all decoded image bytes; oldest placements are evicted past it.
    public static let maxBytesPerScreen = 64 * 1024 * 1024

    /// Whether a width×height image is within the per-image pixel cap (overflow-safe).
    public static func withinPixelCap(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000 else { return false }
        return width * height <= maxPixels
    }
}

/// Image ids, unique across every emulator in the process. The renderer caches textures by id,
/// so two screens, or an emulator swapped in behind a pane, must never reuse one.
enum ImageIDs {
    private static let last = Atomic<Int>(0)

    static func next() -> Int {
        last.wrappingAdd(1, ordering: .relaxed).newValue
    }
}

// Encode pixel storage as binary data rather than millions of individually boxed integers.
extension DecodedImage {
    private enum CodingKeys: String, CodingKey { case rgba, pixelWidth, pixelHeight }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Data(rgba), forKey: .rgba)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Int.self, forKey: .pixelWidth)
        let height = try container.decode(Int.self, forKey: .pixelHeight)
        guard ImageLimits.withinPixelCap(width: width, height: height) else {
            throw TerminalCheckpointError.invalidState
        }
        let data = try container.decode(Data.self, forKey: .rgba)
        guard data.count == width * height * 4 else { throw TerminalCheckpointError.invalidState }
        self.init(rgba: Array(data), pixelWidth: width, pixelHeight: height)
    }
}
