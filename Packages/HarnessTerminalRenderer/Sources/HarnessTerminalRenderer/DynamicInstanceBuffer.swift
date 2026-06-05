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
    /// Per-slot pending spans are kept as a small coalesced list so scattered damage (e.g. a
    /// status row + the cursor row) uploads two row-sized spans instead of everything between
    /// them. Beyond this cap the list collapses to its bounding range — bounded memory, and the
    /// degradation reproduces the previous single-union behavior exactly.
    static let maxPendingSpans = 8

    private let device: MTLDevice
    private let label: String
    /// One buffer per ring slot, allocated on first use and reused thereafter.
    private var buffers: [MTLBuffer?]
    /// Byte capacity of each slot's current buffer (0 until first allocation).
    private var capacities: [Int]
    /// Per ring slot: the coalesced, ordered instance-index spans that still need to be
    /// (re)written to that slot's buffer to make it match the current frame's array; empty when
    /// the slot is already current. A content change in one frame is unioned into *every* slot's
    /// pending list, because each slot is written on its own frame (the GPU may still be reading
    /// slots written up to `ringSize` frames ago). When a slot is written, only its own pending
    /// spans are copied and then cleared — so two distant dirty rows upload ~two rows' bytes,
    /// not the whole region between them.
    private var slotPending: [[Range<Int>]]

    init(device: MTLDevice, ringSize: Int, label: String) {
        self.device = device
        self.label = label
        self.buffers = Array(repeating: nil, count: ringSize)
        self.capacities = Array(repeating: 0, count: ringSize)
        self.slotPending = Array(repeating: [], count: ringSize)
    }

    /// Copy only the bytes that changed into the ring `slot`'s buffer. `instances` is the *whole*
    /// current array (so the buffer can be re-seeded on a grow); `dirty` is the list of half-open
    /// instance spans the caller changed this frame (`nil` = the whole array changed — scroll,
    /// full damage, cache bypass). The spans are unioned into every slot's pending list, then
    /// this `slot`'s accumulated pending spans (everything changed since it was last written) are
    /// copied and cleared. Returns the buffer to bind and the number of bytes actually written
    /// (0 when nothing was pending for this slot — the buffer already holds the right data).
    ///
    /// Correctness under the in-flight ring: each slot is written on a distinct frame, so a change
    /// must reach all of them; unioning into every slot guarantees a slot the GPU finished N frames
    /// ago still gets every span that changed meanwhile, leaving it byte-identical to the current
    /// array. A capacity grow allocates a fresh buffer for this slot, so it is re-seeded in full.
    func uploadIncremental<T>(_ instances: [T], dirty: [Range<Int>]?, slot: Int) -> (buffer: MTLBuffer, bytesWritten: Int)? {
        let count = instances.count
        guard count > 0 else {
            // An empty stream binds no buffer and draws nothing, so there is nothing to upload.
            // Clear this slot's pending spans: they index an array that no longer exists, and a
            // later non-empty frame re-dirties its own content (any row gaining instances is in
            // that frame's damage), so dropping them here loses no required write.
            slotPending[slot] = []
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
        let added = (dirty ?? [0 ..< count]).compactMap { span -> Range<Int>? in
            let lo = max(0, min(span.lowerBound, count))
            let hi = max(lo, min(span.upperBound, count))
            return lo < hi ? lo ..< hi : nil
        }
        if !added.isEmpty {
            for i in slotPending.indices {
                slotPending[i] = Self.merge(slotPending[i], adding: added)
            }
        }

        // A freshly grown buffer holds no prior bytes, so re-seed it fully; otherwise write
        // exactly the spans this slot is missing, clamped to the current array bounds.
        let effective: [Range<Int>]
        if grew {
            effective = [0 ..< count]
        } else {
            effective = slotPending[slot].compactMap { span -> Range<Int>? in
                let lo = max(0, min(span.lowerBound, count))
                let hi = max(lo, min(span.upperBound, count))
                return lo < hi ? lo ..< hi : nil
            }
        }

        guard let target = buffers[slot] else { return nil }
        var written = 0
        if !effective.isEmpty {
            instances.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for span in effective {
                    let offset = span.lowerBound * stride
                    let bytes = span.count * stride
                    _ = memcpy(target.contents().advanced(by: offset), base.advanced(by: offset), bytes)
                    written += bytes
                }
            }
        }
        slotPending[slot] = []
        return (target, written)
    }

    /// Union `added` (already clamped, individually non-empty) into an ordered, coalesced span
    /// list. Adjacent/overlapping spans merge; past `maxPendingSpans` the list collapses to its
    /// bounding range (the pre-span-list behavior), keeping memory bounded.
    static func merge(_ existing: [Range<Int>], adding added: [Range<Int>]) -> [Range<Int>] {
        var all = existing
        all.append(contentsOf: added)
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        merged.reserveCapacity(min(all.count, maxPendingSpans + 1))
        for span in all {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                if span.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound ..< span.upperBound
                }
            } else {
                merged.append(span)
            }
        }
        if merged.count > maxPendingSpans, let first = merged.first, let last = merged.last {
            return [first.lowerBound ..< last.upperBound]
        }
        return merged
    }
}
