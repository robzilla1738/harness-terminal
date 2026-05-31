import Foundation

/// A growable ring buffer (deque) for scrollback history. Newest entries are appended at the tail;
/// the oldest are dropped from the head. Dropping the oldest entries advances a head index instead
/// of shifting the survivors, so a long-running session that trims to a scrollback cap no longer
/// pays an O(retained-count) array shift per trim — it pays only O(dropped). Logical index 0 is
/// always the oldest retained element, matching the `[HistoryLine]` array it replaces, so every
/// reader (random access, iteration, `count`) is a drop-in.
///
/// Internal by design: it is an implementation detail of `TerminalScreen`'s scrollback, not part of
/// the engine's public surface.
struct HistoryRingBuffer<Element> {
    /// Backing storage sized to `capacity`. Slots outside `[head, head+count)` (mod capacity) are
    /// `nil` so dropped/empty entries don't retain references (e.g. a `HistoryLine`'s cell arrays).
    private var storage: ContiguousArray<Element?>
    /// Backing index of the oldest retained element (logical index 0). Meaningful only when
    /// `count > 0`; otherwise the buffer is treated as empty regardless of `head`.
    private var head: Int
    /// Number of retained elements.
    private(set) var count: Int

    init() {
        storage = []
        head = 0
        count = 0
    }

    /// Build from a sequence, oldest first. Used by reflow, which recomputes the whole history.
    init<S: Sequence>(_ elements: S) where S.Element == Element {
        var slots = ContiguousArray<Element?>()
        slots.reserveCapacity(elements.underestimatedCount)
        for element in elements { slots.append(element) }
        storage = slots
        head = 0
        count = slots.count
    }

    var isEmpty: Bool { count == 0 }

    /// Append a new newest element. O(1) amortized; grows the backing store (doubling) when full.
    mutating func append(_ element: Element) {
        if count == storage.count {
            growStorage(to: Swift.max(1, storage.count * 2))
        }
        storage[backingIndex(count)] = element
        count += 1
    }

    /// Random access by logical index (0 = oldest). The setter lets callers mutate an element in
    /// place (e.g. `buffer[i].field = x`), which a plain array's element subscript also allows.
    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "HistoryRingBuffer index out of range")
            return storage[backingIndex(index)]!
        }
        set {
            precondition(index >= 0 && index < count, "HistoryRingBuffer index out of range")
            storage[backingIndex(index)] = newValue
        }
    }

    /// Drop the oldest `n` entries (clamped to `count`). Advances `head` rather than shifting the
    /// survivors; the vacated slots are niled so their elements are released.
    mutating func removeFirst(_ n: Int = 1) {
        let drop = Swift.min(Swift.max(0, n), count)
        guard drop > 0 else { return }
        for i in 0 ..< drop { storage[backingIndex(i)] = nil }
        head = (head + drop) % storage.count
        count -= drop
    }

    mutating func removeAll() {
        storage = []
        head = 0
        count = 0
    }

    /// Map a logical index (0 = oldest) to its slot in `storage`. Only called when `count > 0` (or
    /// from `append` after ensuring capacity), so `storage.count > 0` holds.
    private func backingIndex(_ logical: Int) -> Int {
        (head + logical) % storage.count
    }

    /// Re-lay the retained elements out from index 0 into a larger backing store, then pad with nil.
    private mutating func growStorage(to newCapacity: Int) {
        var next = ContiguousArray<Element?>()
        next.reserveCapacity(newCapacity)
        for i in 0 ..< count { next.append(storage[backingIndex(i)]) }
        while next.count < newCapacity { next.append(nil) }
        storage = next
        head = 0
    }
}

extension HistoryRingBuffer: Sequence {
    func makeIterator() -> Iterator { Iterator(buffer: self) }

    struct Iterator: IteratorProtocol {
        private let buffer: HistoryRingBuffer
        private var index = 0
        init(buffer: HistoryRingBuffer) { self.buffer = buffer }
        mutating func next() -> Element? {
            guard index < buffer.count else { return nil }
            defer { index += 1 }
            return buffer[index]
        }
    }
}
