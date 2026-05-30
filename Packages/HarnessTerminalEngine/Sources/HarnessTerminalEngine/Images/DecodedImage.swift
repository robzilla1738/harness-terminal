import Foundation

/// A decoded raster image (RGBA8, premultiplied not assumed) ready for placement + GPU upload.
/// The common output of every image protocol decoder (Sixel, Kitty graphics, iTerm2).
public struct DecodedImage: Sendable, Equatable {
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
