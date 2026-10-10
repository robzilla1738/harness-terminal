import AppKit
import HarnessCore

@MainActor
final class AISummaryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let endpoint: Endpoint, workspaceID: UUID?
    private let table = NSTableView(), details = NSTextView(), status = NSTextField(wrappingLabelWithString: "AI prose is optional. The deterministic digest remains available in Overview. External generation is off until you review a destination and content categories.")
    private let workers = OperationQueue()
    private var providerStatus: AIProviderStatus?, closed = false, polling = false
    private var currentRequestID: UUID? { didSet { updateActions() } }
    private var timer: Timer?, historyOffset = 0, historyNext: Int?
    private var actionButtons: [NSButton] = []
    var onClose: (() -> Void)?
    init(endpoint: Endpoint, workspaceID: UUID?) {
        self.endpoint = endpoint; self.workspaceID = workspaceID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Optional AI summaries"; window.delegate = self; window.minSize = NSSize(width: 760, height: 520)
        workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        let providerButtons = HarnessToolPage.actionRows([HarnessToolPage.button("Refresh", target: self, action: #selector(refresh)), HarnessToolPage.button("Add provider…", target: self, action: #selector(addProvider)), HarnessToolPage.button("Edit / consent…", target: self, action: #selector(editProvider)), HarnessToolPage.button("Discover models", target: self, action: #selector(discoverModels)), HarnessToolPage.button("Choose model…", target: self, action: #selector(chooseModel)), HarnessToolPage.button("Remove…", target: self, action: #selector(removeProvider))]); providerButtons.spacing = 7; root.addArrangedSubview(providerButtons)
        let summaryButtons = HarnessToolPage.actionRows([HarnessToolPage.button("Summarize workspace…", target: self, action: #selector(generate)), HarnessToolPage.button("Cancel request", target: self, action: #selector(cancel)), HarnessToolPage.button("Automatic workspace…", target: self, action: #selector(automatic)), HarnessToolPage.button("History", target: self, action: #selector(history)), HarnessToolPage.button("Previous", target: self, action: #selector(previousHistory)), HarnessToolPage.button("Next", target: self, action: #selector(nextHistory))]); summaryButtons.spacing = 7; root.addArrangedSubview(summaryButtons)
        for group in [providerButtons, summaryButtons] {
            for row in group.arrangedSubviews.compactMap({ $0 as? NSStackView }) { actionButtons += row.arrangedSubviews.compactMap { $0 as? NSButton } }
        }
        updateActions()
        for (id, title, width) in [("name", "Provider", 190.0), ("state", "Enabled", 70.0), ("model", "Selected model", 270.0), ("catalog", "Model discovery", 320.0)] { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column) }
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("Optional summary providers, exact model selection and catalog freshness")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.heightAnchor.constraint(equalToConstant: 180).isActive = true; root.addArrangedSubview(list)
        details.isEditable = false; details.isSelectable = true; details.font = .systemFont(ofSize: 13); details.isVerticallyResizable = true; details.autoresizingMask = [.width]; details.setAccessibilityLabel("Summary provenance, plain text result, and failure state")
        let scroll = NSScrollView(); scroll.documentView = details; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true; root.addArrangedSubview(scroll); root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }; window.contentView = root; HarnessToolPage.group(root, title: "Providers and models", views: [list, providerButtons]); HarnessToolPage.group(root, title: "Summary", views: [summaryButtons, scroll]); HarnessToolPage.install(in: window, title: "AI summaries", subtitle: "Your providers, your models, and explicit control over what is shared.", symbol: "text.bubble", content: root); window.center(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; timer?.invalidate(); timer = nil; workers.cancelAllOperations(); onClose?() }
    private var selected: AIProviderConfiguration? { guard let providers = providerStatus?.settings.providers, providers.indices.contains(table.selectedRow) else { return nil }; return providers[table.selectedRow] }
    private func request(_ operation: AISummaryOperation, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        guard workers.operationCount < 8 else { status.stringValue = "The bounded request queue is busy."; return }
        let endpoint = endpoint
        workers.addOperation { [weak self] in
            let result = Result<Data, Error> {
                let client = DaemonClient(endpoint: endpoint)
                guard case let .daemonStats(stats) = try client.request(.daemonStats), stats.supports(DaemonStats.aiSummaries) else { throw AISummaryError.unavailable("The current daemon lacks summary support. Pending updates preserve existing shells.") }
                let response = try client.request(.activity(.aiSummaries(operation)), timeout: 10)
                if case let .error(reason) = response { throw AISummaryError.configuration(reason) }; guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }; return Data(json.utf8)
            }
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; completion(result); self.updateActions() }
        }
    }
    private func apply(_ value: AIProviderStatus) {
        let id = selected?.id; providerStatus = value; table.reloadData()
        if let id, let index = value.settings.providers.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        status.stringValue = value.unavailable ?? "Loaded \(Date().ISO8601Format()). Catalog refresh preserves your model selection. Closing this window keeps accepted requests in history; Cancel stops the selected request."
    }
    @objc private func refresh() {
        request(.status) { [weak self] result in do { self?.apply(try JSONDecoder().decode(AIProviderStatus.self, from: result.get())); self?.showProvider() } catch { self?.status.stringValue = error.localizedDescription } }
    }
    private func poll() {
        guard !closed, !polling, workers.operationCount == 0 else { return }
        if let id = currentRequestID {
            polling = true; request(.record(id: id)) { [weak self] result in
                guard let self else { return }; self.polling = false
                do { let record = try JSONDecoder().decode(AISummaryRecord.self, from: result.get()); self.show(record); if record.state != .submitted { self.currentRequestID = nil } } catch { self.status.stringValue = error.localizedDescription; self.currentRequestID = nil }
            }
        } else if providerStatus?.refreshing.isEmpty == false {
            polling = true; request(.status) { [weak self] result in self?.polling = false; do { self?.apply(try JSONDecoder().decode(AIProviderStatus.self, from: result.get())) } catch { self?.status.stringValue = error.localizedDescription } }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { providerStatus?.settings.providers.count ?? 0 }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard let providerStatus, providerStatus.settings.providers.indices.contains(row) else { return nil }; let provider = providerStatus.settings.providers[row]
        switch column?.identifier.rawValue {
        case "name": return provider.name; case "state": return provider.enabled ? "On" : "Off"; case "model": return provider.modelID.isEmpty ? "Explicit model required" : provider.modelID
        default:
            if providerStatus.refreshing.contains(provider.id) { return "Refreshing…" }
            let failure = providerStatus.failures[provider.id.uuidString]
            if let catalog = providerStatus.catalogs.first(where: { $0.providerID == provider.id }) { return "\(catalog.modelCount ?? catalog.models.count) models · \(catalog.fetchedAt.ISO8601Format())" + (failure == nil ? "" : " · refresh failed") }
            return failure == nil ? "Not discovered" : "Discovery failed"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions(); if currentRequestID == nil { showProvider() } }
    private func updateActions() {
        for button in actionButtons {
            switch button.action {
            case #selector(editProvider), #selector(discoverModels), #selector(chooseModel), #selector(removeProvider): button.isEnabled = selected != nil
            case #selector(generate): button.isEnabled = currentRequestID == nil && selected?.enabled == true && workspaceID != nil
            case #selector(cancel): button.isEnabled = currentRequestID != nil
            case #selector(automatic): button.isEnabled = selected != nil && workspaceID != nil
            case #selector(previousHistory): button.isEnabled = historyOffset > 0
            case #selector(nextHistory): button.isEnabled = historyNext != nil
            default: break
            }
        }
    }
    private func showProvider() {
        guard let selected else { return }
        let catalog = providerStatus?.catalogs.first { $0.providerID == selected.id }
        details.string = selected.name + "\nDestination: " + selected.destination + "\nProtocol: " + selected.apiProtocol.rawValue + "\nModel: " + selected.modelID + "\nIncluded: " + selected.consentedCategories.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: ", ") + "\n\n" + (catalog?.warning ?? "Capability metadata unavailable until discovery. Explicit IDs are allowed; the selection is never switched automatically.") + "\n" + (providerStatus?.failures[selected.id.uuidString] ?? "")
    }
    private func save(_ settings: AISettings, expected: AISettings) {
        request(.configure(settings, expected: expected)) { [weak self] result in do { self?.apply(try JSONDecoder().decode(AIProviderStatus.self, from: result.get())); self?.showProvider() } catch { self?.status.stringValue = error.localizedDescription } }
    }
    @objc private func addProvider() { edit(nil) }
    @objc private func editProvider() { guard let selected else { return }; edit(selected) }
    private func edit(_ existing: AIProviderConfiguration?) {
        guard let original = providerStatus?.settings else { return }
        let presetAlert = NSAlert(); presetAlert.messageText = "Choose a summary integration"; let presets = HarnessSelect(); presets.addItems(withTitles: AIProviderPreset.allCases.map(\.displayName)); if let existing, let index = AIProviderPreset.allCases.firstIndex(of: existing.preset) { presets.selectItem(at: index) }; presetAlert.accessoryView = presets; presetAlert.addButton(withTitle: "Continue"); presetAlert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(presetAlert) == .alertFirstButtonReturn else { return }
        let preset = AIProviderPreset.allCases[presets.indexOfSelectedItem]
        var value = existing?.preset == preset ? existing! : AIProviderConfiguration(id: existing?.id ?? UUID(), preset: preset)
        if preset == .appleOnDevice { value.modelID = "apple-system" }
        let alert = NSAlert(); alert.messageText = "Review provider and content consent"; alert.informativeText = "Enabling permits bounded digest text to the exact destination below. Captured messages, repository paths and terminal excerpts require separate selection. No tools are available and failures never switch providers or models. A newly entered key is stored in the credential store."
        let name = HarnessTextField(string: value.name), endpoint = HarnessTextField(string: value.baseURL ?? ""), model = HarnessTextField(string: value.modelID), tokens = HarnessTextField(string: String(value.maximumOutputTokens)), key = HarnessSecureTextField(), protocolChoice = HarnessSelect(), enabled = HarnessToggle(title: "Enable this provider for explicitly requested summaries")
        let protocols: [AIProtocol] = [.responses, .messages, .gemini, .openAICompatible, .appleOnDevice]; protocolChoice.addItems(withTitles: protocols.map(\.rawValue)); protocolChoice.selectItem(at: protocols.firstIndex(of: value.apiProtocol)!); protocolChoice.isEnabled = preset == .custom
        endpoint.isEnabled = preset != .appleOnDevice; model.isEnabled = preset != .appleOnDevice; key.isEnabled = preset != .appleOnDevice; key.placeholderString = value.credentialReference == nil ? "Optional local/custom credential; required for cloud generation" : "Leave blank to retain credential reference"; enabled.state = value.enabled ? .on : .off
        let fields = NSStackView(); fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 5
        for (label, view) in [("Name", name as NSView), ("Base URL (HTTPS, or local loopback HTTP)", endpoint), ("Protocol (Custom only)", protocolChoice), ("Explicit model ID (discover/choose after saving)", model), ("Maximum output tokens (128–8192)", tokens), ("Credential", key)] { view.setAccessibilityLabel(label); fields.addArrangedSubview(NSTextField(labelWithString: label)); fields.addArrangedSubview(view); view.widthAnchor.constraint(equalToConstant: 520).isActive = true }
        var categories: [SummaryContentCategory: HarnessToggle] = [:]
        for category in SummaryContentCategory.allCases { let check = HarnessToggle(title: category.displayName); check.state = value.consentedCategories.contains(category) ? .on : .off; categories[category] = check; fields.addArrangedSubview(check) }; fields.addArrangedSubview(enabled)
        alert.accessoryView = fields; alert.addButton(withTitle: "Save Reviewed Selection"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { key.stringValue = ""; return }
        value.name = name.stringValue; value.baseURL = preset == .appleOnDevice ? nil : endpoint.stringValue; value.modelID = model.stringValue; value.apiProtocol = protocols[protocolChoice.indexOfSelectedItem]; value.maximumOutputTokens = Int(tokens.stringValue) ?? 0; value.enabled = enabled.state == .on; value.consentedCategories = Set(categories.filter { $0.value.state == .on }.map(\.key)); value.consentedDestination = value.enabled ? value.destination : nil
        let secret = key.stringValue; key.stringValue = ""
        if !secret.isEmpty { value.credentialReference = UUID() }
        do { try value.validate(requireModel: value.enabled) } catch { status.stringValue = error.localizedDescription; return }
        var proposed = original; proposed.providers.removeAll { $0.id == value.id }; proposed.providers.append(value)
        if !value.enabled { proposed.automaticWorkspaces.removeAll { $0.providerID == value.id } }
        if secret.isEmpty { save(proposed, expected: original); return }
        guard !secret.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), secret.utf8.count <= 8192, let reference = value.credentialReference else { status.stringValue = "Invalid credential input."; return }
        let proposedSettings = proposed
        workers.addOperation { [weak self] in
            let result = Result<Void, Error> { try CredentialStore.save(["key": secret], reference: reference, allowInteraction: true) }
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; do { try result.get(); self.status.stringValue = "Saved credential reference \(reference.uuidString)."; self.save(proposedSettings, expected: original) } catch { self.status.stringValue = error.localizedDescription } }
        }
    }
    @objc private func discoverModels() {
        guard let selected else { return }
        let alert = NSAlert(); alert.messageText = "Refresh model catalog?"; alert.informativeText = "Contact " + selected.destination + " using its credential reference. No activity text is sent. The selected model remains " + selected.modelID + "."; alert.addButton(withTitle: "Refresh Catalog"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        request(.refreshModels(providerID: selected.id)) { [weak self] result in do { self?.apply(try JSONDecoder().decode(AIProviderStatus.self, from: result.get())) } catch { self?.status.stringValue = error.localizedDescription } }
    }
    @objc private func chooseModel() {
        guard let selected, let original = providerStatus?.settings else { return }; let endpoint = endpoint
        let hasCatalog = providerStatus?.catalogs.contains(where: { $0.providerID == selected.id }) == true
        guard workers.operationCount < 8 else { return }; status.stringValue = "Loading the complete cached catalog…"
        workers.addOperation { [weak self] in
            let result = Result<[AIModel], Error> {
                guard hasCatalog else { return [] }
                let client = DaemonClient(endpoint: endpoint); var models: [AIModel] = [], offset = 0, fetchedAt: Date?
                repeat {
                    let response = try client.request(.activity(.aiSummaries(.catalog(providerID: selected.id, offset: offset, limit: 500))), timeout: 5)
                    if case let .error(reason) = response { throw AISummaryError.configuration(reason) }; guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }
                    let page = try JSONDecoder().decode(AIModelCatalogPage.self, from: Data(json.utf8))
                    if let fetchedAt, fetchedAt != page.catalog.fetchedAt { throw AISummaryError.configuration("The catalog refreshed while paging; choose again from the complete new catalog.") }; fetchedAt = page.catalog.fetchedAt
                    models += page.catalog.models; guard models.count <= 5000 else { throw AISummaryError.responseLimit }; guard let next = page.nextOffset else { break }; guard next > offset else { throw AISummaryError.invalidResponse }; offset = next
                } while true
                return models
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                do {
                    let models = try result.get(); let alert = NSAlert(); alert.messageText = "Select an explicit model"; alert.informativeText = "Type to find a catalog ID, or enter an explicit ID. Models without capability metadata remain labeled unknown; generation will report unsupported requests. Your current selection is preserved unless you save."
                    let choice = HarnessTextField(string: selected.modelID); choice.setAccessibilityLabel("Model ID")
                    let catalog = HarnessSelect()
                    catalog.addItems(withTitles: ["Enter an explicit model ID"] + models.map { $0.id + ($0.supportsTextGeneration == nil ? " · capabilities unknown" : "") })
                    catalog.selectItem(at: models.firstIndex(where: { $0.id == selected.modelID }).map { $0 + 1 } ?? 0)
                    catalog.setAccessibilityLabel("Available models")
                    catalog.isEnabled = !models.isEmpty
                    catalog.onSelection = { [weak choice, weak catalog] _ in
                        guard let index = catalog?.indexOfSelectedItem, index > 0, models.indices.contains(index - 1) else { return }
                        choice?.stringValue = models[index - 1].id
                    }
                    let form = NSStackView(views: [HarnessToolPage.field("Available models", control: catalog), HarnessToolPage.field("Model ID", control: choice, hint: "Choose from the catalog or enter the exact model ID.")]); form.orientation = .vertical; form.alignment = .leading; form.spacing = 16
                    for row in form.arrangedSubviews { row.widthAnchor.constraint(equalToConstant: 550).isActive = true }
                    alert.accessoryView = form; alert.addButton(withTitle: "Use Model"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
                    var proposed = original; guard let index = proposed.providers.firstIndex(where: { $0.id == selected.id }) else { return }; proposed.providers[index].modelID = choice.stringValue; try proposed.validate(); self.save(proposed, expected: original)
                } catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    @objc private func generate() {
        guard currentRequestID == nil, let selected, selected.enabled, let workspaceID else { status.stringValue = "Select an enabled provider and local workspace, and wait for any current request."; return }
        let alert = NSAlert(); alert.messageText = "Summarize this workspace’s last 24 hours?"; alert.informativeText = "Destination: " + selected.destination + "\nModel: " + selected.modelID + "\nIncluded: " + selected.consentedCategories.map(\.displayName).sorted().joined(separator: ", ") + "\nSubmission may be billable. Cancel or failure never triggers automatic retries. Deterministic totals remain available."; alert.addButton(withTitle: "Generate Once"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        let id = UUID(), to = Date(); currentRequestID = id
        request(.generate(id: id, providerID: selected.id, workspaceID: workspaceID, from: to.addingTimeInterval(-86400), to: to)) { [weak self] result in
            do { let record = try JSONDecoder().decode(AISummaryRecord.self, from: result.get()); self?.show(record); if record.state != .submitted { self?.currentRequestID = nil } } catch { self?.status.stringValue = error.localizedDescription; self?.currentRequestID = nil }
        }
    }
    @objc private func cancel() { guard let id = currentRequestID else { return }; request(.cancel(id: id)) { [weak self] result in do { self?.show(try JSONDecoder().decode(AISummaryRecord.self, from: result.get())); self?.currentRequestID = nil } catch { self?.status.stringValue = error.localizedDescription } } }
    private func show(_ record: AISummaryRecord) {
        details.string = "\(record.providerName) · \(record.state.rawValue)\nDestination: \(record.destination)\nRequested model: \(record.requestedModel)\nReported model: \(record.output?.reportedModel ?? "unavailable")\nRequest: \(record.id.uuidString)\nRange: \(record.from.ISO8601Format()) – \(record.to.ISO8601Format())\n\n" + (record.output?.text ?? record.failure ?? "Waiting for bounded provider response…") + (record.output?.truncated == true ? "\n\nThe provider reached its output limit; this prose is incomplete." : "")
        if let reported = record.output?.reportedModel, reported != record.requestedModel { details.string += "\n\nThe provider reported a different model/version than the requested ID. Harness retained your selection." }
        status.stringValue = "AI prose supplements recorded evidence. No tools were exposed. The deterministic digest remains available."
    }
    @objc private func automatic() {
        guard let selected, selected.enabled, let workspaceID, let original = providerStatus?.settings else { status.stringValue = "Choose an enabled provider and local workspace."; return }
        let existing = original.automaticWorkspaces.contains { $0.workspaceID == workspaceID }
        let alert = NSAlert(); alert.messageText = existing ? "Disable automatic summaries for this workspace?" : "Enable automatic summaries for this workspace?"; alert.informativeText = "Provider: " + selected.name + "\nDestination: " + selected.destination + "\nModel: " + selected.modelID + "\nSelected content: " + selected.consentedCategories.map(\.displayName).sorted().joined(separator: ", ") + "\nAt most once per 60 minutes. Failed or interrupted submissions are not automatically retried. Each submission may be billable."; alert.addButton(withTitle: existing ? "Disable" : "Enable for This Workspace"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        var proposed = original; proposed.automaticWorkspaces.removeAll { $0.workspaceID == workspaceID }; if !existing { proposed.automaticWorkspaces.append(AIAutomaticWorkspace(workspaceID: workspaceID, providerID: selected.id)) }; save(proposed, expected: original)
    }
    @objc private func removeProvider() {
        guard let selected, let original = providerStatus?.settings else { return }; let alert = NSAlert(); alert.messageText = "Remove \(selected.name)?"; alert.informativeText = "Disable its automatic workspaces and cancel accepted requests. Stored credential references remain available for explicit credential removal; existing results follow history retention."; alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel"); guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }; var proposed = original; proposed.providers.removeAll { $0.id == selected.id }; proposed.automaticWorkspaces.removeAll { $0.providerID == selected.id }; save(proposed, expected: original)
    }
    @objc private func history() { historyOffset = 0; loadHistory() }
    @objc private func previousHistory() { historyOffset = max(0, historyOffset - 20); loadHistory() }
    @objc private func nextHistory() { guard let next = historyNext else { return }; historyOffset = next; loadHistory() }
    private func loadHistory() {
        request(.history(offset: historyOffset, limit: 20)) { [weak self] result in
            do { let page = try JSONDecoder().decode(AISummaryPage.self, from: result.get()); self?.historyNext = page.nextOffset; self?.details.string = page.records.map { record in "\(record.submittedAt.ISO8601Format()) · \(record.providerName) · \(record.requestedModel) · \(record.state.rawValue)\nRequest: \(record.id.uuidString)\nDestination: \(record.destination)\n" + (record.output?.text ?? record.failure ?? "Output unavailable or purged") }.joined(separator: "\n\n––––\n\n"); self?.status.stringValue = page.unavailable ?? "History offset \(self?.historyOffset ?? 0); \(page.records.count) records. " + (page.nextOffset == nil ? "End of retained history." : "Next page is available.") } catch { self?.status.stringValue = error.localizedDescription }
        }
    }
}
