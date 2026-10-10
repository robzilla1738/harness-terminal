import Foundation

public struct RecordingRedaction: Sendable, Identifiable {
    public var id: Int
    public var reason: String
    public var byteRange: Range<Int>
    public var timeMs: Int
    public var context: String
}
public struct RecordingExportReview: Sendable {
    public var candidates: [RecordingRedaction]
    public var warnings: [String]
    public var outputBytes: Int
    public var protection: String
    fileprivate var chunks: [ExportChunk]
    fileprivate var bytes: Data
    fileprivate var document: RecordingDocument
}
fileprivate struct ExportChunk: Sendable { var eventIndex: Int; var range: Range<Int> }

/// This produces a reviewed local artifact, never publishes it. Masking is
/// heuristic and exact literal additions are bounded; arbitrary regex is not run.
public enum AsciicastExport {
    public static let maximumOutputBytes = 16 << 20
    public static func review(_ document: RecordingDocument, cancelled: @escaping () -> Bool = { false }) throws -> RecordingExportReview {
        try RecordingArchive.validate(document.events)
        guard document.skippedLines == 0 else { throw RecordingArchiveError.invalid }
        var sanitizer = SharedTerminalSanitizer(), bytes = Data(), pending = Data(), chunks: [ExportChunk] = [], invalidUTF8 = false
        for (index, event) in document.events.enumerated() {
            if cancelled() { throw CancellationError() }
            guard case let .output(_, data) = event else { continue }
            pending.append(sanitizer.consume(data))
            let prefix = utf8Prefix(pending)
            let complete = Data(pending.prefix(prefix))
            if String(data: complete, encoding: .utf8) == nil { invalidUTF8 = true }
            let clean = Data(String(decoding: complete, as: UTF8.self).utf8), start = bytes.count
            pending = Data(pending.dropFirst(prefix))
            guard clean.count <= maximumOutputBytes - bytes.count else { throw RecordingArchiveError.capacity }
            bytes.append(clean); chunks.append(ExportChunk(eventIndex: index, range: start..<bytes.count))
        }
        if !pending.isEmpty {
            invalidUTF8 = true; let tail = Data(String(decoding: pending, as: UTF8.self).utf8)
            guard tail.count <= maximumOutputBytes - bytes.count else { throw RecordingArchiveError.capacity }
            bytes.append(tail)
            if let last = chunks.indices.last { chunks[last].range = chunks[last].range.lowerBound..<bytes.count }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let patterns: [(String, String)] = [
            ("Provider or service key", #"(?:sk-(?:proj-|ant-|or-v1-)?[A-Za-z0-9_-]{16,256}|gh[pousr]_[A-Za-z0-9]{20,256}|AIza[A-Za-z0-9_-]{20,128}|AKIA[0-9A-Z]{16})"#),
            ("Named credential assignment", #"(?i)(?:api[_-]?key|password|passwd|secret|token)[ \t]{0,32}[:=][ \t]{0,32}[\"']?[^\s\"'\x1b]{4,256}"#),
            ("Private key block", #"-----BEGIN (?:[A-Z ]{0,24})PRIVATE KEY-----[\s\S]{1,65536}?-----END (?:[A-Z ]{0,24})PRIVATE KEY-----"#)
        ]
        var candidates: [RecordingRedaction] = []
        for (reason, pattern) in patterns {
            if cancelled() { throw CancellationError() }
            let regex = try NSRegularExpression(pattern: pattern)
            regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
                guard candidates.count < 1024, !cancelled() else { stop.pointee = true; return }
                guard let match, let range = Range(match.range, in: text) else { return }
                let start = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8)!), end = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound.samePosition(in: text.utf8)!)
                let chunk = chunks.first { $0.range.upperBound > start }
                let time = chunk.flatMap { document.events[$0.eventIndex].timeMs } ?? 0
                let context = String(decoding: bytes[max(0, start - 48)..<start], as: UTF8.self) + "[candidate masked]" + String(decoding: bytes[end..<min(bytes.count, end + 48)], as: UTF8.self)
                candidates.append(RecordingRedaction(id: candidates.count, reason: reason, byteRange: start..<end, timeMs: time, context: context))
            }
        }
        var warnings = ["Masking is heuristic. Review the complete output and add literal redactions before sharing. Terminal cursor edits, formatting and unusual credential formats can conceal secrets.", "Input is omitted. OSC, DCS, APC, PM, SOS, terminal queries and window-control payloads are removed."]
        if document.legacyGeometry { warnings.append("Legacy dimensions may describe the recorder’s local terminal and may omit remote PTY resizes. Export preserves the recorded values without inventing missing sizes.") }
        if document.interrupted { warnings.append("The source is unfinished or truncated. Only completed frames are included; Linux and legacy plaintext have no cryptographic authenticity.") }
        if sanitizer.dropped { warnings.append("Control payloads were removed from the shared output.") }
        if sanitizer.unfinished { warnings.append("An incomplete terminal control sequence was dropped at the end.") }
        if invalidUTF8 { warnings.append("Invalid UTF-8 bytes are shown as replacement characters in the export.") }
        if candidates.count == 1024 { warnings.append("The candidate display limit was reached. Review all output manually.") }
        if cancelled() { throw CancellationError() }
        return RecordingExportReview(candidates: candidates, warnings: warnings, outputBytes: bytes.count, protection: document.protection, chunks: chunks, bytes: bytes, document: document)
    }
    public static func render(_ review: RecordingExportReview, masking ids: Set<Int>? = nil, additionalLiterals: [String] = [], cancelled: () -> Bool = { false }) throws -> Data {
        guard additionalLiterals.count <= 64, additionalLiterals.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw RecordingArchiveError.capacity }
        let selected = ids ?? Set(review.candidates.map(\.id))
        var ranges = review.candidates.filter { selected.contains($0.id) }.map(\.byteRange)
        for literal in additionalLiterals {
            let needle = Data(literal.utf8); var offset = 0
            while offset < review.bytes.count, let match = review.bytes.range(of: needle, in: offset..<review.bytes.count) {
                guard ranges.count < 4096 else { throw RecordingArchiveError.capacity }; ranges.append(match); offset = match.upperBound
            }
        }
        var masked = review.bytes
        for range in ranges {
            if cancelled() { throw CancellationError() }
            masked.replaceSubrange(range, with: repeatElement(UInt8(ascii: "*"), count: range.count))
        }
        guard let initial = review.document.events.compactMap({ event -> ReplaySize? in if case let .resize(_, rows, cols) = event { return ReplaySize(sequence: 0, cols: cols, rows: rows) }; return nil }).first else { throw RecordingArchiveError.invalid }
        let header: [String: Any] = ["version": 2, "width": Int(initial.cols), "height": Int(initial.rows)]
        var result = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]); result.append(10)
        var chunks = Dictionary(uniqueKeysWithValues: review.chunks.map { ($0.eventIndex, $0.range) }), pending = Data()
        for (index, event) in review.document.events.enumerated() {
            if cancelled() { throw CancellationError() }
            switch event {
            case let .resize(time, rows, cols): try append([Double(time) / 1000, "r", "\(cols)x\(rows)"], to: &result)
            case let .output(time, _):
                if let range = chunks.removeValue(forKey: index) { pending.append(masked[range]) }
                let count = utf8Prefix(pending)
                if count > 0 { let text = String(decoding: pending.prefix(count), as: UTF8.self); pending = Data(pending.dropFirst(count)); if !text.isEmpty { try append([Double(time) / 1000, "o", text], to: &result) } }
            case .input, .metadata: break
            }
        }
        if !pending.isEmpty { try append([Double(review.document.events.last?.timeMs ?? 0) / 1000, "o", String(decoding: pending, as: UTF8.self)], to: &result) }
        return result
    }
    public static func save(_ data: Data, to url: URL, replacing expected: Data? = nil) throws {
        guard data.count <= 32 << 20 else { throw RecordingArchiveError.capacity }
        _ = try PrivateFile.replace(url, data: data, expected: expected, backup: false, maximumBytes: 32 << 20)
    }

    private static func append(_ event: [Any], to result: inout Data) throws {
        let row = try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes])
        guard row.count < (32 << 20) - result.count else { throw RecordingArchiveError.capacity }; result.append(row); result.append(10)
    }
    private static func utf8Prefix(_ bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var start = bytes.count - 1
        while start > 0 && bytes[start] & 0xC0 == 0x80 && bytes.count - start < 4 { start -= 1 }
        let lead = bytes[start], expected = lead < 0x80 ? 1 : lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 1
        return bytes.count - start < expected ? start : bytes.count
    }
}

/// Incremental control filtering spans output chunks without retaining payloads.
private struct SharedTerminalSanitizer {
    private enum State { case ground, escape, csi, string, stringEscape, charset }
    private var state: State = .ground, control = Data(), utf8Remaining = 0
    private(set) var dropped = false
    var unfinished: Bool { state != .ground }
    mutating func consume(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            switch state {
            case .ground:
                if utf8Remaining > 0 && byte & 0xC0 == 0x80 { utf8Remaining -= 1; output.append(byte); continue }
                utf8Remaining = continuationCount(byte)
                if byte == 0x1B { state = .escape; control = Data([byte]) }
                else if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(byte) { state = .string; dropped = true }
                else if byte == 0x9B { state = .csi; control = Data([0x1B, 0x5B]) }
                else if byte >= 0x20 || [0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(byte) { output.append(byte) }
                else { dropped = true }
            case .escape:
                control.append(byte)
                if byte == 0x5B { state = .csi }
                else if [0x5D, 0x50, 0x5F, 0x5E, 0x58].contains(byte) { state = .string; control.removeAll(); utf8Remaining = 0; dropped = true }
                else if [0x28, 0x29, 0x2A, 0x2B, 0x25].contains(byte) { state = .charset }
                else { if Array("78DEHM=>c".utf8).contains(byte) { output.append(control) } else { dropped = true }; control.removeAll(); state = .ground }
            case .charset:
                if (0x30...0x7E).contains(byte) { control.append(byte); output.append(control) } else { dropped = true }
                control.removeAll(); state = .ground
            case .csi:
                guard control.count < 128 else { control.removeAll(); state = .ground; dropped = true; continue }
                control.append(byte)
                if (0x40...0x7E).contains(byte) {
                    if Array("@ABCDEFGH IJKLMPSTXYZabcdefghlmqrsu".utf8).contains(byte) { output.append(control) } else { dropped = true }
                    control.removeAll(); state = .ground
                } else if !(0x20...0x3F).contains(byte) { control.removeAll(); state = .ground; dropped = true }
            case .string:
                if byte == 0x1B { state = .stringEscape }
                else if byte == 0x07 { state = .ground; utf8Remaining = 0 }
                else if utf8Remaining > 0 && byte & 0xC0 == 0x80 { utf8Remaining -= 1 }
                else if byte == 0x9C { state = .ground; utf8Remaining = 0 }
                else { utf8Remaining = continuationCount(byte) }
            case .stringEscape:
                if byte == 0x5C { state = .ground; utf8Remaining = 0 }
                else if byte != 0x1B { state = .string; utf8Remaining = continuationCount(byte) }
            }
        }
        return output
    }
    private func continuationCount(_ byte: UInt8) -> Int { byte >= 0xC2 && byte <= 0xDF ? 1 : byte >= 0xE0 && byte <= 0xEF ? 2 : byte >= 0xF0 && byte <= 0xF4 ? 3 : 0 }
}
