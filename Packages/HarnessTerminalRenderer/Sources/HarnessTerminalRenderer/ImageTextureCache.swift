import Foundation
import Metal

/// GPU texture cache for inline images, keyed by the engine's monotonic image id (so pixels for
/// a given id never change — a cache hit is always valid). Mirrors `GlyphAtlas`'s upload pattern.
/// Bounded by entry count; least-recently-used textures are evicted.
final class ImageTextureCache {
    private let device: MTLDevice
    private let maxEntries: Int
    private var textures: [Int: MTLTexture] = [:]
    private var lru: [Int] = [] // ids, most-recent last

    init(device: MTLDevice, maxEntries: Int = 64) {
        self.device = device
        self.maxEntries = maxEntries
    }

    /// Texture for image `id`, uploading `pixels` (RGBA8, row-major top-to-bottom) on first sight.
    func texture(id: Int, rgba: [UInt8], width: Int, height: Int) -> MTLTexture? {
        if let existing = textures[id] {
            touch(id)
            return existing
        }
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 4)
        }
        textures[id] = texture
        touch(id)
        evictIfNeeded()
        return texture
    }

    private func touch(_ id: Int) {
        if let i = lru.firstIndex(of: id) { lru.remove(at: i) }
        lru.append(id)
    }

    private func evictIfNeeded() {
        while textures.count > maxEntries, let oldest = lru.first {
            lru.removeFirst()
            textures.removeValue(forKey: oldest)
        }
    }
}
