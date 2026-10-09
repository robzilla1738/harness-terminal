import Foundation
import Metal

/// GPU texture cache for inline images, keyed by the engine's monotonic image id (so pixels for
/// a given id never change — a cache hit is always valid). Mirrors `GlyphAtlas`'s upload pattern.
/// Every retransmit, Kitty frame edit, or compose mints a new id, so an id a pane stops drawing
/// is usually dead: `endFrame` frees textures left undrawn for `idleFrames` frames. A playing
/// Kitty animation holds them instead — each of its frames has its own id and comes round again,
/// so it uploads each frame once. Bounded by bytes and by entries too, least recently drawn
/// first. Lookups, uploads, and evictions are O(1); a sweep costs only what it frees.
final class ImageTextureCache {
    /// Frames a texture may go undrawn and stay: a frame or two without the images (copy mode,
    /// a scroll) doesn't upload them again.
    static let idleFrames = 3

    /// A texture and its place in the recency list threaded through `entries` by id.
    private struct Entry {
        let texture: MTLTexture
        var drawnInFrame: Int
        var older: Int?
        var newer: Int?

        var bytes: Int { texture.width * texture.height * 4 }
    }

    private let device: MTLDevice
    private let maxBytes: Int
    private let maxEntries: Int
    private var entries: [Int: Entry] = [:]
    private var oldest: Int? // least recently drawn
    private var newest: Int?
    private var bytes = 0
    private var frame = 0

    init(device: MTLDevice, maxBytes: Int, maxEntries: Int = 1024) {
        self.device = device
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
    }

    /// Texture for image `id`, uploading `pixels` (RGBA8, row-major top-to-bottom) on first sight.
    /// Marks it drawn this frame.
    func texture(id: Int, rgba: [UInt8], width: Int, height: Int) -> MTLTexture? {
        if let existing = entries[id] {
            unlink(id)
            link(id)
            entries[id]?.drawnInFrame = frame
            return existing.texture
        }
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 4)
        }
        let entry = Entry(texture: texture, drawnInFrame: frame)
        entries[id] = entry
        link(id)
        bytes += entry.bytes
        // Past a cap the least recently drawn go, keeping the newest even if it alone is larger.
        while bytes > maxBytes || entries.count > maxEntries, let oldest, oldest != id {
            remove(oldest)
        }
        return texture
    }

    /// Ends a frame: frees the textures undrawn for more than `idleFrames` frames, unless
    /// `animating` — a Kitty animation on screen is playing, and its other frames are due back.
    func endFrame(animating: Bool) {
        defer { frame += 1 }
        guard !animating else { return }
        while let oldest, let entry = entries[oldest], frame - entry.drawnInFrame > Self.idleFrames {
            remove(oldest)
        }
    }

    /// Textures held, for tests.
    var count: Int { entries.count }

    /// Links `id` in as the most recently drawn.
    private func link(_ id: Int) {
        entries[id]?.older = newest
        entries[id]?.newer = nil
        if let newest { entries[newest]?.newer = id } else { oldest = id }
        newest = id
    }

    private func unlink(_ id: Int) {
        guard let entry = entries[id] else { return }
        if let older = entry.older { entries[older]?.newer = entry.newer } else { oldest = entry.newer }
        if let newer = entry.newer { entries[newer]?.older = entry.older } else { newest = entry.older }
    }

    private func remove(_ id: Int) {
        unlink(id)
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.bytes }
    }
}
