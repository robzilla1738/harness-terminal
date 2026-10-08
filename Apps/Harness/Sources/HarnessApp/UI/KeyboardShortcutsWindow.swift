import AppKit
import HarnessCore

/// Help ▸ Keyboard Shortcuts (⌘/): every key Harness answers to, from every source — the
/// menu bar, shortcuts assigned in the palette, keybindings.json (the prefix table only
/// while the prefix is on), and the Lua config. Rebuilt each time it opens, so it never
/// shows a binding that changed since.
@MainActor
final class KeyboardShortcutsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = KeyboardShortcutsWindow()

    private struct Row {
        var keys: String
        var action: String
        var source: String
    }

    private var panel: NSPanel?
    private let table = NSTableView()
    private let search = NSSearchField()
    private var all: [Row] = []
    private var shown: [Row] = []

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        all = Self.rows()
        let panel = panel ?? build()
        self.panel = panel
        search.stringValue = ""
        filter()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    // MARK: - Rows

    private static func rows() -> [Row] {
        var rows: [Row] = []
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
                if let submenu = item.submenu {
                    walk(submenu, path: path + [item.title])
                } else if !item.keyEquivalent.isEmpty {
                    rows.append(Row(keys: CommandPaletteController.shortcutText(item), action: item.title,
                                    source: path.joined(separator: " ▸ ")))
                }
            }
        }
        for top in NSApp.mainMenu?.items ?? [] {
            if let submenu = top.submenu { walk(submenu, path: [submenu.title]) }
        }

        let settings = SessionCoordinator.shared.settings
        let prefix = ParsedShortcut.parse(settings.prefixKey)?.displayString ?? settings.prefixKey
        let keymap = KeymapRow.rows(
            tables: KeybindingsService.shared.tables,
            manifest: ScriptStore.load(),
            palette: settings.paletteShortcuts
        )
        for row in keymap {
            switch row.source {
            case "palette":
                let title = CommandPaletteController.title(ofAction: row.action) ?? row.action
                rows.append(Row(keys: ParsedShortcut.parse(row.key)?.displayString ?? row.key, action: title, source: "Palette"))
            case "keybindings":
                let action = [row.action, row.args].filter { !$0.isEmpty }.joined(separator: " ")
                if row.key.hasPrefix("prefix ") {
                    guard settings.effectivePrefixKeyEnabled else { continue }
                    rows.append(Row(keys: "\(prefix) then \(row.key.dropFirst("prefix ".count))", action: action, source: "Prefix"))
                } else if let space = row.key.firstIndex(of: " "), !row.key.hasPrefix("root") {
                    rows.append(Row(keys: String(row.key[row.key.index(after: space)...]), action: action,
                                    source: "Key table \(row.key[..<space])"))
                } else {
                    rows.append(Row(keys: row.key, action: action, source: "Key table"))
                }
            default:
                let action = [row.action, row.args].filter { !$0.isEmpty }.joined(separator: " ")
                rows.append(Row(keys: row.key, action: action, source: "Lua (\(row.source))"))
            }
        }
        return rows
    }

    private func filter() {
        let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = needle.isEmpty ? all : all.filter {
            $0.action.lowercased().contains(needle) || $0.keys.lowercased().contains(needle) || $0.source.lowercased().contains(needle)
        }
        table.reloadData()
    }

    // MARK: - Window

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.minSize = NSSize(width: 420, height: 300)

        search.placeholderString = "Search shortcuts"
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("keys", "Keys", 150.0), ("action", "Action", 260.0), ("source", "Where", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Keyboard shortcuts")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(search)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        return panel
    }

    func controlTextDidChange(_ obj: Notification) {
        filter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        let text: String
        switch id {
        case "keys": text = entry.keys
        case "action": text = entry.action
        default: text = entry.source
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        if id == "keys" { field.font = .monospacedSystemFont(ofSize: 12, weight: .medium) }
        if id == "source" { field.textColor = .secondaryLabelColor }
        return field
    }
}
