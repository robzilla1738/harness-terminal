import Foundation
import CLua51
import HarnessCore

public struct ScriptInvocation: Equatable, Sendable {
    public var ran: Bool
    public var queued: [String]
    public var exitCode: Int
    public var message: String?

    public init(ran: Bool, queued: [String], exitCode: Int, message: String?) {
        self.ran = ran
        self.queued = queued
        self.exitCode = exitCode
        self.message = message
    }
}

public enum ScriptLoad: Equatable, Sendable {
    case loaded
    case syntax(String)
    case refused
}

public enum ScriptEngineError: Error {
    case open
}

/// Lua 5.1 with the standard library (`io`, `os`, `require`). Lives in the CLI, never the daemon.
public final class ScriptEngine {
    private let state: OpaquePointer
    private var pointer: UnsafeMutableRawPointer!
    public private(set) var keymap = ScriptKeymap()
    public private(set) var actions: [ScriptAction] = []
    public private(set) var warnings: [String] = []
    public private(set) var bindCount = 0
    public private(set) var removalCount = 0
    public private(set) var generation = 0
    public var poll: (() -> FollowEvent?)?
    /// Scripts (`harness-cli do -e …` / a script file) may register `harness.on` handlers.
    /// The config file may not: it is loaded to publish a keymap, and nothing runs after it.
    public var allowsHandlers = false
    /// `harness.stop(code)` was called; `stopCode` is its code (0 when omitted).
    public var isStopped: Bool { stopped }
    public private(set) var stopCode = 0
    public var hasHandlers: Bool { !handlerRefs.isEmpty }

    /// Commands queued with `harness.queue` outside an action (by a script's top level or a
    /// handler), handed over once.
    public func takeQueued() -> [String] {
        defer { guiQueue = [] }
        return guiQueue
    }
    /// `harness.call` and the generated `harness.pane.*` / `harness.tab.*` / … functions.
    /// The CLI runs them through `APIExecutor`; without it they return `nil, err, 4`.
    public var call: ((String, [String: APIArgument]) -> APIResult)?
    /// `harness.log(level, message)`. Defaults to stderr.
    public var log: ((String, String) -> Void)?
    public var tunnel = false
    public var remoteControlEnabled = false
    public var onHostsChanged: (() -> Void)?
    public let hosts: RemoteHostStore

    private var actionRefs: [String: Int32] = [:]
    private var functionRefs: [Int: Int32] = [:]
    private var handlerRefs: [String: [Int32]] = [:]
    private var nextFunction = 1
    private var sourcePath = ""
    private var stopped = false
    private var invokeDepth = 0
    private var guiQueue: [String] = []
    private static let globals = Int32(-10002)
    private static let registry = Int32(-10000)
    private static let upvalueEngine = Int32(-10003)
    private static let upvalueName = Int32(-10004)

    public init(hosts: RemoteHostStore = RemoteHostStore()) throws {
        guard let state = luaL_newstate() else { throw ScriptEngineError.open }
        self.state = state
        self.hosts = hosts
        pointer = Unmanaged.passUnretained(self).toOpaque()
        luaL_openlibs(state)
        installHarness()
        installGenerated()
    }

    deinit { lua_close(state) }

    public var fingerprint: String {
        let bindings = (keymap.root + keymap.modes.values.flatMap(\.bindings)).map { binding in
            binding.sequence.map(\.spec).joined(separator: ">") + "\t" + binding.source
        }
        return ScriptFingerprint.hash(bindings: bindings, actions: actions.map(\.name))
    }

    public func load(_ source: String, from path: String, replacingFileLayer: Bool) -> ScriptLoad {
        let savedKeymap = keymap
        let savedActions = actions
        let savedWarnings = warnings
        let savedBinds = bindCount
        let savedRemovals = removalCount
        if replacingFileLayer {
            keymap.remove(layer: .configFile)
            actions.removeAll { $0.source == path }
        }
        warnings = []
        bindCount = 0
        removalCount = 0
        sourcePath = path
        if let error = runChunk(source, name: path) {
            keymap = savedKeymap
            actions = savedActions
            warnings = savedWarnings
            bindCount = savedBinds
            removalCount = savedRemovals
            return .syntax(error)
        }
        generation += 1
        return .loaded
    }

    /// A remote reload does not parse and does not write the file.
    public func reload(file: URL, remote: Bool) -> ScriptLoad {
        if remote { return .refused }
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            return .syntax("cannot read \(file.path)")
        }
        return load(source, from: file.path, replacingFileLayer: true)
    }

    public static func check(path: String) -> ConfigReport {
        let exists = FileManager.default.fileExists(atPath: path)
        guard exists, let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ConfigReport(path: path, exists: exists, bindings: 0, removals: 0, modes: [], actions: [], warnings: [], syntaxError: exists ? "cannot read" : nil)
        }
        guard let engine = try? ScriptEngine() else {
            return ConfigReport(path: path, exists: true, bindings: 0, removals: 0, modes: [], actions: [], warnings: [], syntaxError: "lua failed to open")
        }
        switch engine.load(source, from: path, replacingFileLayer: false) {
        case .loaded:
            return ConfigReport(
                path: path,
                exists: true,
                bindings: engine.bindCount,
                removals: engine.removalCount,
                modes: engine.keymap.modes.keys.sorted(),
                actions: engine.actions.map(\.name).sorted(),
                warnings: engine.warnings + engine.keymap.warnings,
                syntaxError: nil
            )
        case let .syntax(message):
            return ConfigReport(path: path, exists: true, bindings: 0, removals: 0, modes: [], actions: [], warnings: [], syntaxError: message)
        case .refused:
            return ConfigReport(path: path, exists: true, bindings: 0, removals: 0, modes: [], actions: [], warnings: ["refused"], syntaxError: nil)
        }
    }

    public func invoke(name: String, arguments: [String: String], origin: ScriptOrigin) -> ScriptInvocation {
        guard let action = actions.last(where: { $0.name == name }) else {
            return ScriptInvocation(ran: false, queued: [], exitCode: 2, message: "Unknown action \(name)")
        }
        if let bad = ScriptArgs.reject(action.args, keys: Array(arguments.keys)) {
            return ScriptInvocation(ran: false, queued: [], exitCode: 2, message: "Unknown argument \(bad)")
        }
        if action.drivesGUI, !RemoteControlPolicy.allowsGUI(tunnel: tunnel, enabled: remoteControlEnabled) {
            return ScriptInvocation(ran: false, queued: [], exitCode: 1, message: "Remote Control is off")
        }
        if invokeDepth >= 16 {
            return ScriptInvocation(ran: false, queued: [], exitCode: 1, message: "invoke nested past 16")
        }
        guard let ref = actionRefs[name] else {
            return ScriptInvocation(ran: false, queued: [], exitCode: 1, message: "action \(name) has no run")
        }
        guiQueue = []
        invokeDepth += 1
        defer { invokeDepth -= 1 }
        setGlobal("HARNESS_ORIGIN", origin.rawValue)
        lua_rawgeti(state, Self.registry, ref)
        pushStringMap(arguments)
        if lua_pcall(state, 1, 0, 0) != 0 {
            let message = popString()
            guiQueue = []
            return ScriptInvocation(ran: true, queued: [], exitCode: 1, message: message)
        }
        return ScriptInvocation(ran: true, queued: guiQueue, exitCode: 0, message: nil)
    }

    public func invokeAll(name: String, arguments: [String: String], targets: [String], failFast: Bool, origin: ScriptOrigin) -> ScriptInvocation {
        var last = ScriptInvocation(ran: false, queued: [], exitCode: 2, message: "no targets")
        for target in targets {
            setGlobal("HARNESS_FOR", target)
            last = invoke(name: name, arguments: arguments, origin: origin)
            if last.exitCode != 0, failFast { return last }
        }
        return last
    }

    @discardableResult
    public func bind(_ spec: String, target: ScriptTarget, layer: ScriptLayer, source: String) -> String? {
        keymap.bind(spec: spec, target: target, layer: layer, source: source)
    }

    public func press(_ chord: ScriptChord) -> KeyDelivery {
        keymap.press(chord) { id in
            self.callFunction(id)
        }
    }

    /// Run handlers for events until `harness.stop`, the feed ending, or `deadline`.
    /// Returns when there is nothing left to wait for.
    public func runHandlers(
        until deadline: Date = .distantFuture,
        afterEach: () -> Void = {},
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        while !stopped, hasHandlers, Date() < deadline {
            if let event = poll?() {
                deliver(event)
                afterEach()
            } else {
                sleep(0.02)
            }
        }
    }

    public func deliver(_ event: FollowEvent) {
        for ref in (handlerRefs[event.type] ?? []) + (handlerRefs["*"] ?? []) {
            lua_rawgeti(state, Self.registry, ref)
            push(event)
            if lua_pcall(state, 1, 0, 0) != 0 { _ = popString() }
        }
    }

    public func stringGlobal(_ name: String) -> String? {
        lua_getfield(state, Self.globals, name)
        let value = Self.luaString(state, -1)
        lua_settop(state, -2)
        return value
    }

    public func numberGlobal(_ name: String) -> Double? {
        lua_getfield(state, Self.globals, name)
        guard lua_type(state, -1) == LUA_TNUMBER else {
            lua_settop(state, -2)
            return nil
        }
        let value = lua_tonumber(state, -1)
        lua_settop(state, -2)
        return value
    }

    private func callFunction(_ id: Int) -> Bool {
        guard let ref = functionRefs[id] else { return false }
        lua_rawgeti(state, Self.registry, ref)
        if lua_pcall(state, 0, 1, 0) != 0 {
            warnings.append(popString())
            return false
        }
        let consumed = lua_type(state, -1) == LUA_TBOOLEAN && lua_toboolean(state, -1) != 0
        lua_settop(state, -2)
        return consumed
    }

    private func installHarness() {
        lua_createtable(state, 0, 12)
        let table = lua_gettop(state)
        for name in ["bind", "unbind", "mode", "action", "on", "wait", "sleep", "stop", "host", "queue", "invoke", "call", "log"] {
            lua_pushlightuserdata(state, pointer)
            name.withCString { lua_pushstring(state, $0) }
            lua_pushcclosure(state, Self.trampoline, 2)
            lua_setfield(state, table, name)
        }
        lua_createtable(state, 0, 0)
        lua_setfield(state, table, "args")
        lua_setfield(state, Self.globals, "harness")
    }

    /// One function per API method (`harness.pane.split{…}` is `harness.call("pane.split", {…})`),
    /// generated from `HarnessAPI.methods` so Lua can't drift from the API, and the layout
    /// builders for `session.create` / `pane.split`. `horizontal` is side by side.
    private func installGenerated() {
        let names = HarnessAPI.methods.map(\.name).filter { $0.contains(".") }
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let prelude = """
        local h = harness
        for _, name in ipairs({ \(list) }) do
          local domain, verb = name:match("^(%a+)%.([%w_]+)$")
          h[domain] = h[domain] or {}
          h[domain][verb] = function(args) return h.call(name, args) end
        end
        local function split(direction)
          return function(ratio, ...)
            local children = { ... }
            if type(ratio) ~= "number" then table.insert(children, 1, ratio); ratio = 0.5 end
            return { direction = direction, ratio = ratio, children = children }
          end
        end
        h.layout = {
          pane = function(options) return options or {} end,
          horizontal = split("horizontal"),
          vertical = split("vertical"),
        }
        """
        if let error = runChunk(prelude, name: "harness") { warnings.append(error) }
    }

    /// `harness.args`: the script's `do --args '{json}'`.
    public func setArguments(_ arguments: [String: APIArgument]) {
        lua_getfield(state, Self.globals, "harness")
        Self.push(.object(arguments), state)
        lua_setfield(state, -2, "args")
        lua_settop(state, -2)
    }

    /// Runs the root Lua function bound to `spec` (`harness-cli do --binding`, from a key in
    /// the app). False when no function has that spec.
    public func runBinding(spec: String) -> Bool {
        guard let parsed = ScriptKey.parse(spec), parsed.mode == nil else { return false }
        let bound = keymap.root.last { binding in
            if case .function = binding.target { return binding.sequence == parsed.sequence }
            return false
        }
        guard let bound, case let .function(id) = bound.target else { return false }
        _ = callFunction(id)
        return true
    }

    private static let trampoline: @convention(c) (OpaquePointer?) -> Int32 = { state in
        guard let state, let raw = lua_touserdata(state, -10003) else { return 0 }
        let engine = Unmanaged<ScriptEngine>.fromOpaque(raw).takeUnretainedValue()
        guard let name = luaString(state, -10004) else { return 0 }
        return engine.perform(name, state)
    }

    private func perform(_ name: String, _ state: OpaquePointer) -> Int32 {
        switch name {
        case "bind": return luaBind(state)
        case "unbind": return luaUnbind(state)
        case "mode": return luaMode(state)
        case "action": return luaAction(state)
        case "on": return luaOn(state)
        case "wait": return luaWait(state)
        case "sleep": return luaSleep(state)
        case "stop":
            stopped = true
            stopCode = lua_type(state, 1) == LUA_TNUMBER ? Int(lua_tointeger(state, 1)) : 0
            return 0
        case "host": return luaHost(state)
        case "queue": return luaQueue(state)
        case "invoke": return luaInvoke(state)
        case "call": return luaCall(state)
        case "log": return luaLog(state)
        default: return 0
        }
    }

    private func luaBind(_ state: OpaquePointer) -> Int32 {
        guard let spec = Self.luaString(state, 1) else {
            note("bad bind")
            return 0
        }
        let target: ScriptTarget
        if Self.luaString(state, 2) != nil, let name = Self.luaString(state, 2) {
            guard ScriptKey.isActionName(name) else {
                note("bad bind \(spec)")
                return 0
            }
            target = .action(name)
        } else if lua_type(state, 2) == LUA_TTABLE, let mode = stringField(state, 2, "mode") {
            guard ScriptKey.isModeName(mode) else {
                note("bad bind \(spec)")
                return 0
            }
            target = .enter(mode)
        } else if lua_type(state, 2) == LUA_TFUNCTION {
            lua_pushvalue(state, 2)
            let ref = luaL_ref(state, Self.registry)
            let id = nextFunction
            nextFunction += 1
            functionRefs[id] = ref
            target = .function(id)
        } else {
            note("bad bind \(spec)")
            return 0
        }
        if let error = keymap.bind(spec: spec, target: target, layer: .configFile, source: sourcePath) {
            note(error)
            return 0
        }
        bindCount += 1
        return 0
    }

    private func luaUnbind(_ state: OpaquePointer) -> Int32 {
        guard let spec = Self.luaString(state, 1) else {
            note("bad unbind")
            return 0
        }
        if let error = keymap.unbind(spec: spec, layer: .configFile) {
            note(error)
            return 0
        }
        removalCount += 1
        return 0
    }

    private func luaMode(_ state: OpaquePointer) -> Int32 {
        guard let name = Self.luaString(state, 1) else {
            note("bad mode")
            return 0
        }
        var exclusive = false
        var once = false
        var unknown: String?
        if lua_type(state, 2) == LUA_TTABLE {
            let keys = tableKeys(state, 2)
            for key in keys where key != "exclusive" && key != "once" {
                unknown = key
            }
            exclusive = boolField(state, 2, "exclusive")
            once = boolField(state, 2, "once")
        }
        if let error = keymap.defineMode(name: name, exclusive: exclusive, once: once, unknownOption: unknown) {
            note(error)
        }
        return 0
    }

    private func luaAction(_ state: OpaquePointer) -> Int32 {
        guard lua_type(state, 1) == LUA_TTABLE, let name = stringField(state, 1, "name") else {
            note("bad action")
            return 0
        }
        guard ScriptKey.isActionName(name) else {
            note("bad action name \(name)")
            return 0
        }
        guard let title = stringField(state, 1, "title"), !title.isEmpty else {
            note("bad action \(name)")
            return 0
        }
        lua_getfield(state, 1, "run")
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            lua_settop(state, -2)
            note("bad action \(name)")
            return 0
        }
        let ref = luaL_ref(state, Self.registry)
        if let previous = actions.last(where: { $0.name == name }) {
            note("\(sourcePath) replaces \(previous.source) for action \(name)")
            actions.removeAll { $0.name == name }
        }
        actionRefs[name] = ref
        actions.append(ScriptAction(
            name: name,
            title: title,
            detail: stringField(state, 1, "description") ?? "",
            category: stringField(state, 1, "category") ?? "Actions",
            keywords: stringList(state, 1, "keywords"),
            args: argSchema(state, 1),
            repeats: boolField(state, 1, "repeats"),
            drivesGUI: boolField(state, 1, "gui"),
            source: sourcePath
        ))
        return 0
    }

    private func luaOn(_ state: OpaquePointer) -> Int32 {
        guard let event = Self.luaString(state, 1), lua_type(state, 2) == LUA_TFUNCTION else {
            note("bad on")
            return 0
        }
        guard allowsHandlers else {
            note("harness.on is for scripts (harness-cli do -e / a script file), not the config file")
            return 0
        }
        lua_pushvalue(state, 2)
        let ref = luaL_ref(state, Self.registry)
        handlerRefs[FollowEvent.canonicalType(event), default: []].append(ref)
        return 0
    }

    private func luaWait(_ state: OpaquePointer) -> Int32 {
        let timeout = timeoutSeconds(state)
        let kind = lua_type(state, 1)
        let result = ScriptWait.next(
            timeout: timeout,
            poll: { self.poll?() },
            accept: { event in self.accepts(event, kind: kind, state: state) },
            stopped: { self.stopped }
        )
        switch result {
        case let .success(event):
            if let code = ScriptWait.childExit(event) {
                lua_pushinteger(state, lua_Integer(code))
            } else {
                lua_pushstring(state, event.type)
            }
            lua_pushnil(state)
            return 2
        case .failure(.timeout):
            lua_pushnil(state)
            lua_pushstring(state, "timeout")
            return 2
        case .failure(.stopped):
            lua_pushnil(state)
            lua_pushstring(state, "stopped")
            return 2
        }
    }

    private func luaSleep(_ state: OpaquePointer) -> Int32 {
        let seconds = lua_tonumber(state, 1)
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        return 0
    }

    private func luaHost(_ state: OpaquePointer) -> Int32 {
        guard lua_type(state, 1) == LUA_TTABLE,
              let name = stringField(state, 1, "name"),
              let ssh = stringField(state, 1, "ssh"),
              let socket = stringField(state, 1, "socket")
        else {
            note("bad host")
            return 0
        }
        let result = hosts.upsert(RemoteHost(name: name, sshTarget: ssh, remoteSocketPath: socket))
        if result.saved { onHostsChanged?() }
        else { note("host \(name) was not saved") }
        return 0
    }

    private func luaQueue(_ state: OpaquePointer) -> Int32 {
        guard let name = Self.luaString(state, 1) else { return 0 }
        guiQueue.append(name)
        return 0
    }

    private func luaInvoke(_ state: OpaquePointer) -> Int32 {
        guard let name = Self.luaString(state, 1) else {
            lua_pushnil(state)
            lua_pushstring(state, "missing action")
            return 2
        }
        let arguments = lua_type(state, 2) == LUA_TTABLE ? stringFields(state, 2) : [:]
        let outcome = invoke(name: name, arguments: arguments, origin: .script)
        if outcome.exitCode == 0 {
            lua_pushboolean(state, 1)
            lua_pushnil(state)
        } else {
            lua_pushnil(state)
            lua_pushstring(state, outcome.message ?? "invoke failed")
        }
        return 2
    }

    /// `harness.call(method, args)`: the result table, or `nil, message, exit code`.
    private func luaCall(_ state: OpaquePointer) -> Int32 {
        func failure(_ message: String, _ code: APIExit) -> Int32 {
            lua_pushnil(state)
            lua_pushstring(state, message)
            lua_pushinteger(state, lua_Integer(code.rawValue))
            return 3
        }
        guard let method = Self.luaString(state, 1) else { return failure("harness.call needs a method name", .badArguments) }
        var arguments: [String: APIArgument] = [:]
        switch lua_type(state, 2) {
        case LUA_TNONE, LUA_TNIL: break
        case LUA_TTABLE:
            guard case let .object(fields)? = Self.argument(state, 2, depth: 0) else {
                return failure("\(method) arguments must be a table with named fields", .badArguments)
            }
            arguments = fields
        default:
            return failure("\(method) arguments must be a table", .badArguments)
        }
        guard let call else { return failure("harness.call needs a running daemon (harness-cli do)", .unreachable) }
        let result = call(method, arguments)
        guard let json = result.json else {
            return failure(result.message ?? "\(method) failed", APIExit(rawValue: Int(result.exitCode)) ?? .failed)
        }
        if let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) {
            Self.push(json: value, state)
        } else {
            lua_pushstring(state, json)
        }
        return 1
    }

    /// `harness.log([level,] message)`.
    private func luaLog(_ state: OpaquePointer) -> Int32 {
        let (level, message) = lua_gettop(state) >= 2
            ? (Self.luaString(state, 1) ?? "info", Self.luaString(state, 2) ?? "")
            : ("info", Self.luaString(state, 1) ?? "")
        if let log {
            log(level, message)
        } else {
            FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
        }
        return 0
    }

    /// A Lua value as an API argument. A table with keys 1…n is an array; any other table is
    /// an object. Functions and other values have no JSON form and are dropped.
    private static func argument(_ state: OpaquePointer, _ index: Int32, depth: Int) -> APIArgument? {
        let index = index > 0 ? index : lua_gettop(state) + index + 1
        switch lua_type(state, index) {
        case LUA_TSTRING:
            return luaString(state, index).map(APIArgument.string)
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(state, index) != 0)
        case LUA_TNUMBER:
            let number = lua_tonumber(state, index)
            return number.rounded() == number && abs(number) < 1e15 ? .int(Int(number)) : .double(number)
        case LUA_TTABLE:
            guard depth < 32 else { return nil }
            var fields: [String: APIArgument] = [:]
            var items: [Int: APIArgument] = [:]
            lua_pushnil(state)
            while lua_next(state, index) != 0 {
                if let value = argument(state, -1, depth: depth + 1) {
                    if lua_type(state, -2) == LUA_TNUMBER {
                        items[Int(lua_tonumber(state, -2))] = value
                    } else if lua_type(state, -2) == LUA_TSTRING, let key = luaString(state, -2) {
                        fields[key] = value
                    }
                }
                lua_settop(state, -2)
            }
            if fields.isEmpty, !items.isEmpty, items.keys.sorted() == Array(1...items.count) {
                return .array((1...items.count).compactMap { items[$0] })
            }
            for (key, value) in items { fields[String(key)] = value }
            return .object(fields)
        default:
            return nil
        }
    }

    private static func push(_ argument: APIArgument, _ state: OpaquePointer) {
        switch argument {
        case let .string(text): lua_pushstring(state, text)
        case let .int(number): lua_pushinteger(state, lua_Integer(number))
        case let .double(number): lua_pushnumber(state, number)
        case let .bool(flag): lua_pushboolean(state, flag ? 1 : 0)
        case let .array(items):
            lua_createtable(state, Int32(items.count), 0)
            for (offset, item) in items.enumerated() {
                push(item, state)
                lua_rawseti(state, -2, Int32(offset + 1))
            }
        case let .object(fields):
            lua_createtable(state, 0, Int32(fields.count))
            for (key, value) in fields {
                push(value, state)
                lua_setfield(state, -2, key)
            }
        }
    }

    /// A decoded JSON value as Lua. `null` becomes nil (absent from tables).
    private static func push(json value: Any, _ state: OpaquePointer) {
        switch value {
        case let text as String:
            lua_pushstring(state, text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                lua_pushboolean(state, number.boolValue ? 1 : 0)
            } else {
                lua_pushnumber(state, number.doubleValue)
            }
        case let items as [Any]:
            lua_createtable(state, Int32(items.count), 0)
            var slot: Int32 = 0
            for item in items where !(item is NSNull) {
                slot += 1
                push(json: item, state)
                lua_rawseti(state, -2, slot)
            }
        case let fields as [String: Any]:
            lua_createtable(state, 0, Int32(fields.count))
            for (key, item) in fields where !(item is NSNull) {
                push(json: item, state)
                lua_setfield(state, -2, key)
            }
        default:
            lua_pushnil(state)
        }
    }

    private func accepts(_ event: FollowEvent, kind: Int32, state: OpaquePointer) -> Bool {
        if kind == LUA_TSTRING {
            return event.type == Self.luaString(state, 1).map(FollowEvent.canonicalType)
        }
        if kind == LUA_TTABLE {
            // Every field in the filter must match: `type` against the event type, the rest
            // against the payload (`{ type = "terminal.child_exited", pane = id }`).
            let filter = stringFields(state, 1)
            guard !filter.isEmpty else { return false }
            return filter.allSatisfy { key, value in
                key == "type" ? event.type == FollowEvent.canonicalType(value) : event.payload[key]?.display == value
            }
        }
        if kind == LUA_TFUNCTION {
            lua_pushvalue(state, 1)
            push(event)
            if lua_pcall(state, 1, 1, 0) != 0 {
                _ = popString()
                return false
            }
            let matched = lua_toboolean(state, -1) != 0
            lua_settop(state, -2)
            return matched
        }
        return false
    }

    private func timeoutSeconds(_ state: OpaquePointer) -> TimeInterval {
        let options: Int32 = lua_type(state, 2) == LUA_TTABLE ? 2 : 0
        guard options != 0 else { return 30 }
        lua_getfield(state, options, "timeout")
        let value = lua_type(state, -1) == LUA_TNUMBER ? lua_tonumber(state, -1) : 30
        lua_settop(state, -2)
        return value
    }

    private func argSchema(_ state: OpaquePointer, _ table: Int32) -> ScriptArgSchema {
        lua_getfield(state, table, "args")
        defer { lua_settop(state, -2) }
        guard lua_type(state, -1) == LUA_TTABLE else { return .none }
        let args = lua_gettop(state)
        if stringField(state, args, "type") == "object" || luaTypeField(state, args, "properties") == LUA_TTABLE {
            let properties = tableKeys(child: state, args, "properties")
            let required = stringList(state, args, "required")
            return .schema(properties: properties, required: required)
        }
        var shorthand: [String: String] = [:]
        for key in tableKeys(state, args) {
            if let value = stringField(state, args, key) { shorthand[key] = value }
        }
        return shorthand.isEmpty ? .none : .shorthand(shorthand)
    }

    private func runChunk(_ source: String, name: String) -> String? {
        let bytes = Array(source.utf8)
        let loaded: Int32 = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            let pointer = base.assumingMemoryBound(to: CChar.self)
            return name.withCString { cname in
                luaL_loadbuffer(state, pointer, raw.count, cname)
            }
        }
        if loaded != 0 { return popString() }
        if lua_pcall(state, 0, 0, 0) != 0 { return popString() }
        return nil
    }

    private func note(_ message: String) { warnings.append(message) }

    private func popString() -> String {
        let message = Self.luaString(state, -1) ?? "lua error"
        lua_settop(state, -2)
        return message
    }

    private func setGlobal(_ name: String, _ value: String) {
        value.withCString { lua_pushstring(state, $0) }
        lua_setfield(state, Self.globals, name)
    }

    private func pushStringMap(_ fields: [String: String]) {
        lua_createtable(state, 0, Int32(fields.count))
        let table = lua_gettop(state)
        for (key, value) in fields {
            value.withCString { lua_pushstring(state, $0) }
            lua_setfield(state, table, key)
        }
    }

    private func push(_ event: FollowEvent) {
        lua_createtable(state, 0, Int32(event.payload.count + 1))
        let table = lua_gettop(state)
        event.type.withCString { lua_pushstring(state, $0) }
        lua_setfield(state, table, "type")
        for (key, value) in event.payload {
            switch value {
            case let .string(text):
                text.withCString { lua_pushstring(state, $0) }
            case let .int(number):
                lua_pushinteger(state, lua_Integer(number))
            case let .bool(flag):
                lua_pushboolean(state, flag ? 1 : 0)
            }
            lua_setfield(state, table, key)
        }
    }

    private func stringField(_ state: OpaquePointer, _ table: Int32, _ key: String) -> String? {
        lua_getfield(state, table, key)
        let value = Self.luaString(state, -1)
        lua_settop(state, -2)
        return value
    }

    private func boolField(_ state: OpaquePointer, _ table: Int32, _ key: String) -> Bool {
        lua_getfield(state, table, key)
        let value = lua_type(state, -1) == LUA_TBOOLEAN && lua_toboolean(state, -1) != 0
        lua_settop(state, -2)
        return value
    }

    private func luaTypeField(_ state: OpaquePointer, _ table: Int32, _ key: String) -> Int32 {
        lua_getfield(state, table, key)
        let kind = lua_type(state, -1)
        lua_settop(state, -2)
        return kind
    }

    private func tableKeys(_ state: OpaquePointer, _ table: Int32) -> [String] {
        var keys: [String] = []
        lua_pushnil(state)
        while lua_next(state, table) != 0 {
            if lua_type(state, -2) == LUA_TSTRING, let key = Self.luaString(state, -2) { keys.append(key) }
            lua_settop(state, -2)
        }
        return keys
    }

    private func tableKeys(child state: OpaquePointer, _ table: Int32, _ key: String) -> [String] {
        lua_getfield(state, table, key)
        guard lua_type(state, -1) == LUA_TTABLE else {
            lua_settop(state, -2)
            return []
        }
        let keys = tableKeys(state, lua_gettop(state))
        lua_settop(state, -2)
        return keys
    }

    private func stringList(_ state: OpaquePointer, _ table: Int32, _ key: String) -> [String] {
        lua_getfield(state, table, key)
        guard lua_type(state, -1) == LUA_TTABLE else {
            lua_settop(state, -2)
            return []
        }
        let list = lua_gettop(state)
        var values: [String] = []
        var index: Int32 = 1
        while true {
            lua_rawgeti(state, list, index)
            guard let value = Self.luaString(state, -1) else {
                lua_settop(state, -2)
                break
            }
            values.append(value)
            lua_settop(state, -2)
            index += 1
        }
        lua_settop(state, -2)
        return values
    }

    private func stringFields(_ state: OpaquePointer, _ table: Int32) -> [String: String] {
        var fields: [String: String] = [:]
        for key in tableKeys(state, table) {
            if let value = stringField(state, table, key) { fields[key] = value }
        }
        return fields
    }

    private static func luaString(_ state: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = lua_tolstring(state, index, nil) else { return nil }
        return String(cString: pointer)
    }
}
