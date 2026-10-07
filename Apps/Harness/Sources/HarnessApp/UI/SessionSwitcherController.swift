import AppKit
import HarnessCore

/// Floating session switcher: filter field, a check on the current session, and the
/// existing new-session and add-remote actions. Colors come from the shared palette.
@MainActor
enum SessionSwitcherController {
    private static var panel: NSPanel?

    static func present(relativeTo parent: NSWindow?, anchor: NSView? = nil) {
        panel?.close()
        let host = SessionSwitcherView()
        let window = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = host
        if let anchor, let anchorWindow = anchor.window {
            // Drop down from the button, left edges aligned.
            let rect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            window.setFrameTopLeftPoint(NSPoint(x: rect.minX, y: rect.minY - HarnessDesign.Spacing.xs))
        } else if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - 160, y: frame.midY - 40))
        }
        window.makeKeyAndOrderFront(nil)
        panel = window
        host.onClose = { window.close() }
    }
}

@MainActor
private final class SessionSwitcherView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onClose: (() -> Void)?
    private let filter = NSTextField()
    private let table = NSTableView()
    private var rows: [ChromeMenuRow] = []
    private var query = ""
    private var selectedID: String?
    private var applyingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let c = HarnessChrome.current
        layer?.backgroundColor = c.sidebarBackground.cgColor
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = c.border.cgColor

        filter.isBezeled = false
        filter.isBordered = false
        filter.drawsBackground = false
        filter.focusRingType = .none
        filter.font = HarnessDesign.Typography.sidebarLabel
        filter.textColor = c.textPrimary
        filter.placeholderString = "Filter or create..."
        filter.delegate = self
        filter.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(filter)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            filter.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        reloadRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) {
        query = filter.stringValue
        reloadRows()
    }

    private func reloadRows() {
        let workspace = SessionCoordinator.shared.snapshot.activeWorkspace
        let sessions = (workspace?.sessions ?? []).map { session -> (id: String, title: String) in
            let tab = session.activeTab ?? session.tabs.first
            let title = tab.map {
                SurfaceIdentity.label(directory: $0.cwd, program: $0.currentCommand, agent: $0.agent?.kind.commandToken)
            } ?? (session.name.isEmpty ? "Session" : session.name)
            return (session.id.uuidString, title)
        }
        if selectedID == nil {
            selectedID = workspace?.activeSessionID?.uuidString
        }
        let built = ChromeMenus.sessionRows(
            sessions: sessions,
            currentID: workspace?.activeSessionID?.uuidString,
            selectedID: selectedID
        )
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rows = needle.isEmpty ? built : built.filter { $0.title.lowercased().contains(needle) || $0.id.hasPrefix("action.") }
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) {
            self.selectedID = rows.first(where: \.current)?.id ?? rows.first?.id
            reloadRows()
            return
        }
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            applyingSelection = true
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            applyingSelection = false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SessionSwitcherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let chrome = HarnessChrome.current
        let label = NSTextField(labelWithString: item.current ? "✓  \(item.title)" : item.title)
        label.font = HarnessDesign.Typography.sidebarLabel
        label.textColor = item.selected ? chrome.activePillLabel : chrome.textPrimary
        if item.shortcut.isEmpty == false {
            label.stringValue += "    \(item.shortcut)"
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        selectedID = rows[index].id
        reloadRows()
        guard rows.indices.contains(index) else { return }
        let item = rows[index]
        let coordinator = SessionCoordinator.shared
        switch item.id {
        case "action.newSession":
            if let id = coordinator.snapshot.activeWorkspaceID { coordinator.addSession(to: id) }
        case "action.addRemoteHost":
            MenuTarget.shared.addRemoteHost()
        default:
            if let uuid = UUID(uuidString: item.id),
               let workspaceID = coordinator.snapshot.activeWorkspaceID {
                coordinator.selectSession(workspaceID: workspaceID, sessionID: uuid)
            }
        }
        onClose?()
    }
}

/// Selected session row. The fill and label come from the shared pill colors,
/// not the system table highlight.
@MainActor
private final class SessionSwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        HarnessChrome.current.activePillFill.setFill()
        let rect = bounds.insetBy(dx: 4, dy: 2)
        NSBezierPath(roundedRect: rect, xRadius: HarnessDesign.Radius.control, yRadius: HarnessDesign.Radius.control).fill()
    }
}
