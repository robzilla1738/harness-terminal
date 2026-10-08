import Foundation
import HarnessTerminalEngine
import Metal

/// GPU texture cache for inline images, keyed by the engine's monotonic image id (so pixels for
/// a given id never change — a cache hit is always valid). Mirrors `GlyphAtlas`'s upload pattern.
/// Each Kitty animation frame has its own id, so a playing animation uploads each frame once.
/// Bounded by bytes — a screen's image budget twice over, room for its images and an animation's
/// frames together; least-recently-used textures are evicted.
final class ImageTextureCache {
    private let device: MTLDevice
    private let maxBytes: Int
    private var textures: [Int: MTLTexture] = [:]
    private var lru: [Int] = [] // ids, most-recent last
    private var bytes = 0

    init(device: MTLDevice, maxBytes: Int = 2 * ImageLimits.maxBytesPerScreen) {
        self.device = device
        self.maxBytes = maxBytes
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
        bytes += width * height * 4
        touch(id)
        evictIfNeeded()
        return texture
    }

    private func touch(_ id: Int) {
        if let i = lru.firstIndex(of: id) { lru.remove(at: i) }
        lru.append(id)
    }

    /// Drops the least-recently-used textures past the budget, keeping the newest even if it
    /// alone is larger.
    private func evictIfNeeded() {
        while bytes > maxBytes, lru.count > 1 {
            if let texture = textures.removeValue(forKey: lru.removeFirst()) {
                bytes -= texture.width * texture.height * 4
            }
        }
    }
}
