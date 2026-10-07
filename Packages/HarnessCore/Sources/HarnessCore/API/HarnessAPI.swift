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

    public var string: String? {
        if case let .string(value) = self { return value }
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
    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct APITabRecord: Equatable, Sendable {
    public var id: String
    public var sessionID: String
    public var label: String
    public init(id: String, sessionID: String, label: String) {
        self.id = id
        self.sessionID = sessionID
        self.label = label
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

public struct APICatalog: Equatable, Sendable {
    public var sessions: [APISessionRecord]
    public var tabs: [APITabRecord]
    public var panes: [APIPaneRecord]
    public var clients: [APIClientRecord]

    public init(
        sessions: [APISessionRecord] = [],
        tabs: [APITabRecord] = [],
        panes: [APIPaneRecord] = [],
        clients: [APIClientRecord] = []
    ) {
        self.sessions = sessions
        self.tabs = tabs
        self.panes = panes
        self.clients = clients
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

public enum APIResolution: Equatable, Sendable {
    case found(String)
    case missing(String)
    case ambiguous(query: String, matches: [String])
}

public enum APIPlan: Equatable, Sendable {
    case failure(code: Int, message: String)
    case version
    case listSessions
    case viewSession(String)
    case split(tabID: String, paneID: String?, direction: String, command: String?, cwd: String?, layout: APILayoutNode?)
    case sessionCreate(name: String?, layout: APILayoutNode?)
    case clientList
    case clientDisconnect(id: String)
    /// A bindable verb that `api list` publishes. Calling it does not invent a mutation.
    case verb(String)
    case zoom(paneID: String)
    case focus(tabID: String, paneID: String)
    case label(tabID: String, title: String)
    case close(paneID: String)
    case write(surfaceID: String, text: String)
    case sendKey(surfaceID: String, keys: [String], hex: Bool)
    case capture(surfaceID: String, format: String, trim: Bool, unwrap: Bool)
    case process(surfaceID: String)
    case pwd(surfaceID: String)
    case listDir(surfaceID: String, path: String?)
    case title(surfaceID: String)
    case size(surfaceID: String)
    case programStatus(surfaceID: String)
    case wait(surfaceID: String, until: String, timeout: Double)
    case theme(surfaceID: String, theme: String)
    case reset(surfaceID: String)
}

public enum HarnessAPI {
    public static let schemaURL = "https://json-schema.org/draft/2020-12/schema"

    public static let methods: [APIMethod] = [
        method("server.version", "Daemon version", object([:]), object(["version": string("Marketing version"), "build": int("Build number")])),
        method("session.list", "List sessions", object([:]), object(["sessions": array("Sessions")])),
        method("session.view", "One session and its tabs", object(["session": string("Session id or label")]), object(["session": string("Session id")])),
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
    ] + CommandParser.knownVerbs.map { name in
        method(
            name,
            "Bindable command \(name)",
            APIJSONSchema(type: "object", additionalProperties: true),
            object(["listed": bool("The verb is in the bindable catalog")])
        )
    }

    public static func method(named name: String) -> APIMethod? {
        methods.first { $0.name == name }
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
        switch method {
        case "server.version":
            return .version
        case "session.list":
            return .listSessions
        case "session.view":
            let resolution = resolve(arguments["session"]?.string, kind: .session, catalog: catalog, environment: environment)
            if case let .found(id) = resolution { return .viewSession(id) }
            return fail(resolution)
        case "pane.split":
            let tab = resolve(arguments["tab"]?.string, kind: .tab, catalog: catalog, environment: environment)
            let pane = arguments["pane"]?.string == nil && environment.surface == nil
                ? nil
                : resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment)
            guard case let .found(tabID) = tab else { return fail(tab) }
            if let pane, case .found = pane {} else if let pane { return fail(pane) }
            let paneID: String? = {
                if case let .found(id)? = pane { return catalog.panes.first { $0.surfaceID == id || $0.paneID == id }?.paneID }
                return nil
            }()
            let direction = arguments["direction"]?.string ?? "vertical"
            guard direction == "horizontal" || direction == "vertical" else {
                return .failure(code: APIExit.badArguments.rawValue, message: "direction must be horizontal or vertical")
            }
            let layout: APILayoutNode?
            if let raw = arguments["layout"] {
                switch LayoutTree.parse(raw) {
                case let .success(node): layout = node
                case let .failure(error):
                    return .failure(code: APIExit.badArguments.rawValue, message: error.message)
                }
            } else {
                layout = nil
            }
            return .split(
                tabID: tabID, paneID: paneID, direction: direction,
                command: arguments["command"]?.string, cwd: arguments["cwd"]?.string, layout: layout
            )
        case "session.create":
            let layout: APILayoutNode?
            if let raw = arguments["layout"] {
                switch LayoutTree.parse(raw) {
                case let .success(node): layout = node
                case let .failure(error):
                    return .failure(code: APIExit.badArguments.rawValue, message: error.message)
                }
            } else {
                layout = nil
            }
            return .sessionCreate(name: arguments["name"]?.string, layout: layout)
        case "client.list":
            return .clientList
        case "client.disconnect":
            guard let id = arguments["id"]?.string, !id.isEmpty else {
                return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument id")
            }
            return .clientDisconnect(id: id)
        case "pane.list_dir":
            let path = arguments["path"]?.string
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .listDir(surfaceID: pane.surfaceID, path: path)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.zoom", "pane.focus", "pane.close", "pane.process", "pane.pwd", "pane.title", "pane.size", "pane.program_status", "pane.reset":
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                switch method {
                case "pane.zoom": return .zoom(paneID: pane.paneID)
                case "pane.focus": return .focus(tabID: pane.tabID, paneID: pane.paneID)
                case "pane.close": return .close(paneID: pane.paneID)
                case "pane.process": return .process(surfaceID: pane.surfaceID)
                case "pane.pwd": return .pwd(surfaceID: pane.surfaceID)
                case "pane.title": return .title(surfaceID: pane.surfaceID)
                case "pane.size": return .size(surfaceID: pane.surfaceID)
                case "pane.program_status": return .programStatus(surfaceID: pane.surfaceID)
                default: return .reset(surfaceID: pane.surfaceID)
                }
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.label":
            guard let title = arguments["title"]?.string else {
                return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument title")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .label(tabID: pane.tabID, title: title)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.write":
            guard let text = arguments["text"]?.string else {
                return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument text")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .write(surfaceID: pane.surfaceID, text: text)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.send_key":
            guard let keys = arguments["keys"]?.string else {
                return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument keys")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                let tokens = keys.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                return .sendKey(surfaceID: pane.surfaceID, keys: tokens, hex: arguments["hex"]?.bool ?? false)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.capture":
            let format = arguments["format"]?.string ?? "text"
            guard ["text", "html", "vt"].contains(format) else {
                return .failure(code: APIExit.badArguments.rawValue, message: "format must be text, html, or vt")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .capture(
                    surfaceID: pane.surfaceID,
                    format: format,
                    trim: arguments["trim"]?.bool ?? false,
                    unwrap: arguments["unwrap"]?.bool ?? false
                )
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.wait":
            let until = arguments["until"]?.string ?? "child"
            guard until == "child" || until == "command" else {
                return .failure(code: APIExit.badArguments.rawValue, message: "until must be child or command")
            }
            let timeout = arguments["timeout"]?.double ?? 30
            guard timeout > 0 else {
                return .failure(code: APIExit.badArguments.rawValue, message: "timeout must be greater than 0")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .wait(surfaceID: pane.surfaceID, until: until, timeout: timeout)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        case "pane.theme":
            guard let theme = arguments["theme"]?.string, !theme.isEmpty else {
                return .failure(code: APIExit.badArguments.rawValue, message: "Missing argument theme")
            }
            switch resolve(arguments["pane"]?.string, kind: .pane, catalog: catalog, environment: environment) {
            case let .found(id):
                guard let pane = paneRecord(id, catalog: catalog) else {
                    return .failure(code: APIExit.ambiguous.rawValue, message: "No pane \(id)")
                }
                return .theme(surfaceID: pane.surfaceID, theme: theme)
            case let .missing(message):
                return .failure(code: APIExit.ambiguous.rawValue, message: message)
            case let .ambiguous(query, matches):
                return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
            }
        default:
            if CommandParser.knownVerbs.contains(method) {
                return .verb(method)
            }
            return .failure(code: APIExit.badArguments.rawValue, message: "Unknown method \(method)")
        }
    }

    public static func catalog(snapshot: SessionSnapshot, clients: [ClientSummary] = []) -> APICatalog {
        var sessions: [APISessionRecord] = []
        var tabs: [APITabRecord] = []
        var panes: [APIPaneRecord] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                let label = session.name.isEmpty ? workspace.name : session.name
                sessions.append(APISessionRecord(id: session.id.uuidString, label: label))
                for tab in session.tabs {
                    tabs.append(APITabRecord(id: tab.id.uuidString, sessionID: session.id.uuidString, label: tab.title))
                    for leaf in tab.rootPane.allLeaves() {
                        panes.append(APIPaneRecord(
                            surfaceID: leaf.surfaceID.uuidString,
                            paneID: leaf.id.uuidString,
                            tabID: tab.id.uuidString,
                            sessionID: session.id.uuidString,
                            label: tab.title
                        ))
                    }
                }
            }
        }
        let clientRows = clients.map { APIClientRecord(id: $0.id.uuidString, label: $0.label) }
        return APICatalog(sessions: sessions, tabs: tabs, panes: panes, clients: clientRows)
    }

    public static func resolve(_ token: String?, kind: APITargetKind, catalog: APICatalog, environment: APIEnvironment) -> APIResolution {
        let raw = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (raw?.isEmpty == false ? raw : nil) ?? environmentDefault(kind, environment)
        guard let chosen, !chosen.isEmpty else {
            return .missing("Missing \(kind.rawValue)")
        }
        let (prefix, body) = splitPrefix(chosen)
        if let prefix, prefix != kind {
            return .missing("\(chosen) is a \(prefix.rawValue), not a \(kind.rawValue)")
        }
        let needle = body
        switch kind {
        case .session:
            return resolveID(needle, ids: catalog.sessions.map(\.id), labels: catalog.sessions.map { ($0.label, $0.id) })
        case .tab:
            return resolveID(needle, ids: catalog.tabs.map(\.id), labels: catalog.tabs.map { ($0.label, $0.id) })
        case .pane:
            let ids = catalog.panes.flatMap { [$0.surfaceID, $0.paneID] }
            if let exact = ids.first(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
                return .found(exact)
            }
            let labeled = catalog.panes.filter { $0.label.caseInsensitiveCompare(needle) == .orderedSame }
            if labeled.count == 1 { return .found(labeled[0].surfaceID) }
            if labeled.count > 1 {
                return .ambiguous(query: needle, matches: labeled.map(\.surfaceID))
            }
            return .missing("No \(kind.rawValue) \(needle)")
        case .client:
            return resolveID(needle, ids: catalog.clients.map(\.id), labels: catalog.clients.map { ($0.label, $0.id) })
        }
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

    public static func ambiguousMessage(query: String, matches: [String]) -> String {
        (["Ambiguous \(query)"] + matches).joined(separator: "\n")
    }

    private static func environmentDefault(_ kind: APITargetKind, _ environment: APIEnvironment) -> String? {
        switch kind {
        case .session: return environment.session
        case .tab: return environment.tab
        case .pane: return environment.surface
        case .client: return nil
        }
    }

    private static func splitPrefix(_ token: String) -> (APITargetKind?, String) {
        let prefixes: [(String, APITargetKind)] = [
            ("session:", .session), ("tab:", .tab), ("pane:", .pane), ("client:", .client),
        ]
        for (prefix, kind) in prefixes where token.lowercased().hasPrefix(prefix) {
            return (kind, String(token.dropFirst(prefix.count)))
        }
        return (nil, token)
    }

    private static func resolveID(_ needle: String, ids: [String], labels: [(String, String)]) -> APIResolution {
        if let exact = ids.first(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
            return .found(exact)
        }
        let labeled = labels.filter { $0.0.caseInsensitiveCompare(needle) == .orderedSame }
        if labeled.count == 1 { return .found(labeled[0].1) }
        if labeled.count > 1 { return .ambiguous(query: needle, matches: labeled.map(\.1)) }
        return .missing("No match \(needle)")
    }

    private static func paneRecord(_ id: String, catalog: APICatalog) -> APIPaneRecord? {
        catalog.panes.first { $0.surfaceID.caseInsensitiveCompare(id) == .orderedSame || $0.paneID.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func fail(_ resolution: APIResolution) -> APIPlan {
        switch resolution {
        case let .missing(message):
            return .failure(code: APIExit.ambiguous.rawValue, message: message)
        case let .ambiguous(query, matches):
            return .failure(code: APIExit.ambiguous.rawValue, message: ambiguousMessage(query: query, matches: matches))
        case .found:
            return .failure(code: APIExit.failed.rawValue, message: "Unresolved target")
        }
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
