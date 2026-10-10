import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RegexBatch: Codable, Sendable {
    public var pattern: String
    public var caseSensitive: Bool
    public var lines: [String]
    public init(pattern: String, caseSensitive: Bool, lines: [String]) { self.pattern = pattern; self.caseSensitive = caseSensitive; self.lines = lines }
}
struct RegexBatchResult: Codable { var matches: [Bool]?; var spans: [OutputSearchSpan?]?; var error: String? }

/// ICU backtracking is not cancellable in-process. Run it in a disposable worker
/// with bounded stdin/results and a parent-enforced deadline, outside all PTY locks.
public enum IsolatedRegex {
    static func matches(_ batch: RegexBatch, executable: URL, timeout: TimeInterval, cancelled: () -> Bool) throws -> [Bool] {
        try matchSpans(batch, executable: executable, timeout: timeout, cancelled: cancelled).map { $0 != nil }
    }
    static func matchSpans(_ batch: RegexBatch, executable: URL, timeout: TimeInterval, cancelled: () -> Bool) throws -> [OutputSearchSpan?] {
        let bytes = try JSONEncoder().encode(batch)
        guard bytes.count <= 4 << 20, batch.lines.count <= 128 else { throw RegexSearchError.budget }
        let result = try ProcessCapture.run(executable, arguments: ["--search-regex-worker"], stdin: bytes,
            timeout: min(timeout, 1), maxOutputBytes: 65536, cancelled: cancelled)
        guard result.status == 0, let value = try? JSONDecoder().decode(RegexBatchResult.self, from: result.stdout),
              let matches = value.matches, matches.count == batch.lines.count, let spans = value.spans, spans.count == matches.count else {
            throw RegexSearchError.pattern
        }
        for index in spans.indices {
            guard matches[index] == (spans[index] != nil) else { throw RegexSearchError.pattern }
            if let span = spans[index] {
                let count = batch.lines[index].utf16.count
                guard span.location >= 0, span.length >= 0, span.location <= count, span.length <= count - span.location else { throw RegexSearchError.pattern }
            }
        }
        return spans
    }
    public static func runWorker() -> Int32 {
        var input = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, poll(&descriptor, 1, Int32(min(remaining * 1000, 1000))) > 0 else { return 2 }
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0, input.count + count <= 4 << 20 else { return 2 }
            input.append(contentsOf: buffer.prefix(count))
        }
        let result: RegexBatchResult
        do {
            let request = try JSONDecoder().decode(RegexBatch.self, from: input)
            guard !request.pattern.isEmpty, request.pattern.count <= 256, request.lines.count <= 128,
                  request.lines.reduce(0, { $0 + $1.utf8.count }) <= 2 << 20 else { throw RegexSearchError.budget }
            let regex = try NSRegularExpression(pattern: request.pattern, options: request.caseSensitive ? [] : [.caseInsensitive])
            let spans = request.lines.map { line -> OutputSearchSpan? in
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) else { return nil }
                return OutputSearchSpan(location: match.range.location, length: match.range.length)
            }
            result = RegexBatchResult(matches: spans.map { $0 != nil }, spans: spans, error: nil)
        } catch { result = RegexBatchResult(matches: nil, spans: nil, error: "Invalid or over-budget regular expression request.") }
        guard let bytes = try? JSONEncoder().encode(result) else { return 2 }
        do { try FileHandle.standardOutput.write(contentsOf: bytes); return 0 } catch { return 2 }
    }
}
enum RegexSearchError: Error, LocalizedError {
    case pattern, budget
    var errorDescription: String? { self == .pattern ? "The regular expression is invalid or its isolated worker failed. No partial result is advertised as complete." : "Search reached its bounded input or time budget. Narrow the session or execution filters." }
}
