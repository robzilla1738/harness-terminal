import Foundation

/// OSC 7501 rev 0.2 (Program Status Protocol).
/// https://www.superlogical.com/rex/docs/build/program-status
public enum ProgramStatusRevision {
    public static let revision = "0.2"
    public static let specURL = "https://www.superlogical.com/rex/docs/build/program-status"
    /// Terminfo source spelling of the extended string capability.
    public static let terminfoSource = "Pst=\\E]7501;%p1%s\\E\\\\"
    /// Capability value a program receives from XTGETTCAP (`Pst`).
    public static let terminfoValue = "\u{1b}]7501;%p1%s\u{1b}\\"
    public static let queryReply = "\u{1b}]7501;?\u{1b}\\"
    public static let maxSequenceBytes = 4096
    public static let maxRecords = 256
}

public enum ProgramStatusState: String, Equatable, Sendable {
    case idle, working, done, blocked, error, clear
}

public enum ProgramStatusKind: String, Equatable, Sendable {
    case permission, question, auth

    public var glyph: String {
        switch self {
        case .permission: return "!"
        case .question: return "?"
        case .auth: return "#"
        }
    }
}

public struct ProgramStatusRecord: Equatable, Sendable {
    public var state: ProgramStatusState
    public var kind: ProgramStatusKind?
    public var progress: Int?
    public var app: String?
    public var title: String?
    public var message: String?
    public var id: String
    var updatedGeneration: UInt64
}

public enum ProgramStatusApply: Equatable, Sendable {
    case query
    case applied
    case discarded
    case ignored
}

/// One terminal's program-status records. Pure: no clock, no I/O.
public struct ProgramStatusBook: Equatable, Sendable {
    public private(set) var records: [String: ProgramStatusRecord] = [:]
    public private(set) var acceptedRealReport = false
    private var generation: UInt64 = 0

    public init() {}

    /// `body` is the text after `7501;`. `sequenceLength` counts OSC through ST.
    public mutating func apply(body: String, sequenceLength: Int) -> ProgramStatusApply {
        if sequenceLength > ProgramStatusRevision.maxSequenceBytes { return .discarded }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "?" { return .query }
        guard let fields = Self.fields(in: trimmed) else { return .discarded }
        guard let rawState = fields["state"] else { return .ignored }
        guard let state = ProgramStatusState(rawValue: rawState) else { return .ignored }

        let idResult = Self.identify(fields["id"])
        switch idResult {
        case .discard: return .discarded
        case .ignore: return .ignored
        case .root, .path: break
        }
        let id = idResult.path

        let decoded: (title: String?, message: String?)
        switch Self.textFields(fields) {
        case .discard: return .discarded
        case let .ok(title, message): decoded = (title, message)
        }
        switch Self.appField(fields["app"]) {
        case .discard: return .discarded
        case .absent, .value: break
        }

        if state == .clear {
            clear(id: id, hadID: idResult != .root)
            acceptedRealReport = true
            return .applied
        }

        generation &+= 1
        var record = ProgramStatusRecord(
            state: state,
            kind: nil,
            progress: nil,
            app: nil,
            title: decoded.title,
            message: decoded.message,
            id: id,
            updatedGeneration: generation
        )
        if state == .blocked, let kind = fields["kind"] {
            record.kind = ProgramStatusKind(rawValue: kind)
        }
        if state == .working || state == .blocked {
            record.progress = Self.progress(fields["progress"])
        }
        if case let .value(app) = Self.appField(fields["app"]) {
            record.app = app
        }
        if records[id] == nil, records.count >= ProgramStatusRevision.maxRecords {
            evictLeastRecentlyUpdated()
        }
        records[id] = record
        acceptedRealReport = true
        return .applied
    }

    /// OSC 133 `A` and process exit: drop `working` and `blocked`. `done` and `error` stay.
    public mutating func dropEphemeral() {
        records = records.filter { $0.value.state != .working && $0.value.state != .blocked }
    }

    /// The focused pane received a key. `done` and `error` have been seen.
    public mutating func acknowledgeVisible() {
        records = records.filter { $0.value.state != .done && $0.value.state != .error }
    }

    /// RIS. DECSTR and the alternate screen do not call this.
    public mutating func reset() {
        records.removeAll()
        acceptedRealReport = false
        generation = 0
    }

    /// Map OSC 9;4 onto the root record until the first real 7501 report.
    public mutating func applyOSC94(_ report: TerminalProgressReport) {
        guard !acceptedRealReport else { return }
        generation &+= 1
        switch report.state {
        case .remove:
            records[""] = nil
        case .set, .indeterminate, .paused:
            records[""] = ProgramStatusRecord(
                state: .working,
                kind: nil,
                progress: report.state == .indeterminate ? nil : report.value,
                app: nil,
                title: nil,
                message: nil,
                id: "",
                updatedGeneration: generation
            )
        case .error:
            records[""] = ProgramStatusRecord(
                state: .error,
                kind: nil,
                progress: nil,
                app: nil,
                title: nil,
                message: nil,
                id: "",
                updatedGeneration: generation
            )
        }
    }

    public func inheritedApp(for id: String) -> String? {
        if let app = records[id]?.app { return app }
        var path = id
        while let slash = path.lastIndex(of: "/") {
            path = String(path[..<slash])
            if let app = records[path]?.app { return app }
        }
        if !id.isEmpty, let app = records[""]?.app { return app }
        return nil
    }

    private mutating func clear(id: String, hadID: Bool) {
        if !hadID {
            records.removeAll()
            return
        }
        let prefix = id + "/"
        records = records.filter { key, _ in key != id && !key.hasPrefix(prefix) }
    }

    private mutating func evictLeastRecentlyUpdated() {
        guard let victim = records.min(by: { $0.value.updatedGeneration < $1.value.updatedGeneration })?.key else { return }
        records[victim] = nil
    }

    private enum IDResult: Equatable {
        case root
        case path(String)
        case discard
        case ignore

        var path: String {
            switch self {
            case .root: return ""
            case let .path(value): return value
            case .discard, .ignore: return ""
            }
        }
    }

    private static func identify(_ raw: String?) -> IDResult {
        guard let raw else { return .root }
        if raw.utf8.count > 128 { return .discard }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 8 { return .discard }
        if parts.contains(where: { $0.utf8.count > 32 }) { return .discard }
        if parts.contains(where: { $0.isEmpty || !isIDSegment($0) }) { return .ignore }
        return .path(raw)
    }

    private static func isIDSegment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.utf8.allSatisfy(isIDByte)
    }

    private static func isIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A: return true
        case 0x5F, 0x2E, 0x2B, 0x2D: return true // _ . + -
        default: return false
        }
    }

    /// nil means a limit was broken and the whole report is discarded.
    private static func fields(in body: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for raw in body.split(separator: ":", omittingEmptySubsequences: false) {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty || !key.utf8.allSatisfy({ (0x61 ... 0x7A).contains($0) }) { continue }
            if key.utf8.count > 16 { return nil }
            if !value.utf8.allSatisfy(isValueByte) { continue }
            fields[String(key)] = String(value)
        }
        return fields
    }

    /// Value bytes, plus `/` so an id path is not a malformed pair.
    private static func isValueByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A: return true
        case 0x5F, 0x2E, 0x2C, 0x2B, 0x2F, 0x3D, 0x2D: return true // _ . , + / = -
        default: return false
        }
    }

    private enum TextFields {
        case ok(String?, String?)
        case discard
    }

    private static func textFields(_ fields: [String: String]) -> TextFields {
        let title: String?
        let message: String?
        switch decodeText(fields["title"], encodedLimit: 256, decodedLimit: 192) {
        case .absent: title = nil
        case .discard: return .discard
        case let .value(text): title = text
        }
        switch decodeText(fields["msg"], encodedLimit: 2732, decodedLimit: 2048) {
        case .absent: message = nil
        case .discard: return .discard
        case let .value(text): message = text
        }
        return .ok(title, message)
    }

    private enum DecodedText {
        case absent
        case value(String)
        case discard
    }

    private static func decodeText(_ encoded: String?, encodedLimit: Int, decodedLimit: Int) -> DecodedText {
        guard let encoded else { return .absent }
        if encoded.utf8.count > encodedLimit { return .discard }
        guard let data = decodeBase64(encoded), let text = String(data: data, encoding: .utf8) else { return .discard }
        if text.utf8.count > decodedLimit { return .discard }
        if text.unicodeScalars.contains(where: isControl) { return .discard }
        return .value(text)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x1F || value == 0x7F || (0x80 ... 0x9F).contains(value)
    }

    private static func decodeBase64(_ text: String) -> Data? {
        var padded = text
        let remainder = padded.count % 4
        if remainder != 0 { padded += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: padded)
    }

    private enum AppField {
        case absent
        case value(String)
        case discard
    }

    private static func appField(_ raw: String?) -> AppField {
        guard let raw else { return .absent }
        if raw.utf8.count > 32 { return .discard }
        if raw.isEmpty || !raw.utf8.allSatisfy(isIDByte) { return .absent }
        return .value(raw)
    }

    private static func progress(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw), (0 ... 100).contains(value) else { return nil }
        return value
    }
}

public enum ProgramStatusText {
    /// Direction overrides are untrusted when a record is drawn outside the grid.
    public static func stripBidi(_ text: String) -> String {
        String(text.unicodeScalars.filter { !bidi.contains($0.value) })
    }

    public static func shorten(_ text: String, limit: Int = 160) -> String {
        let plain = stripBidi(text)
        if plain.count <= limit { return plain }
        return String(plain.prefix(limit - 1)) + "…"
    }

    private static let bidi: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

public struct ProgramStatusDetectorFill: Equatable, Sendable {
    public var app: String
    public var silent: Bool

    public init(app: String, silent: Bool) {
        self.app = app
        self.silent = silent
    }
}

public struct ProgramStatusNotification: Equatable, Sendable {
    public var paneName: String
    public var title: String
    public var body: String
    public var fingerprint: String
}

public struct ProgramStatusPresentation: Equatable, Sendable {
    public enum Mark: String, Equatable, Sendable {
        case none, working, blocked, done, error
    }

    public var mark: Mark
    public var kind: ProgramStatusKind?
    public var progress: Int?
    public var message: String?
    public var app: String?
    public var fromRealReport: Bool
    public var notifications: [ProgramStatusNotification]
    public var accessibilityLabel: String

    public var showsWorkingDot: Bool { mark == .working }
    public var joinsWaitingQueue: Bool { mark == .blocked }
}

/// One decision for the tab, the session row, notifications, and the waiting queue.
public enum ProgramStatusPresenter {
    public static func decide(
        book: ProgramStatusBook,
        detector: ProgramStatusDetectorFill?,
        paneName: String,
        previous: ProgramStatusPresentation?,
        now: TimeInterval,
        lastNotifiedAt: TimeInterval?,
        rateLimit: TimeInterval = 2
    ) -> ProgramStatusPresentation {
        let chosen = choose(book: book, detector: detector)
        let message = chosen.message.map { ProgramStatusText.shorten($0) }
        let label = accessibility(pane: paneName, mark: chosen.mark, message: message, app: chosen.app)
        var notes: [ProgramStatusNotification] = []
        if chosen.fromRealReport, chosen.mark == .blocked || chosen.mark == .done || chosen.mark == .error {
            let fingerprint = "\(paneName)|\(chosen.mark.rawValue)|\(message ?? "")"
            let changed = previous?.mark != chosen.mark || previous?.message != message
            let cooled = lastNotifiedAt.map { now - $0 >= rateLimit } ?? true
            if changed, cooled {
                notes.append(ProgramStatusNotification(
                    paneName: paneName,
                    title: paneName,
                    body: message ?? chosen.mark.rawValue,
                    fingerprint: fingerprint
                ))
            }
        }
        return ProgramStatusPresentation(
            mark: chosen.mark,
            kind: chosen.kind,
            progress: chosen.progress,
            message: message,
            app: chosen.app,
            fromRealReport: chosen.fromRealReport,
            notifications: notes,
            accessibilityLabel: label
        )
    }

    /// Highest attention across the tabs of one session.
    public static func sessionMark(_ marks: [ProgramStatusPresentation.Mark]) -> ProgramStatusPresentation.Mark {
        if marks.contains(.blocked) { return .blocked }
        if marks.contains(.error) { return .error }
        if marks.contains(.done) { return .done }
        if marks.contains(.working) { return .working }
        return .none
    }

    private struct Chosen {
        var mark: ProgramStatusPresentation.Mark
        var kind: ProgramStatusKind?
        var progress: Int?
        var message: String?
        var app: String?
        var fromRealReport: Bool
    }

    private static func choose(book: ProgramStatusBook, detector: ProgramStatusDetectorFill?) -> Chosen {
        let ranked = book.records.values.sorted { rank($0.state) > rank($1.state) }
        if let record = ranked.first(where: { rank($0.state) > 0 }) {
            let fromReal = book.acceptedRealReport
            return Chosen(
                mark: mark(record.state),
                kind: record.kind,
                progress: record.progress,
                message: record.message,
                app: record.app ?? book.inheritedApp(for: record.id),
                fromRealReport: fromReal
            )
        }
        if book.acceptedRealReport {
            return Chosen(mark: .none, kind: nil, progress: nil, message: nil, app: nil, fromRealReport: true)
        }
        if let detector, detector.silent {
            return Chosen(mark: .none, kind: nil, progress: nil, message: nil, app: detector.app, fromRealReport: false)
        }
        return Chosen(mark: .none, kind: nil, progress: nil, message: nil, app: nil, fromRealReport: false)
    }

    private static func rank(_ state: ProgramStatusState) -> Int {
        switch state {
        case .blocked: return 4
        case .error: return 3
        case .done: return 2
        case .working: return 1
        case .idle, .clear: return 0
        }
    }

    private static func mark(_ state: ProgramStatusState) -> ProgramStatusPresentation.Mark {
        switch state {
        case .working: return .working
        case .blocked: return .blocked
        case .done: return .done
        case .error: return .error
        case .idle, .clear: return .none
        }
    }

    private static func accessibility(pane: String, mark: ProgramStatusPresentation.Mark, message: String?, app: String?) -> String {
        var parts = [pane]
        if mark != .none { parts.append(mark.rawValue) }
        if let app, !app.isEmpty { parts.append(app) }
        if let message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: ", ")
    }
}
