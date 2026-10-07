import Foundation

/// One line on `harness-cli events --follow`. `type` plus `payload` is the wire shape.
/// Unknown types are delivered, not rejected. Extra payload fields are ignored by readers.
public struct FollowEvent: Codable, Equatable, Sendable {
    public var type: String
    public var payload: [String: FollowValue]

    public init(type: String, payload: [String: FollowValue] = [:]) {
        self.type = type
        self.payload = payload
    }

    public func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// One human line for a terminal. NDJSON stays the machine format.
    public func humanLine() -> String {
        let fields = payload.keys.sorted().map { key -> String in
            "\(key)=\(payload[key]?.display ?? "")"
        }
        return ([type] + fields).joined(separator: " ")
    }

    public static func programStatusChanged(pane: String, session: String?, state: String, app: String?, message: String?) -> FollowEvent {
        var payload: [String: FollowValue] = ["pane": .string(pane), "state": .string(state)]
        if let session { payload["session"] = .string(session) }
        if let app, !app.isEmpty { payload["app"] = .string(app) }
        if let message, !message.isEmpty { payload["message"] = .string(message) }
        return FollowEvent(type: "program_status_changed", payload: payload)
    }

    public static func keymapChanged(generation: Int, hash: String) -> FollowEvent {
        FollowEvent(type: "keymap.changed", payload: [
            "generation": .int(generation),
            "hash": .string(hash),
            "server": .bool(true),
        ])
    }

    public static func hostsChanged() -> FollowEvent {
        FollowEvent(type: "hosts.changed", payload: ["server": .bool(true)])
    }

    /// A tunneled client lost its SSH forward. Local disconnects stay `client.disconnected`.
    public static func clientConnection(state: String, client: String?, host: String?) -> FollowEvent {
        var payload: [String: FollowValue] = ["state": .string(state), "server": .bool(true)]
        if let client, !client.isEmpty { payload["client"] = .string(client) }
        if let host, !host.isEmpty { payload["host"] = .string(host) }
        return FollowEvent(type: "client.connection", payload: payload)
    }

    /// Emitted only when `tailscale status` is present. A missing command emits nothing.
    public static func tailscaleStatusChanged(commandPresent: Bool, peerCount: Int) -> FollowEvent? {
        guard commandPresent else { return nil }
        return FollowEvent(type: "tailscale_status_changed", payload: [
            "peers": .int(peerCount),
            "server": .bool(true),
        ])
    }

    public static func programStatusRemoved(pane: String, session: String?) -> FollowEvent {
        var payload: [String: FollowValue] = ["pane": .string(pane)]
        if let session { payload["session"] = .string(session) }
        return FollowEvent(type: "program_status_removed", payload: payload)
    }
}

public enum FollowValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    var display: String {
        switch self {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        }
    }
}

extension FollowValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        }
    }
}

/// Who a follow subscription wants. A pinned session drops other sessions.
/// Server events (no session, `server == true`) pass only when `includeServer` is set.
public struct FollowSubscription: Equatable, Sendable {
    public var sessionID: String?
    public var includeServer: Bool

    public init(sessionID: String? = nil, includeServer: Bool = false) {
        self.sessionID = sessionID
        self.includeServer = includeServer
    }

    public func accepts(_ event: FollowEvent) -> Bool {
        let server = event.payload["server"] == .bool(true)
        if server && !includeServer { return false }
        guard let sessionID else { return true }
        if server { return includeServer }
        if case let .string(id)? = event.payload["session"] { return id == sessionID }
        return false
    }
}

/// Facts a hook already knows, turned into a follow event. Hooks keep their own names.
public struct FollowHookContext: Equatable, Sendable {
    public var sessionID: String?
    public var sessionName: String?
    public var tabID: String?
    public var tabName: String?
    public var paneID: String?
    public var cwd: String?
    public var pid: Int?
    public var command: String?
    public var client: String?
    public var exitCode: Int?

    public init(
        sessionID: String? = nil,
        sessionName: String? = nil,
        tabID: String? = nil,
        tabName: String? = nil,
        paneID: String? = nil,
        cwd: String? = nil,
        pid: Int? = nil,
        command: String? = nil,
        client: String? = nil,
        exitCode: Int? = nil
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.tabID = tabID
        self.tabName = tabName
        self.paneID = paneID
        self.cwd = cwd
        self.pid = pid
        self.command = command
        self.client = client
        self.exitCode = exitCode
    }
}

public enum FollowHookBridge {
    /// Map a hook name onto the follow stream. Names with no follow row return nil.
    /// The hook catalog itself is not renamed.
    public static func event(hook: String, context: FollowHookContext) -> FollowEvent? {
        let type: String
        var server = false
        switch hook {
        case "after-new-tab": type = "tab.created"
        case "after-kill-tab": type = "tab.closed"
        case "window-renamed": type = "tab.renamed"
        case "window-pane-changed": type = "tab.activated"
        case "after-split-pane": type = "pane.created"
        case "after-kill-pane": type = "pane.closed"
        case "after-new-session", "session-created": type = "session_created"
        case "session-closed": type = "session_destroyed"
        case "session-renamed": type = "session.renamed"
        case "client-attached": type = "client.connected"; server = true
        case "client-detached": type = "client.disconnected"; server = true
        case "alert-bell": type = "terminal.bell"
        case "notification-posted": type = "terminal.notification"
        case "agent-state-changed": type = "agent.state"
        case "pane-exited": type = "terminal.child_exited"
        default: return nil
        }
        var payload: [String: FollowValue] = [:]
        func put(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { payload[key] = .string(value) }
        }
        put("session", context.sessionID)
        put("session_name", context.sessionName)
        put("tab", context.tabID)
        put("tab_name", context.tabName)
        put("pane", context.paneID)
        put("cwd", context.cwd)
        put("command", context.command)
        put("client", context.client)
        if let pid = context.pid { payload["pid"] = .int(pid) }
        if let exitCode = context.exitCode { payload["exit"] = .int(exitCode) }
        if server { payload["server"] = .bool(true) }
        return FollowEvent(type: type, payload: payload)
    }
}
