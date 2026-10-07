import Foundation

public enum ScriptOrigin: String, Equatable, Sendable {
    case key, palette, cli, api, script
}

public enum ScriptArgSchema: Equatable, Sendable {
    case none
    /// Shorthand `name = "string"`. Every key the caller passes must be declared.
    case shorthand([String: String])
    /// JSON Schema object: property names plus the required subset.
    case schema(properties: [String], required: [String])
}

public struct ScriptAction: Equatable, Sendable, Codable {
    public var name: String
    public var title: String
    public var detail: String
    public var category: String
    public var keywords: [String]
    public var args: ScriptArgSchema
    public var repeats: Bool
    public var drivesGUI: Bool
    public var source: String

    public init(
        name: String,
        title: String,
        detail: String = "",
        category: String = "Actions",
        keywords: [String] = [],
        args: ScriptArgSchema = .none,
        repeats: Bool = false,
        drivesGUI: Bool = false,
        source: String
    ) {
        self.name = name
        self.title = title
        self.detail = detail
        self.category = category
        self.keywords = keywords
        self.args = args
        self.repeats = repeats
        self.drivesGUI = drivesGUI
        self.source = source
    }
}

extension ScriptArgSchema: Codable {
    private enum Kind: String, Codable { case none, shorthand, schema }
    private struct Box: Codable {
        var kind: Kind
        var shorthand: [String: String]?
        var properties: [String]?
        var required: [String]?
    }

    public init(from decoder: Decoder) throws {
        let box = try Box(from: decoder)
        switch box.kind {
        case .none: self = .none
        case .shorthand: self = .shorthand(box.shorthand ?? [:])
        case .schema: self = .schema(properties: box.properties ?? [], required: box.required ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            try Box(kind: .none, shorthand: nil, properties: nil, required: nil).encode(to: encoder)
        case let .shorthand(fields):
            try Box(kind: .shorthand, shorthand: fields, properties: nil, required: nil).encode(to: encoder)
        case let .schema(properties, required):
            try Box(kind: .schema, shorthand: nil, properties: properties, required: required).encode(to: encoder)
        }
    }
}

public enum ScriptArgs {
    /// The misspelled or undeclared key, if the call must not run.
    public static func reject(_ schema: ScriptArgSchema, keys: [String]) -> String? {
        switch schema {
        case .none:
            return keys.sorted().first
        case let .shorthand(fields):
            return keys.filter { fields[$0] == nil }.sorted().first
        case let .schema(properties, required):
            if let missing = required.filter({ !keys.contains($0) }).sorted().first {
                return missing
            }
            return keys.filter { !properties.contains($0) }.sorted().first
        }
    }
}

/// One action or blocked binding the GUI can replay. Function bindings stay in the CLI.
public struct ScriptBindingRecord: Equatable, Sendable, Codable {
    public var spec: String
    public var action: String?
    public var blocked: Bool
    public var enter: String?
    public var layer: Int
    public var source: String

    public init(
        spec: String,
        action: String? = nil,
        blocked: Bool = false,
        enter: String? = nil,
        layer: Int,
        source: String
    ) {
        self.spec = spec
        self.action = action
        self.blocked = blocked
        self.enter = enter
        self.layer = layer
        self.source = source
    }
}

public struct ScriptModeRecord: Equatable, Sendable, Codable {
    public var name: String
    public var exclusive: Bool
    public var once: Bool

    public init(name: String, exclusive: Bool, once: Bool) {
        self.name = name
        self.exclusive = exclusive
        self.once = once
    }
}

public struct ScriptManifest: Equatable, Sendable, Codable {
    public var generation: Int
    public var hash: String
    public var actions: [ScriptAction]
    public var bindingCount: Int
    public var bindings: [ScriptBindingRecord]
    public var modes: [ScriptModeRecord]

    public init(
        generation: Int,
        hash: String,
        actions: [ScriptAction],
        bindingCount: Int,
        bindings: [ScriptBindingRecord] = [],
        modes: [ScriptModeRecord] = []
    ) {
        self.generation = generation
        self.hash = hash
        self.actions = actions
        self.bindingCount = bindingCount
        self.bindings = bindings
        self.modes = modes
    }

    private enum CodingKeys: String, CodingKey {
        case generation, hash, actions, bindingCount, bindings, modes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(Int.self, forKey: .generation)
        hash = try container.decode(String.self, forKey: .hash)
        actions = try container.decode([ScriptAction].self, forKey: .actions)
        bindingCount = try container.decode(Int.self, forKey: .bindingCount)
        bindings = try container.decodeIfPresent([ScriptBindingRecord].self, forKey: .bindings) ?? []
        modes = try container.decodeIfPresent([ScriptModeRecord].self, forKey: .modes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(hash, forKey: .hash)
        try container.encode(actions, forKey: .actions)
        try container.encode(bindingCount, forKey: .bindingCount)
        try container.encode(bindings, forKey: .bindings)
        try container.encode(modes, forKey: .modes)
    }
}

public enum ScriptStore {
    public static var url: URL {
        HarnessPaths.sessionsDirectory.appendingPathComponent("script.json")
    }

    public static func load(from url: URL = url) -> ScriptManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScriptManifest.self, from: data)
    }

    public static func save(_ manifest: ScriptManifest, to url: URL = url) throws {
        try HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard HarnessPaths.atomicWrite(data, to: url, label: "ScriptStore") else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public enum ScriptPalette {
    public static func rows(actions: [ScriptAction]) -> [(id: String, title: String, category: String)] {
        actions.map { ("script.\($0.name)", $0.title, $0.category.isEmpty ? "Actions" : $0.category) }
    }
}

public enum ScriptFingerprint {
    public static func hash(bindings: [String], actions: [String]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in (bindings + actions).joined(separator: "\n").utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}

public enum ScriptWaitError: Equatable, Error, Sendable {
    case timeout
    case stopped
}

public enum ScriptWait {
    public static func childExit(_ event: FollowEvent) -> Int? {
        guard event.type == "terminal.child_exited" else { return nil }
        if case let .int(code)? = event.payload["exit"] { return code }
        return nil
    }

    /// Poll until an event is accepted, the clock passes `timeout`, or `stopped` is set.
    /// The default sleeper is a real sleep. A 1-second timeout with no event is `.timeout`.
    public static func next(
        timeout: TimeInterval,
        poll: () -> FollowEvent?,
        accept: (FollowEvent) -> Bool,
        stopped: () -> Bool = { false },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = Date.init
    ) -> Result<FollowEvent, ScriptWaitError> {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if stopped() { return .failure(.stopped) }
            if let event = poll(), accept(event) { return .success(event) }
            if now() >= deadline { return .failure(.timeout) }
            let slice = min(0.05, deadline.timeIntervalSince(now()))
            if slice > 0 { sleep(slice) }
        }
    }
}

/// Local clients may drive GUI actions. A tunneled client may not, until Remote Control is on.
public enum RemoteControlPolicy {
    public static func allowsGUI(tunnel: Bool, enabled: Bool) -> Bool {
        if !tunnel { return true }
        return enabled
    }
}

public enum ScriptConfigPath {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let override = environment["HARNESS_CONFIG"], !override.isEmpty { return override }
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = (xdg as NSString).expandingTildeInPath
        } else {
            base = (home as NSString).appendingPathComponent(".config")
        }
        return (base as NSString).appendingPathComponent("harness/init.lua")
    }
}

public struct ConfigReport: Equatable, Sendable {
    public var path: String
    public var exists: Bool
    public var bindings: Int
    public var removals: Int
    public var modes: [String]
    public var actions: [String]
    public var warnings: [String]
    public var syntaxError: String?

    public init(
        path: String,
        exists: Bool,
        bindings: Int,
        removals: Int,
        modes: [String],
        actions: [String],
        warnings: [String],
        syntaxError: String?
    ) {
        self.path = path
        self.exists = exists
        self.bindings = bindings
        self.removals = removals
        self.modes = modes
        self.actions = actions
        self.warnings = warnings
        self.syntaxError = syntaxError
    }

    public var text: String {
        var lines = [
            "path: \(path)",
            "exists: \(exists)",
            "bindings: \(bindings)",
            "removals: \(removals)",
            "modes: \(modes.joined(separator: " "))",
            "actions: \(actions.joined(separator: " "))",
        ]
        for warning in warnings { lines.append("warning: \(warning)") }
        if let syntaxError { lines.append("syntax: \(syntaxError)") }
        return lines.joined(separator: "\n")
    }
}
