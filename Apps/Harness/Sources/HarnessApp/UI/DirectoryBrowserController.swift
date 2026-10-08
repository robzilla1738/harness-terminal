import AppKit
import HarnessCore

/// Go to Directory (⌥⌘G): browse folders on the daemon that owns the focused pane (this Mac
/// or a remote host) without leaving the keyboard. Type to filter; → or Tab opens a folder,
/// ← goes up; ↩ cds the pane there, ⌘↩ opens a new tab there, ⌥↩ types the path.
@MainActor
final class DirectoryBrowserController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: DirectoryBrowserController?

    static func present(over window: NSWindow?) {
        current?.close()
        guard let surface = SessionCoordinator.shared.activeSurfaceID else { return }
        let browser = DirectoryBrowserController(surface: surface)
        current = browser
        browser.show(over: window)
        browser.load(path: nil)
    }

    private let surface: SurfaceID
    private let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let pathLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var listing = PaneDirListing(root: "/", entries: [])
    private var shown: [PaneDirEntry] = []
    private var loading = 0

    private init(surface: SurfaceID) {
        self.surface = surface
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = "Filter folders"
        field.font = HarnessDesign.Typography.sidebarLabel
        field.delegate = self
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        let hint = NSTextField(labelWithString: "↩ cd   ⌘↩ new tab   ⌥↩ insert path   → open   ← up")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let stack = NSStackView(views: [field, pathLabel, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 14, bottom: 12, right: 14)
        for view in [field, pathLabel, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        panel.contentView = stack
    }

    private func show(over window: NSWindow?) {
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 80))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    /// List `path` (nil: the pane's cwd) on the pane's daemon, off the main thread.
    private func load(path: String?) {
        loading += 1
        let ticket = loading
        let client = DaemonClient(endpoint: SessionCoordinator.shared.activeEndpoint)
        let surfaceID = surface.uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            let response = try? client.request(.listDir(surfaceID: surfaceID, path: path), timeout: 5)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.loading, case let .text(body)? = response, let listing = PaneDirectory.decode(body) else { return }
                    self.listing = listing
                    self.field.stringValue = ""
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = listing.entries.filter { $0.directory && (query.isEmpty || $0.name.lowercased().contains(query)) }
        pathLabel.stringValue = listing.root
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private var selected: String {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].path : listing.root
    }

    @objc private func openSelected() {
        guard shown.indices.contains(table.selectedRow) else { return }
        load(path: shown[table.selectedRow].path)
    }

    private func goUp() {
        let parent = (listing.root as NSString).deletingLastPathComponent
        load(path: parent.isEmpty ? "/" : parent)
    }

    private func finish(_ modifiers: NSEvent.ModifierFlags) {
        let path = selected
        close()
        let coordinator = SessionCoordinator.shared
        if modifiers.contains(.command), let workspace = coordinator.snapshot.activeWorkspaceID {
            coordinator.addTab(to: workspace, cwd: path)
        } else if modifiers.contains(.option) {
            coordinator.requestDaemon(.send(surfaceID: surface.uuidString, text: PaneDirectory.insertion([path])))
        } else {
            coordinator.requestDaemon(.send(surfaceID: surface.uuidString, text: PaneDirectory.goToDirectory(path) + "\r"))
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.insertTab(_:)): openSelected()
        case #selector(NSResponder.moveLeft(_:)) where field.stringValue.isEmpty: goUp()
        case #selector(NSResponder.insertNewline(_:)): finish(NSApp.currentEvent?.modifierFlags ?? [])
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func step(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let next = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row].name + "/")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
