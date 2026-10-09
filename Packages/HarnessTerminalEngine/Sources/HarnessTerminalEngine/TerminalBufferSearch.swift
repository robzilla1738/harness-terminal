import Foundation

public struct TerminalBufferSpan: Equatable, Sendable {
    public let bufferLine: Int
    public let columns: Range<Int>
    public init(bufferLine: Int, columns: Range<Int>) { self.bufferLine = bufferLine; self.columns = columns }
}

/// One logical match can span several soft-wrapped physical rows.
public struct TerminalBufferMatch: Equatable, Sendable {
    public let spans: [TerminalBufferSpan]
    public var bufferLine: Int { spans.first?.bufferLine ?? 0 }
    public var columns: Range<Int> { spans.first?.columns ?? 0..<0 }
    public init(bufferLine: Int, columns: Range<Int>) {
        spans = [TerminalBufferSpan(bufferLine: bufferLine, columns: columns)]
    }
    public init(spans: [TerminalBufferSpan]) { self.spans = spans }
    public func shifted(by lines: Int) -> Self {
        Self(spans: spans.map { TerminalBufferSpan(bufferLine: $0.bufferLine + lines, columns: $0.columns) })
    }
}

public struct TerminalBufferSearchOptions: Equatable, Sendable {
    public var isRegex: Bool
    public var caseSensitive: Bool
    public init(isRegex: Bool = false, caseSensitive: Bool = false) {
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }
    public static let `default` = TerminalBufferSearchOptions()
}

public enum TerminalSearchOutcome: Equatable, Sendable {
    case matches([TerminalBufferMatch], limited: Bool)
    case invalidPattern(String)
    case cancelled
    case expired
}

/// Bounded matching on immutable text, outside parser and rendering queues.
public enum TerminalBufferSearch {
    public static func matches(query: String, lineCount: Int, line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        matches(query: query, options: .default, lineCount: lineCount, line: line)
    }

    public static func matches(query: String, options: TerminalBufferSearchOptions, lineCount: Int,
                               clusters: [UInt32: String] = [:],
                               line: (Int) -> [TerminalGridCell]) -> [TerminalBufferMatch] {
        if case let .matches(matches, _) = search(query: query, options: options, lineCount: lineCount,
                                                 clusters: clusters, line: line) { return matches }
        return []
    }

    public static func search(query: String, options: TerminalBufferSearchOptions = .default,
                              lineCount: Int, clusters: [UInt32: String] = [:],
                              isWrapped: (Int) -> Bool = { _ in false },
                              cancelled: @escaping () -> Bool = { false },
                              line: (Int) -> [TerminalGridCell]) -> TerminalSearchOutcome {
        guard !query.isEmpty, lineCount > 0 else { return .matches([], limited: false) }
        guard query.utf8.count <= 4096 else { return .invalidPattern("Search is limited to 4,096 bytes.") }
        var pattern = query.precomposedStringWithCanonicalMapping
        if !options.isRegex {
            // Match the terminal's SARA AM decomposition after a base, including long clusters.
            var normalized = ""
            for scalar in pattern.unicodeScalars {
                if scalar.value == 0x0E33, !normalized.isEmpty { normalized += "\u{0E4D}\u{0E32}" }
                else { normalized.unicodeScalars.append(scalar) }
            }
            pattern = normalized.precomposedStringWithCanonicalMapping
        }
        let regex: NSRegularExpression?
        do {
            regex = options.isRegex ? try NSRegularExpression(pattern: pattern,
                options: options.caseSensitive ? [] : [.caseInsensitive]) : nil
        } catch { return .invalidPattern(error.localizedDescription) }
        let asciiPattern = !options.isRegex && pattern.utf16.allSatisfy({ $0 < 128 })
            ? Array(pattern.utf16).map { foldASCII($0, caseSensitive: options.caseSensitive) } : []
        var skip = [Int](repeating: max(1, asciiPattern.count), count: 128)
        if asciiPattern.count > 1 {
            for index in 0..<(asciiPattern.count - 1) { skip[Int(asciiPattern[index])] = asciiPattern.count - index - 1 }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var matches: [TerminalBufferMatch] = []
        var mapped = TerminalMappedText()
        var resolver = TerminalTextResolver()
        var limited = false
        for index in 0..<lineCount {
            if cancelled() { return .cancelled }
            mapped.append(line(index), line: index, clusters: clusters, resolver: &resolver)
            if mapped.text.utf16.count > 262_144 { return .matches(matches, limited: true) }
            if isWrapped(index), index + 1 < lineCount { continue }
            let text = mapped.text as NSString
            let fullRange = NSRange(location: 0, length: text.length)
            if let regex {
                regex.enumerateMatches(in: mapped.text, options: [.reportProgress], range: fullRange) { result, _, stop in
                    if cancelled() || ProcessInfo.processInfo.systemUptime > deadline || matches.count >= 50_000 {
                        limited = true; stop.pointee = true; return
                    }
                    if let result, result.range.length > 0 {
                        matches.append(TerminalBufferMatch(spans: mapped.cells(for: result.range)))
                    }
                }
            } else {
                // Logs overwhelmingly contain ASCII with box/block drawing. Avoid Foundation's
                // per-line case-folding search there; Unicode letters keep the full Foundation
                // path (e.g. Kelvin sign and long s can match an ASCII needle).
                let units = asciiPattern.isEmpty ? [] : Array(mapped.text.utf16)
                if !asciiPattern.isEmpty, units.allSatisfy({ $0 < 128 || (0x2500...0x259F).contains($0) }) {
                    var offset = 0, iterations = 0
                    while offset + asciiPattern.count <= units.count {
                        if iterations & 63 == 0, cancelled() || ProcessInfo.processInfo.systemUptime > deadline {
                            limited = true; break
                        }
                        iterations += 1
                        var count = asciiPattern.count
                        while count > 0, foldASCII(units[offset + count - 1], caseSensitive: options.caseSensitive) == asciiPattern[count - 1] {
                            count -= 1
                        }
                        if count == 0 {
                            matches.append(TerminalBufferMatch(spans: mapped.cells(for: NSRange(location: offset, length: asciiPattern.count))))
                            if matches.count >= 50_000 { limited = true; break }
                            offset += asciiPattern.count
                        } else {
                            let last = foldASCII(units[offset + asciiPattern.count - 1], caseSensitive: options.caseSensitive)
                            offset += last < 128 ? skip[Int(last)] : asciiPattern.count
                        }
                    }
                } else {
                    var remaining = fullRange
                    while remaining.length > 0 {
                        let found = text.range(of: pattern, options: options.caseSensitive ? [] : [.caseInsensitive], range: remaining)
                        if found.location == NSNotFound { break }
                        matches.append(TerminalBufferMatch(spans: mapped.cells(for: found)))
                        if matches.count >= 50_000 { limited = true; break }
                        remaining = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
                    }
                }
            }
            if cancelled() { return .cancelled }
            if ProcessInfo.processInfo.systemUptime > deadline { limited = true }
            if limited { break }
            mapped = TerminalMappedText()
        }
        return .matches(matches, limited: limited)
    }

    private static func foldASCII(_ unit: UInt16, caseSensitive: Bool) -> UInt16 {
        !caseSensitive && unit >= 65 && unit <= 90 ? unit + 32 : unit
    }
}

public final class TerminalSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
