import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Decodes standard image formats (PNG, JPEG, …) to RGBA8 via the system ImageIO/CoreGraphics
/// frameworks. Shared by the Kitty graphics protocol (format 100 = PNG) and iTerm2 inline images
/// (OSC 1337, any format). Returns nil on undecodable data or an over-cap size.
public enum ImageDecoder {
    public static func decode(_ data: Data) -> DecodedImage? {
        #if canImport(ImageIO)
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return rasterize(cgImage)
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    /// Draw a CGImage into a known RGBA8 (premultiplied-last, sRGB) buffer and read it back, so
    /// downstream code never has to reason about the source's color space or bitmap layout.
    static func rasterize(_ cgImage: CGImage) -> DecodedImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard ImageLimits.withinPixelCap(width: width, height: height) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpace(name: CGColorSpace.genericRGBLinear) else {
            return nil
        }
        let success: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        return DecodedImage(rgba: pixels, pixelWidth: width, pixelHeight: height)
    }
    #endif
}
