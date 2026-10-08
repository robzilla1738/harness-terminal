import AppKit
import HarnessCore

/// Go to Directory (⌥⌘G): browse folders on the daemon that owns the focused pane (this Mac
/// or a remote host) without leaving the keyboard. Type to filter; → or Tab opens a folder,
/// ← goes up; ↩ cds the pane there, ⌘↩ opens a new tab there, ⌥↩ types the path.
@MainActor
final class DirectoryBrowserController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var current: DirectoryBrowserController?

    enum Mode { case directory, insert }

    static func present(over window: NSWindow?, mode: Mode = .directory) {
        current?.close()
        guard let surface = SessionCoordinator.shared.activeSurfaceID else { return }
        let browser = DirectoryBrowserController(surface: surface, mode: mode)
        current = browser
        browser.show(over: window)
        browser.load(path: nil)
    }

    private let surface: SurfaceID
    private let mode: Mode
    private let endpoint: Endpoint
    private let sessionID: SessionID?
    private let scope = NSPopUpButton()
    private var pendingSearch: UUID?
    private var debounce: DispatchWorkItem?
    private let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let pathLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private var listing = PaneDirListing(root: "/", entries: [])
    /// Nothing listed yet (or the last listing failed): there's no folder to act on.
    private var loaded = false
    private var listedRoot: String?
    private var shown: [PaneDirEntry] = []
    private var loading = 0

    private init(surface: SurfaceID, mode: Mode) {
        self.surface = surface
        self.mode = mode
        endpoint = SessionCoordinator.shared.activeEndpoint
        sessionID = SessionCoordinator.shared.snapshot.activeWorkspace?.activeSessionID
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        field.placeholderString = mode == .insert ? "Find files and folders" : "Find folders"
        field.font = HarnessDesign.Typography.sidebarLabel
        field.delegate = self
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        let hint = NSTextField(labelWithString: mode == .insert ? "↩ insert selected paths   → open folder   ← up" : "↩ cd   ⌘↩ new tab   ⌥↩ insert path   → open   ← up")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.setAccessibilityLabel("Paths")
        table.allowsMultipleSelection = mode == .insert
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        scope.addItems(withTitles: ["Current Folder", "Project Files"])
        scope.target = self
        scope.action = #selector(scopeChanged)
        let stack = NSStackView(views: [field, scope, pathLabel, scroll, hint])
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
        debounce?.cancel()
        cancelSearch()
        loading += 1
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    private func cancelSearch() {
        guard let id = pendingSearch else { return }
        let endpoint = endpoint
        DispatchQueue.global(qos: .utility).async {
            do { _ = try DaemonClient(endpoint: endpoint).request(.cancelSearch(id: id)) }
            catch { fputs("Harness path search cancellation failed: \(error)\n", harnessStderr) }
        }
        pendingSearch = nil
    }

    @objc private func scopeChanged() { load(path: loaded ? listing.root : nil) }

    private func load(path: String?) {
        cancelSearch()
        loading += 1
        let ticket = loading, id = UUID()
        pendingSearch = id
        let client = DaemonClient(endpoint: endpoint)
        let surfaceID = surface.uuidString, query = field.stringValue
        let project = scope.indexOfSelectedItem == 1
        loaded = false
        pathLabel.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<PaneDirListing, Error> {
                let response = try client.request(.searchPaths(id: id, surfaceID: surfaceID, path: path, query: query, project: project), timeout: 10)
                if case let .error(message) = response { throw SetupError.invalid(message == "unrecognized request" ? "Update this host's daemon to use the path picker." : message) }
                guard case let .text(body) = response, let listing = PaneDirectory.decode(body) else { throw SetupError.invalid("Could not read this folder.") }
                return listing
            }
            DispatchQueue.main.async {
                guard ticket == self.loading else { return }
                self.pendingSearch = nil
                switch result {
                case let .success(listing):
                    self.loaded = true
                    self.listing = listing
                    self.listedRoot = listing.root
                    self.refresh()
                case let .failure(error): self.pathLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func refresh() {
        shown = listing.entries.filter { mode == .insert || $0.directory }
        pathLabel.stringValue = listing.root + (listing.entries.count == 200 ? " · First 200 results; narrow your search" : "")
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    private var selected: String {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].path : listing.root
    }

    @objc private func openSelected() {
        guard shown.indices.contains(table.selectedRow) else { return }
        guard shown[table.selectedRow].directory else { return }
        field.stringValue = ""
        scope.selectItem(at: 0)
        load(path: shown[table.selectedRow].path)
    }

    private func goUp() {
        field.stringValue = ""
        scope.selectItem(at: 0)
        let parent = (listing.root as NSString).deletingLastPathComponent
        load(path: parent.isEmpty ? "/" : parent)
    }

    private func finish(_ modifiers: NSEvent.ModifierFlags) {
        guard loaded else { return }
        let path = selected
        let request: IPCRequest
        if mode == .insert || modifiers.contains(.option) {
            let paths = table.selectedRowIndexes.filter { shown.indices.contains($0) }.map { shown[$0].path }
            let chosen = paths.isEmpty ? [path] : paths
            guard chosen.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
                pathLabel.stringValue = "Paths containing control characters cannot be inserted safely."
                return
            }
            request = .send(surfaceID: surface.uuidString, text: PaneDirectory.insertion(chosen))
        } else if modifiers.contains(.command), let sessionID {
            request = .newTabInSession(sessionID: sessionID, cwd: path)
        } else {
            guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
                pathLabel.stringValue = "Paths containing control characters cannot be inserted safely."
                return
            }
            request = .send(surfaceID: surface.uuidString, text: PaneDirectory.goToDirectory(path) + "\r")
        }
        let endpoint = endpoint
        loaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<IPCResponse, Error> { try DaemonClient(endpoint: endpoint).request(request) }
            DispatchQueue.main.async {
                self.loaded = true
                switch result {
                case let .success(.error(message)): self.pathLabel.stringValue = message
                case .success: self.close(); SessionCoordinator.shared.refreshSnapshot()
                case let .failure(error): self.pathLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel()
        cancelSearch()
        loading += 1
        let path = listedRoot
        loaded = false
        let work = DispatchWorkItem { [weak self] in self?.load(path: path) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

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
        let label = NSTextField(labelWithString: shown[row].name + (shown[row].directory ? "/" : ""))
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
