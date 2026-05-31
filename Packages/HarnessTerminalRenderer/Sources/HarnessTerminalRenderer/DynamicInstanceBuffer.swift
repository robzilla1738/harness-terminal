import Foundation  // memcpy
import Metal

/// A small triple-buffered ring of CPU-writable Metal buffers for per-frame instance data.
///
/// **Why a ring?** The live-view `present(_:to:…)` path commits its command buffer without
/// waiting for the GPU, so the GPU may still be reading frame N's instance buffer while the
/// CPU is already building frame N+1. Reusing a single buffer would let the CPU overwrite
/// bytes the GPU is mid-read on, corrupting the in-flight frame. Cycling through `ringSize`
/// distinct buffers — paired with the renderer's in-flight semaphore, which caps frames in
/// flight at `ringSize` — guarantees the slot the CPU writes was last used `ringSize` frames
/// ago and is no longer referenced by the GPU.
///
/// Each slot's buffer is allocated lazily and grown on demand, then reused. In steady state
/// (a stable grid size) the hot render path performs only a `memcpy` — no Metal allocation.
final class DynamicInstanceBuffer {
    private let device: MTLDevice
    private let label: String
    /// One buffer per ring slot, allocated on first use and reused thereafter.
    private var buffers: [MTLBuffer?]
    /// Byte capacity of each slot's current buffer (0 until first allocation).
    private var capacities: [Int]

    init(device: MTLDevice, ringSize: Int, label: String) {
        self.device = device
        self.label = label
        self.buffers = Array(repeating: nil, count: ringSize)
        self.capacities = Array(repeating: 0, count: ringSize)
    }

    /// Copy `instances` into the ring `slot`'s buffer (growing it if needed) and return the
    /// buffer ready to bind. Returns `nil` for an empty array so callers skip the pass entirely
    /// — `makeBuffer(length:)` is undefined for length 0, and binding a zero-length buffer is
    /// pointless, so no buffer is created or bound (matching the renderer's prior behavior).
    func upload<T>(_ instances: [T], slot: Int) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        let needed = instances.count * MemoryLayout<T>.stride

        if buffers[slot] == nil || capacities[slot] < needed {
            // Grow with doubling headroom so a frame that adds a cell or two doesn't force a
            // reallocation every time. `.storageModeShared` matches the CPU-upload behavior the
            // renderer relied on with the old per-frame `makeBuffer(bytes:)`.
            let newCapacity = max(needed, capacities[slot] * 2)
            guard let grown = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                return nil
            }
            grown.label = "\(label)[\(slot)]"
            buffers[slot] = grown
            capacities[slot] = newCapacity
        }

        guard let target = buffers[slot] else { return nil }
        instances.withUnsafeBytes { raw in
            // `raw.baseAddress` is non-nil because the array is non-empty.
            memcpy(target.contents(), raw.baseAddress!, needed)
        }
        return target
    }
}
