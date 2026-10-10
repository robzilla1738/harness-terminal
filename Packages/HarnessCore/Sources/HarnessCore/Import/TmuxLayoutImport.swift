import Foundation

public struct TmuxPaneRecord: Codable, Equatable, Sendable {
    public var id: String
    public var directory: String
    public var startupSuggestion: String?
    public init(id: String, directory: String, startupSuggestion: String? = nil) { self.id = id; self.directory = directory; self.startupSuggestion = startupSuggestion }
}
public struct TmuxWindowRecord: Codable, Equatable, Sendable {
    public var sessionID: String, windowID: String, sessionName: String, windowName: String, layout: String
    public var panes: [TmuxPaneRecord]
    public init(sessionID: String, windowID: String, sessionName: String, windowName: String, layout: String, panes: [TmuxPaneRecord]) {
        self.sessionID = sessionID; self.windowID = windowID; self.sessionName = sessionName; self.windowName = windowName; self.layout = layout; self.panes = panes
    }
}
public struct TmuxImportSnapshot: Codable, Sendable {
    public var version = 1
    public var capturedAt = Date()
    public var windows: [TmuxWindowRecord]
    public init(windows: [TmuxWindowRecord]) { self.windows = windows }
    private enum CodingKeys: String, CodingKey { case version, capturedAt, windows }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        windows = try values.decode([TmuxWindowRecord].self, forKey: .windows)
        if let legacy = try? values.decode(Date.self, forKey: .capturedAt) { capturedAt = legacy }
        else {
            let text = try values.decode(String.self, forKey: .capturedAt)
            guard text.count <= 40, let date = ISO8601DateFormatter().date(from: text) else { throw TmuxImportError.invalid("capture timestamp") }
            capturedAt = date
        }
        guard capturedAt.timeIntervalSince1970.isFinite else { throw TmuxImportError.invalid("capture timestamp") }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version); try values.encode(windows, forKey: .windows)
        try values.encode(ISO8601DateFormatter().string(from: capturedAt), forKey: .capturedAt)
    }
}
public struct TmuxSetupProposal: Codable, Sendable {
    public var sourceSessionID: String
    public var sourceWindowIDs: [String]
    public var setup: SavedSetup
    /// Informational only. None becomes a Saved Setup startup command on import.
    public var suggestions: [TmuxPaneRecord]
    public var warnings: [String]
}
public enum TmuxImportError: Error, LocalizedError {
    case invalid(String), unsupported(String), changed, unavailable
    public var errorDescription: String? {
        switch self {
        case let .invalid(message): "Invalid tmux import: " + message
        case let .unsupported(message): "Unsupported tmux layout: " + message + ". The tmux session was left untouched."
        case .changed: "The tmux pane identities or layout changed during capture. Retry the preview; no Harness setup was saved."
        case .unavailable: "tmux could not return a bounded layout snapshot. Check the selected server or session; no setup was saved."
        }
    }
}

/// Supports checksummed v1 and current v2 JSON layouts by stable pane IDs.
/// Imported fields stay data: no shell parsing, PTY acquisition or command execution.
public enum TmuxLayoutImport {
    public static func proposals(_ snapshot: TmuxImportSnapshot) throws -> [TmuxSetupProposal] {
        guard snapshot.version == 1, !snapshot.windows.isEmpty, snapshot.windows.count <= 128 else { throw TmuxImportError.invalid("snapshot version or window count") }
        let groups = Dictionary(grouping: snapshot.windows, by: \.sessionID)
        guard groups.count <= 32 else { throw TmuxImportError.invalid("too many sessions; select one session") }
        return try groups.keys.sorted().map { sessionID in
            guard validID(sessionID, prefix: "$"), let windows = groups[sessionID], windows.count <= 32, Set(windows.map(\.windowID)).count == windows.count else { throw TmuxImportError.invalid("duplicate or invalid session/window identities") }
            var warnings: [String] = [], suggestions: [TmuxPaneRecord] = [], tabs: [SetupTab] = []
            for window in windows {
                guard validID(window.windowID, prefix: "@"), window.panes.count <= 64, window.windowName.utf8.count <= 1024 else { throw TmuxImportError.invalid("window identity, name or pane count") }
                let records = try window.panes.reduce(into: [String: TmuxPaneRecord]()) { result, pane in
                    guard validID(pane.id, prefix: "%"), result[pane.id] == nil, pane.directory.hasPrefix("/"), !pane.directory.contains("\0"), pane.directory.utf8.count <= 8192,
                          pane.startupSuggestion.map({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) ?? true else { throw TmuxImportError.invalid("pane identity, directory or suggestion") }
                    result[pane.id] = pane
                }
                let cell = try parse(window.layout)
                guard Set(cell.paneIDs) == Set(records.keys), cell.paneIDs.count == records.count else { throw TmuxImportError.changed }
                let layout = try convert(cell, records: records, warnings: &warnings)
                var tab = SetupTab(Tab(cwd: records.values.first?.directory ?? "/", rootPane: layout.makePaneTree()))
                tab.title = window.windowName; tab.layout = layout; tabs.append(tab)
                suggestions += window.panes.filter { $0.startupSuggestion?.isEmpty == false }
            }
            let originalName = windows[0].sessionName
            let name = originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || originalName.count > 180 ? "Imported tmux " + sessionID : originalName + " (tmux)"
            let setup = SavedSetup(name: name, tabs: tabs); try setup.validate()
            warnings.append("Startup commands are unchecked informational suggestions. Saving this proposal creates no PTYs and runs no commands; opening the Saved Setup later creates new Harness-owned shells.")
            return TmuxSetupProposal(sourceSessionID: sessionID, sourceWindowIDs: windows.map(\.windowID), setup: setup, suggestions: suggestions, warnings: Array(Set(warnings)).sorted())
        }
    }
    public static func validID(_ value: String, prefix: Character) -> Bool {
        value.count >= 2 && value.count <= 20 && value.first == prefix && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
    private struct Cell: Decodable {
        var type: String, width: Int, height: Int, x: Int, y: Int
        var paneID: String?, children: [Cell]
        enum CodingKeys: String, CodingKey { case type = "t", width = "w", height = "h", x, y, paneID = "I", children = "c", z }
        init(type: String, width: Int, height: Int, x: Int, y: Int, paneID: String? = nil, children: [Cell] = []) {
            self.type = type; self.width = width; self.height = height; self.x = x; self.y = y; self.paneID = paneID; self.children = children
        }
        init(from decoder: Decoder) throws {
            guard decoder.codingPath.count < 48 else { throw TmuxImportError.invalid("layout nesting limit") }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard !values.contains(.z) else { throw TmuxImportError.unsupported("floating panes cannot be represented as split panes") }
            type = try values.decode(String.self, forKey: .type); width = try values.decode(Int.self, forKey: .width); height = try values.decode(Int.self, forKey: .height)
            x = try values.decode(Int.self, forKey: .x); y = try values.decode(Int.self, forKey: .y)
            paneID = try values.decodeIfPresent(String.self, forKey: .paneID); children = try values.decodeIfPresent([Cell].self, forKey: .children) ?? []
            try validate()
        }
        var paneIDs: [String] { paneID.map { [$0] } ?? children.flatMap(\.paneIDs) }
        func validate() throws {
            guard ["p", "h", "v"].contains(type), (1...4096).contains(width), (1...4096).contains(height), (0...1_000_000).contains(x), (0...1_000_000).contains(y) else { throw TmuxImportError.invalid("cell type or geometry") }
            if type == "p" { guard let paneID, TmuxLayoutImport.validID(paneID, prefix: "%"), children.isEmpty else { throw TmuxImportError.invalid("leaf identity") } }
            else { guard paneID == nil, (2...64).contains(children.count) else { throw TmuxImportError.invalid("branch children") } }
        }
    }
    private static func parse(_ text: String) throws -> Cell {
        guard text.utf8.count <= 1 << 20 else { throw TmuxImportError.invalid("layout exceeds one MiB") }
        if text.hasPrefix("{") {
            struct Envelope: Decodable { var V: Int; var L: Cell }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
            guard envelope.V == 2 else { throw TmuxImportError.unsupported("unknown JSON layout version") }; return envelope.L
        }
        let bytes = Array(text.utf8)
        guard bytes.count > 5, bytes[4] == 44, let checksum = UInt16(String(decoding: bytes.prefix(4), as: UTF8.self), radix: 16) else { throw TmuxImportError.invalid("checksum header") }
        var actual: UInt16 = 0
        for byte in bytes.dropFirst(5) { actual = ((actual >> 1) | ((actual & 1) << 15)) &+ UInt16(byte) }
        guard actual == checksum else { throw TmuxImportError.invalid("checksum mismatch") }
        var parser = LegacyParser(bytes: Array(bytes.dropFirst(5)))
        let root = try parser.cell(depth: 0); guard parser.position == parser.bytes.count else { throw TmuxImportError.invalid("trailing layout data") }; return root
    }
    private struct LegacyParser {
        var bytes: [UInt8], position = 0, count = 0
        mutating func integer() throws -> Int {
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            guard position > start, position - start <= 7, let value = Int(String(decoding: bytes[start..<position], as: UTF8.self)) else { throw TmuxImportError.invalid("layout number") }; return value
        }
        mutating func expect(_ byte: UInt8) throws { guard position < bytes.count, bytes[position] == byte else { throw TmuxImportError.invalid("layout delimiter") }; position += 1 }
        mutating func cell(depth: Int) throws -> Cell {
            count += 1; guard depth < 16, count <= 127 else { throw TmuxImportError.invalid("layout nesting or node limit") }
            let width = try integer(); try expect(120); let height = try integer(); try expect(44); let x = try integer(); try expect(44); let y = try integer()
            guard position < bytes.count else { throw TmuxImportError.invalid("missing cell identity") }
            let marker = bytes[position]; position += 1
            let result: Cell
            if marker == 44 { result = Cell(type: "p", width: width, height: height, x: x, y: y, paneID: "%" + String(try integer())) }
            else if marker == 123 || marker == 91 {
                var children = [try cell(depth: depth + 1)]
                while position < bytes.count, bytes[position] == 44 { position += 1; children.append(try cell(depth: depth + 1)) }
                try expect(marker == 123 ? 125 : 93)
                result = Cell(type: marker == 123 ? "h" : "v", width: width, height: height, x: x, y: y, children: children)
            } else { throw TmuxImportError.invalid("cell kind") }
            try result.validate(); return result
        }
    }
    private static func convert(_ cell: Cell, records: [String: TmuxPaneRecord], warnings: inout [String]) throws -> SetupLayout {
        if let id = cell.paneID, let pane = records[id] { return .pane(SetupPane(directory: pane.directory)) }
        let children = cell.children
        for child in children {
            guard child.x >= cell.x, child.y >= cell.y, child.x + child.width <= cell.x + cell.width, child.y + child.height <= cell.y + cell.height else { throw TmuxImportError.invalid("child outside parent bounds") }
        }
        guard let first = children.first, let last = children.last else { throw TmuxImportError.invalid("empty branch") }
        if cell.type == "h" {
            guard first.x == cell.x, last.x + last.width == cell.x + cell.width,
                  children.allSatisfy({ $0.y == cell.y && $0.height == cell.height }),
                  zip(children, children.dropFirst()).allSatisfy({ $1.x == $0.x + $0.width + 1 }) else { throw TmuxImportError.invalid("overlapping or incomplete horizontal tiles") }
        } else {
            guard first.y == cell.y, last.y + last.height == cell.y + cell.height,
                  children.allSatisfy({ $0.x == cell.x && $0.width == cell.width }),
                  zip(children, children.dropFirst()).allSatisfy({ $1.y == $0.y + $0.height + 1 }) else { throw TmuxImportError.invalid("overlapping or incomplete vertical tiles") }
        }
        func fold(_ cells: ArraySlice<Cell>) throws -> SetupLayout {
            if cells.count == 1 { return try convert(cells.first!, records: records, warnings: &warnings) }
            let middle = cells.index(cells.startIndex, offsetBy: cells.count / 2), left = cells[..<middle], right = cells[middle...]
            let first = left.first!, last = left.last!, rFirst = right.first!, rLast = right.last!
            let a = cell.type == "h" ? last.x + last.width - first.x : last.y + last.height - first.y
            let b = cell.type == "h" ? rLast.x + rLast.width - rFirst.x : rLast.y + rLast.height - rFirst.y
            guard a > 0, b > 0 else { throw TmuxImportError.invalid("split span") }
            let fraction = Double(a) / Double(a + b), ratio = min(0.9, max(0.1, fraction))
            if ratio != fraction { warnings.append("A split smaller than Harness's supported 10% minimum was clamped in the preview.") }
            return try .split(direction: cell.type == "h" ? .horizontal : .vertical, ratio: ratio, first: fold(left), second: fold(right))
        }
        return try fold(children[...])
    }
}
