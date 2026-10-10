import AppKit
import HarnessCore

@MainActor
final class FanoutWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let endpoint: Endpoint, hostOwner: String
    private let repository = HarnessTextField(), base = HarnessTextField()
    private let shared = HarnessToggle(title: "Use the shared checkout instead of separate worktrees")
    private let prompt = NSTextView(), detail = NSTextView(), groupsTable = NSTableView(), participantsTable = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Loading fan-out history…")
    private var providerRows: [(FanoutProvider, HarnessSelect)] = []
    private var groups: [FanoutGroup] = [], nextOffset: Int?, buttons: [NSButton] = []
    private var requestID: UUID?, pendingGroupID: UUID?, closed = false
    var onClose: (() -> Void)?
    init(endpoint: Endpoint, directory: String, owner: String) {
        self.endpoint = endpoint; self.hostOwner = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Fan-out · " + owner; window.minSize = NSSize(width: 900, height: 700)
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 16, right: 16)
        repository.stringValue = directory; repository.placeholderString = "Choose a repository directory"
        repository.setAccessibilityLabel("Fan-out repository directory")
        base.placeholderString = "Current commit"; base.setAccessibilityLabel("Optional explicit committed base")
        let location = ToolSectionView("Starting point", views: [
            HarnessToolPage.field("Repository", control: repository),
            HarnessToolPage.field("Base commit", control: base, hint: "Leave blank to use a clean checkout. Uncommitted changes are not copied."), shared
        ])
        root.addArrangedSubview(location)
        var agents: [NSView] = []
        for provider in [AgentKind.codex, .claudeCode, .cursor] {
            let count = HarnessSelect(); count.widthAnchor.constraint(equalToConstant: 64).isActive = true; count.addItems(withTitles: (0...8).map(String.init)); count.selectItem(withTitle: provider == .codex ? "1" : "0")
            count.setAccessibilityLabel(provider.displayName + " participant count")
            let label = NSTextField(labelWithString: provider.displayName); label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let configure = HarnessToolPage.button("Profile and executable…", target: self, action: #selector(configureProvider(_:))); configure.tag = providerRows.count
            let row = NSStackView(views: [label, count, configure]); row.spacing = 12
            agents.append(row); providerRows.append((FanoutProvider(provider: provider), count))
        }
        let approval = NSTextField(wrappingLabelWithString: "Each provider keeps its approval settings. Headless agents may refuse tools that need interaction.")
        agents.append(approval)
        root.addArrangedSubview(ToolSectionView("Agents", views: agents))
        let launch = actionRow([("Start agents", #selector(start))])
        root.addArrangedSubview(ToolSectionView("Task", views: [textScroll(prompt, editable: true, height: 110, label: "Task prompt sent to each agent"), launch]))
        configureTable(groupsTable, columns: [("id", "Task", 300), ("base", "Base", 110), ("count", "Agents", 70), ("state", "Status", 300)], label: "Fan-out groups")
        configureTable(participantsTable, columns: [("provider", "Agent / profile", 200), ("state", "Outcome", 200), ("directory", "Working directory", 380)], label: "Fan-out participants")
        root.addArrangedSubview(ToolSectionView("Recent tasks", views: [tableScroll(groupsTable, height: 135), actionRow([("Refresh", #selector(refresh)), ("More", #selector(more)), ("Inspect", #selector(inspect)), ("Compare changes", #selector(compare))])]))
        root.addArrangedSubview(ToolSectionView("Selected task · agents", views: [tableScroll(participantsTable, height: 135), actionRow([("Jump to pane", #selector(jump)), ("Copy difftool command", #selector(difftool)), ("Run test…", #selector(test))]), actionRow([("Cancel workloads…", #selector(cancel)), ("Clean up…", #selector(cleanup))])]))
        root.addArrangedSubview(ToolSectionView("Execution details", views: [textScroll(detail, editable: false, height: 180, label: "Fan-out outcomes, repository comparisons and recovery details")], collapsible: true))
        root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        HarnessToolPage.install(in: window, title: "Fan-out", subtitle: "Give one task to several agents, then compare their work.", symbol: "arrow.triangle.branch", content: root); window.center(); refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func actionRow(_ actions: [(String, Selector)]) -> NSStackView {
        let row = NSStackView(); row.spacing = 8; row.alignment = .centerY
        for (title, action) in actions {
            let button = HarnessToolPage.button(title, target: self, action: action, primary: action == #selector(start))
            button.setAccessibilityLabel(title); row.addArrangedSubview(button); buttons.append(button)
        }
        return row
    }
    private func textScroll(_ text: NSTextView, editable: Bool, height: CGFloat, label: String) -> NSScrollView {
        text.isEditable = editable; text.isRichText = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.setAccessibilityLabel(label)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text; scroll.heightAnchor.constraint(equalToConstant: height).isActive = true; return scroll
    }
    private func configureTable(_ table: NSTableView, columns: [(String, String, Double)], label: String) {
        for (id, title, width) in columns { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column) }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false; table.setAccessibilityLabel(label)
    }
    private func tableScroll(_ table: NSTableView, height: CGFloat) -> NSScrollView { let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table; scroll.heightAnchor.constraint(equalToConstant: height).isActive = true; return scroll }
    private var selectedGroup: FanoutGroup? { groups.indices.contains(groupsTable.selectedRow) ? groups[groupsTable.selectedRow] : nil }
    private var selectedParticipant: FanoutParticipant? { guard let group = selectedGroup, group.participants.indices.contains(participantsTable.selectedRow) else { return nil }; return group.participants[participantsTable.selectedRow] }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === groupsTable ? groups.count : selectedGroup?.participants.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === groupsTable {
            guard groups.indices.contains(row) else { return nil }; let group = groups[row]
            switch tableColumn?.identifier.rawValue { case "id": text = group.prompt.map { String($0.split(whereSeparator: \.isNewline).first ?? "Untitled task").prefix(100).description } ?? "Task " + group.createdAt.formatted(date: .abbreviated, time: .shortened); case "base": text = String(group.baseCommit.prefix(12)); case "count": text = String(group.participants.count); default: text = group.participants.map { $0.state.rawValue }.joined(separator: ", ") }
        } else {
            guard let group = selectedGroup, group.participants.indices.contains(row) else { return nil }; let participant = group.participants[row]
            switch tableColumn?.identifier.rawValue { case "id": text = participant.id.uuidString; case "provider": text = participant.provider.provider.commandToken + " / " + participant.provider.profile; case "state": text = outcome(participant.outcome, fallback: participant.state.rawValue); default: text = participant.directory ?? "Not created" }
        }
        let label = NSTextField(labelWithString: text); label.font = HarnessDesign.Typography.sidebarLabel; label.textColor = HarnessChrome.current.textPrimary; label.lineBreakMode = .byTruncatingMiddle; label.toolTip = text; label.setAccessibilityLabel((tableColumn?.title ?? "") + ": " + text); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === groupsTable { participantsTable.reloadData(); if selectedGroup?.participants.isEmpty == false { participantsTable.selectRowIndexes([0], byExtendingSelection: false) } }
        showSelected()
    }
    private func outcome(_ value: WorkloadOutcome?, fallback: String) -> String {
        guard let value else { return fallback }
        let text = value.state == .exited ? "Process exited " + (value.exitCode.map(String.init) ?? "unknown") : value.state.rawValue
        return text + (value.cancellationRequested ? " · cancellation requested" : "")
    }
    private func showSelected() {
        updateActions()
        guard let group = selectedGroup else { detail.string = "Select a task to inspect its agents and outcomes."; return }
        detail.string = "Group " + group.id.uuidString + "\nPinned base: " + group.baseCommit + "\n" + (group.captureDisabled ? "Captured prompt and arguments were removed by persistence opt-out.\n" : "")
        for participant in group.participants {
            detail.string += "\n" + participant.id.uuidString + " · " + participant.provider.provider.commandToken + "\n" + (participant.directory ?? "Directory not created") + "\n" + outcome(participant.outcome, fallback: participant.state.rawValue) + "\n" + (participant.failure ?? "")
            if let launch = participant.launch { detail.string += "\nPrepared launch: " + ([launch.executable] + launch.arguments).map(ShellQuoting.quote).joined(separator: " ") + "\nApproval settings: provider defaults.\n" }
            for test in participant.tests { detail.string += "\nExplicit test " + test.id.uuidString + ": " + outcome(test.outcome, fallback: test.failure ?? "Outcome pending") + "\n" + (test.failure ?? "") }
        }
    }
    private func updateActions() {
        for button in buttons {
            if requestID != nil { button.isEnabled = button.action == #selector(cancel) && (pendingGroupID != nil || selectedGroup != nil); continue }
            switch button.action {
            case #selector(more): button.isEnabled = nextOffset != nil
            case #selector(inspect), #selector(compare), #selector(cancel), #selector(cleanup): button.isEnabled = selectedGroup != nil
            case #selector(jump): button.isEnabled = selectedParticipant != nil
            case #selector(difftool), #selector(test): button.isEnabled = selectedParticipant?.directory != nil && selectedParticipant?.cleanedUp == false
            default: button.isEnabled = true
            }
        }
    }
    private func perform(_ operation: FanoutOperation, completion: @escaping @MainActor (String) -> Void) {
        guard requestID == nil, !closed else { return }
        let id = UUID(), endpoint = endpoint; requestID = id
        updateActions(); status.stringValue = "Working…"
        Task { @MainActor [weak self] in
            let response = await Task.detached { () -> IPCResponse in
                do {
                    let client = DaemonClient(endpoint: endpoint)
                    guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.fanout) else { return .error(FanoutError.host.localizedDescription) }
                    return try client.request(.activity(.fanout(requestID: id, operation: operation)), timeout: operation.requestTimeout)
                } catch { return .error(error.localizedDescription + ". Inspect the saved group ID after an uncertain request; no launch is automatically repeated.") }
            }.value
            guard let self, !closed, requestID == id else { return }
            requestID = nil; pendingGroupID = nil
            switch response { case let .text(json): status.stringValue = "Completed request."; completion(json); case let .error(message): status.stringValue = message; default: status.stringValue = "Unsupported fan-out response." }
            updateActions()
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? { do { return try JSONDecoder().decode(type, from: Data(json.utf8)) } catch { status.stringValue = "The host response could not be decoded: " + error.localizedDescription; return nil } }
    private func replace(_ group: FanoutGroup) {
        let participantID = selectedParticipant?.id
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group } else { groups.insert(group, at: 0) }
        groupsTable.reloadData(); if let index = groups.firstIndex(where: { $0.id == group.id }) { groupsTable.selectRowIndexes([index], byExtendingSelection: false) }
        participantsTable.reloadData()
        if let participantID, let index = group.participants.firstIndex(where: { $0.id == participantID }) { participantsTable.selectRowIndexes([index], byExtendingSelection: false) }
        showSelected()
    }
    @objc private func configureProvider(_ sender: NSButton) {
        guard providerRows.indices.contains(sender.tag) else { return }; let value = providerRows[sender.tag].0
        let fields = [HarnessTextField(string: value.profile), HarnessTextField(string: value.executable ?? ""), HarnessTextField(string: value.providerHome ?? "")]
        for (field, label) in zip(fields, ["Harness profile label", "Optional absolute provider executable", "Optional provider configuration directory"]) { field.placeholderString = label; field.setAccessibilityLabel(label) }
        let rows = zip(fields, ["Profile label", "Executable (optional)", "Configuration directory (optional)"]).map { HarnessToolPage.field($0.1, control: $0.0) }
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.frame = NSRect(x: 0, y: 0, width: 620, height: 210)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let alert = NSAlert(); alert.messageText = value.provider.commandToken + " launch profile"; alert.informativeText = "The profile label identifies observed usage; it is not an account identity. Claude and Codex configuration directories select CLAUDE_CONFIG_DIR or CODEX_HOME. Cursor uses its normal installed configuration. Empty executable uses PATH. Approval settings remain unchanged."
        alert.accessoryView = stack; alert.addButton(withTitle: "Use configuration"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        providerRows[sender.tag].0 = FanoutProvider(provider: value.provider, executable: fields[1].stringValue.isEmpty ? nil : (fields[1].stringValue as NSString).expandingTildeInPath, profile: fields[0].stringValue,
            providerHome: fields[2].stringValue.isEmpty ? nil : (fields[2].stringValue as NSString).expandingTildeInPath)
    }
    @objc private func start() {
        let providers = providerRows.flatMap { value, count in Array(repeating: value, count: Int(count.titleOfSelectedItem ?? "0") ?? 0) }
        guard (1...8).contains(providers.count), !prompt.string.isEmpty, prompt.string.utf8.count <= 32 << 10 else { status.stringValue = FanoutError.invalid.localizedDescription; return }
        let id = UUID(); pendingGroupID = id; detail.string = "Group ID: " + id.uuidString + "\nInspect this ID after any interruption. Work already launched stays independently owned."
        let directory = (repository.stringValue as NSString).expandingTildeInPath
        perform(.start(id: id, directory: directory, base: base.stringValue.isEmpty ? nil : base.stringValue, workspaceID: nil, prompt: prompt.string, providers: providers, managedWorktrees: shared.state != .on)) { [weak self] json in guard let self, let group = decode(FanoutGroup.self, json) else { return }; replace(group) }
    }
    @objc private func refresh() { load(offset: 0) }
    @objc private func more() { if let nextOffset { load(offset: nextOffset) } }
    private func load(offset: Int) {
        perform(.list(offset: offset, limit: 100)) { [weak self] json in
            guard let self, let page = decode(FanoutPage.self, json) else { return }; let selected = selectedGroup?.id
            groups = offset == 0 ? page.groups : groups + page.groups; nextOffset = page.nextOffset; groupsTable.reloadData()
            if let selected, let index = groups.firstIndex(where: { $0.id == selected }) { groupsTable.selectRowIndexes([index], byExtendingSelection: false) }
            else if !groups.isEmpty { groupsTable.selectRowIndexes([0], byExtendingSelection: false) }
            status.stringValue = page.historyUnavailable ?? "Last observed outcomes; Inspect refreshes actual process receipts."
        }
    }
    @objc private func inspect() { guard let group = selectedGroup else { return }; perform(.inspect(id: group.id)) { [weak self] json in guard let self, let group = decode(FanoutGroup.self, json) else { return }; replace(group) } }
    @objc private func compare() {
        guard let group = selectedGroup else { return }; perform(.compare(id: group.id)) { [weak self] json in
            guard let self, let report = decode(FanoutComparison.self, json) else { return }; replace(report.group)
            for (id, comparison) in report.repositories.sorted(by: { $0.key < $1.key }) {
                let c = comparison.committed, w = comparison.workingTree
                detail.string += "\n\nRepository comparison for " + id + "\n" + comparison.worktree.directory + "\n" + (comparison.worktree.note ?? "") + "\nCommitted: \(c.files) files, +\(c.added)/−\(c.removed). Working tree: \(w.files) files, +\(w.added)/−\(w.removed).\nUntracked: " + comparison.untrackedFiles.joined(separator: ", ") + "\n" + (comparison.patchUnavailable ?? comparison.patch ?? "No patch captured")
            }
            for (id, failure) in report.failures { detail.string += "\n" + id + ": " + failure }
        }
    }
    @objc private func cancel() {
        guard let id = pendingGroupID ?? selectedGroup?.id else { return }
        let alert = NSAlert(); alert.messageText = "Cancel this group's recorded workloads?"; alert.informativeText = "Only processes belonging to its recorded launch identities are signaled. Accepted Git work is stopped at its cancellation boundary; partial worktrees remain for inspection. A requested cancellation is not a completed exit."; alert.addButton(withTitle: "Keep running"); alert.addButton(withTitle: "Cancel workloads")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        if requestID == nil { perform(.cancel(id: id)) { [weak self] json in guard let self, let group = decode(FanoutGroup.self, json) else { return }; replace(group) }; return }
        let endpoint = endpoint
        Task { @MainActor [weak self] in
            let response = await Task.detached { () -> IPCResponse in do { return try DaemonClient(endpoint: endpoint).request(.activity(.fanout(requestID: UUID(), operation: .cancel(id: id))), timeout: 15) } catch { return .error(error.localizedDescription) } }.value
            guard let self, !closed else { return }; if case let .error(message) = response { status.stringValue = message + ". Inspect group " + id.uuidString } else { status.stringValue = "Cancellation requested. Waiting for actual process outcomes." }
        }
    }
    @objc private func cleanup() {
        guard let group = selectedGroup else { return }
        let alert = NSAlert(); alert.messageText = "Clean up verified managed worktrees?"; alert.informativeText = "Cleanup refuses unresolved live roots, changed files, active descendants and unpushed new commits. A proven absent root can be cleaned up while its exit result remains unknown. Shared checkouts are never removed. Branches remain addressable. Inspect and Compare before cleanup."; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clean up")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        perform(.cleanup(id: group.id)) { [weak self] json in guard let self, let group = decode(FanoutGroup.self, json) else { return }; replace(group) }
    }
    @objc private func test() {
        guard let group = selectedGroup, let participant = selectedParticipant else { return }
        let executable = HarnessTextField(string: "/usr/bin/env"), arguments = HarnessTextField(string: "[]")
        executable.placeholderString = "Absolute executable"; arguments.placeholderString = "Argument array, e.g. [\"swift\",\"test\"]"
        executable.setAccessibilityLabel("Explicit test executable"); arguments.setAccessibilityLabel("Exact test arguments as a JSON string array")
        let rows = [HarnessToolPage.field("Executable", control: executable), HarnessToolPage.field("Arguments (JSON array)", control: arguments)]
        let stack = NSStackView(views: rows); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.frame = NSRect(x: 0, y: 0, width: 700, height: 140)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let alert = NSAlert(); alert.messageText = "Run an explicit test command"; alert.informativeText = "Directory: " + (participant.directory ?? "Unavailable") + "\nRuns once after the provider process exits. Arguments are passed separately. Only this tracked command's actual exit can produce a test result. No tests are inferred or automatically repeated."; alert.accessoryView = stack; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Run test")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        do {
            let values = try JSONDecoder().decode([String].self, from: Data(arguments.stringValue.utf8))
            perform(.test(id: group.id, participantID: participant.id, operationID: UUID(), executable: executable.stringValue, arguments: values)) { [weak self] json in guard let self, let group = decode(FanoutGroup.self, json) else { return }; replace(group) }
        } catch { status.stringValue = "Use a JSON array of separate string arguments. " + error.localizedDescription }
    }
    @objc private func jump() {
        guard let participant = selectedParticipant, let surface = UUID(uuidString: participant.surfaceID) else { return }
        let coordinator = SessionCoordinator.shared, snapshot = coordinator.snapshot(for: hostOwner)
        for workspace in snapshot.workspaces { for session in workspace.sessions { for tab in session.tabs where tab.rootPane.allLeaves().contains(where: { $0.surfaceID == surface }) {
            coordinator.showDaemon(hostOwner, session: session.id); coordinator.activate(owner: hostOwner, selecting: session.id); coordinator.selectTab(workspaceID: workspace.id, tabID: tab.id); coordinator.setActiveSurface(surface); return
        } } }
        status.stringValue = "The recorded terminal pane has closed. Its process receipt and managed worktree remain independently inspectable."
    }
    @objc private func difftool() {
        guard let group = selectedGroup, let participant = selectedParticipant, let directory = participant.directory, !participant.cleanedUp else { return }
        let command = "git -C " + ShellQuoting.quote(directory) + " difftool --no-prompt " + ShellQuoting.quote(group.baseCommit) + " --"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
        status.stringValue = "Prepared difftool command copied. Review and execute it on the recorded host; no command was submitted."
    }
    func windowWillClose(_ notification: Notification) {
        closed = true
        if let id = requestID { let endpoint = endpoint; Task.detached { _ = try? DaemonClient(endpoint: endpoint).request(.cancelSearch(id: id), timeout: 2) } }
        onClose?()
    }
}
