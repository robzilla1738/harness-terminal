import AppKit
import HarnessCore

@MainActor
final class ScheduleWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let endpoint: Endpoint, workspaceID: UUID?, directory: String
    private let table = NSTableView(), details = NSTextView(), status = NSTextField(wrappingLabelWithString: "Scheduling is off until an explicitly enabled definition is saved. Missed occurrences are never caught up automatically.")
    private let workers = OperationQueue()
    private var selectionActions: [NSButton] = []
    private var page: SchedulePage?, closed = false, generation = 0
    var onClose: (() -> Void)?
    init(endpoint: Endpoint, workspaceID: UUID?, directory: String) {
        self.endpoint = endpoint; self.workspaceID = workspaceID; self.directory = directory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Local schedules"; window.delegate = self; window.minSize = NSSize(width: 660, height: 530)
        workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        let buttons = HarnessToolPage.actionRows([HarnessToolPage.button("Refresh", target: self, action: #selector(refresh)), HarnessToolPage.button("New agent schedule…", target: self, action: #selector(newSchedule)), HarnessToolPage.button("Import definition…", target: self, action: #selector(importDefinition)), HarnessToolPage.button("Edit selected…", target: self, action: #selector(editSelected))]); buttons.spacing = 8; root.addArrangedSubview(buttons)
        let controls = HarnessToolPage.actionRows([HarnessToolPage.button("Enable / disable", target: self, action: #selector(toggle)), HarnessToolPage.button("Occurrence history", target: self, action: #selector(history)), HarnessToolPage.button("Cancel active occurrence…", target: self, action: #selector(cancelActive)), HarnessToolPage.button("Delete…", target: self, action: #selector(deleteSelected))]); controls.spacing = 8; root.addArrangedSubview(controls)
        for group in [buttons, controls] {
            for row in group.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
                selectionActions += row.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.action != #selector(refresh) && $0.action != #selector(newSchedule) && $0.action != #selector(importDefinition) }
            }
        }
        selectionActions.forEach { $0.isEnabled = false }
        for (id, name, width) in [("name", "Schedule", 240.0), ("enabled", "Enabled", 80.0), ("zone", "Timezone", 160.0), ("next", "Next time / outcome", 300.0)] { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = name; column.width = width; table.addTableColumn(column) }
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Configured schedules and latest occurrence outcomes")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.heightAnchor.constraint(equalToConstant: 200).isActive = true; root.addArrangedSubview(list)
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 12, weight: .regular); details.isVerticallyResizable = true; details.autoresizingMask = [.width]; details.setAccessibilityLabel("Complete selected schedule definition and actual occurrence history")
        let scroll = NSScrollView(); scroll.documentView = details; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true; root.addArrangedSubview(scroll); root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }; window.contentView = root; HarnessToolPage.group(root, title: "Schedules", views: [list, buttons, controls]); HarnessToolPage.group(root, title: "Selected schedule", views: [scroll]); HarnessToolPage.install(in: window, title: "Schedules", subtitle: "Choose when an agent runs and follow each execution.", symbol: "calendar", content: root); window.center(); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; generation += 1; workers.cancelAllOperations(); onClose?() }
    private var selected: ScheduleRecord? { guard let page, page.schedules.indices.contains(table.selectedRow) else { return nil }; return page.schedules[table.selectedRow] }
    private func request(_ operation: ScheduleOperation, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        guard workers.operationCount < 8 else { status.stringValue = "The bounded schedule request queue is busy; wait for the current operation."; return }
        generation += 1; let generation = generation, endpoint = endpoint; status.stringValue = "Working…"
        workers.addOperation { [weak self] in
            let result = Result<Data, Error> {
                let client = DaemonClient(endpoint: endpoint)
                guard case let .daemonStats(stats) = try client.request(.daemonStats), stats.supports(DaemonStats.schedules) else { throw ScheduleError.unavailable("The current daemon has no scheduling capability. Pending updates preserve existing shells.") }
                let response = try client.request(.activity(.schedules(requestID: UUID(), operation: operation)), timeout: 10)
                if case let .error(message) = response { throw ScheduleError.unavailable(message) }; guard case let .text(text) = response else { throw DaemonClientError.unexpectedResponse }
                if case .list = operation {
                    var page = try JSONDecoder().decode(SchedulePage.self, from: Data(text.utf8))
                    if let offset = page.nextOffset {
                        let more = try client.request(.activity(.schedules(requestID: UUID(), operation: .list(offset: offset, limit: 100))), timeout: 10)
                        guard case let .text(json) = more else { throw ScheduleError.unavailable("The remaining schedule page could not be loaded.") }
                        let extra = try JSONDecoder().decode(SchedulePage.self, from: Data(json.utf8)); page.schedules += extra.schedules; page.occurrences += extra.occurrences; page.nextOffset = extra.nextOffset
                        guard page.nextOffset == nil else { throw ScheduleError.budget }
                    }
                    return try JSONEncoder().encode(page)
                }
                return Data(text.utf8)
            }
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed, generation == self.generation else { return }; completion(result) }
        }
    }
    @objc private func refresh() {
        let selectedID = selected?.id
        request(.list(offset: 0, limit: 100)) { [weak self] result in
            guard let self else { return }
            do { let value = try JSONDecoder().decode(SchedulePage.self, from: result.get()); self.page = value; self.table.reloadData(); if let selectedID, let index = value.schedules.firstIndex(where: { $0.id == selectedID }) { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }; self.status.stringValue = value.unavailable ?? ("Loaded " + Date().formatted(.iso8601) + " · Automatic work uses the recorded timezone, exact executable and normal provider approvals. Unknown acceptance is never retried; missed occurrences do not catch up."); self.showSelected() }
            catch { self.status.stringValue = error.localizedDescription }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { page?.schedules.count ?? 0 }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard let page, page.schedules.indices.contains(row) else { return nil }; let record = page.schedules[row]
        switch column?.identifier.rawValue { case "name": return record.definition.name; case "enabled": return record.definition.enabled ? "On" : "Off"; case "zone": return record.definition.timezone; default: return record.nextAt.map { $0.formatted(.iso8601) } ?? page.occurrences.first(where: { $0.scheduleID == record.id }).map { $0.state.rawValue + ($0.predictedReset ? " · predicted reset" : "") } ?? (record.lastOccurrenceID != nil ? "Last outcome unavailable / expired" : "Waiting for trigger") }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }
    private func json<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func showSelected() {
        for button in selectionActions {
            button.isEnabled = selected != nil
            if button.action == #selector(cancelActive) {
                button.isEnabled = page?.occurrences.contains(where: { $0.id == selected?.lastOccurrenceID && $0.blocksOverlap }) == true
            }
        }
        guard let selected else { details.string = "Select a schedule to inspect its exact launch specification."; return }
        details.string = (try? json(selected)) ?? "Definition could not be encoded."
    }
    private func save(_ definition: ScheduleDefinition, revision: Int?) {
        do { try definition.validate() } catch { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert(); alert.messageText = definition.enabled ? "Enable automatic execution?" : "Save disabled schedule?"
        alert.informativeText = "Review the exact specification. Input is sent through stdin. Normal provider approvals remain in effect. Limit-reset triggers use predictions, not proof of available allowance.\n\n" + ((try? json(definition)) ?? "")
        alert.addButton(withTitle: definition.enabled ? "Save and Enable" : "Save Disabled"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        request(.save(definition: definition, expectedRevision: revision)) { [weak self] result in switch result { case .success: self?.refresh(); case let .failure(error): self?.status.stringValue = error.localizedDescription } }
    }
    @objc private func newSchedule() {
        guard let workspaceID else { status.stringValue = "Select a local workspace first."; return }
        let alert = NSAlert(); alert.messageText = "New agent schedule"; alert.informativeText = "Starts disabled. Review it before enabling. Cron uses five numeric fields; repeated DST times run once and missing wall times are skipped."
        let name = HarnessTextField(string: "Agent task"), provider = HarnessSelect(), kind = HarnessSelect(), date = NSDatePicker(), cron = HarnessTextField(string: "0 9 * * 1-5"), zone = HarnessTextField(string: TimeZone.current.identifier), cwd = HarnessTextField(string: directory), prompt = NSTextView()
        provider.addItems(withTitles: ["Codex", "Claude Code", "Cursor"]); kind.addItems(withTitles: ["One-shot", "Cron"]); date.datePickerStyle = .textFieldAndStepper; date.datePickerElements = [.yearMonthDay, .hourMinute]; date.dateValue = Date().addingTimeInterval(3600); prompt.font = .systemFont(ofSize: 12)
        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 16
        for (label, view) in [("Name", name as NSView), ("Provider", provider), ("Trigger", kind), ("One-shot time (shown in system timezone)", date), ("Cron expression", cron), ("IANA timezone", zone), ("Directory", cwd)] { view.setAccessibilityLabel(label); let row = HarnessToolPage.field(label, control: view); rows.addArrangedSubview(row); row.widthAnchor.constraint(equalToConstant: 480).isActive = true }
        cron.isEnabled = false
        kind.onSelection = { [weak kind, weak date, weak cron] _ in
            let oneShot = kind?.indexOfSelectedItem == 0
            date?.isEnabled = oneShot; cron?.isEnabled = !oneShot
        }
        rows.addArrangedSubview(NSTextField(labelWithString: "Task prompt (stdin)")); let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 90)); scroll.documentView = prompt; scroll.hasVerticalScroller = true; prompt.frame = scroll.bounds; prompt.autoresizingMask = [.width]; prompt.isRichText = false; prompt.setAccessibilityLabel("Task prompt (stdin)"); scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true; scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true; rows.addArrangedSubview(scroll)
        alert.accessoryView = rows; alert.addButton(withTitle: "Review Disabled Definition"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            let agent: AgentKind = [.codex, .claudeCode, .cursor][provider.indexOfSelectedItem]
            let launch = try FanoutProvider(provider: agent).specification(directory: cwd.stringValue, path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            let trigger: ScheduleTrigger = kind.indexOfSelectedItem == 0 ? .once(at: date.dateValue) : .cron(expression: cron.stringValue)
            save(ScheduleDefinition(name: name.stringValue, timezone: zone.stringValue, trigger: trigger, workspaceID: workspaceID, provider: agent, launch: launch, input: prompt.string), revision: nil)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func importDefinition() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { guard let data = try PrivateFile.read(url, maximumBytes: 128 << 10) else { throw ScheduleError.invalid("Definition file is unavailable.") }; let value = try JSONDecoder().decode(ScheduleDefinition.self, from: data); save(value, revision: page?.schedules.first(where: { $0.id == value.id })?.revision) }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func editSelected() {
        guard let selected else { return }; let alert = NSAlert(); alert.messageText = "Edit exact schedule definition"; alert.informativeText = "Advanced event/reset triggers and structured argument arrays are available here. Credentials are not settings; only profile/locale environment overrides are accepted."
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 380)); view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.string = (try? json(selected.definition)) ?? ""; let scroll = NSScrollView(frame: view.frame); scroll.documentView = view; scroll.hasVerticalScroller = true; alert.accessoryView = scroll; alert.addButton(withTitle: "Review Changes"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        do { guard view.string.utf8.count <= 128 << 10 else { throw ScheduleError.budget }; let definition = try JSONDecoder().decode(ScheduleDefinition.self, from: Data(view.string.utf8)); guard definition.id == selected.id else { throw ScheduleError.invalid("Use Import Definition to create a different schedule identity.") }; save(definition, revision: selected.revision) } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func toggle() { guard let selected else { return }; var definition = selected.definition; definition.enabled.toggle(); save(definition, revision: selected.revision) }
    @objc private func history() { guard let selected else { return }; request(.occurrences(id: selected.id, offset: 0, limit: 100)) { [weak self] result in do { let page = try JSONDecoder().decode(SchedulePage.self, from: result.get()); self?.details.string = try self?.json(page) ?? ""; self?.status.stringValue = page.nextOffset.map { "More history is available through schedule occurrences --offset \($0)." } ?? "Recorded process results, missed intervals and skipped overlaps; unknown is not success." } catch { self?.status.stringValue = error.localizedDescription } } }
    @objc private func cancelActive() {
        guard let selected, let occurrence = page?.occurrences.first(where: { $0.id == selected.lastOccurrenceID }), occurrence.blocksOverlap else { status.stringValue = "No active occurrence is selected."; return }
        let alert = NSAlert(); alert.messageText = "Cancel this workload?"; alert.informativeText = "Signals only occurrence " + occurrence.id.uuidString + " after validating its process generation. Completion requires actual process reaping."; alert.addButton(withTitle: "Cancel Workload"); alert.addButton(withTitle: "Keep Running"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        request(.cancelOccurrence(id: occurrence.id)) { [weak self] result in switch result { case .success: self?.refresh(); case let .failure(error): self?.status.stringValue = error.localizedDescription } }
    }
    @objc private func deleteSelected() {
        guard let selected else { return }; let alert = NSAlert(); alert.messageText = "Delete “" + selected.definition.name + "”?"; alert.informativeText = "Active work must be canceled and its outcome confirmed first. Retained occurrence history remains until normal retention expires."; alert.addButton(withTitle: "Delete Schedule"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        request(.delete(id: selected.id, expectedRevision: selected.revision)) { [weak self] result in switch result { case .success: self?.refresh(); case let .failure(error): self?.status.stringValue = error.localizedDescription } }
    }
}
