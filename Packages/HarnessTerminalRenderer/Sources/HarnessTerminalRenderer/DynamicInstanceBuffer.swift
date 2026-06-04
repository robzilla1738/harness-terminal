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
    /// Per ring slot: the half-open instance-index span that still needs to be (re)written to that
    /// slot's buffer to make it match the current frame's array, or nil when the slot is already
    /// current. A content change in one frame is unioned into *every* slot's pending span, because
    /// each slot is written on its own frame (the GPU may still be reading slots written up to
    /// `ringSize` frames ago). When a slot is written, only its own pending span is copied and then
    /// cleared — so a one-row keystroke uploads ~one row's bytes, not the whole frame.
    private var slotPending: [Range<Int>?]

    init(device: MTLDevice, ringSize: Int, label: String) {
        self.device = device
        self.label = label
        self.buffers = Array(repeating: nil, count: ringSize)
        self.capacities = Array(repeating: 0, count: ringSize)
        self.slotPending = Array(repeating: nil, count: ringSize)
    }

    /// Copy only the bytes that changed into the ring `slot`'s buffer. `instances` is the *whole*
    /// current array (so the buffer can be re-seeded on a grow); `dirty` is the half-open instance span the
    /// caller changed this frame. The span is unioned into every slot's pending range, then this
    /// `slot`'s accumulated pending span (everything changed since this slot was last written) is
    /// copied and cleared. Returns the buffer to bind and the number of bytes actually written
    /// (0 when nothing was pending for this slot — the buffer already holds the right data).
    ///
    /// Correctness under the in-flight ring: each slot is written on a distinct frame, so a change
    /// must reach all of them; unioning into every slot guarantees a slot the GPU finished N frames
    /// ago still gets every span that changed meanwhile, leaving it byte-identical to the current
    /// array. A capacity grow allocates a fresh buffer for this slot, so it is re-seeded in full.
    func uploadIncremental<T>(_ instances: [T], dirty: Range<Int>, slot: Int) -> (buffer: MTLBuffer, bytesWritten: Int)? {
        let count = instances.count
        guard count > 0 else {
            // An empty stream binds no buffer and draws nothing, so there is nothing to upload.
            // Clear this slot's pending span: it indexes an array that no longer exists, and a
            // later non-empty frame re-dirties its own content (any row gaining instances is in
            // that frame's damage), so dropping it here loses no required write.
            slotPending[slot] = nil
            return nil
        }
        let stride = MemoryLayout<T>.stride
        let needed = count * stride

        var grew = false
        if buffers[slot] == nil || capacities[slot] < needed {
            let newCapacity = max(needed, capacities[slot] * 2)
            guard let grown = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                return nil
            }
            grown.label = "\(label)[\(slot)]"
            buffers[slot] = grown
            capacities[slot] = newCapacity
            grew = true
        }

        // A content change must reach every ring slot, since each is uploaded on its own frame.
        let lo = max(0, min(dirty.lowerBound, count))
        let hi = max(lo, min(dirty.upperBound, count))
        if lo < hi {
            let span = lo ..< hi
            for i in slotPending.indices {
                slotPending[i] = Self.union(slotPending[i], span)
            }
        }

        // A freshly grown buffer holds no prior bytes, so re-seed it fully; otherwise write exactly
        // what this slot is missing, clamped to the current array bounds.
        let effective: Range<Int>
        if grew {
            effective = 0 ..< count
        } else if let pending = slotPending[slot] {
            let plo = max(0, min(pending.lowerBound, count))
            let phi = max(plo, min(pending.upperBound, count))
            effective = plo ..< phi
        } else {
            effective = 0 ..< 0
        }

        guard let target = buffers[slot] else { return nil }
        if !effective.isEmpty {
            instances.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let offset = effective.lowerBound * stride
                _ = memcpy(target.contents().advanced(by: offset), base.advanced(by: offset), effective.count * stride)
            }
        }
        slotPending[slot] = nil
        return (target, effective.count * stride)
    }

    private static func union(_ existing: Range<Int>?, _ added: Range<Int>) -> Range<Int> {
        guard let existing else { return added }
        return min(existing.lowerBound, added.lowerBound) ..< max(existing.upperBound, added.upperBound)
    }
}
