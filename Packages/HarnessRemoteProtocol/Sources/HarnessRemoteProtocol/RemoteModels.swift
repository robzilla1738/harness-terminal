import Foundation

/// Versioned bridge vocabulary, independent of daemon and platform APIs.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), uint(UInt64), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(UInt64.self) { self = .uint(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .uint(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
    public var string: String? { if case let .string(v) = self { return v }; return nil }
    public var int: Int? { if case let .int(v) = self { return v }; return nil }
    public var bool: Bool? { if case let .bool(v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case let .object(v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case let .array(v) = self { return v }; return nil }
}

public struct RemoteHello: Codable, Equatable, Sendable {
    public static let currentProtocol = 1
    public var protocolVersion: Int
    public var minimumProtocol: Int
    public var cliVersion: String
    public var daemonVersion: String
    public var hostName: String
    public var daemonEpoch: String
    public var capabilities: [String]
    public var maximumUploadBytes: Int
    public init(protocolVersion: Int = 1, minimumProtocol: Int = 1, cliVersion: String, daemonVersion: String, hostName: String, daemonEpoch: String, capabilities: [String], maximumUploadBytes: Int = 8 * 1024 * 1024) {
        self.protocolVersion = protocolVersion; self.minimumProtocol = minimumProtocol
        self.cliVersion = cliVersion; self.daemonVersion = daemonVersion; self.hostName = hostName
        self.daemonEpoch = daemonEpoch; self.capabilities = capabilities; self.maximumUploadBytes = maximumUploadBytes
    }
}

public struct PaneAddress: Codable, Equatable, Hashable, Sendable {
    public var workspaceID: String
    public var sessionID: String
    public var tabID: String
    public var paneID: String
    public var surfaceID: String
    public init(workspaceID: String, sessionID: String, tabID: String, paneID: String, surfaceID: String) {
        self.workspaceID = workspaceID; self.sessionID = sessionID; self.tabID = tabID; self.paneID = paneID; self.surfaceID = surfaceID
    }
}

public struct RemotePane: Codable, Equatable, Sendable, Identifiable {
    public var id: String { address.paneID }
    public var address: PaneAddress
    public var title: String
    public var directory: String
    public var program: String?
    public var agent: String?
    public var sessionName: String
    public var tabTitle: String
    public init(address: PaneAddress, title: String, directory: String, program: String? = nil, agent: String? = nil, sessionName: String, tabTitle: String) {
        self.address = address; self.title = title; self.directory = directory; self.program = program; self.agent = agent; self.sessionName = sessionName; self.tabTitle = tabTitle
    }
}
public indirect enum RemotePaneLayout: Codable, Equatable, Sendable {
    case leaf(paneID: String)
    case split(direction: String, ratio: Double, first: RemotePaneLayout, second: RemotePaneLayout)
}
public struct RemoteTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var directory: String
    public var persistent: Bool
    public var activePaneID: String?
    public var layout: RemotePaneLayout
    public var panes: [RemotePane]
    public init(id: String, title: String, directory: String, persistent: Bool = false, activePaneID: String? = nil, layout: RemotePaneLayout, panes: [RemotePane]) {
        self.id = id; self.title = title; self.directory = directory; self.persistent = persistent; self.activePaneID = activePaneID; self.layout = layout; self.panes = panes
    }
}
public struct RemoteSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var persistent: Bool
    public var activeTabID: String?
    public var tabs: [RemoteTab]
    public init(id: String, name: String, persistent: Bool = false, activeTabID: String? = nil, tabs: [RemoteTab]) {
        self.id = id; self.name = name; self.persistent = persistent; self.activeTabID = activeTabID; self.tabs = tabs
    }
}
public struct RemoteWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sessions: [RemoteSession]
    public init(id: String, name: String, sessions: [RemoteSession]) { self.id = id; self.name = name; self.sessions = sessions }
}
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var themeName: String
    public var workspaces: [RemoteWorkspace]
    public var panes: [RemotePane] { workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap(\.panes) }
    public init(revision: Int, themeName: String, workspaces: [RemoteWorkspace]) { self.revision = revision; self.themeName = themeName; self.workspaces = workspaces }
}
public struct RemoteAttention: Codable, Equatable, Sendable, Identifiable {
    public var id: String { address.surfaceID }
    public var address: PaneAddress
    public var sessionName: String
    public var tabTitle: String
    public var rank: String
    public var message: String?
    public var agent: String?
    public var explicit: Bool
    public var unread: Bool
    public var snoozedUntil: Date?
    public var updatedAt: Date
    public init(address: PaneAddress, sessionName: String, tabTitle: String, rank: String, message: String? = nil, agent: String? = nil, explicit: Bool, unread: Bool, snoozedUntil: Date? = nil, updatedAt: Date) {
        self.address = address; self.sessionName = sessionName; self.tabTitle = tabTitle; self.rank = rank; self.message = message; self.agent = agent; self.explicit = explicit; self.unread = unread; self.snoozedUntil = snoozedUntil; self.updatedAt = updatedAt
    }
}
public struct RemoteRequest: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var arguments: [String: JSONValue]
    public init(id: String = UUID().uuidString, method: String, arguments: [String: JSONValue] = [:]) { self.id = id; self.method = method; self.arguments = arguments }
}
public struct RemoteFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var requestID: String?
    public var deliveryUncertain: Bool
    public var errorDescription: String? { message }
    public init(code: String, message: String, requestID: String? = nil, deliveryUncertain: Bool = false) { self.code = code; self.message = message; self.requestID = requestID; self.deliveryUncertain = deliveryUncertain }
}
public struct RemoteResponse: Codable, Equatable, Sendable {
    public var id: String
    public var result: JSONValue?
    public var failure: RemoteFailure?
    public init(id: String, result: JSONValue? = nil, failure: RemoteFailure? = nil) { self.id = id; self.result = result; self.failure = failure }
}
public struct RemoteAttach: Codable, Equatable, Sendable {
    public var address: PaneAddress
    public var readOnly: Bool
    public var cols: UInt16
    public var rows: UInt16
    public var epoch: String?
    public var fromSequence: UInt64?
    public init(address: PaneAddress, readOnly: Bool = false, cols: UInt16, rows: UInt16, epoch: String? = nil, fromSequence: UInt64? = nil) {
        self.address = address; self.readOnly = readOnly; self.cols = cols; self.rows = rows; self.epoch = epoch; self.fromSequence = fromSequence
    }
}
public struct RemoteAttached: Codable, Equatable, Sendable {
    public var epoch: String
    public var resync: Bool
    public var endSequence: UInt64
    public var screen: Data?
    /// Binary property-list TerminalCheckpoint wrapper, capped at 8 MiB.
    public var checkpoint: Data?
    public var inputErrors: Bool
    public init(epoch: String, resync: Bool, endSequence: UInt64, screen: Data? = nil, checkpoint: Data? = nil, inputErrors: Bool) {
        self.epoch = epoch; self.resync = resync; self.endSequence = endSequence; self.screen = screen; self.checkpoint = checkpoint; self.inputErrors = inputErrors
    }
}
public struct RemoteOutput: Codable, Equatable, Sendable {
    public var surfaceID: String
    /// Sequence is the first byte in this frame. Resume from sequence + data.count after parsing.
    public var sequence: UInt64
    public var data: Data
    public init(surfaceID: String, sequence: UInt64, data: Data) { self.surfaceID = surfaceID; self.sequence = sequence; self.data = data }
}
public struct RemoteInput: Codable, Equatable, Sendable {
    public var surfaceID: String
    public var data: Data
    public init(surfaceID: String, data: Data) { self.surfaceID = surfaceID; self.data = data }
}
public struct RemoteResize: Codable, Equatable, Sendable {
    public var surfaceID: String
    public var cols: UInt16
    public var rows: UInt16
    public var takeOwnership: Bool
    public init(surfaceID: String, cols: UInt16, rows: UInt16, takeOwnership: Bool = false) { self.surfaceID = surfaceID; self.cols = cols; self.rows = rows; self.takeOwnership = takeOwnership }
}
public struct RemoteOwnership: Codable, Equatable, Sendable {
    public var surfaceID: String
    public var owner: Bool
    public var responder: Bool
    public var rows: UInt16
    public var cols: UInt16
    public var mode: String
    public var clientID: String?
    public init(surfaceID: String, owner: Bool, responder: Bool, rows: UInt16, cols: UInt16, mode: String, clientID: String? = nil) {
        self.surfaceID = surfaceID; self.owner = owner; self.responder = responder; self.rows = rows; self.cols = cols; self.mode = mode; self.clientID = clientID
    }
}
/// Immutable host history page. A token is tied to a pane/daemon epoch and expires after inactivity.
public struct RemoteHistoryPage: Codable, Equatable, Sendable {
    public var token: String
    public var epoch: String
    public var totalRows: Int
    public var startRow: Int
    public var rows: [RemoteHistoryRow]
    public var expiresAt: Date
    public var targetRow: Int?
    public init(token: String, epoch: String, totalRows: Int, startRow: Int, rows: [RemoteHistoryRow], expiresAt: Date, targetRow: Int? = nil) {
        self.token = token; self.epoch = epoch; self.totalRows = totalRows; self.startRow = startRow; self.rows = rows; self.expiresAt = expiresAt
        self.targetRow = targetRow
    }
}
public struct RemoteHistoryRow: Codable, Equatable, Sendable {
    public var wrapped: Bool
    public var cells: [RemoteHistoryCell]
    public init(wrapped: Bool, cells: [RemoteHistoryCell]) { self.wrapped = wrapped; self.cells = cells }
}
public struct RemoteHistoryCell: Codable, Equatable, Sendable {
    public var text: String
    public var width: Int
    public var foreground: String
    public var background: String
    public var flags: UInt16
    public var hyperlink: String?
    public init(text: String, width: Int, foreground: String, background: String, flags: UInt16, hyperlink: String? = nil) {
        self.text = text; self.width = width; self.foreground = foreground; self.background = background; self.flags = flags; self.hyperlink = hyperlink
    }
}
public enum RemoteMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello), request(RemoteRequest), response(RemoteResponse)
    case snapshot(RemoteSnapshot), attention([RemoteAttention]), appearance(RemoteAppearance)
    case attach(RemoteAttach), attached(RemoteAttached), output(RemoteOutput), input(RemoteInput)
    case resize(RemoteResize), ownership(RemoteOwnership), error(RemoteFailure), detach
}

/// Pairing metadata only. Importing this never installs a key or executes a command.
public struct RemotePairingInfo: Codable, Equatable, Sendable {
    public var version: Int
    public var host: String
    public var port: Int
    public var username: String
    public var fingerprint: String
    public var executablePath: String
    public var alternateHosts: [String]?
    public init(version: Int = 1, host: String, port: Int = 22, username: String, fingerprint: String, executablePath: String, alternateHosts: [String]? = nil) {
        self.version = version; self.host = host; self.port = port; self.username = username; self.fingerprint = fingerprint; self.executablePath = executablePath
        self.alternateHosts = alternateHosts
    }
}

public struct RemoteAppearance: Codable, Equatable, Sendable {
    public var themeName: String
    public var background: String
    public var foreground: String
    public var cursor: String
    public var cursorText: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var bold: String?
    public var palette: [String]
    public var colorRendering: String
    public var textRendering: String
    public init(themeName: String, background: String, foreground: String, cursor: String, cursorText: String? = nil,
                selectionBackground: String? = nil, selectionForeground: String? = nil, bold: String? = nil,
                palette: [String], colorRendering: String = "accurate", textRendering: String = "native") {
        self.themeName = themeName; self.background = background; self.foreground = foreground; self.cursor = cursor
        self.cursorText = cursorText; self.selectionBackground = selectionBackground; self.selectionForeground = selectionForeground
        self.bold = bold; self.palette = palette; self.colorRendering = colorRendering; self.textRendering = textRendering
    }
}
