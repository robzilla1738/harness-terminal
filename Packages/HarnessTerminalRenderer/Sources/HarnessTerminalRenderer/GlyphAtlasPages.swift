import Metal
import simd

/// Shelf packing and bounded LRU storage, shared by the coverage and color atlases.
final class GlyphAtlasPages {
    private(set) var texture: MTLTexture
    private(set) var pagesUsed = 1
    let size: Int
    let isColor: Bool
    private let device: MTLDevice
    private let maxPages: Int
    private var pageIndex = 0
    private var penX = 0
    private var penY = 0
    private var shelfHeight = 0
    private var useTick: UInt64 = 0
    private var pageLastUse: [UInt64]
    private var bytesPerPixel: Int { isColor ? 4 : 1 }

    init?(device: MTLDevice, size: Int, maxPages: Int, isColor: Bool) {
        guard let texture = Self.makeTexture(device: device, size: size, pages: 1, isColor: isColor) else { return nil }
        self.device = device
        self.size = size
        self.maxPages = max(1, maxPages)
        self.isColor = isColor
        self.texture = texture
        self.pageLastUse = Array(repeating: 0, count: max(1, maxPages))
    }

    @inline(__always)
    func touch(_ page: Int) {
        // One populated page has no eviction choice; avoid clock/array writes on ASCII hits.
        guard pagesUsed > 1 else { return }
        useTick &+= 1
        pageLastUse[page] = useTick
    }

    func reset() {
        pageIndex = 0
        pagesUsed = 1
        penX = 0
        penY = 0
        shelfHeight = 0
        pageLastUse = Array(repeating: 0, count: maxPages)
        touch(0)
    }

    /// The caller removes cached UVs from an evicted page before returning the new entry.
    func pack(_ glyph: RasterizedGlyph) -> (entry: AtlasEntry, evicted: Int?)? {
        guard glyph.width > 0, glyph.height > 0, glyph.width <= size, glyph.height <= size else { return nil }
        var evicted: Int?
        if penX + glyph.width > size {
            penX = 0
            penY += shelfHeight + 1
            shelfHeight = 0
        }
        if penY + glyph.height > size {
            if pagesUsed < maxPages, pagesUsed < texture.arrayLength || grow() {
                // Advance only into a never-used page. An evicted page may precede live pages.
                pageIndex = pagesUsed
                pagesUsed += 1
            } else {
                pageIndex = (0..<pagesUsed).min { pageLastUse[$0] < pageLastUse[$1] } ?? 0
                evicted = pageIndex
            }
            penX = 0
            penY = 0
            shelfHeight = 0
        }
        let pixels = glyph.rgba ?? glyph.coverage
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(penX, penY, glyph.width, glyph.height), mipmapLevel: 0,
                            slice: pageIndex, withBytes: raw.baseAddress!,
                            bytesPerRow: glyph.width * bytesPerPixel,
                            bytesPerImage: glyph.width * glyph.height * bytesPerPixel)
        }
        let entry = AtlasEntry(encodedPageIndex: UInt32(pageIndex) | (isColor ? 0x8000_0000 : 0),
            uvOrigin: SIMD2(Float(penX) / Float(size), Float(penY) / Float(size)),
            uvSize: SIMD2(Float(glyph.width) / Float(size), Float(glyph.height) / Float(size)),
            pixelWidth: glyph.width, pixelHeight: glyph.height,
            bearingX: glyph.bearingX, bearingY: glyph.bearingY)
        penX += glyph.width + 1
        shelfHeight = max(shelfHeight, glyph.height)
        touch(pageIndex)
        return (entry, evicted)
    }

    private func grow() -> Bool {
        let count = min(maxPages, texture.arrayLength * 2)
        guard count > texture.arrayLength,
              let grown = Self.makeTexture(device: device, size: size, pages: count, isColor: isColor) else { return false }
        let region = MTLRegionMake2D(0, 0, size, size)
        let rowBytes = size * bytesPerPixel
        let imageBytes = rowBytes * size
        var bytes = [UInt8](repeating: 0, count: imageBytes)
        for slice in 0..<texture.arrayLength {
            bytes.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: imageBytes,
                                 from: region, mipmapLevel: 0, slice: slice)
                grown.replace(region: region, mipmapLevel: 0, slice: slice, withBytes: raw.baseAddress!,
                              bytesPerRow: rowBytes, bytesPerImage: imageBytes)
            }
        }
        texture = grown
        return true
    }

    private static func makeTexture(device: MTLDevice, size: Int, pages: Int, isColor: Bool) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: isColor ? .rgba8Unorm : .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = pages
        descriptor.usage = [.shaderRead]
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        return device.makeTexture(descriptor: descriptor)
    }
}
