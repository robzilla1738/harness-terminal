import Foundation

/// Named registries of (KeySpec → Command). Tables let us model the
/// multiplexer's stateful key handling: while the user is in copy mode,
/// keystrokes resolve against the `copy-mode` table; after the prefix fires,
/// they resolve against `prefix`; otherwise against `root`.
///
/// Tables are mutable at runtime via `bind-key` / `unbind-key`, persisted to
/// `keybindings.json` so customizations survive restart.
public struct KeyTableID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let root = KeyTableID(rawValue: "root")
    public static let prefix = KeyTableID(rawValue: "prefix")
    public static let copyMode = KeyTableID(rawValue: "copy-mode")
    /// Emacs copy-mode bindings, selected when `mode-keys` is `emacs`.
    public static let copyModeEmacs = KeyTableID(rawValue: "copy-mode-emacs")
    public static let command = KeyTableID(rawValue: "command")

    /// The copy-mode key table for a `mode-keys` option value — the single place both the
    /// GUI overlay and the ssh compositor map `mode-keys` to a table, so they never diverge.
    public static func copyMode(modeKeys: String) -> KeyTableID {
        modeKeys.lowercased() == "emacs" ? .copyModeEmacs : .copyMode
    }
}

public struct Binding: Codable, Sendable, Equatable {
    public let spec: KeySpec
    public var command: Command
    public var note: String?
    /// When true, after this binding fires the prefix stays "armed" briefly so the
    /// key can repeat without re-pressing the prefix (`bind-key -r`, e.g. resize).
    public var repeatable: Bool

    public init(spec: KeySpec, command: Command, note: String? = nil, repeatable: Bool = false) {
        self.spec = spec
        self.command = command
        self.note = note
        self.repeatable = repeatable
    }

    // Tolerant decode so older keybindings.json files (no `repeatable`) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(KeySpec.self, forKey: .spec)
        command = try c.decode(Command.self, forKey: .command)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        repeatable = try c.decodeIfPresent(Bool.self, forKey: .repeatable) ?? false
    }
}

public struct KeyTable: Codable, Sendable, Equatable {
    public let id: KeyTableID
    public private(set) var bindings: [Binding]
    /// Tombstones for explicitly unbound specs. Without them, unbinding a DEFAULT binding
    /// cannot survive a reload: `KeybindingsStore.load()` merges defaults back for every
    /// spec missing from the saved file, so a plain delete is indistinguishable from an
    /// uncustomized default and silently resurrects. Re-binding a spec clears its tombstone.
    public private(set) var disabledSpecs: [KeySpec]

    public init(id: KeyTableID, bindings: [Binding] = [], disabledSpecs: [KeySpec] = []) {
        self.id = id
        self.bindings = bindings
        self.disabledSpecs = disabledSpecs
    }

    public func lookup(_ spec: KeySpec) -> Binding? {
        bindings.first(where: { $0.spec == spec })
    }

    /// Whether `spec` was explicitly unbound (so the load-time default merge must skip it).
    public func isDisabled(_ spec: KeySpec) -> Bool {
        disabledSpecs.contains(spec)
    }

    public mutating func set(_ binding: Binding) {
        disabledSpecs.removeAll { $0 == binding.spec }
        if let index = bindings.firstIndex(where: { $0.spec == binding.spec }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
    }

    public mutating func remove(spec: KeySpec) {
        bindings.removeAll { $0.spec == spec }
        if !disabledSpecs.contains(spec) {
            disabledSpecs.append(spec)
        }
    }

    // Tolerant decode so older keybindings.json files (no `disabledSpecs`) still load.
    enum CodingKeys: String, CodingKey { case id, bindings, disabledSpecs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(KeyTableID.self, forKey: .id)
        bindings = try c.decode([Binding].self, forKey: .bindings)
        disabledSpecs = try c.decodeIfPresent([KeySpec].self, forKey: .disabledSpecs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(bindings, forKey: .bindings)
        // Keep user files tidy: tables with no tombstones encode exactly as before.
        if !disabledSpecs.isEmpty {
            try c.encode(disabledSpecs, forKey: .disabledSpecs)
        }
    }
}

/// Snapshot of every table, persisted as JSON. The store handles defaults,
/// merge-on-load (so adding new defaults doesn't blow away user changes), and
/// atomic writes.
public struct KeyTableSet: Codable, Sendable, Equatable {
    /// Array form (instead of `[KeyTableID: KeyTable]`) keeps the JSON file
    /// stable and readable — Swift's dictionary-with-custom-key encoding is
    /// awkward, and the lookup helpers below preserve the dictionary feel.
    public var tableList: [KeyTable]

    public init(tables: [KeyTable]) {
        self.tableList = tables
    }

    public var tables: [KeyTableID: KeyTable] {
        Dictionary(uniqueKeysWithValues: tableList.map { ($0.id, $0) })
    }

    public func table(_ id: KeyTableID) -> KeyTable? {
        tableList.first(where: { $0.id == id })
    }

    public mutating func setBinding(table: KeyTableID, binding: Binding) {
        if let index = tableList.firstIndex(where: { $0.id == table }) {
            var current = tableList[index]
            current.set(binding)
            tableList[index] = current
        } else {
            var fresh = KeyTable(id: table)
            fresh.set(binding)
            tableList.append(fresh)
        }
    }

    public mutating func removeBinding(table: KeyTableID, spec: KeySpec) {
        guard let index = tableList.firstIndex(where: { $0.id == table }) else { return }
        var current = tableList[index]
        current.remove(spec: spec)
        tableList[index] = current
    }

    enum CodingKeys: String, CodingKey { case tables }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tableList = try container.decode([KeyTable].self, forKey: .tables)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tableList, forKey: .tables)
    }

    public static var defaults: KeyTableSet {
        let prefix = KeyTable(id: .prefix, bindings: [
            // Pane creation / destruction
            Binding(spec: KeySpec(key: "c"), command: .newWindow, note: "New tab"),
            Binding(spec: KeySpec(key: "%"), command: .splitWindow(direction: .vertical), note: "Split side-by-side"),
            Binding(spec: KeySpec(key: "\""), command: .splitWindow(direction: .horizontal), note: "Split top/bottom"),
            Binding(spec: KeySpec(key: "x"), command: .killPane, note: "Kill active pane"),
            Binding(spec: KeySpec(key: "z"), command: .zoomPane, note: "Toggle zoom"),
            Binding(spec: KeySpec(key: "&"), command: .killWindow, note: "Kill tab"),
            // Pane navigation
            Binding(spec: KeySpec(key: "o"), command: .selectPane(target: .next), note: "Cycle pane forward"),
            Binding(spec: KeySpec(key: ";"), command: .selectPane(target: .previous), note: "Cycle pane backward"),
            Binding(spec: KeySpec(key: "Left"), command: .selectPane(target: .left), note: "Pane left"),
            Binding(spec: KeySpec(key: "Right"), command: .selectPane(target: .right), note: "Pane right"),
            Binding(spec: KeySpec(key: "Up"), command: .selectPane(target: .up), note: "Pane up"),
            Binding(spec: KeySpec(key: "Down"), command: .selectPane(target: .down), note: "Pane down"),
            // Tabs
            Binding(spec: KeySpec(key: "n"), command: .nextWindow, note: "Next tab"),
            Binding(spec: KeySpec(key: "p"), command: .previousWindow, note: "Previous tab"),
            Binding(spec: KeySpec(key: ","), command: .renameWindow(newName: nil), note: "Rename tab"),
            // Workspaces
            Binding(spec: KeySpec(key: "0"), command: .selectWorkspace(index: 0), note: "Workspace 0"),
            Binding(spec: KeySpec(key: "1"), command: .selectWorkspace(index: 1), note: "Workspace 1"),
            Binding(spec: KeySpec(key: "2"), command: .selectWorkspace(index: 2), note: "Workspace 2"),
            Binding(spec: KeySpec(key: "3"), command: .selectWorkspace(index: 3), note: "Workspace 3"),
            Binding(spec: KeySpec(key: "4"), command: .selectWorkspace(index: 4), note: "Workspace 4"),
            Binding(spec: KeySpec(key: "5"), command: .selectWorkspace(index: 5), note: "Workspace 5"),
            Binding(spec: KeySpec(key: "6"), command: .selectWorkspace(index: 6), note: "Workspace 6"),
            Binding(spec: KeySpec(key: "7"), command: .selectWorkspace(index: 7), note: "Workspace 7"),
            Binding(spec: KeySpec(key: "8"), command: .selectWorkspace(index: 8), note: "Workspace 8"),
            Binding(spec: KeySpec(key: "9"), command: .selectWorkspace(index: 9), note: "Workspace 9"),
            // Modes
            Binding(spec: KeySpec(key: "["), command: .copyMode, note: "Enter copy mode"),
            Binding(spec: KeySpec(key: "d"), command: .detachClient, note: "Detach"),
            Binding(spec: KeySpec(key: "?"), command: .showCheatsheet, note: "Cheatsheet"),
            Binding(spec: KeySpec(key: "r"), command: .sourceConfig, note: "Re-import config"),
            // Multiplexer power commands.
            Binding(spec: KeySpec(key: "Space"), command: .nextLayout, note: "Cycle layouts"),
            Binding(spec: KeySpec(key: "q"), command: .displayPanes, note: "Show pane numbers"),
            Binding(spec: KeySpec(key: "l"), command: .selectPane(target: .last), note: "Last pane"),
            Binding(spec: KeySpec(key: "m"), command: .markPane(set: true), note: "Mark pane (join source)"),
            Binding(spec: KeySpec(key: "M"), command: .markPane(set: false), note: "Clear marked pane"),
            Binding(spec: KeySpec(key: "j"), command: .joinPane(direction: .vertical), note: "Join marked pane"),
            Binding(spec: KeySpec(key: "S"), command: .synchronizePanes(set: nil), note: "Toggle synchronize-panes"),
            // Resize — repeatable (hold under the prefix to keep nudging). Shifted
            // arrows avoid conflicting with the select-pane arrows above.
            Binding(spec: KeySpec(key: "Left", modifiers: .shift), command: .resizePane(direction: .left, amount: 5), note: "Resize left", repeatable: true),
            Binding(spec: KeySpec(key: "Right", modifiers: .shift), command: .resizePane(direction: .right, amount: 5), note: "Resize right", repeatable: true),
            Binding(spec: KeySpec(key: "Up", modifiers: .shift), command: .resizePane(direction: .up, amount: 3), note: "Resize up", repeatable: true),
            Binding(spec: KeySpec(key: "Down", modifiers: .shift), command: .resizePane(direction: .down, amount: 3), note: "Resize down", repeatable: true),
        ])
        // copy-mode bindings are real, rebindable commands: the copy-mode view
        // resolves each keystroke against this table (merged with user overrides
        // from keybindings.json) and runs the resulting `copy-mode -X` action, so
        // `bind-key -T copy-mode <key> <command>` customizes copy mode. Defaults
        // follow `mode-keys vi`.
        let copyMode = KeyTable(id: .copyMode, bindings: [
            Binding(spec: KeySpec(key: "h"), command: .copyModeCommand(.cursorLeft), note: "Cursor left"),
            Binding(spec: KeySpec(key: "l"), command: .copyModeCommand(.cursorRight), note: "Cursor right"),
            Binding(spec: KeySpec(key: "j"), command: .copyModeCommand(.cursorDown), note: "Cursor down"),
            Binding(spec: KeySpec(key: "k"), command: .copyModeCommand(.cursorUp), note: "Cursor up"),
            // Arrow keys mirror hjkl (tmux parity) — without these, copy mode swallows arrows.
            Binding(spec: KeySpec(key: "Left"), command: .copyModeCommand(.cursorLeft), note: "Cursor left"),
            Binding(spec: KeySpec(key: "Right"), command: .copyModeCommand(.cursorRight), note: "Cursor right"),
            Binding(spec: KeySpec(key: "Down"), command: .copyModeCommand(.cursorDown), note: "Cursor down"),
            Binding(spec: KeySpec(key: "Up"), command: .copyModeCommand(.cursorUp), note: "Cursor up"),
            Binding(spec: KeySpec(key: "0"), command: .copyModeCommand(.startOfLine), note: "Start of line"),
            Binding(spec: KeySpec(key: "$"), command: .copyModeCommand(.endOfLine), note: "End of line"),
            Binding(spec: KeySpec(key: "w"), command: .copyModeCommand(.nextWord), note: "Next word"),
            Binding(spec: KeySpec(key: "b"), command: .copyModeCommand(.previousWord), note: "Previous word"),
            Binding(spec: KeySpec(key: "e"), command: .copyModeCommand(.nextWordEnd), note: "End of next word"),
            Binding(spec: KeySpec(key: "^"), command: .copyModeCommand(.backToIndentation), note: "Back to indentation"),
            // Big-WORD motions (W/B/E): Harness's word motions are whitespace-delimited, so these
            // share the w/b/e implementation (tmux `next-space`/`previous-space`/`next-space-end`).
            Binding(spec: KeySpec(key: "W"), command: .copyModeCommand(.nextWord), note: "Next space-delimited word"),
            Binding(spec: KeySpec(key: "B"), command: .copyModeCommand(.previousWord), note: "Previous space-delimited word"),
            Binding(spec: KeySpec(key: "E"), command: .copyModeCommand(.nextWordEnd), note: "End of next space-delimited word"),
            // Jump-to-char (f/F/t/T) — the front-end captures the next keystroke as the target;
            // `;`/`,` repeat it forward / reversed.
            Binding(spec: KeySpec(key: "f"), command: .copyModeCommand(.jump(.forward, nil)), note: "Jump to char"),
            Binding(spec: KeySpec(key: "F"), command: .copyModeCommand(.jump(.backward, nil)), note: "Jump to char (back)"),
            Binding(spec: KeySpec(key: "t"), command: .copyModeCommand(.jump(.toForward, nil)), note: "Jump before char"),
            Binding(spec: KeySpec(key: "T"), command: .copyModeCommand(.jump(.toBackward, nil)), note: "Jump after char (back)"),
            Binding(spec: KeySpec(key: ";"), command: .copyModeCommand(.jumpAgain), note: "Repeat jump"),
            Binding(spec: KeySpec(key: ","), command: .copyModeCommand(.jumpReverse), note: "Repeat jump reversed"),
            Binding(spec: KeySpec(key: "o"), command: .copyModeCommand(.otherEnd), note: "Other end of selection"),
            Binding(spec: KeySpec(key: "g"), command: .copyModeCommand(.top), note: "Top of history"),
            Binding(spec: KeySpec(key: "G"), command: .copyModeCommand(.bottom), note: "Bottom of history"),
            Binding(spec: KeySpec(key: "H"), command: .copyModeCommand(.topLine), note: "Top of window"),
            Binding(spec: KeySpec(key: "M"), command: .copyModeCommand(.middleLine), note: "Middle of window"),
            Binding(spec: KeySpec(key: "L"), command: .copyModeCommand(.bottomLine), note: "Bottom of window"),
            Binding(spec: KeySpec(key: "["), command: .copyModeCommand(.previousPrompt), note: "Previous prompt"),
            Binding(spec: KeySpec(key: "]"), command: .copyModeCommand(.nextPrompt), note: "Next prompt"),
            Binding(spec: KeySpec(key: "PageUp"), command: .copyModeCommand(.pageUp), note: "Page up"),
            Binding(spec: KeySpec(key: "PageDown"), command: .copyModeCommand(.pageDown), note: "Page down"),
            Binding(spec: KeySpec(key: "u", modifiers: .control), command: .copyModeCommand(.halfPageUp), note: "Half page up"),
            Binding(spec: KeySpec(key: "d", modifiers: .control), command: .copyModeCommand(.halfPageDown), note: "Half page down"),
            Binding(spec: KeySpec(key: "v"), command: .copyModeCommand(.beginSelection), note: "Begin selection"),
            Binding(spec: KeySpec(key: "V"), command: .copyModeCommand(.selectLine), note: "Line selection"),
            Binding(spec: KeySpec(key: "v", modifiers: .control), command: .copyModeCommand(.rectangleToggle), note: "Toggle rectangle selection"),
            Binding(spec: KeySpec(key: "y"), command: .copyModeCommand(.copySelectionAndCancel), note: "Copy selection"),
            Binding(spec: KeySpec(key: "Enter"), command: .copyModeCommand(.copySelectionAndCancel), note: "Copy selection"),
            Binding(spec: KeySpec(key: "/"), command: .copyModeCommand(.searchForward), note: "Search forward"),
            Binding(spec: KeySpec(key: "?"), command: .copyModeCommand(.searchBackward), note: "Search backward"),
            Binding(spec: KeySpec(key: "n"), command: .copyModeCommand(.searchAgain), note: "Next match"),
            Binding(spec: KeySpec(key: "N"), command: .copyModeCommand(.searchReverse), note: "Previous match"),
            Binding(spec: KeySpec(key: "p"), command: .copyModeCommand(.paste), note: "Paste buffer"),
            Binding(spec: KeySpec(key: "q"), command: .copyModeCommand(.cancel), note: "Exit copy mode"),
            Binding(spec: KeySpec(key: "Escape"), command: .copyModeCommand(.cancel), note: "Exit copy mode"),
        ])
        // Emacs copy-mode defaults (`mode-keys emacs`), mirroring tmux's `copy-mode` table.
        // Selected via `KeyTableID.copyMode(modeKeys:)`; equally rebindable.
        let copyModeEmacs = KeyTable(id: .copyModeEmacs, bindings: [
            Binding(spec: KeySpec(key: "b", modifiers: .control), command: .copyModeCommand(.cursorLeft), note: "Cursor left"),
            Binding(spec: KeySpec(key: "f", modifiers: .control), command: .copyModeCommand(.cursorRight), note: "Cursor right"),
            Binding(spec: KeySpec(key: "n", modifiers: .control), command: .copyModeCommand(.cursorDown), note: "Cursor down"),
            Binding(spec: KeySpec(key: "p", modifiers: .control), command: .copyModeCommand(.cursorUp), note: "Cursor up"),
            // Arrow keys mirror the C-bfnp motions (tmux parity).
            Binding(spec: KeySpec(key: "Left"), command: .copyModeCommand(.cursorLeft), note: "Cursor left"),
            Binding(spec: KeySpec(key: "Right"), command: .copyModeCommand(.cursorRight), note: "Cursor right"),
            Binding(spec: KeySpec(key: "Down"), command: .copyModeCommand(.cursorDown), note: "Cursor down"),
            Binding(spec: KeySpec(key: "Up"), command: .copyModeCommand(.cursorUp), note: "Cursor up"),
            Binding(spec: KeySpec(key: "a", modifiers: .control), command: .copyModeCommand(.startOfLine), note: "Start of line"),
            Binding(spec: KeySpec(key: "e", modifiers: .control), command: .copyModeCommand(.endOfLine), note: "End of line"),
            Binding(spec: KeySpec(key: "f", modifiers: .option), command: .copyModeCommand(.nextWord), note: "Next word"),
            Binding(spec: KeySpec(key: "b", modifiers: .option), command: .copyModeCommand(.previousWord), note: "Previous word"),
            Binding(spec: KeySpec(key: "<", modifiers: .option), command: .copyModeCommand(.top), note: "Top of history"),
            Binding(spec: KeySpec(key: ">", modifiers: .option), command: .copyModeCommand(.bottom), note: "Bottom of history"),
            Binding(spec: KeySpec(key: "[", modifiers: .option), command: .copyModeCommand(.previousPrompt), note: "Previous prompt"),
            Binding(spec: KeySpec(key: "]", modifiers: .option), command: .copyModeCommand(.nextPrompt), note: "Next prompt"),
            Binding(spec: KeySpec(key: "PageUp"), command: .copyModeCommand(.pageUp), note: "Page up"),
            Binding(spec: KeySpec(key: "PageDown"), command: .copyModeCommand(.pageDown), note: "Page down"),
            Binding(spec: KeySpec(key: "v", modifiers: .option), command: .copyModeCommand(.pageUp), note: "Page up"),
            Binding(spec: KeySpec(key: "v", modifiers: .control), command: .copyModeCommand(.pageDown), note: "Page down"),
            Binding(spec: KeySpec(key: "Space", modifiers: .control), command: .copyModeCommand(.beginSelection), note: "Begin selection"),
            Binding(spec: KeySpec(key: "w", modifiers: .option), command: .copyModeCommand(.copySelectionAndCancel), note: "Copy selection"),
            Binding(spec: KeySpec(key: "Enter"), command: .copyModeCommand(.copySelectionAndCancel), note: "Copy selection"),
            Binding(spec: KeySpec(key: "s", modifiers: .control), command: .copyModeCommand(.searchForward), note: "Search forward"),
            Binding(spec: KeySpec(key: "r", modifiers: .control), command: .copyModeCommand(.searchBackward), note: "Search backward"),
            Binding(spec: KeySpec(key: "y", modifiers: .control), command: .copyModeCommand(.paste), note: "Paste buffer"),
            Binding(spec: KeySpec(key: "g", modifiers: .control), command: .copyModeCommand(.cancel), note: "Exit copy mode"),
            Binding(spec: KeySpec(key: "Escape"), command: .copyModeCommand(.cancel), note: "Exit copy mode"),
        ])
        // The `root` table holds no-prefix (`bind -n`) bindings: it is seeded empty here AND
        // consulted on every keystroke (GUI `PrefixKeymap`), so `bind-key -T root <key> <cmd>`
        // is a real, working surface — not a misleading no-op. It ships empty (tmux's default);
        // users add global bindings. The `command` table (command-prompt editing) is not seeded
        // until its consumer is wired, to avoid a rebindable-but-unconsulted surface.
        let root = KeyTable(id: .root, bindings: [])
        return KeyTableSet(tables: [prefix, copyMode, copyModeEmacs, root])
    }
}
