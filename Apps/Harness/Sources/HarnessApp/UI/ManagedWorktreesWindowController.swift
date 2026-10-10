import AppKit
import HarnessCore

@MainActor
final class ManagedWorktreesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let endpoint: Endpoint
    private let repository = HarnessTextField(string: "")
    private let base = HarnessTextField(string: "")
    private let table = NSTableView()
    private let detail = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Loading managed worktrees…")
    private var records: [ManagedWorktree] = [], nextOffset: Int?
    private var buttons: [NSButton] = []
    private var requestID: UUID?
    private var closed = false
    var onClose: (() -> Void)?
    init(endpoint: Endpoint, directory: String, host: String) {
        self.endpoint = endpoint
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Managed Worktrees · " + host; window.minSize = NSSize(width: 780, height: 720)
        super.init(window: window); window.delegate = self
        repository.stringValue = directory; repository.placeholderString = "Repository working-tree directory"; repository.setAccessibilityLabel("Repository directory")
        base.placeholderString = "Committed base (empty requires a clean checkout)"; base.setAccessibilityLabel("Explicit committed base; uncommitted changes are never included")
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let explanation = NSTextField(wrappingLabelWithString: "New worktrees use a pinned commit outside the repository by default. A dirty checkout needs an explicitly selected committed base. Uncommitted changes are never copied. Cleanup protects changed files, active processes and unpushed new commits; committed branches remain addressable.")
        let repositoryField = HarnessToolPage.field("Repository directory", control: repository)
        let baseField = HarnessToolPage.field("Committed base", control: base, hint: "Leave blank to use the current commit of a clean checkout.")
        root.addArrangedSubview(explanation); root.addArrangedSubview(repositoryField); root.addArrangedSubview(baseField)
        for view in [explanation, repositoryField, baseField] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        for (id, title, width) in [("id", "Worktree ID", 180.0), ("directory", "Directory", 360), ("state", "State", 100), ("base", "Pinned commit", 150)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false; table.setAccessibilityLabel("Durable managed worktree records")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true; root.addArrangedSubview(scroll)
        let controls = NSStackView(); controls.spacing = 8
        let administration = NSStackView(); administration.spacing = 8
        for (title, action) in [("Create", #selector(create)), ("Inspect", #selector(inspect)), ("Compare", #selector(compare)), ("Open folder", #selector(openFolder)), ("Copy difftool command", #selector(difftool)), ("Clean up…", #selector(remove)), ("More", #selector(more)), ("Refresh", #selector(refresh)), ("Location…", #selector(configure))] {
            let button = HarnessToolPage.button(title, target: self, action: action, primary: title == "Create"); buttons.append(button)
            if ["Clean up…", "More", "Refresh", "Location…"].contains(title) { administration.addArrangedSubview(button) } else { controls.addArrangedSubview(button) }
        }
        let controlRows = HarnessToolPage.actionRows(controls.arrangedSubviews)
        let administrationRows = HarnessToolPage.actionRows(administration.arrangedSubviews)
        root.addArrangedSubview(controlRows); root.addArrangedSubview(administrationRows)
        detail.isEditable = false; detail.isRichText = false; detail.isSelectable = true; detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.setAccessibilityLabel("Worktree inspection, repository comparison and recovery details")
        let details = NSScrollView(); details.hasVerticalScroller = true; details.documentView = detail
        detail.isVerticallyResizable = true; detail.autoresizingMask = [.width]
        details.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true; root.addArrangedSubview(details); root.addArrangedSubview(status)
        for view in [scroll, controlRows, administrationRows, details, status] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        window.contentView = root; HarnessToolPage.group(root, title: "Starting point", views: [repositoryField, baseField]); HarnessToolPage.group(root, title: "Managed checkouts", views: [scroll, controlRows, administrationRows]); HarnessToolPage.group(root, title: "Inspection and comparison", views: [details]); HarnessToolPage.install(in: window, title: "Worktrees", subtitle: "Independent checkouts, a shared starting point, and safe cleanup.", symbol: "square.stack.3d.up", content: root); window.center(); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        closed = true
        if let id = requestID { let endpoint = endpoint; Task.detached { _ = try? DaemonClient(endpoint: endpoint).request(.cancelSearch(id: id), timeout: 2) } }
        onClose?()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "id": text = record.id.uuidString
        case "directory": text = record.directory
        case "state": text = record.state.rawValue
        default: text = String(record.baseCommit.prefix(12))
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = record.failure ?? text
        label.setAccessibilityLabel((tableColumn?.title ?? "") + ": " + text); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
        if let record = selected { detail.string = "Worktree " + record.id.uuidString + "\n" + record.directory + "\nPinned base: " + record.baseCommit + "\nBranch: " + record.branch + "\nState: " + record.state.rawValue + "\n" + ([record.note, record.failure].compactMap { $0 }.joined(separator: "\n")) }
    }
    private func updateActions() {
        let selectionActions: [Selector] = [#selector(inspect), #selector(compare), #selector(openFolder), #selector(difftool), #selector(remove)]
        for button in buttons {
            button.isEnabled = requestID == nil && (button.action != #selector(more) || nextOffset != nil)
                && (!selectionActions.contains(where: { $0 == button.action }) || selected != nil)
        }
    }
    private var selected: ManagedWorktree? { records.indices.contains(table.selectedRow) ? records[table.selectedRow] : nil }
    private func request(_ operation: WorktreeOperation, completion: @escaping @MainActor (String) -> Void) {
        guard requestID == nil, !closed else { return }
        let id = UUID(), endpoint = endpoint; requestID = id; buttons.forEach { $0.isEnabled = false }
        status.stringValue = "Working…"
        Task { @MainActor [weak self] in
            let response = await Task.detached { () -> IPCResponse in
                let client = DaemonClient(endpoint: endpoint)
                do {
                    guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.managedWorktrees) else { return .error("This host needs a newer application daemon for managed worktrees. Existing shells remain running during replacement.") }
                    return try client.request(.activity(.worktrees(requestID: id, operation: operation)), timeout: operation.requestTimeout)
                } catch { return .error(error.localizedDescription + ". Inspect the recorded worktree ID after an uncertain mutation; do not create a second operation blindly.") }
            }.value
            guard let self, !closed, requestID == id else { return }
            requestID = nil; updateActions()
            switch response {
            case let .text(json): status.stringValue = "Completed."; completion(json)
            case let .error(message): status.stringValue = message
            default: status.stringValue = "This host returned an unsupported worktree result."
            }
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, json: String) -> T? {
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) }
        catch { status.stringValue = "The host's worktree response could not be decoded. " + error.localizedDescription; return nil }
    }
    @objc private func refresh() { load(offset: 0) }
    @objc private func more() { if let nextOffset { load(offset: nextOffset) } }
    private func load(offset: Int) {
        request(.list(offset: offset, limit: 100)) { [weak self] json in
            guard let self, let page = decode(WorktreePage.self, json: json) else { return }
            let selectedID = selected?.id
            if offset == 0 { records = page.worktrees } else { records += page.worktrees }
            nextOffset = page.nextOffset; table.reloadData(); updateActions()
            if let selectedID, let index = records.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes([index], byExtendingSelection: false) }
            else if !records.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
            status.stringValue = page.historyUnavailable ?? "\(records.count) records. " + (nextOffset == nil ? "" : "More records are available.")
        }
    }
    @objc private func create() {
        let id = UUID(), directory = (repository.stringValue as NSString).expandingTildeInPath
        let reference = base.stringValue.isEmpty ? nil : base.stringValue
        detail.string = "Operation ID: " + id.uuidString + "\nRetain this ID for inspection if creation is interrupted. Uncommitted changes are never included."
        request(.create(id: id, directory: directory, base: reference)) { [weak self] json in self?.showRecord(json); self?.refresh() }
    }
    @objc private func inspect() { guard let record = selected else { return }; request(.inspect(id: record.id)) { [weak self] json in self?.showRecord(json) } }
    private func showRecord(_ json: String) {
        guard let record = decode(ManagedWorktree.self, json: json) else { status.stringValue = "The worktree record could not be decoded."; return }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        table.reloadData(); status.stringValue = record.failure ?? "Worktree state: " + record.state.rawValue
        detail.string = "Worktree " + record.id.uuidString + "\n" + record.directory + "\nPinned base: " + record.baseCommit + "\nState: " + record.state.rawValue + "\n" + ([record.note, record.failure].compactMap { $0 }.joined(separator: "\n"))
    }
    @objc private func compare() {
        guard let record = selected else { return }
        request(.compare(id: record.id)) { [weak self] json in
            guard let self, let comparison = decode(WorktreeComparison.self, json: json) else { return }
            let committed = comparison.committed, working = comparison.workingTree
            detail.string = "Repository state against pinned base " + comparison.worktree.baseCommit + "; observed " + comparison.observedAt.formatted(.iso8601) + "\nCommitted: \(committed.files) files, +\(committed.added)/−\(committed.removed), \(committed.binaryFiles) binary.\nWorking tree: \(working.files) files, +\(working.added)/−\(working.removed), \(working.binaryFiles) binary.\nUntracked: " + comparison.untrackedFiles.joined(separator: ", ") + "\nNo tracked test execution is inferred from repository state.\n\n" + (comparison.patchUnavailable ?? comparison.patch ?? "Patch unavailable")
        }
    }
    @objc private func openFolder() {
        guard endpoint == .localControlSocket else { status.stringValue = "This directory belongs to a remote host. Open it through an SSH session on that host."; return }
        guard let record = selected, FileManager.default.fileExists(atPath: record.directory), NSWorkspace.shared.open(URL(fileURLWithPath: record.directory)) else { status.stringValue = "This recorded worktree directory is unavailable."; return }
    }
    @objc private func difftool() {
        guard let record = selected else { return }
        request(.difftoolCommand(id: record.id)) { [weak self] json in
            guard let values = self?.decode([String: String].self, json: json), let command = values["command"] else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            self?.detail.string = command + "\n\nPrepared command copied. Review and execute it in a shell on this worktree’s recorded host to open its configured Git difftool. It is never submitted automatically."
        }
    }
    @objc private func remove() {
        guard let record = selected else { return }
        let alert = NSAlert(); alert.messageText = "Remove this managed worktree?"
        alert.informativeText = record.directory + "\nCleanup refuses dirty files, active processes and unpushed new commits. Its branch remains addressable. Inspect and Compare first if the outcome is uncertain."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove verified worktree")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        request(.remove(id: record.id)) { [weak self] json in self?.showRecord(json) }
    }
    @objc private func configure() {
        request(.configure(nil)) { [weak self] json in
            guard let self, let settings = decode(WorktreeSettings.self, json: json) else { return }
            let field = HarnessTextField(string: settings.directory ?? ""); field.frame = NSRect(x: 0, y: 0, width: 600, height: 28)
            field.placeholderString = "Empty uses Harness's private worktree directory"; field.setAccessibilityLabel("Optional absolute parent for managed worktrees")
            let alert = NSAlert(); alert.messageText = "Managed worktree location"
            alert.informativeText = "Choose an absolute parent. Harness creates a repository-specific directory beneath it. If inside the repository, only that generated directory is excluded. Existing worktrees keep their recorded locations."
            alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
            let path = field.stringValue.isEmpty ? nil : (field.stringValue as NSString).expandingTildeInPath
            request(.configure(WorktreeSettings(directory: path))) { [weak self] _ in self?.status.stringValue = "Worktree location saved with a backup. Existing recorded locations are preserved." }
        }
    }
}
