import Foundation

/// An immutable, copy-on-write view of retained rows. Search owns this snapshot off the
/// parser queue; subsequent parser writes cannot change its rows or cluster identifiers.
public struct TerminalTextSnapshot: Sendable {
    public let lineCount: Int
    public let historyCount: Int
    public let clusters: [UInt32: String]
    private let readLine: @Sendable (Int) -> [TerminalGridCell]
    private let wraps: @Sendable (Int) -> Bool

    init(lineCount: Int, historyCount: Int, clusters: [UInt32: String],
         line: @escaping @Sendable (Int) -> [TerminalGridCell],
         wraps: @escaping @Sendable (Int) -> Bool) {
        self.lineCount = lineCount
        self.historyCount = historyCount
        self.clusters = clusters
        self.readLine = line
        self.wraps = wraps
    }

    public func line(_ index: Int) -> [TerminalGridCell] { readLine(index) }
    public func isWrapped(_ index: Int) -> Bool { wraps(index) }

    /// One searchable soft-wrapped line, bounded independently of retained history size.
    public func logicalText(startingAt start: Int) -> (text: TerminalMappedText, nextLine: Int) {
        var mapped = TerminalMappedText(), index = start
        while index >= 0, index < lineCount {
            mapped.append(line(index), line: index, clusters: clusters)
            index += 1
            if !isWrapped(index - 1) || mapped.utf16Count >= 262_144 { break }
        }
        return (mapped, index)
    }

}

/// Shared UTF-16 → terminal-cell mapping. Wide tails contribute no text, while a wide
/// head's span still covers both columns. Normalization never changes the grid coordinates.
public struct TerminalMappedText: Sendable {
    public struct Span: Sendable {
        public var range: NSRange
        public let line: Int
        public let linear: Bool
        public var columns: Range<Int>
    }
    var units: [UInt16] = []
    public var text: String { String(decoding: units, as: UTF16.self) }
    public var utf16Count: Int { units.count }
    public private(set) var spans: [Span] = []

    public init() {}

    public mutating func append(_ cells: [TerminalGridCell], line: Int, clusters: [UInt32: String] = [:]) {
        var resolver = TerminalTextResolver()
        append(cells, line: line, clusters: clusters, resolver: &resolver)
    }

    mutating func append(_ cells: [TerminalGridCell], line: Int, clusters: [UInt32: String], resolver: inout TerminalTextResolver) {
        units.reserveCapacity(units.count + cells.count)
        var runColumn = 0, runOffset = units.count, runLength = 0
        for (column, cell) in cells.enumerated() where cell.width != .spacerTail {
            let offset = units.count
            let count: Int
            if cell.combining0 == 0, cell.codepoint < 128 {
                units.append(UInt16(cell.codepoint == 0 ? 32 : cell.codepoint))
                count = 1
            } else {
                let unit = resolver.unit(cell, clusters: clusters)
                count = unit.utf16.count
                units.append(contentsOf: unit.utf16)
            }
            let columns = column..<min(cells.count, column + (cell.width == .wide ? 2 : 1))
            let linear = count == 1 && cell.width == .normal
            if runLength > 0, !linear || runColumn + runLength != column {
                spans.append(Span(range: NSRange(location: runOffset, length: runLength), line: line,
                                  linear: true, columns: runColumn..<(runColumn + runLength)))
                runLength = 0
            }
            if linear {
                if runLength == 0 { runColumn = column; runOffset = offset }
                runLength += 1
            } else {
                spans.append(Span(range: NSRange(location: offset, length: count), line: line,
                                  linear: linear, columns: columns))
            }
        }
        if runLength > 0 {
            spans.append(Span(range: NSRange(location: runOffset, length: runLength), line: line,
                              linear: true, columns: runColumn..<(runColumn + runLength)))
        }
    }

    public func cells(for range: NSRange) -> [TerminalBufferSpan] {
        guard range.length > 0 else { return [] }
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(spans[mid].range) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        var result: [TerminalBufferSpan] = []
        for span in spans[lo...] {
            if span.range.location >= NSMaxRange(range) { break }
            var columns = span.columns
            if span.linear {
                let first = span.columns.lowerBound + max(0, range.location - span.range.location)
                let end = span.columns.lowerBound + min(span.range.length, NSMaxRange(range) - span.range.location)
                columns = first..<end
            }
            if let last = result.last, last.bufferLine == span.line {
                result[result.count - 1] = TerminalBufferSpan(bufferLine: span.line,
                    columns: last.columns.lowerBound..<columns.upperBound)
            } else { result.append(TerminalBufferSpan(bufferLine: span.line, columns: columns)) }
        }
        return result
    }

    public func offset(atColumn column: Int) -> Int {
        guard let span = spans.first(where: { $0.columns.contains(column) || $0.columns.lowerBound >= column }) else { return units.count }
        return span.range.location + (span.linear ? max(0, column - span.columns.lowerBound) : 0)
    }
}

/// A bounded search-local memo avoids repeatedly normalizing common CJK and drawing glyphs.
/// Marked cells still resolve against the snapshot's own cluster storage.
struct TerminalTextResolver {
    private var scalars: [UInt32: String] = [:]

    mutating func unit(_ cell: TerminalGridCell, clusters: [UInt32: String]) -> String {
        let simple = cell.combining0 == 0 && cell.combining1 == 0
        if simple, let cached = scalars[cell.codepoint] { return cached }
        let unit = cell.resolvedCluster(in: clusters).precomposedStringWithCanonicalMapping
        if simple, scalars.count < 4096 { scalars[cell.codepoint] = unit }
        return unit
    }
}
