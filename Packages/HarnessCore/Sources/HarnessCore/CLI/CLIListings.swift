import Foundation

/// `harness-cli ls`: every session, its tabs, and their panes, with the markers a person
/// needs to pick a target (`*` active, positions for `-s`/`-w`/`-b`, short ids).
public struct SessionTree: Encodable, Equatable, Sendable {
    public struct Session: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var workspace: String
        public var active: Bool
        public var tabs: [Tab]
    }

    public struct Tab: Encodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var active: Bool
        /// The program-status mark (`working`, `blocked`, `done`, `error`), else the tab status.
        public var status: String
        public var message: String?
        public var panes: [Pane]
    }

    public struct Pane: Encodable, Equatable, Sendable {
        public var id: String
        public var surface: String
        public var cwd: String
        public var program: String?
        public var agent: String?
        public var active: Bool
        /// The pane this command runs in.
        public var caller: Bool
    }

    public var sessions: [Session]

    public static func build(_ snapshot: SessionSnapshot, context: TargetContext, callerInside: Bool) -> SessionTree {
        let callerSurface = callerInside ? context.pane?.surfaceID : nil
        let activeWorkspace = snapshot.activeWorkspace?.id
        var sessions: [Session] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                let tabs = session.tabs.map { tab -> Tab in
                    let leaves = tab.rootPane.allLeaves()
                    let activePane = tab.activeLeaf?.id
                    return Tab(
                        id: tab.id.uuidString,
                        label: tab.title,
                        active: tab.id == session.activeTabID,
                        status: tab.programMark?.attention.rawValue ?? tab.status.rawValue,
                        message: tab.programMark?.message,
                        panes: leaves.map { leaf in
                            let identity = PaneIdentity.of(leaf: leaf, in: tab)
                            return Pane(
                                id: leaf.id.uuidString,
                                surface: leaf.surfaceID.uuidString,
                                cwd: identity.directory,
                                program: identity.program,
                                agent: identity.agent?.commandToken,
                                active: leaf.id == activePane,
                                caller: leaf.surfaceID == callerSurface
                            )
                        }
                    )
                }
                sessions.append(Session(
                    id: session.id.uuidString,
                    label: SessionDisplayName.title(of: session, in: workspace),
                    workspace: workspace.name,
                    active: workspace.id == activeWorkspace && session.id == workspace.activeSessionID,
                    tabs: tabs
                ))
            }
        }
        return SessionTree(sessions: sessions)
    }

    /// Indented text: session, then numbered tabs, then numbered panes. The short id is a
    /// unique-enough prefix that `-t`-style targets accept.
    public func text() -> String {
        let showWorkspace = Set(sessions.map(\.workspace)).count > 1
        var lines: [String] = []
        for session in sessions {
            let where_ = showWorkspace ? "  [\(session.workspace)]" : ""
            lines.append("\(mark(session.active)) \(session.label)\(where_)  \(Self.short(session.id))")
            for (tabIndex, tab) in session.tabs.enumerated() {
                let status = tab.status == TabStatus.idle.rawValue ? "" : "  \(tab.status)" + (tab.message.map { ": \($0)" } ?? "")
                lines.append("  \(mark(tab.active)) \(tabIndex + 1) \(tab.label)\(status)  \(Self.short(tab.id))")
                for (paneIndex, pane) in tab.panes.enumerated() {
                    let label = SurfaceIdentity.label(directory: pane.cwd, program: pane.program, agent: pane.agent)
                    let caller = pane.caller ? "  ← here" : ""
                    lines.append("      \(mark(pane.active)) \(paneIndex + 1) \(label)  \(Self.short(pane.surface))\(caller)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func mark(_ active: Bool) -> String { active ? "*" : " " }

    static func short(_ id: String) -> String { String(id.prefix(8)).lowercased() }
}

/// `harness-cli keymap`: every key, from keybindings.json and the Lua config, in one table.
public struct KeymapRow: Encodable, Equatable, Sendable {
    public var key: String
    public var action: String
    public var args: String
    /// `keybindings` (tmux-style tables), or the Lua layer: `default`, `config`, `app`.
    public var source: String

    public static func rows(tables: KeyTableSet, manifest: ScriptManifest?) -> [KeymapRow] {
        var rows: [KeymapRow] = []
        for table in tables.tableList {
            for binding in table.bindings {
                let words = binding.command.shortDescription.split(separator: " ", maxSplits: 1).map(String.init)
                let key = table.id == .root ? binding.spec.description : "\(table.id.rawValue) \(binding.spec.description)"
                rows.append(KeymapRow(key: key, action: words.first ?? "", args: words.count > 1 ? words[1] : "", source: "keybindings"))
            }
        }
        for record in manifest?.bindings ?? [] {
            let action: String, args: String
            if record.blocked {
                (action, args) = ("(blocked)", "")
            } else if let mode = record.enter {
                (action, args) = ("enter-mode", mode)
            } else if record.function {
                (action, args) = ("(lua function)", "")
            } else {
                (action, args) = (record.action ?? "", "")
            }
            rows.append(KeymapRow(key: record.spec, action: action, args: args, source: layerName(record.layer)))
        }
        return rows
    }

    static func layerName(_ layer: Int) -> String {
        switch ScriptLayer(rawValue: layer) {
        case .clientDefault: return "default"
        case .configFile: return "config"
        case .recorder: return "app"
        case nil: return "lua"
        }
    }
}

/// `harness-cli actions`: built-in commands and the config's Lua actions.
public struct ActionRow: Encodable, Equatable, Sendable {
    public var name: String
    public var title: String
    public var source: String

    public static func rows(manifest: ScriptManifest?) -> [ActionRow] {
        let custom = (manifest?.actions ?? []).map { ActionRow(name: $0.name, title: $0.title, source: $0.source) }
        let builtin = CommandParser.knownVerbs.map { ActionRow(name: $0, title: "", source: "builtin") }
        return custom + builtin
    }
}

/// Aligned columns for the list commands. The last column is not padded.
public enum TextTable {
    public static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            row.indices.map { column in
                column == row.count - 1 ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

/// `--for 10m`, `--timeout 90`: seconds, or a number with `s`, `m`, or `h`.
public enum CLIDuration {
    public static func seconds(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]
        if let last = trimmed.last, let unit = units[last] {
            return Double(trimmed.dropLast()).flatMap { $0 >= 0 ? $0 * unit : nil }
        }
        return Double(trimmed).flatMap { $0 >= 0 ? $0 : nil }
    }
}
