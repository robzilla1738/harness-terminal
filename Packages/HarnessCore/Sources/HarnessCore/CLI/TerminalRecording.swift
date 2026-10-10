import Foundation

/// Terminal session recording — the stable, self-describing format behind
/// protected recording archives and legacy JSON Lines imports.
///
/// # Format (JSON Lines, version 1)
///
/// A recording is a UTF-8 text file with **one JSON object per line**. Each line
/// is independently valid JSON, so an interrupted writer can only ever truncate
/// the *last* line — every earlier line stays parseable, and a reader skips a
/// malformed trailing line. Lines are compact (no embedded newlines), keys are
/// sorted, and dates are ISO-8601 (matching `JSONOutputFormatter`).
///
/// The first line is always `metadata`; the rest are time-stamped events:
///
/// ```text
/// {"createdAt":"2026-05-31T18:00:00Z","surfaceID":"<uuid>","type":"metadata","version":1}
/// {"cols":80,"rows":24,"timeMs":0,"type":"resize"}
/// {"dataBase64":"<base64>","timeMs":12,"type":"output"}
/// {"dataBase64":"<base64>","timeMs":18,"type":"input"}
/// ```
///
/// - `type` discriminates the event.
/// - `metadata` anchors the timeline (it carries no `timeMs`); `version` is the
///   format version (currently `1`), `createdAt` is wall-clock ISO-8601.
/// - `timeMs` is milliseconds since recording start, measured on a **monotonic**
///   clock so the deltas between events are stable regardless of wall-clock jumps.
/// - `rows`/`cols` capture the terminal size at that moment.
/// - `dataBase64` is the raw byte payload, base64-encoded (binary-safe).
///
/// `input` events are part of the format and omitted by replay and export. The legacy v1
/// recorder was a passive observer of a shared surface and does not
/// synthesize input events for GUI/other-client keystrokes it cannot see.
public enum RecordingEvent: Equatable, Sendable {
    case metadata(version: Int, createdAt: Date, surfaceID: String)
    case resize(timeMs: Int, rows: UInt16, cols: UInt16)
    case output(timeMs: Int, data: Data)
    case input(timeMs: Int, data: Data)

    /// The event's position on the timeline, or `nil` for `metadata` (which
    /// anchors t=0 and carries no `timeMs`).
    public var timeMs: Int? {
        switch self {
        case .metadata: return nil
        case let .resize(timeMs, _, _): return timeMs
        case let .output(timeMs, _): return timeMs
        case let .input(timeMs, _): return timeMs
        }
    }
}

extension RecordingEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, version, createdAt, surfaceID, timeMs, rows, cols, dataBase64
    }

    private enum Kind: String {
        case metadata, resize, output, input
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .metadata(version, createdAt, surfaceID):
            try c.encode(Kind.metadata.rawValue, forKey: .type)
            try c.encode(version, forKey: .version)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(surfaceID, forKey: .surfaceID)
        case let .resize(timeMs, rows, cols):
            try c.encode(Kind.resize.rawValue, forKey: .type)
            try c.encode(timeMs, forKey: .timeMs)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
        case let .output(timeMs, data):
            try c.encode(Kind.output.rawValue, forKey: .type)
            try c.encode(timeMs, forKey: .timeMs)
            try c.encode(data.base64EncodedString(), forKey: .dataBase64)
        case let .input(timeMs, data):
            try c.encode(Kind.input.rawValue, forKey: .type)
            try c.encode(timeMs, forKey: .timeMs)
            try c.encode(data.base64EncodedString(), forKey: .dataBase64)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown event type \"\(rawType)\""
            )
        }
        switch kind {
        case .metadata:
            self = .metadata(
                version: try c.decode(Int.self, forKey: .version),
                createdAt: try c.decode(Date.self, forKey: .createdAt),
                surfaceID: try c.decode(String.self, forKey: .surfaceID)
            )
        case .resize:
            self = .resize(
                timeMs: try c.decode(Int.self, forKey: .timeMs),
                rows: try c.decode(UInt16.self, forKey: .rows),
                cols: try c.decode(UInt16.self, forKey: .cols)
            )
        case .output:
            self = .output(
                timeMs: try c.decode(Int.self, forKey: .timeMs),
                data: try RecordingEvent.decodeBase64(c, forKey: .dataBase64)
            )
        case .input:
            self = .input(
                timeMs: try c.decode(Int.self, forKey: .timeMs),
                data: try RecordingEvent.decodeBase64(c, forKey: .dataBase64)
            )
        }
    }

    private static func decodeBase64(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Data {
        let encoded = try c.decode(String.self, forKey: key)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c, debugDescription: "invalid base64 payload"
            )
        }
        return data
    }
}

/// Encodes/decodes ``RecordingEvent`` values as JSON Lines. One event ⇄ one line.
public enum TerminalRecordingCodec {
    /// The format version emitted by ``RecordingEvent/metadata(version:createdAt:surfaceID:)``.
    public static let formatVersion = 1

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Sorted keys → deterministic, diff-friendly lines. No `.prettyPrinted`
        // so each event stays on a single line.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode one event as a single-line JSON string (no trailing newline).
    public static func encodeLine(_ event: RecordingEvent) throws -> String {
        let data = try encoder.encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode one line into an event. Returns `nil` for a blank/whitespace line.
    public static func decodeLine(_ line: String) throws -> RecordingEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try decoder.decode(RecordingEvent.self, from: Data(trimmed.utf8))
    }

    /// Decode a whole recording. Blank lines are skipped; a malformed line
    /// (e.g. a truncated final write from an interrupted recorder) is skipped
    /// rather than failing the whole replay — the count is returned so callers
    /// can surface it.
    public static func decode(_ text: String) -> (events: [RecordingEvent], skipped: Int) {
        var events: [RecordingEvent] = []
        var skipped = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            do {
                if let event = try decodeLine(String(rawLine)) {
                    events.append(event)
                }
            } catch {
                skipped += 1
            }
        }
        return (events, skipped)
    }
}

/// A single playback action: wait `delayMs` (on a monotonic clock), then write
/// `data` to the terminal. Produced by ``TerminalReplay/steps(from:honorTiming:speed:)``.
public struct ReplayStep: Equatable, Sendable {
    /// Milliseconds to wait before writing, already scaled by playback speed
    /// (`0` when timing is disabled).
    public var delayMs: Int
    /// Output bytes to write to the terminal.
    public var data: Data

    public init(delayMs: Int, data: Data) {
        self.delayMs = delayMs
        self.data = data
    }
}

/// Turns a recording into an ordered list of ``ReplayStep`` writes. Pure and
/// deterministic — the runtime only has to sleep and write.
public enum TerminalReplay {
    /// Build the playback schedule.
    ///
    /// Events are walked in file order. Every time-stamped event advances a
    /// virtual clock by `max(0, timeMs - previous)`. Only `output` events emit a
    /// write; a `resize`/`input` event between two outputs still advances the
    /// clock, so its gap is folded into the next output's delay (faithful
    /// timing). `metadata` carries no time and is skipped.
    ///
    /// - Parameters:
    ///   - honorTiming: when `false`, every `delayMs` is `0` (instant playback).
    ///   - speed: playback multiplier (`2` = twice as fast). Values `<= 0` are
    ///     treated as instant to avoid division by zero / negative delays.
    public static func steps(
        from events: [RecordingEvent], honorTiming: Bool = true, speed: Double = 1.0
    ) -> [ReplayStep] {
        var steps: [ReplayStep] = []
        var lastTimeMs = 0
        var pendingDelayMs = 0
        let scaleTiming = honorTiming && speed > 0

        for event in events {
            guard let t = event.timeMs else { continue } // metadata anchors t=0
            let (delta, deltaOverflow) = t.subtractingReportingOverflow(lastTimeMs)
            let forward = t >= lastTimeMs ? (deltaOverflow ? Int.max : delta) : 0
            let (pending, pendingOverflow) = pendingDelayMs.addingReportingOverflow(forward)
            pendingDelayMs = pendingOverflow ? Int.max : pending
            lastTimeMs = t
            guard case let .output(_, data) = event else { continue }
            let delay = scaleTiming ? scaledDelayMs(pendingDelayMs, speed: speed) : 0
            steps.append(ReplayStep(delayMs: delay, data: data))
            pendingDelayMs = 0
        }
        return steps
    }

    /// Scale `ms` by playback `speed`, guarding the `Double → Int` conversion: a
    /// near-zero `speed` can make the quotient non-finite or exceed `Int.max`, and
    /// `Int(_:)` traps on either. Clamp to `Int.max` and floor at 0 so any caller-
    /// supplied speed is crash-safe (the CLI also rejects `speed <= 0`).
    private static func scaledDelayMs(_ ms: Int, speed: Double) -> Int {
        let scaled = (Double(ms) / speed).rounded()
        guard scaled.isFinite, scaled > 0 else { return 0 }
        return scaled >= Double(Int.max) ? Int.max : Int(scaled)
    }
}
