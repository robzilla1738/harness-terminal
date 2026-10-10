import AppKit
import HarnessCore

private struct BoardTarget: Sendable { var owner: String, endpoint: Endpoint?, snapshot: SessionSnapshot }
private struct BoardHostResult: Sendable {
    var target: BoardTarget, runs: [AgentRun], usage: UsageSummary?, resources: [String: PaneResources]
    var observedAt: Date?, error: String?, legacy: Bool
    var capabilities: Set<String> = []
    var stale = false
}
private struct BoardRow: Sendable {
    var id: String, owner: String, leaf: PaneLeaf, workspaceID: WorkspaceID, sessionID: SessionID, tabID: TabID
    var title: String, directory: String, run: AgentRun?, usage: ProfileUsage?, resources: PaneResources?
    var observedAt: Date?, error: String?, legacy: Bool, stale: Bool
    var needsYou: Bool { run?.attention != nil && run?.attention != RunAttention.none && (leaf.activity?.snoozedUntil ?? .distantPast) < .now }
}

private enum BoardEntry: Sendable {
    case pane(BoardRow)
    case host(owner: String, message: String, observedAt: Date?)
    var pane: BoardRow? { if case let .pane(row) = self { return row }; return nil }
    var owner: String { switch self { case let .pane(row): row.owner; case let .host(owner, _, _): owner } }
    var id: String { pane?.id ?? owner + ":host" }
    var title: String { pane?.title ?? "Host status" }
    var directory: String { pane?.directory ?? "" }
    var run: AgentRun? { pane?.run }
    var needsYou: Bool { pane?.needsYou ?? false }
}

/// A mode of the existing Overview. Requests are bounded to four concurrent hosts,
/// stale host results stay visible, and selection follows identity through updates.
@MainActor
final class AgentBoardView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    let filterField = HarnessSearchField()
    private let stateFilter = HarnessSelect()
    private let sort = HarnessSelect()
    private let table = NSTableView()
    private let detail = NSTextView()
    private let status = NSTextField(labelWithString: "Loading activity…")
    private var repositoryPageOffset = 0
    private let repositoryReportsButton = HarnessPillButton(title: "Repository reports", kind: .secondary)
    private let digestButton = HarnessPillButton(title: "Digest", kind: .secondary)
    private let workers = OperationQueue()
    private var timer: Timer?
    private var rows: [BoardEntry] = [], shown: [BoardEntry] = []
    private var results: [String: BoardHostResult] = [:]
    private var pending = 0, generation = 0, stopped = false
    private var selectedID: String?
    private var updatingRows = false
    private var paneControls: [NSButton] = []
    private var resourceOffset = 0
    private var detailOperation: Operation?
    private var detailRequest: (id: UUID, endpoint: Endpoint)?
    private var dismissedDigestRevision: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        workers.name = "com.harness.board"; workers.maxConcurrentOperationCount = 4
        wantsLayer = true; layer?.backgroundColor = HarnessChrome.current.terminalBackground.withAlphaComponent(0.96).cgColor
        filterField.placeholderString = "Filter hosts, agents, directories…"; filterField.onChange = { [weak self] _ in self?.filtersChanged() }
        filterField.setAccessibilityLabel("Filter agent Board")
        stateFilter.addItems(withTitles: ["All states", "Working", "Needs attention", "Idle"])
        sort.addItems(withTitles: ["Attention first", "Recent activity", "Host", "Agent"])
        for control in [stateFilter, sort] { control.target = self; control.action = #selector(filtersChanged) }
        stateFilter.setAccessibilityLabel("Filter activity state"); sort.setAccessibilityLabel("Sort Board")
        let header = NSStackView(views: [filterField, stateFilter, sort]); header.orientation = .horizontal; header.spacing = 10
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(jump)
        table.allowsMultipleSelection = false; table.rowHeight = 27; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Agents across connected hosts")
        for (id, name, width) in [("host", "Host", 105.0), ("agent", "Agent / pane", 150), ("state", "State", 120), ("directory", "Directory", 220), ("usage", "Profile tokens in / out", 160), ("cpu", "Tree CPU", 80), ("rss", "Tree RSS", 95), ("freshness", "Observed", 150)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = name; column.width = width
            column.minWidth = 65; table.addTableColumn(column)
        }
        let detailsScroll = NSScrollView(); detailsScroll.hasVerticalScroller = true; detailsScroll.documentView = detail
        detail.isEditable = false; detail.isSelectable = true; detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = HarnessChrome.current.textPrimary; detail.backgroundColor = .clear
        detail.textContainerInset = NSSize(width: 12, height: 12); detail.autoresizingMask = [.width]; detail.isVerticallyResizable = true
        detail.setAccessibilityLabel("Selected agent details and digest")
        let jumpButton = button("Jump", #selector(jump)), peek = button("Peek", #selector(peek))
        let snooze = button("Snooze 15 min", #selector(snooze)), resources = button("Resources", #selector(showResources))
        let terminate = button("Stop process tree…", #selector(stopTree))
        let resume = button("Resume…", #selector(resumeConversation))
        let copyOutput = button("Copy command output", #selector(copyCommandOutput))
        let explain = button("Explain output…", #selector(explainCommandOutput))
        repositoryReportsButton.target = self; repositoryReportsButton.action = #selector(showRepositoryReports)
        repositoryReportsButton.setAccessibilityLabel("Paginated repository activity reports")
        digestButton.target = self; digestButton.action = #selector(showDigest)
        let dismiss = button("Dismiss digest indicator", #selector(dismissDigest))
        let paneActions = [jumpButton, peek, snooze, button("Mute / unmute agent", #selector(toggleAgentMute)), resources, button("Usage", #selector(showUsage))]
        let reportActions: [NSButton] = [digestButton, repositoryReportsButton, dismiss]
        let commandActions = [resume, button("Restore behavior…", #selector(configureResumePolicy)), copyOutput, explain, button("Tool timeline…", #selector(showToolTimeline)), terminate]
        paneControls = (paneActions + reportActions + commandActions).filter { $0 !== dismiss }
        let controls = HarnessToolPage.actionRows(paneActions)
        let reportControls = HarnessToolPage.actionRows(reportActions)
        let commandControls = HarnessToolPage.actionRows(commandActions)
        let stack = NSStackView(views: [header, scroll, controls, reportControls, commandControls, detailsScroll, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        NSLayoutConstraint.activate([
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            stateFilter.widthAnchor.constraint(equalToConstant: 150), sort.widthAnchor.constraint(equalToConstant: 150),
            scroll.heightAnchor.constraint(equalToConstant: 220), detailsScroll.heightAnchor.constraint(equalToConstant: 180)
        ])
        HarnessToolPage.group(stack, title: "Selected agent", views: [controls, commandControls])
        HarnessToolPage.group(stack, title: "Activity reports", views: [reportControls, detailsScroll])
        let page = HarnessToolPage(title: "Board", subtitle: "Agents and activity across your connected hosts.", symbol: "square.grid.2x2", content: stack)
        page.translatesAutoresizingMaskIntoConstraints = false; addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor, constant: 40), page.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        HarnessToolPage.button(title, target: self, action: action)
    }
    func stop() { stopped = true; generation += 1; timer?.invalidate(); timer = nil; workers.cancelAllOperations(); cancelDetail() }
    private func refresh() {
        guard !stopped, pending == 0 else { return }
        let coordinator = SessionCoordinator.shared
        let owners = Set(coordinator.connectedOwners + RemoteHostsService.shared.hosts().map(\.name))
        let targets = owners.sorted().map { BoardTarget(owner: $0, endpoint: coordinator.endpoint(forOwner: $0), snapshot: coordinator.snapshot(for: $0)) }
        pending = targets.count; generation += 1; let ticket = generation, offset = resourceOffset
        resourceOffset += 8
        for target in targets {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let operation, !operation.isCancelled else { return }
                let result = Self.fetch(target, resourceOffset: offset, cancelled: { operation.isCancelled })
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped, ticket == self.generation else { return }
                    self.accept(result); self.pending -= 1
                }
            }
            workers.addOperation(operation)
        }
    }
    private nonisolated static func fetch(_ target: BoardTarget, resourceOffset: Int, cancelled: () -> Bool) -> BoardHostResult {
        var result = BoardHostResult(target: target, runs: [], usage: nil, resources: [:], observedAt: nil, error: nil, legacy: false)
        guard let endpoint = target.endpoint else { result.error = "Offline — connect this host to load activity"; result.stale = true; return result }
        do {
            let client = DaemonClient(endpoint: endpoint)
            guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1) else { throw DaemonClientError.unexpectedResponse }
            result.capabilities = Set(stats.capabilities ?? [])
            if stats.supports(DaemonStats.activityHistory) {
                var offset = 0
                repeat {
                    if cancelled() { return result }
                    guard case let .text(json) = try client.request(.activity(.list(hostID: nil, surfaceID: nil, activeOnly: true, offset: offset, limit: 500, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])), timeout: 1) else { throw DaemonClientError.unexpectedResponse }
                    let page = try JSONDecoder().decode(RunPage.self, from: Data(json.utf8))
                    result.runs += page.runs; result.observedAt = page.observedAt; result.error = page.historyUnavailable
                    guard let next = page.nextOffset else { break }; offset = next
                } while result.runs.count < 4096
            } else { result.legacy = true; result.observedAt = .now }
            if stats.supports(DaemonStats.usageDigest), !cancelled() {
                let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400)
                if case let .text(json) = try client.request(.activity(.usage(from: to.addingTimeInterval(-86400), to: to)), timeout: 1) { result.usage = try JSONDecoder().decode(UsageSummary.self, from: Data(json.utf8)) }
            }
            if stats.supports(DaemonStats.paneResources) {
                let surfaces = target.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { $0.rootPane.allLeaves().filter { $0.paneContent.isTerminal }.map(\.surfaceID) }
                let start = resourceOffset % max(1, surfaces.count)
                for index in 0..<min(8, surfaces.count) where !cancelled() {
                    let surface = surfaces[(start + index) % surfaces.count]
                    if case let .text(json)? = try? client.request(.activity(.resources(surfaceID: surface.uuidString)), timeout: 0.5),
                       let sample = try? JSONDecoder().decode(PaneResources.self, from: Data(json.utf8)) { result.resources[surface.uuidString] = sample }
                }
            }
        } catch { result.stale = true; result.error = "Host unavailable; retained rows are stale. " + error.localizedDescription }
        return result
    }
    private func accept(_ result: BoardHostResult) {
        var updated = result
        if result.observedAt == nil, let previous = results[result.target.owner] {
            updated.runs = previous.runs; updated.observedAt = previous.observedAt; updated.usage = previous.usage
            updated.resources = previous.resources; updated.target.snapshot = previous.target.snapshot
        } else if let previous = results[result.target.owner] {
            updated.resources.merge(previous.resources) { current, _ in current }
        }
        results[result.target.owner] = updated
        let ownerSet = Set(SessionCoordinator.shared.connectedOwners + RemoteHostsService.shared.hosts().map(\.name))
        results = results.filter { ownerSet.contains($0.key) }
        rows = results.values.flatMap { host in
            host.target.snapshot.workspaces.flatMap { workspace in workspace.sessions.flatMap { session in session.tabs.flatMap { tab in
                tab.rootPane.allLeaves().map { leaf in
                    let run = host.runs.filter { $0.surfaceID == leaf.surfaceID.uuidString && $0.parentRunID == nil }.max { $0.startedAt < $1.startedAt }
                    let profile = run.flatMap { run in host.usage?.profiles.first { $0.profile == run.profile && $0.provider == run.provider } }
                    return BoardEntry.pane(BoardRow(id: host.target.owner + ":" + leaf.surfaceID.uuidString, owner: host.target.owner, leaf: leaf,
                        workspaceID: workspace.id, sessionID: session.id, tabID: tab.id, title: tab.title.isEmpty ? session.name : tab.title,
                        directory: leaf.cwd ?? tab.cwd, run: run, usage: profile, resources: host.resources[leaf.surfaceID.uuidString],
                        observedAt: host.observedAt, error: host.error, legacy: host.legacy, stale: host.stale))
                }
            } } }
        }
        for host in results.values where !rows.contains(where: { $0.owner == host.target.owner }) {
            rows.append(.host(owner: host.target.owner, message: host.error ?? "Connected host has no panes.", observedAt: host.observedAt))
        }
        rebuild()
        let offline = results.values.filter { $0.target.endpoint == nil || $0.observedAt == nil }.count
        status.stringValue = "\(rows.compactMap(\.pane).count) panes · \(offline) offline hosts · CPU is sampled over the displayed interval; usage is profile-wide for today (UTC)."
        if rows.isEmpty { detail.string = results.values.compactMap { $0.error }.joined(separator: "\n") }
        let revision = results.values.flatMap(\.runs).map { $0.id.uuidString + ":" + String($0.observedAt.timeIntervalSince1970) }.sorted().joined(separator: ";")
        let changed = !revision.isEmpty && revision != dismissedDigestRevision
        digestButton.setTitleText(changed ? "Digest •" : "Digest")
        digestButton.setAccessibilityLabel(changed ? "Activity digest, updates available" : "Activity digest")
    }
    @objc private func filtersChanged() { rebuild() }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    private func rebuild() {
        // AppKit may notify selection changes while reloadData is replacing rows.
        // Preserve identity until the final selection has been restored.
        let priorSelection = selectedID
        updatingRows = true
        defer { updatingRows = false; updateSelection() }
        let query = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = rows.filter { row in
            let matches = query.isEmpty || [row.owner, row.title, row.directory, row.run?.provider.displayName ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            switch stateFilter.indexOfSelectedItem {
            case 1: return matches && row.run?.turn == .working
            case 2: return matches && row.needsYou
            case 3: return matches && row.run?.turn != .working
            default: return matches
            }
        }.sorted { a, b in
            switch sort.indexOfSelectedItem {
            case 1: if a.run?.observedAt != b.run?.observedAt { return (a.run?.observedAt ?? .distantPast) > (b.run?.observedAt ?? .distantPast) }
            case 2: if a.owner != b.owner { return a.owner < b.owner }
            case 3: if a.run?.provider != b.run?.provider { return (a.run?.provider.displayName ?? "") < (b.run?.provider.displayName ?? "") }
            default: if a.needsYou != b.needsYou { return a.needsYou }
            }
            return a.id < b.id
        }
        table.reloadData()
        if let priorSelection, let index = shown.firstIndex(where: { $0.id == priorSelection }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        paneControls.forEach { $0.isEnabled = selected != nil }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard shown.indices.contains(index), let key = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        guard let row = shown[index].pane else {
            guard case let .host(owner, message, observedAt) = shown[index] else { return nil }
            switch key {
            case "host": text = owner
            case "agent": text = "Host status"
            case "state": text = observedAt == nil ? "Offline" : "No panes"
            case "directory": text = message
            case "freshness": text = observedAt?.formatted(date: .omitted, time: .standard) ?? "unavailable"
            default: text = "not applicable"
            }
            let label = NSTextField(labelWithString: text)
            label.lineBreakMode = .byTruncatingMiddle; label.toolTip = message
            label.setAccessibilityLabel((tableColumn?.title ?? key) + ": " + text + ". " + message)
            return label
        }
        switch key {
        case "host": text = row.owner
        case "agent": text = row.leaf.paneContent.isTerminal ? row.run?.provider.displayName ?? row.title : "Preview · " + row.title
        case "state": text = row.run.map { $0.attention == .none ? $0.turn.rawValue : $0.attention.rawValue } ?? (row.leaf.paneContent.isTerminal ? (row.legacy ? "Legacy observation" : "Terminal") : row.leaf.paneContent.kind)
        case "directory": text = row.directory
        case "usage": text = row.leaf.paneContent.isTerminal ? "\(row.usage?.counters.input.map(String.init) ?? "unknown") / \(row.usage?.counters.output.map(String.init) ?? "unknown")" : "not applicable"
        case "cpu": text = !row.leaf.paneContent.isTerminal ? "not applicable" : row.resources?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "unknown"
        case "rss": text = !row.leaf.paneContent.isTerminal ? "not applicable" : row.resources.map { ByteCountFormatter.string(fromByteCount: Int64($0.residentBytes), countStyle: .memory) } ?? "unknown"
        default: text = row.observedAt.map { $0.formatted(date: .omitted, time: .standard) + (row.stale ? " · stale" : "") } ?? "offline"
        }
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingMiddle
        let warning = [row.error, row.usage?.unavailable].compactMap { $0 } + (row.usage?.coverageWarnings ?? [])
        label.toolTip = ([text] + warning).joined(separator: "\n")
        label.setAccessibilityLabel((tableColumn?.title ?? key) + ": " + ([text] + warning).joined(separator: ". ")); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingRows else { return }
        updateSelection()
    }
    private func updateSelection() {
        paneControls.forEach { $0.isEnabled = selected != nil }
        let selection = shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
        if selectedID != selection?.id {
            repositoryPageOffset = 0; repositoryReportsButton.setTitleText("Repository reports"); cancelDetail()
            detail.string = ""
        }
        selectedID = selection?.id
        if case let .host(_, message, _)? = selection { detail.string = message + "\nUse Remote ▸ Connect or Retry Connection after checking the host configuration." }
    }
    private var selected: BoardRow? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].pane : nil }
    @objc private func jump() {
        guard let row = selected else { return }
        let coordinator = SessionCoordinator.shared
        guard coordinator.endpoint(forOwner: row.owner) != nil else { detail.string = "Connect this host before opening its pane."; return }
        onClose?(); coordinator.showDaemon(row.owner, session: row.sessionID); coordinator.activate(owner: row.owner, selecting: row.sessionID)
        coordinator.selectTab(workspaceID: row.workspaceID, tabID: row.tabID); coordinator.setActiveSurface(row.leaf.surfaceID); coordinator.focusPaneContent(row.leaf.surfaceID)
    }
    private func cancelDetail() {
        detailOperation?.cancel()
        if let pending = detailRequest {
            detailRequest = nil
            DispatchQueue.global(qos: .utility).async {
                _ = try? DaemonClient(endpoint: pending.endpoint).request(.cancelSearch(id: pending.id), timeout: 1)
            }
        }
    }
    private func query(_ request: IPCRequest, row: BoardRow, render: @escaping @MainActor @Sendable (IPCResponse) -> String) {
        guard let endpoint = SessionCoordinator.shared.endpoint(forOwner: row.owner) else { detail.string = "This host is offline."; return }
        cancelDetail(); detail.string = "Loading…"
        let operation = BlockOperation(); detailOperation = operation
        if case let .activity(.repositoryDigest(id, _, _, _, _)) = request { detailRequest = (id, endpoint) }
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let timeout: TimeInterval
            if case .activity(.repositoryDigest) = request { timeout = 6 } else { timeout = 2 }
            let response: IPCResponse
            if case .activity(.repositoryDigest) = request,
               (try? DaemonClient(endpoint: endpoint).request(.daemonStats, timeout: 1)).flatMap({ reply -> Bool? in
                   guard case let .daemonStats(stats) = reply else { return nil }; return stats.supports(DaemonStats.repositoryDigest)
               }) != true {
                response = .error("This host does not advertise the repository-digest capability. Reconnect or replace its application daemon; shells remain running.")
            } else { response = (try? DaemonClient(endpoint: endpoint).request(request, timeout: timeout)) ?? .error("The host did not respond. Try again after reconnecting.") }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !operation.isCancelled else { return }
                self.detailRequest = nil
                self.detail.string = render(response)
            }
        }
        workers.addOperation(operation)
    }
    @objc private func showToolTimeline() {
        guard let row = selected, let endpoint = SessionCoordinator.shared.endpoint(forOwner: row.owner),
              let runID = row.run?.id ?? row.leaf.lastAgentRunID else { detail.string = "Select a pane with a recorded execution."; return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var offset = 0
            while !stopped {
                let pageOffset = offset
                let response = await Task.detached {
                    (try? DaemonClient(endpoint: endpoint).request(.activity(.session(hostID: nil, runID: runID, offset: pageOffset, limit: 100, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])), timeout: 2)) ?? .error("This host is unavailable.")
                }.value
                guard !stopped else { return }
                guard case let .text(json) = response, let page = try? JSONDecoder().decode(AgentRunSession.self, from: Data(json.utf8)) else { detail.string = Self.responseError(response); return }
                let events = page.events.filter { [.toolStarted, .toolCompleted, .permissionRequested].contains($0.kind) }
                let lines = events.map { event in
                    event.at.formatted(.iso8601) + " · " + event.kind.rawValue + " · " + (event.toolName ?? "tool name unavailable") + " · tool " + (event.toolID ?? "unavailable") + " · sequence " + (event.terminalSequence.map(String.init) ?? "unavailable") + " · anchor " + (event.anchorAvailability?.rawValue ?? "unavailable")
                }
                detail.string = "Recorded tool events for execution " + runID.uuidString + "\nSequence anchors mark when observations reached Harness; concurrent tools do not have precisely attributable output ranges.\n" + (page.historyUnavailable ?? "") + "\n\n" + (lines.isEmpty ? "No tool events on this event page." : lines.joined(separator: "\n"))
                guard page.nextOffset != nil || offset > 0 else { return }
                let alert = NSAlert(); alert.messageText = "Tool timeline pages"
                alert.informativeText = "Displaying recorded events \(offset + 1)–\(offset + page.events.count). Output anchor status is based on the current replay window. Older or closed streams cannot be reconstructed from a new shell."
                alert.addButton(withTitle: "Done")
                if page.nextOffset != nil { alert.addButton(withTitle: "Next page") }
                if offset > 0 { alert.addButton(withTitle: "First page") }
                let choice = HarnessToolPage.runModal(alert)
                if choice == .alertFirstButtonReturn { return }
                if choice == .alertSecondButtonReturn, let next = page.nextOffset { offset = next } else { offset = 0 }
            }
        }
    }
    @objc private func showUsage() {
        guard let row = selected else { return }
        let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400)
        query(.activity(.usage(from: to.addingTimeInterval(-86400), to: to)), row: row) { response in
            guard case let .text(json) = response, let summary = try? JSONDecoder().decode(UsageSummary.self, from: Data(json.utf8)) else { return Self.responseError(response) }
            var lines = ["Profile-wide observations for today (UTC). These are observed transcript values, not an account billing statement."]
            if let reason = summary.historyUnavailable { lines.append(reason) }
            if summary.profiles.isEmpty { lines.append("Usage is unavailable until a supported provider transcript is observed.") }
            for profile in summary.profiles {
                lines.append("\n" + profile.provider.displayName + " / " + profile.profile)
                lines.append("Input: " + (profile.counters.input.map(String.init) ?? "unknown") + "; output: " + (profile.counters.output.map(String.init) ?? "unknown"))
                lines.append("Observed: " + (profile.observedAt?.formatted(.iso8601) ?? "unavailable"))
                if let costs = profile.costs {
                    if costs.isEmpty { lines.append("Cost unavailable: no observed model has an explicit configured price.") }
                    for cost in costs {
                        lines.append("Observed cost estimate: " + NSDecimalNumber(decimal: cost.amount).stringValue + " " + cost.currency + (cost.incomplete ? " (incomplete priced coverage)" : "") + "; " + cost.units)
                        if !cost.unavailableModels.isEmpty { lines.append("Unpriced models: " + cost.unavailableModels.joined(separator: ", ")) }
                    }
                } else { lines.append("Cost is not configured. Set explicit model prices in Activity profiles.") }
                for limit in profile.limits {
                    lines.append(limit.window + ": " + String(limit.usedPercent) + "% used; predicted reset " + (limit.predictedReset?.formatted(.iso8601) ?? "unknown") + "; observed " + limit.observedAt.formatted(.iso8601))
                    if let at = limit.resetObservedAt { lines.append("New-window reset evidence observed " + at.formatted(.iso8601)) }
                }
                lines += (profile.coverageWarnings ?? []).map { "Coverage: " + $0 }
                if let reason = profile.unavailable { lines.append(reason) }
            }
            return lines.joined(separator: "\n")
        }
    }
    @objc private func peek() { guard let row = selected else { return }
        if case let .preview(specification) = row.leaf.paneContent {
            cancelDetail(); detail.string = "Preview on \(row.owner)\n\(specification.url)\nUse Jump to view the page."; return
        }; query(.captureFormatted(surfaceID: row.leaf.surfaceID.uuidString, format: "text", trim: false, unwrap: false, screen: true), row: row) { response in
        if case let .text(text) = response { return String(text.prefix(32 * 1024)) }; return Self.responseError(response)
    } }
    @objc private func snooze() { guard let row = selected else { return }; query(.snoozeAttention(surfaceID: row.leaf.surfaceID.uuidString, minutes: 15), row: row) { response in
        if case .ok = response { return "Attention is snoozed for 15 minutes." }; return Self.responseError(response)
    } }
    @objc private func toggleAgentMute() {
        guard let row = selected, let endpoint = SessionCoordinator.shared.endpoint(forOwner: row.owner) else { return }
        Task { @MainActor [weak self] in
            let result = await Task.detached { () -> IPCResponse in
                let client = DaemonClient(endpoint: endpoint)
                do {
                    guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.notificationPolicy) else { return .error("This host does not support the shared notification policy.") }
                    guard case let .text(json) = try client.request(.activity(.notifications(.status)), timeout: 2) else { return .error("Notification policy is unavailable.") }
                    let policy = try JSONDecoder().decode(NotificationPolicyStatus.self, from: Data(json.utf8))
                    var value = policy.controls.first { $0.surfaceID == row.leaf.surfaceID.uuidString && $0.runID == row.run?.id } ?? AgentNotificationControl(surfaceID: row.leaf.surfaceID.uuidString, runID: row.run?.id)
                    value.muted.toggle()
                    let response = try client.request(.activity(.notifications(.control(value))), timeout: 2)
                    if case .text = response { return .text(value.muted ? "Agent muted across delivery channels." : "Agent unmuted. Quiet hours and snooze still apply.") }
                    return response
                } catch { return .error(error.localizedDescription) }
            }.value
            guard let self, !stopped else { return }
            if case let .text(text) = result { detail.string = text } else { detail.string = Self.responseError(result) }
        }
    }
    @objc private func showResources() { guard let row = selected else { return }; query(.activity(.resources(surfaceID: row.leaf.surfaceID.uuidString)), row: row) { response in
        guard case let .text(json) = response, let sample = try? JSONDecoder().decode(PaneResources.self, from: Data(json.utf8)) else { return Self.responseError(response) }
        return "Sampling interval: \(sample.intervalSeconds.map { String(format: "%.2f seconds", $0) } ?? "CPU requires a second observation")\n" + sample.processes.map { "PID \($0.pid)  RSS \($0.residentBytes) bytes  CPU \($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "unknown")  \($0.executable ?? "unavailable")" }.joined(separator: "\n")
    } }
    @objc private func stopTree() {
        guard let row = selected, let sample = row.resources else { detail.string = "Refresh resources before stopping a process tree."; return }
        let alert = NSAlert(); alert.messageText = "Stop this shell and its programs?"
        alert.informativeText = "\(row.title) on \(row.owner) has \(sample.processes.count) observed processes. This terminates the shell, including its background jobs. Process generations are rechecked before signaling."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Stop process tree")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        query(.activity(.terminateTree(surfaceID: row.leaf.surfaceID.uuidString, rootGeneration: sample.rootGeneration)), row: row) { response in
            if case .ok = response { return "Termination signals were sent. Refresh shows the remaining processes." }; return Self.responseError(response)
        }
    }
    @objc private func configureResumePolicy() {
        guard let row = selected else { return }
        let automatic = row.leaf.resumeAutomatically == true
        let runID = row.run?.id ?? row.leaf.lastAgentRunID
        guard automatic || runID != nil else { detail.string = "Was running: exact conversation and launch details are unavailable. Automatic restore cannot be enabled."; return }
        let alert = NSAlert(); alert.messageText = "Conversation restore for this pane"
        alert.informativeText = "Manual Resume inserts a command without Enter. Enabling automatic restore explicitly permits execution of this pane's last verified provider conversation when Harness creates a fresh shell after restoring its layout. The recorded directory and profile are preserved. Adoption of a running shell never re-runs it. Uncertain input is never retried."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: automatic ? "Disable automatic execution" : "Enable automatic execution")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        query(.activity(.resumePolicy(surfaceID: row.leaf.surfaceID.uuidString, runID: runID, automatic: !automatic)), row: row) { response in
            if case .ok = response { return automatic ? "Automatic restore disabled. Manual Resume prepares a command without Enter." : "Automatic conversation execution enabled for the next fresh-shell restore of this pane." }
            return Self.responseError(response)
        }
    }
    @objc private func showDigest() {
        guard let row = selected else { detail.string = "Select a connected host's pane to read its digest."; return }
        let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400)
        query(.activity(.digest(from: to.addingTimeInterval(-86400), to: to, surfaceID: nil, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])), row: row) { response in
            guard case let .text(json) = response, let digest = try? JSONDecoder().decode(ActivityDigest.self, from: Data(json.utf8)) else { return Self.responseError(response) }
            let t = digest.totals
            return "Today (UTC) on \(row.owner): \(t.executions) executions; \(t.turnsCompleted) completed turns; \(t.turnsFailed) failed turns; \(t.toolsCompleted)/\(t.toolsStarted) tool completions/starts.\n" + (digest.historyUnavailable.map { $0 + "\n" } ?? "") + (digest.tests.map { $0.displayText + "\n" } ?? "") + digest.timeline.map { "\($0.at.formatted(date: .omitted, time: .standard))  \($0.kind.rawValue)  \($0.toolName ?? "")  sequence \($0.terminalSequence.map(String.init) ?? "unavailable")" }.joined(separator: "\n") + (digest.timelineTruncated ? "\nTimeline limited to 200 entries; totals include all retained events." : "")
        }
    }
    @objc private func showRepositoryReports() {
        guard let row = selected else { detail.string = "Select a connected host's pane to read repository reports."; return }
        let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400), offset = repositoryPageOffset
        guard results[row.owner]?.capabilities.contains(DaemonStats.repositoryDigest) == true else { detail.string = "This host needs the repository-digest capability. Replace its application daemon to use repository reports; shells remain running."; return }
        query(.activity(.repositoryDigest(requestID: UUID(), from: to.addingTimeInterval(-86400), to: to, offset: offset, limit: 20)), row: row) { [weak self] response in
            guard case let .text(json) = response, let page = try? JSONDecoder().decode(RepositoryDigestPage.self, from: Data(json.utf8)) else { return Self.responseError(response) }
            self?.repositoryPageOffset = page.nextOffset ?? 0
            self?.repositoryReportsButton.setTitleText(page.nextOffset == nil ? "Repository reports" : "More repository reports")
            let body = page.reports.map { report in
                let t = report.totals
                let usage = report.usage.isEmpty ? "Attributable usage unavailable." : report.usage.map { "\($0.provider.rawValue)/\($0.profile): input \($0.counters.input.map(String.init) ?? "unknown"), output \($0.counters.output.map(String.init) ?? "unknown"); observed \($0.observedAt?.formatted(.iso8601) ?? "unavailable")" }.joined(separator: "\n")
                return (report.repository ?? "Unknown repository identity") + "\nWorktrees: " + report.worktrees.joined(separator: ", ") + "\nRetained activity: \(t.executions) executions; \(t.turnsCompleted) completed turns; \(t.turnsFailed) failed turns; \(t.toolsCompleted)/\(t.toolsStarted) tool completions/starts.\n" + usage + "\n" + (report.tests.map { $0.displayText + "\n" } ?? "") + report.coverageWarnings.joined(separator: "\n")
            }.joined(separator: "\n\n")
            return "Today (UTC) on \(row.owner)\n" + (page.historyUnavailable.map { $0 + "\n" } ?? "") + (body.isEmpty ? "No retained execution or attributable usage observations in this range." : body)
        }
    }
    @objc private func copyCommandOutput() {
        guard let row = selected else { return }
        query(.activity(.commandOutput(surfaceID: row.leaf.surfaceID.uuidString, maximumBytes: 65536)), row: row) { response in
            guard case let .text(json) = response, let output = try? JSONDecoder().decode(CommandOutput.self, from: Data(json.utf8)) else { return Self.responseError(response) }
            guard !output.evicted else { return "The output corresponding to this command has been evicted." }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output.text, forType: .string)
            return output.truncated ? "Copied the bounded output suffix (truncated to 64 KiB)." : "Copied the last completed command's output."
        }
    }
    @objc private func explainCommandOutput() {
        guard let row = selected else { return }
        let targets = rows.filter { $0.owner == row.owner && $0.run?.process == .running && $0.run?.parentRunID == nil && $0.run?.pid != nil }
        guard !targets.isEmpty else { detail.string = "Start an agent pane on this host, then select it as the explanation destination."; return }
        let chooser = HarnessSelect(); chooser.frame = NSRect(x: 0, y: 0, width: 520, height: HarnessDesign.formControlHeight); chooser.setAccessibilityLabel("Explanation destination")
        chooser.addItems(withTitles: targets.map { ($0.run?.provider.displayName ?? "Agent") + " · " + $0.title + " · " + $0.directory })
        let alert = NSAlert(); alert.messageText = "Choose an agent for the explanation"
        alert.informativeText = "Harness inserts a quoted excerpt of at most 8 KiB using bracketed paste. Output is treated as untrusted data. Enter is never sent."
        alert.accessoryView = chooser; alert.addButton(withTitle: "Insert explanation"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn, let run = targets[chooser.indexOfSelectedItem].run else { return }
        query(.activity(.explain(sourceSurfaceID: row.leaf.surfaceID.uuidString, targetSurfaceID: run.surfaceID, targetRunID: run.id)), row: row) { response in
            if case .ok = response { return "Explanation message inserted into the selected agent. Review it there and press Enter when ready." }
            return Self.responseError(response)
        }
    }
    @objc private func resumeConversation() {
        guard let row = selected, let endpoint = SessionCoordinator.shared.endpoint(forOwner: row.owner) else { detail.string = "Select a connected host's fresh shell to resume a conversation."; return }
        cancelDetail()
        Task { [weak self] in
            guard let self else { return }
            var offset = 0
            while !self.stopped {
                let pageOffset = offset
                let response = await Task.detached {
                    (try? DaemonClient(endpoint: endpoint).request(.activity(.list(hostID: nil, surfaceID: row.leaf.surfaceID.uuidString, activeOnly: false, offset: pageOffset, limit: 50, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])), timeout: 2)) ?? .error("Run history is unavailable. Reconnect this host before resuming.")
                }.value
                guard !self.stopped else { return }
                guard case let .text(json) = response, let page = try? JSONDecoder().decode(RunPage.self, from: Data(json.utf8)) else { self.detail.string = Self.responseError(response); return }
                guard !page.runs.isEmpty else { self.detail.string = page.historyUnavailable ?? "No recorded execution belongs to this pane. Generic re-run is unavailable without verified arguments."; return }
                let chooser = HarnessSelect(); chooser.frame = NSRect(x: 0, y: 0, width: 560, height: HarnessDesign.formControlHeight); chooser.setAccessibilityLabel("Recorded execution")
                chooser.addItems(withTitles: page.runs.map { "\($0.provider.displayName) · \($0.profile) · \($0.startedAt.formatted()) · \($0.launch == nil || $0.conversationID == nil ? "Was running (resume unavailable)" : "Recorded conversation")" })
                let alert = NSAlert(); alert.messageText = "Resume a recorded conversation"
                alert.informativeText = "Select an execution in this pane. Harness prepares its exact conversation in the recorded directory and profile. The target must still be a fresh shell. Enter is never sent. " + (page.historyUnavailable ?? "")
                alert.accessoryView = chooser; alert.addButton(withTitle: "Prepare command"); alert.addButton(withTitle: "Cancel")
                if page.nextOffset != nil { alert.addButton(withTitle: "Older executions") }
                if offset > 0 { alert.addButton(withTitle: "Newest executions") }
                let choice = HarnessToolPage.runModal(alert)
                if choice == .alertSecondButtonReturn { return }
                if choice == .alertThirdButtonReturn, let next = page.nextOffset { offset = next; continue }
                if choice.rawValue > NSApplication.ModalResponse.alertSecondButtonReturn.rawValue { offset = 0; continue }
                guard choice == .alertFirstButtonReturn else { return }
                let run = page.runs[chooser.indexOfSelectedItem]
                let preparation = await Task.detached {
                    (try? DaemonClient(endpoint: endpoint).request(.activity(.resume(runID: run.id, surfaceID: row.leaf.surfaceID.uuidString, freshShellIdentity: nil)), timeout: 2)) ?? .error("Resume preparation did not complete.")
                }.value
                guard !self.stopped else { return }
                guard case let .text(value) = preparation, let prepared = try? JSONDecoder().decode(PreparedAgentResume.self, from: Data(value.utf8)) else { self.detail.string = Self.responseError(preparation); return }
                self.detail.string = prepared.command
                guard let identity = prepared.freshShellIdentity else { self.detail.string += "\n\n" + (ResumeError.shellChanged.errorDescription ?? ""); return }
                let review = NSAlert(); review.messageText = "Insert this resume command?"
                review.informativeText = prepared.command + "\n\nIt will be inserted into " + row.title + " on " + row.owner + ". Press Enter there when ready."
                review.addButton(withTitle: "Insert command"); review.addButton(withTitle: "Cancel")
                guard HarnessToolPage.runModal(review) == .alertFirstButtonReturn else { return }
                let insertion = await Task.detached {
                    (try? DaemonClient(endpoint: endpoint).request(.activity(.resume(runID: run.id, surfaceID: row.leaf.surfaceID.uuidString, freshShellIdentity: identity)), timeout: 2)) ?? .error("The insertion outcome is uncertain. Inspect the target prompt; Harness will not retry input automatically.")
                }.value
                guard !self.stopped else { return }
                if case .text = insertion { self.detail.string = "Conversation command inserted. Press Enter in the target shell to run it." }
                else { self.detail.string = Self.responseError(insertion) }
                return
            }
        }
    }
    @objc private func dismissDigest() {
        dismissedDigestRevision = results.values.flatMap(\.runs).map { $0.id.uuidString + ":" + String($0.observedAt.timeIntervalSince1970) }.sorted().joined(separator: ";")
        digestButton.setTitleText("Digest"); digestButton.setAccessibilityLabel("Activity digest")
    }
    private static func responseError(_ response: IPCResponse) -> String { if case let .error(message) = response { return message }; return "This host does not support the requested result." }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let index = min(max(table.selectedRow + delta, 0), max(0, shown.count - 1))
            if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
        case #selector(NSResponder.insertNewline(_:)): jump()
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}
