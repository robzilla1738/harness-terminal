import Foundation

/// Exit codes for `harness-cli api` and the other new commands in this slice.
/// Older tmux-style verbs keep the exit codes they already had.
public enum APIExit: Int, Equatable, Sendable {
    case ok = 0
    case failed = 1
    case badArguments = 2
    case ambiguous = 3
    case unreachable = 4
    case interrupted = 130
}

public enum APIArgument: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: APIArgument])
    case array([APIArgument])

    public var jsonValue: Any {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        case let .array(values): values.map(\.jsonValue)
        case let .object(values): values.mapValues(\.jsonValue)
        }
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var object: [String: APIArgument]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var array: [APIArgument]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }
}

/// `items` is a JSON object, not an array of schemas. A class breaks the struct cycle
/// (`APIJSONSchema?` is stored inline; a dictionary of the same struct is already indirect).
public final class APISchemaNode: Encodable, Equatable, Sendable {
    public let schema: APIJSONSchema
    public init(_ schema: APIJSONSchema) { self.schema = schema }
    public static func == (lhs: APISchemaNode, rhs: APISchemaNode) -> Bool { lhs.schema == rhs.schema }
    public func encode(to encoder: Encoder) throws { try schema.encode(to: encoder) }
}

public struct APIJSONSchema: Encodable, Equatable, Sendable {
    public var type: String
    public var description: String?
    public var properties: [String: APIJSONSchema]?
    public var required: [String]?
    public var enumValues: [String]?
    public var additionalProperties: Bool?
    /// Stored as a reference so this struct can describe its own array items.
    public var items: APISchemaNode?

    public init(
        type: String,
        description: String? = nil,
        properties: [String: APIJSONSchema]? = nil,
        required: [String]? = nil,
        enumValues: [String]? = nil,
        additionalProperties: Bool? = nil,
        items: APIJSONSchema? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.enumValues = enumValues
        self.additionalProperties = additionalProperties
        self.items = items.map(APISchemaNode.init)
    }

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
        case additionalProperties
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        try container.encodeIfPresent(items, forKey: .items)
    }
}

public struct APIMethod: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var parameters: APIJSONSchema
    public var result: APIJSONSchema

    public init(name: String, summary: String, parameters: APIJSONSchema, result: APIJSONSchema) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.result = result
    }
}

public struct APIMethodDocument: Encodable, Equatable {
    public var schema: String
    public var title: String
    public var description: String
    public var type: String
    public var properties: [String: APIJSONSchema]?
    public var required: [String]?
    public var additionalProperties: Bool
    public var result: APIJSONSchema

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case title, description, type, properties, required, additionalProperties, result
    }
}

public enum APITargetKind: String, Equatable, Sendable {
    case session, tab, pane, client
}

public struct APISessionRecord: Equatable, Sendable {
    public var id: String
    public var label: String
    public var workspaceID: String
    public init(id: String, label: String, workspaceID: String = "") {
        self.id = id
        self.label = label
        self.workspaceID = workspaceID
    }
}

public struct APITabRecord: Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var label: String
    public var workspaceID: String
    public init(id: String, sessionID: String, label: String, workspaceID: String = "") {
        self.id = id
        self.sessionID = sessionID
        self.label = label
        self.workspaceID = workspaceID
    }
}

public struct APIPaneRecord: Equatable, Sendable {
    public var surfaceID: String
    public var paneID: String
    public var tabID: String
    public var sessionID: String
    public var label: String
    public init(surfaceID: String, paneID: String, tabID: String, sessionID: String, label: String) {
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.tabID = tabID
        self.sessionID = sessionID
        self.label = label
    }
}

public struct APIClientRecord: Equatable, Sendable {
    public var id: String
    public var label: String
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct APISessionView: Encodable, Equatable, Sendable {
    public struct PaneView: Encodable, Equatable, Sendable {
        public var pane: String
        public var surface: String
        public var active: Bool
    }

    public struct TabView: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var cwd: String
        public var active: Bool
        public var agent: String?
        public var panes: [PaneView]
    }

    public var session: String
    public var label: String
    public var workspace: String
    public var activeTab: String?
    public var tabs: [TabView]

    enum CodingKeys: String, CodingKey {
        case session, label, workspace, tabs
        case activeTab = "active_tab"
    }
}

public struct APICatalog: Equatable, Sendable {
    public var sessions: [APISessionRecord]
    public var tabs: [APITabRecord]
    public var panes: [APIPaneRecord]
    public var clients: [APIClientRecord]
    /// What the window is showing, the default target when the caller has no `HARNESS_*` context.
    public var activeSession: String?
    public var activeTab: String?
    public var activeSurface: String?

    public init(
        sessions: [APISessionRecord] = [],
        tabs: [APITabRecord] = [],
        panes: [APIPaneRecord] = [],
        clients: [APIClientRecord] = [],
        activeSession: String? = nil,
        activeTab: String? = nil,
        activeSurface: String? = nil
    ) {
        self.sessions = sessions
        self.tabs = tabs
        self.panes = panes
        self.clients = clients
        self.activeSession = activeSession
        self.activeTab = activeTab
        self.activeSurface = activeSurface
    }
}

public struct APIEnvironment: Equatable, Sendable {
    public var session: String?
    public var tab: String?
    public var server: String?
    public var surface: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        session = environment["HARNESS_SESSION"].flatMap { $0.isEmpty ? nil : $0 }
        tab = environment["HARNESS_TAB"].flatMap { $0.isEmpty ? nil : $0 }
        server = environment["HARNESS_SERVER"].flatMap { $0.isEmpty ? nil : $0 }
        surface = environment["HARNESS_SURFACE"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// What `api call` does once its targets are resolved. Single daemon writes and reads go
/// through `.request` / `.query`; everything else has its own case.
public enum APIPlan: Sendable {
    case failure(code: Int, message: String)
    case version
    case listSessions
    case viewSession(String)
    case viewPane(surfaceID: String)
    case split(tabID: String, paneID: String?, direction: String, command: String?, cwd: String?, layout: APILayoutNode?)
    case sessionCreate(name: String?, layout: APILayoutNode?)
    case clientList
    case clientDisconnect(id: String)
    /// A bindable command line (`split-window -h`), run through `CommandRunner`.
    case verb(String)
    /// One daemon write. The reply becomes `{"ok":true}`, or `{"tab"|"pane"|"session": id}`.
    case request(IPCRequest)
    /// One daemon read whose text reply is already JSON.
    case query(IPCRequest)
    case sendKey(surfaceID: String, keys: [String], hex: Bool)
    case capture(surfaceID: String, format: String, trim: Bool, unwrap: Bool, screen: Bool)
    case wait(surfaceID: String, until: String, timeout: Double)
    case theme(surfaceID: String, theme: String)
}

public enum HarnessAPI {
    public static let schemaURL = "https://json-schema.org/draft/2020-12/schema"

    public static let methods: [APIMethod] = [
        method("server.version", "Daemon version", object([:]), object(["version": string("Marketing version"), "build": int("Build number")])),
        method("pane.search_paths", "Find files and directories on a pane’s host", object(["pane": string("Source pane"), "path": string("Directory"), "query": string("Fuzzy query"), "project": bool("Search project files")]), object(["root": string("Search root"), "entries": array("Matching paths")])),
        method("output.search", "Search retained output in open sessions (100 results per page)", object(["query": string("Literal text"), "case_sensitive": bool("Match case"), "session": string("Optional session scope"), "offset": int("Result offset")]), object(["matches": array("Matches with source and line locator"), "hasMore": bool("More results are available")])),
        method("setup.list", "Saved setups and recently closed layouts", object([:]), object(["setups": array("Saved setups"), "recentlyClosed": array("Closed layouts")])),
        method("setup.capture", "Save a session as a setup without capturing running commands", object(["session": string("Session id or name"), "name": string("Setup name")]), object(["ok": bool("Success")])),
        method("setup.save", "Import or update a setup; never executes commands", object(["definition": APIJSONSchema(type: "object", description: "Versioned setup definition", additionalProperties: true)]), object(["ok": bool("Success")])),
        method("setup.open", "Return to a running setup or explicitly open a new copy", object(["id": string("Setup UUID"), "mode": enumString("Open mode", ["existing", "newCopy"])]), object(["session": string("Session id")])),
        method("setup.delete", "Delete a setup definition, leaving running sessions intact", object(["id": string("Setup UUID")]), object(["ok": bool("Success")])),
        method("closed.restore", "Recreate a closed layout with fresh shells", object(["id": string("Closed entry UUID")]), object(["session": string("Session id")])),
        method("closed.delete", "Remove a closed entry, or clear the list when id is omitted", object(["id": string("Closed entry UUID")]), object(["ok": bool("Success")])),
        method("attention.list", "Activity for every pane", object([:]), array("Pane activity")),
        method("attention.read", "Mark a pane alert read without resolving its status", object(["pane": string("Pane id")]), object(["ok": bool("Success")])),
        method("attention.snooze", "Snooze a pane for 0, 15, or 60 minutes", object(["pane": string("Pane id"), "minutes": int("0, 15, or 60")]), object(["ok": bool("Success")])),
        method("session.list", "List sessions", object([:]), object(["sessions": array("Sessions")])),
        method("session.view", "One session and its tabs", object(["session": string("Session id or label")]), object([
            "session": string("Session id"),
            "label": string("Session label"),
            "workspace": string("Workspace id"),
            "active_tab": string("Active tab id"),
            "tabs": array("Tabs, each with id, label, cwd, active, agent, and panes (pane, surface, active)"),
        ])),
        method("pane.split", "Split a pane", object([
            "pane": string("Pane to split. Defaults to the current pane."),
            "tab": string("Tab id. Defaults to the current tab."),
            "direction": enumString("horizontal or vertical", ["horizontal", "vertical"]),
            "command": string("Executable for the new pane."),
            "cwd": string("Working directory for the new pane."),
            "layout": APIJSONSchema(type: "object", description: "Layout tree. The first leaf is this pane.", additionalProperties: true),
        ]), object(["pane": string("New pane id")])),
        method("session.create", "Create a session from an optional layout tree", object([
            "name": string("Session name"),
            "layout": APIJSONSchema(type: "object", description: "Layout tree", additionalProperties: true),
        ]), object(["session": string("New session id")])),
        method("client.list", "List connected clients", object([:]), object(["clients": array("Connected clients")])),
        method("client.disconnect", "Disconnect a client by id", object([
            "id": string("Client id"),
        ], required: ["id"]), object(["ok": bool("Applied")])),
        method("pane.zoom", "Toggle zoom for a pane", object(["pane": string("Pane id or label")]), object(["ok": bool("Applied")])),
        method("pane.focus", "Focus a pane", object(["pane": string("Pane id or label")]), object(["ok": bool("Applied")])),
        method("pane.label", "Rename the pane's tab", object([
            "pane": string("Pane id or label"),
            "title": string("New label"),
        ], required: ["title"]), object(["ok": bool("Applied")])),
        method("pane.close", "Close a pane", object(["pane": string("Pane id or label")]), object(["ok": bool("Applied")])),
        method("pane.write", "Write text to a pane", object([
            "pane": string("Pane id or label"),
            "text": string("Bytes to write, as text"),
        ], required: ["text"]), object(["ok": bool("Applied")])),
        method("pane.send_key", "Send key tokens using the pane's keyboard modes", object([
            "pane": string("Pane id or label"),
            "keys": string("Key tokens separated by spaces"),
            "hex": bool("Send raw hex bytes instead of key tokens"),
        ], required: ["keys"]), object(["ok": bool("Applied")])),
        method("pane.capture", "Capture a pane as text, HTML, or VT", object([
            "pane": string("Pane id or label"),
            "format": enumString("text, html, or vt", ["text", "html", "vt"]),
            "trim": bool("Drop trailing whitespace"),
            "unwrap": bool("Join soft-wrapped rows"),
            "screen": bool("Only the visible screen, without scrollback"),
        ]), object([
            "format": string("The format that was rendered"),
            "text": string("Captured text"),
        ])),
        method("pane.process", "Child, foreground process, and ancestors", object(["pane": string("Pane id or label")]), object([
            "child": string("Process the terminal started"),
            "foreground": string("Foreground process"),
            "ancestors": array("Parent chain"),
        ])),
        method("pane.pwd", "Working directory as a file URL plus the owner", object(["pane": string("Pane id or label")]), object([
            "url": string("file:// URL"),
            "pid": int("Owner pid"),
            "name": string("Owner process name"),
        ])),
        method("pane.list_dir", "List the owning daemon's directory, rooted at the pane cwd unless a path is given", object([
            "pane": string("Pane id or label"),
            "path": string("Directory to list. Omitted means the pane's cwd."),
        ]), object([
            "root": string("Directory that was listed"),
            "entries": array("Names on the owning daemon"),
        ])),
        method("pane.title", "Pane tab title", object(["pane": string("Pane id or label")]), object(["title": string("Title")])),
        method("pane.size", "Pane size in cells", object(["pane": string("Pane id or label")]), object([
            "rows": int("Rows"),
            "cols": int("Columns"),
        ])),
        method("pane.program_status", "OSC 7501 records for a pane", object(["pane": string("Pane id or label")]), object(["records": array("Status records")])),
        method("pane.wait", "Wait for the child process to exit, or for OSC 133 command-finished", object([
            "pane": string("Pane id or label"),
            "until": enumString("child or command", ["child", "command"]),
            "timeout": number("Seconds before the wait fails"),
        ]), object(["exit": int("Status code")])),
        method("pane.theme", "Set the pane theme through its profile rule", object([
            "pane": string("Pane id or label"),
            "theme": string("Theme name"),
        ], required: ["theme"]), object(["ok": bool("Applied")])),
        method("pane.reset", "Reset the pane's terminal (RIS)", object(["pane": string("Pane id or label")]), object(["ok": bool("Applied")])),
        method("pane.view", "Everything about one pane: ids, cwd, program, size, status, process", object([
            "pane": string("Pane id or label"),
        ]), object([
            "pane": string("Pane id"), "surface": string("Surface id"), "tab": string("Tab id"),
            "cwd": string("Working directory"), "command": string("Foreground command"),
            "size": APIJSONSchema(type: "object", description: "rows and cols"),
            "status": array("OSC 7501 records"), "process": APIJSONSchema(type: "object", description: "Process tree"),
        ])),
        method("pane.swap", "Swap two panes (across tabs too)", object([
            "pane": string("Pane id or label"), "with": string("The other pane"),
        ], required: ["with"]), object(["ok": bool("Applied")])),
        method("pane.move", "Move a pane next to another pane", object([
            "pane": string("Pane to move"), "to": string("Pane to split"),
            "side": enumString("Where it lands next to `to` (default right)", ["left", "right", "above", "below"]),
            "direction": enumString("horizontal or vertical, when no side is given (the pane goes after)", ["horizontal", "vertical"]),
        ], required: ["to"]), object(["pane": string("The moved pane's new id")])),
        method("pane.detach", "Move a pane into its own new tab", object(["pane": string("Pane id or label")]), object(["tab": string("New tab id")])),
        method("pane.resize", "Move a pane's divider", object([
            "pane": string("Pane id or label"),
            "direction": enumString("left, right, up, or down", ["left", "right", "up", "down"]),
            "amount": int("Cells. Default 1."),
        ], required: ["direction"]), object(["ok": bool("Applied")])),
        method("pane.focus_direction", "Focus the neighbouring pane", object([
            "pane": string("Pane to move from"),
            "direction": enumString("left, right, up, or down", ["left", "right", "up", "down"]),
        ], required: ["direction"]), object(["ok": bool("Applied")])),
        method("tab.create", "Open a tab in the session's workspace", object([
            "session": string("Session id or label. Defaults to the current session."),
            "cwd": string("Working directory"),
            "command": string("Executable to run instead of the shell"),
        ]), object(["tab": string("New tab id")])),
        method("tab.close", "Close a tab and its panes", object(["tab": string("Tab id or label")]), object(["ok": bool("Applied")])),
        method("tab.label", "Rename a tab", object([
            "tab": string("Tab id or label"), "title": string("New label"),
        ], required: ["title"]), object(["ok": bool("Applied")])),
        method("tab.move", "Move a tab to a 0-based index, in its session or another one", object([
            "tab": string("Tab id or label"), "index": int("Destination index (default: the end)"),
            "session": string("Session id or label to move it into, or \"new\" for a session of its own"),
        ]), object(["session": string("The session the tab is in now")])),
        method("tab.focus", "Select a tab", object(["tab": string("Tab id or label")]), object(["ok": bool("Applied")])),
        method("session.label", "Rename a session", object([
            "session": string("Session id or label"), "name": string("New name"),
        ], required: ["name"]), object(["ok": bool("Applied")])),
    ] + CommandParser.knownVerbs.map(verbMethod)

    /// A bindable command as an API method: `{"args": "-h"}` runs `<name> -h`.
    static func verbMethod(_ name: String) -> APIMethod {
        method(
            name,
            "Run the \(name) command (same as the : prompt and key bindings)",
            object(["args": string("The command's arguments, e.g. \"-h\" for split-window")]),
            object(["ok": bool("Applied")])
        )
    }

    /// A listed method, or any command the parser accepts under another name (an alias
    /// such as `split-window`), described the same way as the listed verbs.
    public static func method(named name: String) -> APIMethod? {
        if let listed = methods.first(where: { $0.name == name }) { return listed }
        return (try? CommandParser.parse(name)) != nil ? verbMethod(name) : nil
    }

    public static func document(for name: String) -> APIMethodDocument? {
        guard let method = method(named: name) else { return nil }
        return APIMethodDocument(
            schema: schemaURL,
            title: method.name,
            description: method.summary,
            type: "object",
            properties: method.parameters.properties,
            required: method.parameters.required,
            additionalProperties: false,
            result: method.result
        )
    }

    public static func describeJSON(named name: String) throws -> String {
        guard let document = document(for: name) else {
            throw APIPlanError(code: .badArguments, message: "Unknown method \(name)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    public static func listJSON() throws -> String {
        struct Row: Encodable { var name: String; var summary: String }
        let rows = methods.map { Row(name: $0.name, summary: $0.summary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(rows), as: UTF8.self)
    }

    public static func arguments(from json: String) -> Result<[String: APIArgument], APIPlanError> {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(APIPlanError(code: .badArguments, message: "Arguments must be a JSON object"))
        }
        var parsed: [String: APIArgument] = [:]
        for (key, value) in object {
            guard let argument = argument(from: value) else {
                return .failure(APIPlanError(code: .badArguments, message: "Unsupported argument \(key)"))
            }
            parsed[key] = argument
        }
        return .success(parsed)
    }

    private static func argument(from value: Any) -> APIArgument? {
        if let text = value as? String { return .string(text) }
        if let items = value as? NSArray {
            var parsed: [APIArgument] = []
            for item in items {
                guard let one = argument(from: item) else { return nil }
                parsed.append(one)
            }
            return .array(parsed)
        }
        if let fields = value as? NSDictionary {
            var parsed: [String: APIArgument] = [:]
            for case let (key as String, item) in fields {
                guard let one = argument(from: item) else { return nil }
                parsed[key] = one
            }
            return .object(parsed)
        }
        if let number = value as? NSNumber {
            // JSON booleans are NSNumbers whose objC type is "c"/"B". A plain `as? Bool`
            // also matches 0 and 1, which would swallow integer timeouts.
            let kind = String(cString: number.objCType)
            if kind == "c" || kind == "B" { return .bool(number.boolValue) }
            if kind == "d" || kind == "f" { return .double(number.doubleValue) }
            return .int(number.intValue)
        }
        return nil
    }

    public static func plan(method: String, arguments: [String: APIArgument], catalog: APICatalog, environment: APIEnvironment) -> APIPlan {
        guard let spec = self.method(named: method) else {
            return .failure(code: APIExit.badArguments.rawValue, message: "Unknown method \(method)")
        }
        if spec.parameters.additionalProperties != true {
            let allowed = Set(spec.parameters.properties?.keys.map { $0 } ?? [])
            if let key = arguments.keys.filter({ !allowed.contains($0) }).sorted().first {
                return .failure(code: APIExit.badArguments.rawValue, message: "Unknown argument \(key)")
            }
        }
        for name in spec.parameters.required ?? [] where arguments[name] == nil {
            return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument \(name)")
        }
        do {
            return try plan(method, arguments, APITargets(catalog: catalog, environment: environment))
        } catch let failure as APIPlanError {
            return .failure(code: failure.code.rawValue, message: failure.message)
        } catch {
            return .failure(code: APIExit.failed.rawValue, message: "\(error)")
        }
    }

    private static func plan(_ method: String, _ arguments: [String: APIArgument], _ targets: APITargets) throws -> APIPlan {
        func pane() throws -> APIPaneRecord { try targets.pane(arguments["pane"]?.string) }
        func text(_ key: String) throws -> String {
            guard let value = arguments[key]?.string else { throw APIPlanError(code: .badArguments, message: "Missing argument \(key)") }
            return value
        }
        func direction(_ key: String) throws -> DirectionalAxis {
            guard let value = DirectionalAxis(rawValue: try text(key)) else {
                throw APIPlanError(code: .badArguments, message: "\(key) must be left, right, up, or down")
            }
            return value
        }
        switch method {
        case "server.version":
            return .version
        case "pane.search_paths":
            return .query(.searchPaths(id: UUID(), surfaceID: try pane().surfaceID, path: arguments["path"]?.string, query: arguments["query"]?.string ?? "", project: arguments["project"]?.bool ?? false))
        case "output.search":
            let session = try arguments["session"]?.string.map { try uuid(targets.session($0).id) }
            return .request(.searchOutput(id: UUID(), query: try text("query"), caseSensitive: arguments["case_sensitive"]?.bool ?? false, sessionID: session, offset: arguments["offset"]?.int ?? 0))
        case "setup.list": return .request(.library(.list))
        case "setup.capture":
            return .request(.library(.capture(sessionID: try uuid(targets.session(arguments["session"]?.string).id), name: try text("name"))))
        case "setup.save":
            guard let definition = arguments["definition"]?.object else {
                throw APIPlanError(code: .badArguments, message: "A setup definition is required")
            }
            let data = try JSONSerialization.data(withJSONObject: definition.mapValues(\.jsonValue))
            let setup = try JSONDecoder().decode(SavedSetup.self, from: data)
            try setup.validate()
            return .request(.library(.save(setup)))
        case "setup.open":
            guard let mode = SetupOpenMode(rawValue: arguments["mode"]?.string ?? "existing") else {
                throw APIPlanError(code: .badArguments, message: "mode must be existing or newCopy")
            }
            return .request(.library(.open(try uuid(text("id")), mode: mode)))
        case "setup.delete": return .request(.library(.deleteSetup(try uuid(text("id")))))
        case "closed.restore": return .request(.library(.restoreClosed(try uuid(text("id")))))
        case "closed.delete": return .request(.library(.deleteClosed(try arguments["id"]?.string.map(uuid))))
        case "attention.list":
            return .request(.listAttention)
        case "attention.read":
            return .request(.acknowledgeAttention(surfaceID: try pane().surfaceID))
        case "attention.snooze":
            return .request(.snoozeAttention(surfaceID: try pane().surfaceID, minutes: arguments["minutes"]?.int ?? 15))
        case "session.list":
            return .listSessions
        case "session.view":
            return .viewSession(try targets.session(arguments["session"]?.string).id)
        case "session.label":
            return .request(.renameSession(sessionID: try uuid(targets.session(arguments["session"]?.string).id), name: try text("name")))
        case "session.create":
            return .sessionCreate(name: arguments["name"]?.string, layout: try layout(arguments["layout"]))
        case "client.list":
            return .clientList
        case "client.disconnect":
            return .clientDisconnect(id: try targets.client(arguments["id"]?.string).id)
        case "tab.create":
            let session = try targets.session(arguments["session"]?.string)
            return .request(.newTab(workspaceID: try uuid(session.workspaceID), cwd: arguments["cwd"]?.string, shell: arguments["command"]?.string))
        case "tab.close":
            return .request(.closeTab(tabID: try uuid(targets.tab(arguments["tab"]?.string).id)))
        case "tab.label":
            return .request(.renameTab(tabID: try uuid(targets.tab(arguments["tab"]?.string).id), name: try text("title")))
        case "tab.move", "tab.focus":
            let tab = try targets.tab(arguments["tab"]?.string)
            let (workspace, id) = (try uuid(tab.workspaceID), try uuid(tab.id))
            if method == "tab.focus" { return .request(.selectTab(workspaceID: workspace, tabID: id)) }
            var index: Int?
            if let raw = arguments["index"] {
                guard case let .int(value) = raw, value >= 0 else {
                    throw APIPlanError(code: .badArguments, message: "index must be a non-negative integer")
                }
                index = value
            }
            if let session = arguments["session"]?.string {
                let destination = session == "new" ? nil : try uuid(targets.session(session).id)
                return .request(.moveTab(tabID: id, toSessionID: destination, index: index))
            }
            guard let index else { throw APIPlanError(code: .badArguments, message: "tab.move needs an index or a session") }
            return .request(.reorderTab(workspaceID: workspace, tabID: id, toIndex: index))
        case "pane.split":
            let tab = try targets.tab(arguments["tab"]?.string)
            // No explicit pane and no calling pane: split the tab's active pane.
            let anchor = arguments["pane"]?.string == nil && targets.environment.surface == nil ? nil : try pane().paneID
            let splitDirection = arguments["direction"]?.string ?? "vertical"
            guard splitDirection == "horizontal" || splitDirection == "vertical" else {
                throw APIPlanError(code: .badArguments, message: "direction must be horizontal or vertical")
            }
            return .split(
                tabID: tab.id, paneID: anchor, direction: splitDirection,
                command: arguments["command"]?.string, cwd: arguments["cwd"]?.string, layout: try layout(arguments["layout"])
            )
        case "pane.view":
            return .viewPane(surfaceID: try pane().surfaceID)
        case "pane.zoom":
            return .request(.zoomPane(paneID: try uuid(pane().paneID)))
        case "pane.focus":
            let target = try pane()
            return .request(.selectPane(tabID: try uuid(target.tabID), paneID: try uuid(target.paneID)))
        case "pane.label":
            return .request(.renameTab(tabID: try uuid(pane().tabID), name: try text("title")))
        case "pane.close":
            return .request(.killPane(paneID: try uuid(pane().paneID)))
        case "pane.reset":
            return .request(.resetSurface(surfaceID: try pane().surfaceID))
        case "pane.write":
            return .request(.send(surfaceID: try pane().surfaceID, text: try text("text")))
        case "pane.swap":
            let other = try targets.pane(arguments["with"]?.string)
            return .request(.swapPanes(srcPaneID: try uuid(pane().paneID), dstPaneID: try uuid(other.paneID)))
        case "pane.move":
            let destination = try targets.pane(arguments["to"]?.string)
            let zones: [String: PaneDropZone] = ["left": .left, "right": .right, "above": .top, "below": .bottom]
            let zone = arguments["side"]?.string.flatMap { zones[$0] }
            if arguments["side"] != nil, zone == nil {
                throw APIPlanError(code: .badArguments, message: "side must be left, right, above, or below")
            }
            let layoutDirection = zone?.direction ?? SplitDirection(rawValue: arguments["direction"]?.string ?? "horizontal") ?? .horizontal
            return .request(.joinPane(
                sourcePaneID: try uuid(pane().paneID), destPaneID: try uuid(destination.paneID),
                direction: layoutDirection, placement: zone?.placement ?? .after
            ))
        case "pane.detach":
            return .request(.breakPane(paneID: try uuid(pane().paneID)))
        case "pane.resize":
            let amount: Int
            if case let .int(value)? = arguments["amount"] { amount = value } else { amount = 1 }
            guard let resize = ResizeDirection(rawValue: try direction("direction").rawValue) else {
                throw APIPlanError(code: .badArguments, message: "direction must be left, right, up, or down")
            }
            return .request(.resizePane(paneID: try uuid(pane().paneID), direction: resize, amount: amount))
        case "pane.focus_direction":
            return .request(.selectPaneDirectional(currentPaneID: try uuid(pane().paneID), direction: try direction("direction")))
        case "pane.process":
            return .query(.processTree(surfaceID: try pane().surfaceID))
        case "pane.pwd", "pane.title", "pane.size", "pane.program_status":
            return .query(.paneQuery(surfaceID: try pane().surfaceID, kind: String(method.dropFirst("pane.".count))))
        case "pane.list_dir":
            return .query(.listDir(surfaceID: try pane().surfaceID, path: arguments["path"]?.string))
        case "pane.send_key":
            let tokens = try text("keys").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            return .sendKey(surfaceID: try pane().surfaceID, keys: tokens, hex: arguments["hex"]?.bool ?? false)
        case "pane.capture":
            let format = arguments["format"]?.string ?? "text"
            guard ["text", "html", "vt"].contains(format) else {
                throw APIPlanError(code: .badArguments, message: "format must be text, html, or vt")
            }
            return .capture(
                surfaceID: try pane().surfaceID, format: format, trim: arguments["trim"]?.bool ?? false,
                unwrap: arguments["unwrap"]?.bool ?? false, screen: arguments["screen"]?.bool ?? false
            )
        case "pane.wait":
            let until = arguments["until"]?.string ?? "child"
            guard until == "child" || until == "command" else {
                throw APIPlanError(code: .badArguments, message: "until must be child or command")
            }
            let timeout = arguments["timeout"]?.double ?? 30
            guard timeout > 0 else { throw APIPlanError(code: .badArguments, message: "timeout must be greater than 0") }
            return .wait(surfaceID: try pane().surfaceID, until: until, timeout: timeout)
        case "pane.theme":
            let theme = try text("theme")
            guard !theme.isEmpty else { throw APIPlanError(code: .badArguments, message: "Missing argument theme") }
            return .theme(surfaceID: try pane().surfaceID, theme: theme)
        default:
            // Any command the parser accepts, aliases included (`split-window`, `new-tab`…).
            let source = method + (arguments["args"]?.string.map { " " + $0 } ?? "")
            guard (try? CommandParser.parse(source)) != nil else {
                throw APIPlanError(code: .badArguments, message: "Unknown method \(method)")
            }
            return .verb(source)
        }
    }

    private static func uuid(_ id: String) throws -> UUID {
        guard let value = UUID(uuidString: id) else { throw APIPlanError(code: .ambiguous, message: "\(id) is not an id") }
        return value
    }

    private static func layout(_ raw: APIArgument?) throws -> APILayoutNode? {
        guard let raw else { return nil }
        switch LayoutTree.parse(raw) {
        case let .success(node): return node
        case let .failure(error): throw APIPlanError(code: .badArguments, message: error.message)
        }
    }

    /// `session.view`: the session and the tabs and panes inside it, or nil when it's gone.
    public static func sessionView(snapshot: SessionSnapshot, sessionID: String) -> APISessionView? {
        for workspace in snapshot.workspaces {
            guard let session = workspace.sessions.first(where: { $0.id.uuidString.caseInsensitiveCompare(sessionID) == .orderedSame })
            else { continue }
            let tabs = session.tabs.map { tab in
                let active = tab.activePaneID ?? tab.rootPane.allLeaves().first?.id
                return APISessionView.TabView(
                    id: tab.id.uuidString,
                    label: tab.title,
                    cwd: tab.cwd,
                    active: tab.id == session.activeTabID,
                    agent: tab.agent?.kind.commandToken,
                    panes: tab.rootPane.allLeaves().map {
                        APISessionView.PaneView(pane: $0.id.uuidString, surface: $0.surfaceID.uuidString, active: $0.id == active)
                    }
                )
            }
            return APISessionView(
                session: session.id.uuidString,
                label: session.name.isEmpty ? workspace.name : session.name,
                workspace: workspace.id.uuidString,
                activeTab: session.activeTabID?.uuidString,
                tabs: tabs
            )
        }
        return nil
    }

    public static func catalog(snapshot: SessionSnapshot, clients: [ClientSummary] = []) -> APICatalog {
        var sessions: [APISessionRecord] = []
        var tabs: [APITabRecord] = []
        var panes: [APIPaneRecord] = []
        for workspace in snapshot.workspaces {
            let workspaceID = workspace.id.uuidString
            for session in workspace.sessions {
                let label = SessionDisplayName.title(of: session, in: workspace)
                sessions.append(APISessionRecord(id: session.id.uuidString, label: label, workspaceID: workspaceID))
                for tab in session.tabs {
                    tabs.append(APITabRecord(id: tab.id.uuidString, sessionID: session.id.uuidString, label: tab.title, workspaceID: workspaceID))
                    let leaves = tab.rootPane.allLeaves()
                    for leaf in leaves {
                        panes.append(APIPaneRecord(
                            surfaceID: leaf.surfaceID.uuidString,
                            paneID: leaf.id.uuidString,
                            tabID: tab.id.uuidString,
                            sessionID: session.id.uuidString,
                            // A split pane has no label of its own; only a lone pane answers to the tab title.
                            label: leaves.count == 1 ? tab.title : ""
                        ))
                    }
                }
            }
        }
        let clientRows = clients.map { APIClientRecord(id: $0.id.uuidString, label: $0.label) }
        let workspace = snapshot.activeWorkspace
        let session = workspace?.sessions.first { $0.id == workspace?.activeSessionID }
        let tab = session?.activeTab
        let leaves = tab?.rootPane.allLeaves() ?? []
        let surface = (leaves.first { $0.id == tab?.activePaneID } ?? leaves.first)?.surfaceID
        return APICatalog(
            sessions: sessions, tabs: tabs, panes: panes, clients: clientRows,
            activeSession: session?.id.uuidString, activeTab: tab?.id.uuidString, activeSurface: surface?.uuidString
        )
    }

    public static func fileURL(path: String) -> String {
        if path.hasPrefix("file://") { return path }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://\(encoded)"
    }

    public static func upsertPaneTheme(_ profiles: [ProfileRule], surfaceID: String, theme: String) -> [ProfileRule] {
        var next = profiles.filter { $0.surface?.caseInsensitiveCompare(surfaceID) != .orderedSame }
        next.append(ProfileRule(surface: surfaceID, theme: theme))
        return next
    }

    private static func method(_ name: String, _ summary: String, _ parameters: APIJSONSchema, _ result: APIJSONSchema) -> APIMethod {
        APIMethod(name: name, summary: summary, parameters: parameters, result: result)
    }

    private static func object(_ properties: [String: APIJSONSchema], required: [String] = []) -> APIJSONSchema {
        APIJSONSchema(type: "object", properties: properties, required: required.isEmpty ? nil : required, additionalProperties: false)
    }

    private static func string(_ description: String) -> APIJSONSchema {
        APIJSONSchema(type: "string", description: description)
    }

    private static func bool(_ description: String) -> APIJSONSchema {
        APIJSONSchema(type: "boolean", description: description)
    }

    private static func int(_ description: String) -> APIJSONSchema {
        APIJSONSchema(type: "integer", description: description)
    }

    private static func number(_ description: String) -> APIJSONSchema {
        APIJSONSchema(type: "number", description: description)
    }

    private static func array(_ description: String) -> APIJSONSchema {
        APIJSONSchema(type: "array", description: description, items: APIJSONSchema(type: "object"))
    }

    private static func enumString(_ description: String, _ values: [String]) -> APIJSONSchema {
        APIJSONSchema(type: "string", description: description, enumValues: values)
    }
}

public struct APIPlanError: Error, Equatable {
    public var code: APIExit
    public var message: String
    public init(code: APIExit, message: String) {
        self.code = code
        self.message = message
    }
}

/// Resolves `api call` targets against a catalog: an explicit token (optionally prefixed
/// `session:` / `tab:` / `pane:` / `client:`), else the caller's `HARNESS_*` context, with
/// `TargetResolver`'s rules (id, label, position, id fragment).
struct APITargets {
    let catalog: APICatalog
    let environment: APIEnvironment

    // Positions count like the CLI's: sessions of the caller's workspace, tabs of its
    // session, panes of its tab. The caller is its `HARNESS_*` pane, else what the window shows.
    private var hereSurface: String? { environment.surface ?? catalog.activeSurface }
    private var hereTab: String? {
        environment.tab ?? catalog.panes.first { $0.surfaceID == hereSurface }?.tabID ?? catalog.activeTab
    }
    private var hereSession: String? {
        environment.session ?? catalog.tabs.first { $0.id == hereTab }?.sessionID ?? catalog.activeSession
    }

    func session(_ token: String?) throws -> APISessionRecord {
        let workspace = catalog.sessions.first { $0.id == hereSession }?.workspaceID
        let id = try resolve(token, kind: .session,
                             candidates: catalog.sessions.map { TargetCandidate(id: $0.id, labels: [$0.label]) },
                             positional: catalog.sessions.filter { workspace == nil || $0.workspaceID == workspace }.map(\.id))
        return catalog.sessions.first { $0.id == id }!
    }

    func tab(_ token: String?) throws -> APITabRecord {
        let id = try resolve(token, kind: .tab,
                             candidates: catalog.tabs.map { TargetCandidate(id: $0.id, labels: [$0.label]) },
                             positional: catalog.tabs.filter { $0.sessionID == hereSession }.map(\.id))
        return catalog.tabs.first { $0.id == id }!
    }

    func pane(_ token: String?) throws -> APIPaneRecord {
        let scope = catalog.panes.filter { $0.tabID == hereTab }
        let id = try resolve(token, kind: .pane,
                             candidates: catalog.panes.map { TargetCandidate(id: $0.surfaceID, otherIDs: [$0.paneID], labels: [$0.label]) },
                             positional: scope.map(\.surfaceID))
        return catalog.panes.first { $0.surfaceID == id }!
    }

    func client(_ token: String?) throws -> APIClientRecord {
        let id = try resolve(token, kind: .client,
                             candidates: catalog.clients.map { TargetCandidate(id: $0.id, labels: [$0.label]) },
                             positional: catalog.clients.map(\.id))
        return catalog.clients.first { $0.id == id }!
    }

    private func resolve(_ token: String?, kind: APITargetKind, candidates: [TargetCandidate], positional: [String]) throws -> String {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chosen = (trimmed?.isEmpty == false ? trimmed : nil) ?? fallback(kind) else {
            throw APIPlanError(code: .ambiguous, message: "Missing \(kind.rawValue)")
        }
        var needle = chosen
        for prefixed in [APITargetKind.session, .tab, .pane, .client] where chosen.lowercased().hasPrefix(prefixed.rawValue + ":") {
            guard prefixed == kind else {
                throw APIPlanError(code: .ambiguous, message: "\(chosen) is a \(prefixed.rawValue), not a \(kind.rawValue)")
            }
            needle = String(chosen.dropFirst(prefixed.rawValue.count + 1))
        }
        let resolverKind: TargetResolver.Kind = switch kind {
        case .session: .session
        case .tab: .tab
        case .pane, .client: .surface
        }
        switch TargetResolver.resolve(needle, kind: resolverKind, candidates: candidates, positional: positional) {
        case let .resolved(id): return id
        case let .ambiguous(text, matches):
            throw APIPlanError(code: .ambiguous, message: (["Ambiguous \(text)"] + matches).joined(separator: "\n"))
        case let .notFound(text):
            throw APIPlanError(code: .ambiguous, message: text)
        }
    }

    /// The caller's own pane/tab/session (`HARNESS_*`), else what the window is showing.
    private func fallback(_ kind: APITargetKind) -> String? {
        switch kind {
        case .session: return environment.session ?? catalog.activeSession
        case .tab: return environment.tab ?? catalog.activeTab
        case .pane: return environment.surface ?? catalog.activeSurface
        case .client: return nil
        }
    }
}
