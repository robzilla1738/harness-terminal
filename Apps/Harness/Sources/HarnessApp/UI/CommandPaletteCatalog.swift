import Foundation
import HarnessCore

/// The palette's full-vocabulary command rows, derived from the SAME catalog that backs
/// `bind-key`, the `:` prompt, hooks, and `list-commands` (`CommandParser.knownVerbs`) — never
/// a hand-maintained copy, so a new bindable verb lands in the palette automatically.
/// Pure (no coordinator/daemon access) so the catalog logic is unit-testable.
enum CommandPaletteCatalog {
    enum RowKind: Equatable {
        /// The verb parses with no arguments — the palette runs it directly.
        case direct(Command)
        /// The verb needs arguments — the palette opens the `:` prompt pre-filled.
        case prompt
    }

    struct Entry: Equatable {
        let verb: String
        let kind: RowKind
        /// Display shortcut ("Prefix x", "Ctrl-B") when some key table binds the same command.
        let shortcut: String
    }

    /// Verbs already represented by a curated palette action (richer title/subtitle/handler) —
    /// a catalog row for them would just be a duplicate. Keep in sync with `buildActions()`.
    static let curatedVerbs: Set<String> = [
        "split-window", "kill-pane", "zoom-pane", "copy-mode",
        "new-window", "new-tab", "new-session", "rename-window", "rename-tab",
    ]

    /// Verbs that PARSE bare but to empty-argument forms that would silently no-op (empty
    /// layout name, empty key list, empty message, zero menu items) — running them from a
    /// palette row would look broken, so they take the pre-filled prompt instead.
    static let promptPreferredVerbs: Set<String> = [
        "select-layout", "send-keys", "display-message", "display-menu",
    ]

    /// One entry per bindable verb not covered by a curated action, alphabetized.
    /// `bindings` maps a command's canonical text (`shortDescription`) → display shortcut.
    static func entries(bindings: [String: String] = [:]) -> [Entry] {
        CommandParser.knownVerbs
            .filter { !curatedVerbs.contains($0) }
            .sorted()
            .map { verb in
                guard !promptPreferredVerbs.contains(verb),
                      let parsed = try? CommandParser.parse(verb) else {
                    return Entry(verb: verb, kind: .prompt, shortcut: "")
                }
                return Entry(
                    verb: verb,
                    kind: .direct(parsed),
                    shortcut: bindings[parsed.shortDescription] ?? ""
                )
            }
    }

    /// Display shortcut per bound command (keyed by `shortDescription`), from the live key
    /// tables: prefix-table bindings read "Prefix <key>", root-table (no-prefix) bindings show
    /// the bare spec. First binding wins per command.
    static func bindingDisplayMap(tables: KeyTableSet) -> [String: String] {
        var map: [String: String] = [:]
        for (tableID, table) in tables.tables where tableID == .prefix || tableID == .root {
            for binding in table.bindings {
                let key = binding.command.shortDescription
                guard map[key] == nil else { continue }
                map[key] = tableID == .prefix
                    ? "Prefix \(binding.spec.description)"
                    : binding.spec.description
            }
        }
        return map
    }
}
