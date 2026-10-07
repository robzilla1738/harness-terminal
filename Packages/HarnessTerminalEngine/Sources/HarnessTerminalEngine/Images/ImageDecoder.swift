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
        // ImageIO's first look at a multi-megabyte non-image loads plugins and scans the
        // buffer. A terminal feed must not pay that for ASCII that will never be a bitmap.
        guard looksLikeImage(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return rasterize(cgImage)
        #else
        return nil
        #endif
    }

    /// True when `data` starts with a container ImageIO actually decodes for inline images.
    /// The check is the header only: PNG, JPEG, GIF, BMP, TIFF, ICO, WebP, JPEG 2000, HEIF/AVIF.
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }
            guard data.count >= 4 else { return false }
            if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }
            if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return true }
            if b[0] == 0x42 && b[1] == 0x4D { return true }
            if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
                || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return true }
            if b[0] == 0 && b[1] == 0 && b[2] == 1 && b[3] == 0 { return true }
            guard data.count >= 12 else { return false }
            if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
                && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true }
            if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return true }
            if b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0x0C
                && b[4] == 0x6A && b[5] == 0x50 { return true }
            return false
        }
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
