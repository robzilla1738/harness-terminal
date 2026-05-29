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
    public static let command = KeyTableID(rawValue: "command")
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

    public init(id: KeyTableID, bindings: [Binding] = []) {
        self.id = id
        self.bindings = bindings
    }

    public func lookup(_ spec: KeySpec) -> Binding? {
        bindings.first(where: { $0.spec == spec })
    }

    public mutating func set(_ binding: Binding) {
        if let index = bindings.firstIndex(where: { $0.spec == binding.spec }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
    }

    public mutating func remove(spec: KeySpec) {
        bindings.removeAll { $0.spec == spec }
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
        // copy-mode bindings are documentation/discoverability today: the
        // CopyModeViewController interprets vim-keys natively. Listing them
        // here means `list-keys -T copy-mode` shows what's available and a
        // future inline-overlay rewrite can rebind them via `bind-key`.
        let copyMode = KeyTable(id: .copyMode, bindings: [
            Binding(spec: KeySpec(key: "h"), command: .selectPane(target: .left), note: "Cursor left"),
            Binding(spec: KeySpec(key: "l"), command: .selectPane(target: .right), note: "Cursor right"),
            Binding(spec: KeySpec(key: "j"), command: .selectPane(target: .down), note: "Cursor down"),
            Binding(spec: KeySpec(key: "k"), command: .selectPane(target: .up), note: "Cursor up"),
            Binding(spec: KeySpec(key: "v"), command: .displayMessage(format: "char selection"), note: "Start char selection"),
            Binding(spec: KeySpec(key: "V"), command: .displayMessage(format: "line selection"), note: "Start line selection"),
            Binding(spec: KeySpec(key: "y"), command: .displayMessage(format: "yank"), note: "Yank to buffer"),
            Binding(spec: KeySpec(key: "/"), command: .displayMessage(format: "search-forward"), note: "Search forward"),
            Binding(spec: KeySpec(key: "?"), command: .displayMessage(format: "search-backward"), note: "Search backward"),
            Binding(spec: KeySpec(key: "n"), command: .displayMessage(format: "search-next"), note: "Next match"),
            Binding(spec: KeySpec(key: "q"), command: .displayMessage(format: "exit-copy-mode"), note: "Exit copy mode"),
        ])
        // The `root` (no-prefix / mouse) and `command` (command-prompt editing)
        // tables are introduced — and actually consulted — in later phases. They are
        // intentionally NOT seeded as empty tables here: an empty-but-unconsulted
        // table is a misleading rebindable surface (`bind-key -T root …` would appear
        // to work yet do nothing). `.root`/`.command` IDs still exist for when those
        // phases wire them up.
        return KeyTableSet(tables: [prefix, copyMode])
    }
}
