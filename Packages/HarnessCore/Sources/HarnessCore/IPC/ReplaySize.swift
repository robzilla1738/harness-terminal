import Foundation

/// PTY geometry effective immediately before the byte at `sequence`.
public struct ReplaySize: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var cols: UInt16
    public var rows: UInt16

    public init(sequence: UInt64, cols: UInt16, rows: UInt16) {
        self.sequence = sequence
        self.cols = cols
        self.rows = rows
    }

    public var isValid: Bool {
        cols > 0 && rows > 0 && cols <= 4096 && rows <= 4096
            && Int(cols) * Int(rows) <= 1_048_576
    }

    public static func validated(_ sizes: [ReplaySize]) -> [ReplaySize] {
        guard sizes.allSatisfy(\.isValid),
              zip(sizes, sizes.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else { return [] }
        return sizes
    }

    /// Apply a byte slice with the sizes at which it was produced. Sizes at the end boundary
    /// apply too: a resize with no subsequent output still changes the restored screen.
    public static func replay(
        _ data: Data, sequence: UInt64, sizes: [ReplaySize],
        resize: (Int, Int) -> Void, feed: (Data) -> Void
    ) {
        var low = 0
        var high = sizes.count
        while low < high {
            let mid = low + (high - low) / 2
            if sizes[mid].sequence <= sequence { low = mid + 1 } else { high = mid }
        }
        if low > 0 {
            let size = sizes[low - 1]
            if size.isValid { resize(Int(size.cols), Int(size.rows)) }
        }
        var offset = 0
        for size in sizes[low...] {
            guard size.sequence >= sequence, size.sequence - sequence <= UInt64(data.count) else { break }
            let end = Int(size.sequence - sequence)
            if end > offset { feed(Data(data.dropFirst(offset).prefix(end - offset))) }
            if size.isValid { resize(Int(size.cols), Int(size.rows)) }
            offset = end
        }
        if offset < data.count { feed(Data(data.dropFirst(offset))) }
    }
}
