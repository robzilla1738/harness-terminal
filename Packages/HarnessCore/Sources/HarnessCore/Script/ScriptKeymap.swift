import Foundation

/// Where a binding came from. Higher wins: client defaults, then the config file, then the in-app recorder.
public enum ScriptLayer: Int, Comparable, Sendable {
    case clientDefault = 0
    case configFile = 1
    case recorder = 2

    public static func < (lhs: ScriptLayer, rhs: ScriptLayer) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ScriptTarget: Equatable, Sendable {
    case action(String)
    case function(Int)
    case blocked
    /// Enter a mode. A mode binding cannot use this; the root binding can, and it round-trips to the GUI.
    case enter(String)
    /// A Lua function binding as the app replays it: the key is consumed and the function
    /// runs in `harness-cli do --binding <spec>`. The CLI keeps the real `.function`.
    case binding(String)
}

public struct ScriptBinding: Equatable, Sendable {
    public var sequence: [ScriptChord]
    public var target: ScriptTarget
    public var layer: ScriptLayer
    public var source: String

    public init(sequence: [ScriptChord], target: ScriptTarget, layer: ScriptLayer, source: String) {
        self.sequence = sequence
        self.target = target
        self.layer = layer
        self.source = source
    }
}

public struct ScriptMode: Equatable, Sendable {
    public var name: String
    public var exclusive: Bool
    public var once: Bool
    public var bindings: [ScriptBinding]

    public init(name: String, exclusive: Bool, once: Bool, bindings: [ScriptBinding] = []) {
        self.name = name
        self.exclusive = exclusive
        self.once = once
        self.bindings = bindings
    }
}

/// What one key did. `forward` is what the terminal still receives.
/// A sequence whose functions all return false forwards only the last chord.
public enum KeyDelivery: Equatable, Sendable {
    case partial
    case cancelled
    case leftMode
    case consumed(ScriptTarget)
    case forward([ScriptChord])
}

public enum KeyRole: Equatable, Sendable {
    case none
    case immediate
    case prefix
}

public struct KeymapEntry: Equatable, Sendable {
    public var spec: String
    public var winner: String
    public var source: String
    public var also: [String]

    public init(spec: String, winner: String, source: String, also: [String]) {
        self.spec = spec
        self.winner = winner
        self.source = source
        self.also = also
    }
}

/// Bindings, modes, and the partial-sequence state. Pure: Lua and the app both call this.
public struct ScriptKeymap: Equatable, Sendable {
    public private(set) var root: [ScriptBinding] = []
    public private(set) var modes: [String: ScriptMode] = [:]
    public var stack: [String] = []
    public var pending: [ScriptChord] = []
    public private(set) var warnings: [String] = []

    public init() {}

    public mutating func remove(layer: ScriptLayer) {
        root.removeAll { $0.layer == layer }
        for name in modes.keys {
            modes[name]?.bindings.removeAll { $0.layer == layer }
        }
    }

    /// `unknownOption` is any mode option other than `exclusive` or `once`. Those two are the
    /// whole option set; anything else skips the definition.
    public mutating func defineMode(name: String, exclusive: Bool, once: Bool, unknownOption: String? = nil) -> String? {
        guard ScriptKey.isModeName(name) else { return "invalid mode name \(name)" }
        if let unknownOption { return "unknown mode option \(unknownOption)" }
        var mode = modes[name] ?? ScriptMode(name: name, exclusive: exclusive, once: once)
        mode.exclusive = exclusive
        mode.once = once
        modes[name] = mode
        return nil
    }

    public mutating func bind(spec raw: String, target: ScriptTarget, layer: ScriptLayer, source: String) -> String? {
        guard let spec = ScriptKey.parse(raw) else { return "bad bind \(raw)" }
        if spec.mode != nil {
            if case .function = target { return "mode binding \(raw) must name an action" }
            if case .binding = target { return "mode binding \(raw) must name an action" }
            if case .enter = target { return "mode binding \(raw) must name an action" }
        }
        if let mode = spec.mode, modes[mode] == nil {
            modes[mode] = ScriptMode(name: mode, exclusive: false, once: false)
        }
        let binding = ScriptBinding(sequence: spec.sequence, target: target, layer: layer, source: source)
        if let previous = table(spec.mode).last(where: { $0.sequence == spec.sequence && $0.source != source }) {
            warnings.append("\(source) replaces \(previous.source) for \(spec.spec)")
        }
        if let mode = spec.mode {
            modes[mode]?.bindings.append(binding)
        } else {
            root.append(binding)
        }
        return nil
    }

    /// Removes the exact sequence. Sequences that only start with it stay.
    /// Inside a mode, the key is then blocked so it does not fall through to the shell.
    public mutating func unbind(spec raw: String, layer: ScriptLayer) -> String? {
        guard let spec = ScriptKey.parse(raw) else { return "bad unbind \(raw)" }
        if let mode = spec.mode {
            modes[mode]?.bindings.removeAll { $0.sequence == spec.sequence && $0.layer == layer }
            modes[mode]?.bindings.append(ScriptBinding(sequence: spec.sequence, target: .blocked, layer: layer, source: "unbind"))
        } else {
            root.removeAll { $0.sequence == spec.sequence && $0.layer == layer }
        }
        return nil
    }

    public mutating func enter(_ name: String) -> Bool {
        guard modes[name] != nil else { return false }
        stack.append(name)
        pending.removeAll()
        return true
    }

    public func role(of chord: ScriptChord) -> KeyRole {
        let rows = activeTable()
        if rows.contains(where: { $0.sequence.count > 1 && $0.sequence.first == chord && $0.target != .blocked }) {
            return .prefix
        }
        if winner(sequence: [chord], in: rows) != nil { return .immediate }
        return .none
    }

    public func listing() -> [KeymapEntry] {
        var groups: [[ScriptBinding]] = []
        for binding in activeTable() {
            if let index = groups.firstIndex(where: { $0[0].sequence == binding.sequence }) {
                groups[index].append(binding)
            } else {
                groups.append([binding])
            }
        }
        return groups.map { group in
            let best = group.enumerated().max { lhs, rhs in
                if lhs.element.layer != rhs.element.layer { return lhs.element.layer < rhs.element.layer }
                return lhs.offset < rhs.offset
            }!
            let others = group.filter { $0.source != best.element.source }.map(\.source)
            let winner: String
            switch best.element.target {
            case let .action(name): winner = name
            case .function, .binding: winner = "function"
            case .blocked: winner = "blocked"
            case let .enter(name): winner = "enter \(name)"
            }
            return KeymapEntry(
                spec: ScriptSpec(mode: stack.last, sequence: best.element.sequence).spec,
                winner: winner,
                source: best.element.source,
                also: others
            )
        }
    }

    public mutating func press(_ chord: ScriptChord, functionReturns: (Int) -> Bool) -> KeyDelivery {
        if !pending.isEmpty, chord.isEscape {
            pending.removeAll()
            return .cancelled
        }
        if let name = stack.last, let mode = modes[name], chord.isEscape, !bindsEscape(mode) {
            stack.removeLast()
            pending.removeAll()
            return .leftMode
        }
        let table = activeTable()
        let sequence = pending + [chord]
        if table.contains(where: { row in
            row.sequence.count > sequence.count && Array(row.sequence.prefix(sequence.count)) == sequence && row.target != .blocked
        }) {
            pending = sequence
            return .partial
        }
        if let delivery = resolve(sequence, in: table, functionReturns: functionReturns) {
            pending.removeAll()
            popIfOnce()
            if case let .consumed(.enter(name)) = delivery {
                _ = enter(name)
            }
            return delivery
        }
        pending.removeAll()
        if let name = stack.last, modes[name]?.exclusive == true {
            popIfOnce()
            return .consumed(.blocked)
        }
        if sequence.count > 1 {
            return press(chord, functionReturns: functionReturns)
        }
        return .forward([chord])
    }

    /// Prefer a physical chord when the active table has one at the next sequence slot.
    public func chordToPress(named: ScriptChord, physical: ScriptChord?) -> ScriptChord {
        let index = pending.count
        guard let physical else { return named }
        let matched = activeTable().contains { row in
            row.sequence.count > index
                && Array(row.sequence.prefix(index)) == pending
                && row.sequence[index] == physical
        }
        return matched ? physical : named
    }

    public func exportedBindings() -> [ScriptBindingRecord] {
        var records: [ScriptBindingRecord] = []
        func append(_ binding: ScriptBinding, mode: String?) {
            let spec = ScriptSpec(mode: mode, sequence: binding.sequence).spec
            switch binding.target {
            case .function:
                records.append(ScriptBindingRecord(spec: spec, function: true, layer: binding.layer.rawValue, source: binding.source))
            case .binding:
                return
            case let .action(name):
                records.append(ScriptBindingRecord(spec: spec, action: name, layer: binding.layer.rawValue, source: binding.source))
            case .blocked:
                records.append(ScriptBindingRecord(spec: spec, blocked: true, layer: binding.layer.rawValue, source: binding.source))
            case let .enter(name):
                records.append(ScriptBindingRecord(spec: spec, enter: name, layer: binding.layer.rawValue, source: binding.source))
            }
        }
        for binding in root { append(binding, mode: nil) }
        for name in modes.keys.sorted() {
            for binding in modes[name]?.bindings ?? [] { append(binding, mode: name) }
        }
        return records
    }

    public func exportedModes() -> [ScriptModeRecord] {
        modes.values
            .map { ScriptModeRecord(name: $0.name, exclusive: $0.exclusive, once: $0.once) }
            .sorted { $0.name < $1.name }
    }

    public static func replay(bindings: [ScriptBindingRecord], modes: [ScriptModeRecord]) -> ScriptKeymap {
        var map = ScriptKeymap()
        for mode in modes {
            _ = map.defineMode(name: mode.name, exclusive: mode.exclusive, once: mode.once)
        }
        for record in bindings {
            let layer = ScriptLayer(rawValue: record.layer) ?? .configFile
            let target: ScriptTarget
            if record.blocked {
                target = .blocked
            } else if let mode = record.enter {
                target = .enter(mode)
            } else if record.function {
                target = .binding(record.spec)
            } else if let action = record.action {
                target = .action(action)
            } else {
                continue
            }
            _ = map.bind(spec: record.spec, target: target, layer: layer, source: record.source)
        }
        return map
    }

    private mutating func popIfOnce() {
        guard let name = stack.last, modes[name]?.once == true else { return }
        stack.removeLast()
    }

    private func isFunction(_ target: ScriptTarget) -> Bool {
        if case .function = target { return true }
        return false
    }

    private func bindsEscape(_ mode: ScriptMode) -> Bool {
        mode.bindings.contains { $0.sequence.count == 1 && $0.sequence[0].isEscape }
    }

    private func activeTable() -> [ScriptBinding] {
        if let name = stack.last, let mode = modes[name] { return mode.bindings }
        return root
    }

    private func table(_ mode: String?) -> [ScriptBinding] {
        if let mode, let found = modes[mode] { return found.bindings }
        return root
    }

    private func winner(sequence: [ScriptChord], in table: [ScriptBinding]) -> ScriptBinding? {
        let indexed = table.enumerated().filter { $0.element.sequence == sequence }
        return indexed.max { lhs, rhs in
            if lhs.element.layer != rhs.element.layer { return lhs.element.layer < rhs.element.layer }
            return lhs.offset < rhs.offset
        }?.element
    }

    private func resolve(_ sequence: [ScriptChord], in table: [ScriptBinding], functionReturns: (Int) -> Bool) -> KeyDelivery? {
        guard let best = winner(sequence: sequence, in: table) else { return nil }
        switch best.target {
        case .blocked:
            return .consumed(.blocked)
        case let .action(name):
            return .consumed(.action(name))
        case let .enter(name):
            return .consumed(.enter(name))
        case let .binding(spec):
            return .consumed(.binding(spec))
        case .function:
            let chain = table.enumerated().filter { item in
                item.element.sequence == sequence && isFunction(item.element.target)
            }.sorted { lhs, rhs in
                if lhs.element.layer != rhs.element.layer { return lhs.element.layer > rhs.element.layer }
                return lhs.offset > rhs.offset
            }
            for item in chain {
                if case let .function(id) = item.element.target, functionReturns(id) {
                    return .consumed(.function(id))
                }
            }
            let forward = sequence.count > 1 ? [sequence[sequence.count - 1]] : sequence
            return .forward(forward)
        }
    }
}
