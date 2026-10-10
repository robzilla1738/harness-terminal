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
    public var access: APIAccess

    public init(name: String, summary: String, parameters: APIJSONSchema, result: APIJSONSchema,
                access: APIAccess = .init(effect: .write, exposures: [.cli])) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.result = result
        self.access = access
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
    public var access: APIAccess

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case title, description, type, properties, required, additionalProperties, result, access
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
        method("pane.explain", "Insert bounded quoted output into a selected foreground agent using bracketed paste, without Enter", object(["pane": string("Source command pane"), "target": string("Selected agent pane"), "run": string("Selected current agent execution UUID")], required: ["target", "run"]), object([:])),
        method("pane.command_output", "Read the last completed OSC 133 command's bounded output with eviction and truncation flags", object(["pane": string("Canonical pane or surface target"), "maximum_bytes": int("Plain text byte limit, 1–65536; default 32768")]), object(["span": APIJSONSchema(type: "object"), "text": string("Plain output excerpt"), "evicted": bool("Command output has been evicted"), "truncated": bool("Output exceeds the requested bound")])),
        method("pane.resume_policy", "Explicit per-pane consent to submit the recorded conversation once when a fresh shell is restored", object(["pane": string("Target pane"), "run": string("Verified execution UUID, required when enabling"), "automatic": bool("Explicit automatic restore consent")], required: ["automatic"]), object(["ok": bool("Policy saved")])),
        method("pane.resume", "Prepare an exact recorded conversation; insert only into an unchanged fresh shell when its identity is supplied", object(["pane": string("Target fresh shell"), "run": string("Recorded execution UUID"), "fresh_shell_identity": string("Identity returned by preparation; omit to preview")], required: ["run"]), object(["command": string("Prepared command, never submitted"), "freshShellIdentity": string("Available only for a fresh shell"), "inserted": bool("Whether the command was inserted")])),
        method("pane.preview", "Create an adjacent loopback preview, or change an existing preview without replacing a shell", object(["pane": string("Target pane"), "url": string("HTTP or HTTPS loopback URL on the pane host"), "title": string("Optional title"), "update": bool("Update only an existing preview")], required: ["url"]), object(["pane": string("Preview pane UUID")])),
        method("pane.resources", "Sample CPU and RSS across the pane's process tree", object(["pane": string("Canonical pane or surface target")]), object(["processes": array("Generation-identified processes"), "intervalSeconds": APIJSONSchema(type: "number"), "sampledAt": APIJSONSchema(type: "number")])),
        method("pane.kill_tree", "Terminate a confirmed process tree after validating its root generation", object(["pane": string("Canonical pane target"), "generation": string("Root generation returned by pane.resources"), "confirmed": bool("Explicit confirmation that the shell and its programs will stop")], required: ["generation", "confirmed"]), object(["ok": bool("Signals sent")])),
        method("notification.status", "Inspect local notification policy and redacted delivery diagnostics", object([:]), APIJSONSchema(type: "object")),
        method("notification.configure", "Replace local typed notification policy; external destinations and captured content require explicit opt-in", object(["settings": APIJSONSchema(type: "object", description: "NotificationPolicySettings, including explicit sink consent and credential references", additionalProperties: true)], required: ["settings"]), APIJSONSchema(type: "object")),
        method("agent.mute", "Mute an exact execution, or agents in a pane when run is omitted", object(["pane": string("Canonical pane target"), "run": string("Optional execution UUID"), "muted": bool("Mute or unmute")], required: ["muted"]), APIJSONSchema(type: "object")),
        method("power.status", "Inspect daemon idle-sleep policy and observed wake duration", object([:]), APIJSONSchema(type: "object")),
        method("power.mode", "Override idle-sleep policy until auto or service restart; battery restrictions still apply", object(["mode": APIJSONSchema(type: "string", enumValues: ["auto", "on", "off"])], required: ["mode"]), APIJSONSchema(type: "object")),
        method("power.configure", "Save local idle-sleep settings with a backup", object(["keepWorkingAgentsAwake": bool("Hold idle sleep while agents work"), "allowOnBattery": bool("Explicit battery opt-in"), "graceSeconds": APIJSONSchema(type: "number", description: "Release grace from zero to 3600 seconds")], required: ["keepWorkingAgentsAwake", "allowOnBattery", "graceSeconds"]), APIJSONSchema(type: "object")),
        method("profile.list", "Local approved transcript profiles", object([:]), object(["profiles": array("Configured provider profiles")])),
        method("profile.configure", "Configure local approved transcript profiles with a backup", object(["settings": object(["profiles": APIJSONSchema(type: "array", items: object([
            "id": string("Stable profile UUID"), "name": string("Profile label"),
            "provider": APIJSONSchema(type: "string", enumValues: ["codex", "claude-code", "cursor"]),
            "transcriptRoots": APIJSONSchema(type: "array", items: APIJSONSchema(type: "string")),
            "pricing": APIJSONSchema(type: "array", items: object([
                "model": string("Observed model ID"), "currency": string("ISO currency"), "units": APIJSONSchema(type: "string", enumValues: ["per_million_tokens"]),
                "input": APIJSONSchema(type: "number"), "output": APIJSONSchema(type: "number"), "cachedInput": APIJSONSchema(type: "number"), "cacheCreation": APIJSONSchema(type: "number")
            ], required: ["model", "currency", "units", "input", "output"]))
        ], required: ["id", "name", "provider", "transcriptRoots"]))], required: ["profiles"])], required: ["settings"]), object(["ok": bool("Configuration saved")])),
        method("history.recover", "Retry encrypted history recovery after unlocking the local credential store", object([:]), object(["ok": bool("History recovery completed")])),
        method("usage.summary", "Observed profile usage and limit freshness; UTC day aggregates", object(["days": int("UTC days, 1–90")]), object(["profiles": array("Observed profile usage"), "from": APIJSONSchema(type: "number"), "to": APIJSONSchema(type: "number")])),
        method("digest.repositories", "Paginated per-repository retained activity and attributable usage, grouping linked worktrees by canonical Git common identity", object(["days": int("UTC days, 1–90"), "offset": int("Nonnegative repository report offset"), "limit": int("Page size, 1–100")]), object(["reports": array("Repository groups with retained totals, attributable usage and coverage warnings"), "nextOffset": int("Next repository page") ])),
        method("digest.get", "Deterministic activity totals and a bounded timeline", object(["days": int("UTC days, 1–90"), "surface": string("Optional recorded surface UUID")]), object(["totals": APIJSONSchema(type: "object"), "timeline": array("At most 200 recorded events"), "timelineTruncated": bool("More events contribute to totals than are displayed")])),
        method("summary.status", "Local opted-in provider configuration and complete model catalog freshness; credentials are references only", object([:]), object(["settings": APIJSONSchema(type: "object"), "catalogs": array("Successful model catalogs"), "refreshing": array("Provider UUIDs"), "failures": APIJSONSchema(type: "object")])),
        method("summary.configure", "Save reviewed AI settings with exact destination/content consent; automatic workspaces require separate opt-in", object(["settings": APIJSONSchema(type: "object", description: "Versioned AISettings with providers and automaticWorkspaces; never credential values")], required: ["settings"]), object(["settings": APIJSONSchema(type: "object")])),
        method("summary.models", "Explicitly refresh one provider catalog; preserve the selected model and last successful catalog", object(["provider": string("Provider UUID")], required: ["provider"]), object(["catalogs": array("Cached complete catalogs"), "refreshing": array("Provider UUIDs")])),
        method("summary.catalog", "Page one complete successful cached model catalog without network requests", object(["provider": string("Provider UUID"), "offset": int("Model offset"), "limit": int("Page size 1–500")], required: ["provider"]), object(["catalog": APIJSONSchema(type: "object"), "nextOffset": int("Next page")])),
        method("summary.generate", "Submit one bounded digest without tools or automatic billable retries; inspect the returned request UUID", object(["id": string("Stable submission UUID; reuse only for the same request"), "provider": string("Enabled provider UUID"), "workspace": string("Optional local workspace UUID; omitted means host"), "from": number("Unix seconds"), "to": number("Unix seconds")], required: ["id", "provider", "from", "to"]), object(["id": string("Submission UUID"), "state": string("Submitted/result state")])),
        method("summary.record", "Inspect one submission and encrypted result with provider/model provenance", object(["id": string("Submission UUID")], required: ["id"]), object(["state": string("Result state"), "output": APIJSONSchema(type: "object")])),
        method("summary.history", "Page retained local summary receipts/results; absent result text may have been purged by persistence opt-out", object(["offset": int("Page offset"), "limit": int("Page size 1–100")]), object(["records": array("Summary observations"), "nextOffset": int("Next page")])),
        method("summary.cancel", "Cancel an exact submission; uncertain delivery may already be billable", object(["id": string("Submission UUID")], required: ["id"]), object(["state": string("Last recorded state")])),
        method("agent.list", "Durable agent executions, distinct from provider conversations", object(["host": string("Recorded host UUID"), "surface": string("Recorded surface UUID"), "active": bool("Only live executions"), "offset": int("Nonnegative page offset"), "limit": int("Page size, 1–500")]), object(["runs": array("Executions"), "nextOffset": int("Next page offset when available"), "historyUnavailable": string("Unavailable-history reason when present")])),
        method("agent.session", "One execution and a page of anchored activity events", object(["host": string("Recorded host UUID"), "run": string("Harness execution UUID"), "offset": int("Nonnegative event offset"), "limit": int("Page size, 1–499")], required: ["run"]), object(["run": APIJSONSchema(type: "object"), "events": array("Activity events"), "nextOffset": int("Next page offset when available")])),
        method("server.version", "Daemon version", object([:]), object(["version": string("Marketing version"), "build": int("Build number")])),
        method("pane.search_paths", "Find files and directories on a pane’s host", object(["pane": string("Source pane"), "path": string("Directory"), "query": string("Fuzzy query"), "project": bool("Search project files")]), object(["root": string("Search root"), "entries": array("Matching paths")])),
        method("output.search", "Search retained output in open sessions (100 results per page)", object(["query": string("Literal text"), "case_sensitive": bool("Match case"), "session": string("Optional session scope"), "offset": int("Result offset")]), object(["matches": array("Matches with source and line locator"), "hasMore": bool("More results are available")])),
        method("output.search_filtered", "Search retained output with isolated regex and recorded execution filters (100 results per page); times select executions, not individual output lines", object(["query": string("Text or ICU regular expression"), "case_sensitive": bool("Match case"), "session": string("Optional session scope"), "offset": int("Result offset"), "generation": string("Page generation from prior result"), "regex": bool("Use an isolated bounded regex worker"), "agent": enumString("Recorded provider", AgentKind.allCases.map(\.rawValue)), "from": number("Execution overlap start, Unix seconds"), "to": number("Execution overlap end, Unix seconds")], required: ["query"]), object(["matches": array("Matches with source and line locator"), "hasMore": bool("More results available"), "generation": string("Page generation")])),
        method("policy.audit", "Read redacted evaluated hook decisions; delivery and actual tool execution are separate observations", object(["offset": int("Record offset"), "limit": int("Page size 1–100")]), object(["records": array("Bounded evaluated decisions without tool input, command text, repository or secrets"), "nextOffset": int("Next page"), "unavailable": string("History availability; unavailable keys retain bounded memory capture")])),
        method("schedule.list", "List explicitly configured local schedules and their latest workload observations", object(["offset": int("Record offset"), "limit": int("Page size 1–100")]), object(["schedules": array("Definitions, timezone, revision and next occurrence"), "occurrences": array("Latest outcomes"), "unavailable": string("Unavailable history or execution state")])),
        method("schedule.save", "Create or replace a reviewed local schedule; enabled execution is explicit and preserves normal provider approvals", object(["definition": object(["id": string("Schedule UUID"), "name": string("Display name"), "enabled": bool("Explicit opt-in to automatic execution"), "timezone": string("IANA timezone"), "workspaceID": string("Recorded host workspace UUID"), "provider": string("Provider kind; generic for other explicit executables"), "trigger": APIJSONSchema(type: "object", description: "ScheduleTrigger: once(at), cron(expression), agentEvent(kind, optional surfaceID/provider/profile), limitReset(profileID, window, acceptPredictedTime)"), "launch": object(["executable": string("Absolute executable"), "arguments": APIJSONSchema(type: "array", items: APIJSONSchema(type: "string")), "directory": string("Absolute working directory"), "profile": string("Harness profile label"), "environment": APIJSONSchema(type: "object", description: "Optional profile/locale overrides")], required: ["executable", "arguments", "directory", "profile"]), "input": string("Optional bounded initial stdin; never a command argument")], required: ["id", "name", "enabled", "timezone", "workspaceID", "provider", "trigger", "launch"]), "expectedRevision": int("Required for an existing schedule; omit for creation")], required: ["definition"]), object(["revision": int("Saved revision"), "nextAt": number("Next time, if known")])),
        method("schedule.delete", "Delete an inactive schedule at its reviewed revision", object(["id": string("Schedule UUID"), "expectedRevision": int("Reviewed revision")], required: ["id", "expectedRevision"]), object([:])),
        method("schedule.occurrences", "Page retained actual/missed/skipped schedule occurrences", object(["id": string("Schedule UUID"), "offset": int("Record offset"), "limit": int("Page size 1–100")], required: ["id"]), object(["occurrences": array("Recorded occurrence outcomes"), "nextOffset": int("Next page")])),
        method("schedule.cancel", "Request cancellation of one exact workload identity; only reaping establishes its outcome", object(["id": string("Occurrence/workload UUID")], required: ["id"]), object(["state": string("Last observed state")])),
        method("fanout.list", "List retained fan-out intent and last observed process outcomes", object(["offset": int("Record offset"), "limit": int("Page size, 1–100")]), object(["groups": array("Fan-out records"), "nextOffset": int("Next page")])),
        method("fanout.start", "Launch 1–8 provider processes against one pinned committed base, preserving their configured approval settings", object(["id": string("Durable operation UUID"), "directory": string("Repository directory"), "base": string("Optional explicit committed base; never includes uncommitted changes"), "workspace": string("Optional workspace UUID"), "prompt": string("Prepared stdin, at most 32 KiB"), "providers": APIJSONSchema(type: "array", items: object(["provider": APIJSONSchema(type: "string", enumValues: ["claude-code", "codex", "cursor"]), "profile": string("Harness profile label, default default"), "executable": string("Optional absolute provider executable"), "providerHome": string("Optional Claude/Codex configuration directory")], required: ["provider"])), "worktrees": bool("Use managed worktrees, default true; false explicitly shares the checkout")], required: ["id", "directory", "prompt", "providers"]), object(["id": string("Durable group ID"), "participants": array("Accepted workloads and partial failures")])),
        method("fanout.inspect", "Reconcile retained fan-out intent against actual host process receipts; never repeat a launch", object(["id": string("Group UUID")], required: ["id"]), object(["participants": array("Process outcomes and recovery details")])),
        method("fanout.cancel", "Request cancellation of exactly the recorded workloads; reaping determines completion", object(["id": string("Group UUID")], required: ["id"]), object(["participants": array("Cancellation observations")])),
        method("fanout.compare", "Compare committed, working-tree and untracked repository state against the pinned base; test results are explicit executions only", object(["id": string("Group UUID")], required: ["id"]), object(["repositories": APIJSONSchema(type: "object"), "failures": APIJSONSchema(type: "object")])),
        method("fanout.cleanup", "Remove only verified managed worktrees after workload exit, preserving changed files, active processes and unpushed work", object(["id": string("Group UUID")], required: ["id"]), object(["participants": array("Protected cleanup outcomes")])),
        method("fanout.test", "Run a user-specified test command once in an exited participant's directory, recording its actual process result", object(["id": string("Group UUID"), "participant": string("Participant UUID"), "operation": string("One-shot test UUID"), "executable": string("Absolute executable"), "arguments": APIJSONSchema(type: "array", items: APIJSONSchema(type: "string"))], required: ["id", "participant", "operation", "executable", "arguments"]), object(["participants": array("Explicit test records")])),
        method("worktree.list", "List durable managed worktree records", object(["offset": int("Record offset"), "limit": int("Page size, 1–100")]), object(["worktrees": array("Managed records"), "nextOffset": int("Next page offset")])),
        method("worktree.configure", "Set a local absolute parent directory for managed worktrees; omitted directory restores the private default", object(["directory": string("Optional absolute managed parent")]), object(["directory": string("Configured parent, if any")])),
        method("worktree.create", "Create a managed worktree at one pinned committed base; default requires a clean current checkout", object(["id": string("Operation/worktree UUID, retained for safe retry"), "directory": string("Repository working-tree directory"), "base": string("Explicit committed base; never includes uncommitted changes")], required: ["id", "directory"]), object(["id": string("Management UUID"), "directory": string("Created directory"), "baseCommit": string("Pinned commit"), "state": string("Creation outcome")])),
        method("worktree.inspect", "Inspect and reconcile a recorded partial operation", object(["id": string("Management UUID")], required: ["id"]), object(["state": string("Reconciled operation outcome")])),
        method("worktree.compare", "Compare committed, working-tree and untracked changes against the pinned base", object(["id": string("Management UUID")], required: ["id"]), object(["committed": APIJSONSchema(type: "object"), "workingTree": APIJSONSchema(type: "object"), "untrackedFiles": array("Untracked paths")])),
        method("worktree.difftool", "Prepare a quoted command for the user-configured Git difftool; execution stays explicit", object(["id": string("Management UUID")], required: ["id"]), object(["command": string("Prepared command; never automatically submitted")])),
        method("worktree.remove", "Remove only a verified managed worktree, protecting dirty files, active processes and unpushed new commits; branches remain addressable", object(["id": string("Management UUID")], required: ["id"]), object(["state": string("Cleanup outcome")])),
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
        APIMethod(
            name: name,
            summary: "Run the \(name) command (same as the : prompt and key bindings)",
            parameters: object(["args": string("The command's arguments, e.g. \"-h\" for split-window")]),
            result: object(["ok": bool("Applied")]),
            access: .init(effect: .write, exposures: [.cli, .lua])
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
            result: method.result,
            access: method.access
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
        struct Row: Encodable { var name: String; var summary: String; var access: APIAccess }
        let rows = methods.map { Row(name: $0.name, summary: $0.summary, access: $0.access) }
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
            try validate(.object(arguments), schema: spec.parameters, path: "arguments")
            return try plan(method, arguments, APITargets(catalog: catalog, environment: environment))
        } catch let failure as APIPlanError {
            return .failure(code: failure.code.rawValue, message: failure.message)
        } catch {
            return .failure(code: APIExit.failed.rawValue, message: "\(error)")
        }
    }

    private static func validate(_ value: APIArgument, schema: APIJSONSchema, path: String, depth: Int = 0) throws {
        guard depth <= 16 else { throw APIPlanError(code: .badArguments, message: "Arguments exceed the nesting limit") }
        var valid = false
        switch (schema.type, value) {
        case ("string", .string(let text)):
            valid = schema.enumValues?.contains(text) ?? true
        case ("integer", .int): valid = true
        case ("number", .int): valid = true
        case ("number", .double(let n)): valid = n.isFinite
        case ("boolean", .bool): valid = true
        case ("object", .object(let object)):
            valid = true
            for required in schema.required ?? [] where object[required] == nil {
                throw APIPlanError(code: .badArguments, message: "Missing argument " + path + "." + required)
            }
            for (key, item) in object {
                if let nested = schema.properties?[key] { try validate(item, schema: nested, path: path + "." + key, depth: depth + 1) }
                else if schema.additionalProperties == false { throw APIPlanError(code: .badArguments, message: "Unknown argument " + path + "." + key) }
            }
        case ("array", .array(let items)):
            valid = true
            if let nested = schema.items?.schema { for item in items { try validate(item, schema: nested, path: path + "[]", depth: depth + 1) } }
        default: break
        }
        guard valid else { throw APIPlanError(code: .badArguments, message: path + " must match its " + schema.type + " schema") }
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
        case "output.search", "output.search_filtered":
            let session = try arguments["session"]?.string.map { try uuid(targets.session($0).id) }
            if method == "output.search_filtered" {
                let filter = OutputSearchFilter(regex: arguments["regex"]?.bool ?? false, agent: arguments["agent"]?.string.flatMap(AgentKind.init(rawValue:)), from: arguments["from"]?.double.map { Date(timeIntervalSince1970: $0) }, to: arguments["to"]?.double.map { Date(timeIntervalSince1970: $0) })
                try filter.validate()
                return .request(.searchOutputFiltered(id: UUID(), query: try text("query"), caseSensitive: arguments["case_sensitive"]?.bool ?? false, sessionID: session, offset: arguments["offset"]?.int ?? 0, generation: arguments["generation"]?.string, filter: filter))
            }
            return .request(.searchOutput(id: UUID(), query: try text("query"), caseSensitive: arguments["case_sensitive"]?.bool ?? false, sessionID: session, offset: arguments["offset"]?.int ?? 0, generation: arguments["generation"]?.string))
        case "policy.audit": return .query(.activity(.hookPolicy(.audit(offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100))))
        case "summary.status", "summary.configure", "summary.models", "summary.catalog", "summary.generate", "summary.record", "summary.history", "summary.cancel":
            let operation: AISummaryOperation
            switch method {
            case "summary.status": operation = .status
            case "summary.configure":
                guard let value = arguments["settings"]?.object else { throw AISummaryError.configuration("Provide reviewed AISettings.") }
                let settings = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: value.mapValues(\.jsonValue))); try settings.validate(); operation = .configure(settings)
            case "summary.models": operation = .refreshModels(providerID: try uuid(text("provider")))
            case "summary.catalog": operation = .catalog(providerID: try uuid(text("provider")), offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 500)
            case "summary.generate":
                guard let from = arguments["from"]?.double, let to = arguments["to"]?.double else { throw AISummaryError.configuration("Provide the exact range in Unix seconds.") }
                operation = .generate(id: try uuid(text("id")), providerID: try uuid(text("provider")), workspaceID: try arguments["workspace"]?.string.map(uuid), from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
            case "summary.record": operation = .record(id: try uuid(text("id")))
            case "summary.cancel": operation = .cancel(id: try uuid(text("id")))
            default: operation = .history(offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100)
            }
            return .query(.activity(.aiSummaries(operation)))
        case "schedule.list", "schedule.save", "schedule.delete", "schedule.occurrences", "schedule.cancel":
            let operation: ScheduleOperation
            switch method {
            case "schedule.list": operation = .list(offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100)
            case "schedule.occurrences": operation = .occurrences(id: try uuid(text("id")), offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100)
            case "schedule.delete": operation = .delete(id: try uuid(text("id")), expectedRevision: arguments["expectedRevision"]?.int ?? 0)
            case "schedule.cancel": operation = .cancelOccurrence(id: try uuid(text("id")))
            default:
                guard let value = arguments["definition"]?.object else { throw ScheduleError.invalid("Provide the reviewed definition object.") }
                let definition = try JSONDecoder().decode(ScheduleDefinition.self, from: JSONSerialization.data(withJSONObject: value.mapValues(\.jsonValue)))
                try definition.validate(); operation = .save(definition: definition, expectedRevision: arguments["expectedRevision"]?.int)
            }
            return .query(.activity(.schedules(requestID: UUID(), operation: operation)))
        case "fanout.start", "fanout.list", "fanout.inspect", "fanout.cancel", "fanout.compare", "fanout.cleanup", "fanout.test":
            let operation: FanoutOperation
            switch method {
            case "fanout.list": operation = .list(offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100)
            case "fanout.start":
                guard let values = arguments["providers"]?.array else { throw FanoutError.invalid }
                let providers = try values.map { value -> FanoutProvider in
                    guard let fields = value.object, let raw = fields["provider"]?.string, let provider = AgentKind(rawValue: raw) else { throw FanoutError.invalid }
                    return FanoutProvider(provider: provider, executable: fields["executable"]?.string, profile: fields["profile"]?.string ?? "default", providerHome: fields["providerHome"]?.string)
                }
                operation = .start(id: try uuid(text("id")), directory: try text("directory"), base: arguments["base"]?.string,
                    workspaceID: try arguments["workspace"]?.string.map(uuid), prompt: try text("prompt"), providers: providers, managedWorktrees: arguments["worktrees"]?.bool ?? true)
            case "fanout.inspect": operation = .inspect(id: try uuid(text("id")))
            case "fanout.cancel": operation = .cancel(id: try uuid(text("id")))
            case "fanout.compare": operation = .compare(id: try uuid(text("id")))
            case "fanout.cleanup": operation = .cleanup(id: try uuid(text("id")))
            default:
                guard let values = arguments["arguments"]?.array else { throw FanoutError.invalid }
                let strings = try values.map { value -> String in guard let text = value.string else { throw FanoutError.invalid }; return text }
                operation = .test(id: try uuid(text("id")), participantID: try uuid(text("participant")), operationID: try uuid(text("operation")), executable: try text("executable"), arguments: strings)
            }
            return .query(.activity(.fanout(requestID: UUID(), operation: operation)))
        case "worktree.list", "worktree.configure", "worktree.create", "worktree.inspect", "worktree.compare", "worktree.difftool", "worktree.remove":
            let operation: WorktreeOperation
            switch method {
            case "worktree.list": operation = .list(offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100)
            case "worktree.configure": operation = .configure(WorktreeSettings(directory: arguments["directory"]?.string))
            case "worktree.create": operation = .create(id: try uuid(text("id")), directory: try text("directory"), base: arguments["base"]?.string)
            case "worktree.inspect": operation = .inspect(id: try uuid(text("id")))
            case "worktree.compare": operation = .compare(id: try uuid(text("id")))
            case "worktree.difftool": operation = .difftoolCommand(id: try uuid(text("id")))
            default: operation = .remove(id: try uuid(text("id")))
            }
            return .query(.activity(.worktrees(requestID: UUID(), operation: operation)))
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
            return .request(.listAttention(capabilities: [DaemonStats.agentIdentities]))
        case "pane.explain": return .request(.activity(.explain(sourceSurfaceID: try pane().surfaceID, targetSurfaceID: try targets.pane(text("target")).surfaceID, targetRunID: try uuid(text("run")))))
        case "pane.command_output": return .query(.activity(.commandOutput(surfaceID: try pane().surfaceID, maximumBytes: arguments["maximum_bytes"]?.int ?? 32768)))
        case "pane.resume_policy": return .request(.activity(.resumePolicy(surfaceID: try pane().surfaceID, runID: try arguments["run"].map { _ in try uuid(text("run")) }, automatic: arguments["automatic"]?.bool ?? false)))
        case "pane.resume": return .request(.activity(.resume(runID: try uuid(text("run")), surfaceID: try pane().surfaceID, freshShellIdentity: arguments["fresh_shell_identity"]?.string)))
        case "pane.preview":
            let specification = PreviewSpecification(url: try text("url"), title: arguments["title"]?.string)
            _ = try specification.validatedURL()
            return .request(.previewPane(surfaceID: try pane().surfaceID, specification: specification, updateExisting: arguments["update"]?.bool ?? false, capabilities: [DaemonStats.paneContent]))
        case "pane.resources": return .query(.activity(.resources(surfaceID: try pane().surfaceID)))
        case "pane.kill_tree":
            guard arguments["confirmed"]?.bool == true else { throw APIPlanError(code: .badArguments, message: "Confirm termination of the shell and its programs before signaling this tree") }
            return .request(.activity(.terminateTree(surfaceID: try pane().surfaceID, rootGeneration: try text("generation"))))
        case "notification.status": return .query(.activity(.notifications(.status)))
        case "notification.configure":
            guard let value = arguments["settings"]?.object else { throw APIPlanError(code: .badArguments, message: "Typed notification settings are required") }
            let data = try JSONSerialization.data(withJSONObject: value.mapValues(\.jsonValue))
            let settings = try JSONDecoder().decode(NotificationPolicySettings.self, from: data)
            try settings.validate()
            return .request(.activity(.notifications(.configure(settings))))
        case "agent.mute":
            let run = try arguments["run"]?.string.map(uuid)
            return .request(.activity(.notifications(.control(AgentNotificationControl(surfaceID: try pane().surfaceID, runID: run, muted: arguments["muted"]?.bool ?? false)))))
        case "power.status": return .query(.activity(.power(.status)))
        case "power.mode":
            guard let mode = AwakeMode(rawValue: try text("mode")) else { throw APIPlanError(code: .badArguments, message: "Power mode must be auto, on, or off") }
            return .request(.activity(.power(.mode(mode))))
        case "power.configure":
            let data = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.jsonValue))
            let settings = try JSONDecoder().decode(PowerSettings.self, from: data)
            try settings.validate()
            return .request(.activity(.power(.configure(settings))))
        case "profile.list": return .query(.activity(.configure(nil)))
        case "profile.configure":
            guard let value = arguments["settings"]?.object else { throw APIPlanError(code: .badArguments, message: "Typed profile settings are required") }
            let data = try JSONSerialization.data(withJSONObject: value.mapValues(\.jsonValue))
            let settings = try JSONDecoder().decode(ActivitySettings.self, from: data)
            try settings.validate()
            return .request(.activity(.configure(settings)))
        case "history.recover": return .request(.retryHistory)
        case "usage.summary", "digest.get", "digest.repositories":
            let days = arguments["days"]?.int ?? 1
            guard (1...90).contains(days) else { throw APIPlanError(code: .badArguments, message: "days must be 1–90") }
            let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400)
            let from = to.addingTimeInterval(-Double(days) * 86400)
            if method == "digest.repositories" { return .query(.activity(.repositoryDigest(requestID: UUID(), from: from, to: to, offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 20))) }
            if method == "usage.summary" { return .query(.activity(.usage(from: from, to: to))) }
            return .query(.activity(.digest(from: from, to: to, surfaceID: try arguments["surface"]?.string.map { try uuid($0).uuidString }, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])))
        case "agent.list":
            return .query(.activity(.list(hostID: try arguments["host"]?.string.map(uuid), surfaceID: try arguments["surface"]?.string.map { try uuid($0).uuidString }, activeOnly: arguments["active"]?.bool ?? false, offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 100, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])))
        case "agent.session":
            return .query(.activity(.session(hostID: try arguments["host"]?.string.map(uuid), runID: try uuid(text("run")), offset: arguments["offset"]?.int ?? 0, limit: arguments["limit"]?.int ?? 200, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])))
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
        APIMethod(name: name, summary: summary, parameters: parameters, result: result, access: .existing(name))
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
