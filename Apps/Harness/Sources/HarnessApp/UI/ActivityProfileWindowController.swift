import AppKit
import HarnessCore

/// Local profile configuration. Loading the form never probes credentials or transcripts.
@MainActor
final class ActivityProfileWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var settings = ActivitySettings()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Loading local profiles…")
    private var buttons: [NSButton] = []
    private var isBusy = false
    private var editorRoots: NSTextView?
    private var editorProvider: HarnessSelect?
    var onClose: (() -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent Usage Profiles"; window.minSize = NSSize(width: 620, height: 320)
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let caption = NSTextField(wrappingLabelWithString: "Profiles label observed usage and approve transcript directories. Launch an agent with HARNESS_AGENT_PROFILE set to this name. No account identity is read from credentials. Cursor's transcript usage is unavailable until a documented format is supported.")
        root.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        for (id, title, width) in [("name", "Profile", 130.0), ("provider", "Provider", 130.0), ("roots", "Approved transcript roots", 400.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Approved agent profiles")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 10
        for (label, action) in [("Add Profile…", #selector(add)), ("Edit…", #selector(edit)), ("Remove", #selector(remove))] {
            let button = HarnessToolPage.button(label, target: self, action: action); buttons.append(button); actions.addArrangedSubview(button)
        }
        root.addArrangedSubview(actions); root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        window.contentView = root; HarnessToolPage.group(root, title: "Profiles", views: [scroll, actions]); HarnessToolPage.install(in: window, title: "Usage profiles", subtitle: "Connect observed activity to the profiles you use.", symbol: "person.crop.rectangle", content: root); window.center()
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { settings.profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard settings.profiles.indices.contains(row) else { return nil }
        let profile = settings.profiles[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = profile.name
        case "provider": value = profile.provider.displayName
        default: value = profile.transcriptRoots.joined(separator: "; ")
        }
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail; field.toolTip = value
        return field
    }
    private func busy(_ value: Bool) { isBusy = value; updateActions(); table.isEnabled = !value }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        for (index, button) in buttons.enumerated() {
            button.isEnabled = !isBusy && (index == 0 || settings.profiles.indices.contains(table.selectedRow))
        }
    }
    private func refresh() {
        busy(true)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { () -> ActivitySettings in
                let client = DaemonClient(endpoint: .localControlSocket)
                guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.activityProfiles) else { throw ProfileError.unavailable }
                guard case let .text(json) = try client.request(.activity(.configure(nil)), timeout: 1) else { throw ProfileError.unavailable }
                return try JSONDecoder().decode(ActivitySettings.self, from: Data(json.utf8))
            } }.value
            guard let self else { return }
            switch result {
            case .success(let value): settings = value; table.reloadData(); busy(false); status.stringValue = settings.profiles.isEmpty ? "No profiles configured. Add a profile to approve its transcript directories and label observed usage." : "Only configured roots are approved for their named profile. Changes receive a settings backup."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func add() { editProfile(nil) }
    @objc private func edit() { guard settings.profiles.indices.contains(table.selectedRow) else { return }; editProfile(settings.profiles[table.selectedRow]) }
    @objc private func providerChanged() {
        guard let popup = editorProvider else { return }
        editorRoots?.string = ActivitySettings.defaultRoots(provider: [.codex, .claudeCode, .cursor][popup.indexOfSelectedItem]).joined(separator: "\n")
    }
    private func editProfile(_ prior: AgentProfile?) {
        let name = HarnessTextField(string: prior?.name ?? "work"); name.setAccessibilityLabel("Profile name")
        let provider = HarnessSelect(); provider.addItems(withTitles: ["Codex", "Claude Code", "Cursor"])
        let providers: [AgentKind] = [.codex, .claudeCode, .cursor]
        provider.selectItem(at: providers.firstIndex(of: prior?.provider ?? .codex) ?? 0)
        provider.isEnabled = prior == nil
        name.widthAnchor.constraint(equalToConstant: 520).isActive = true
        provider.target = self; provider.action = #selector(providerChanged)
        let roots = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 140)); roots.isRichText = false
        roots.string = (prior?.transcriptRoots ?? ActivitySettings.defaultRoots(provider: .codex)).joined(separator: "\n")
        roots.font = .monospacedSystemFont(ofSize: 11, weight: .regular); roots.setAccessibilityLabel("Absolute approved roots, one per line")
        let scroll = NSScrollView(frame: roots.frame); scroll.hasVerticalScroller = true; scroll.documentView = roots; scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        let prices = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 90)); prices.isRichText = false
        prices.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        prices.setAccessibilityLabel("Optional explicit model pricing JSON")
        if let configured = prior?.pricing, let bytes = try? JSONEncoder().encode(configured) { prices.string = String(decoding: bytes, as: UTF8.self) }
        else { prices.string = "[]" }
        let priceScroll = NSScrollView(frame: prices.frame); priceScroll.hasVerticalScroller = true; priceScroll.documentView = prices; priceScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        let pricingHint = NSTextField(wrappingLabelWithString: "Optional model pricing JSON: model, currency (e.g. USD), units: per_million_tokens, input, output; cachedInput and cacheCreation are optional. No inferred prices. Estimates require observed models and identify incomplete coverage.")
        pricingHint.preferredMaxLayoutWidth = 520
        let form = NSStackView(views: [NSTextField(labelWithString: "Profile name"), name, NSTextField(labelWithString: "Provider"), provider, NSTextField(labelWithString: "Approved transcript roots (absolute, one per line)"), scroll, pricingHint, priceScroll])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 8
        provider.widthAnchor.constraint(equalToConstant: 520).isActive = true
        name.setAccessibilityLabel("Profile name"); provider.setAccessibilityLabel("Provider")
        form.frame = NSRect(x: 0, y: 0, width: 520, height: 410)
        let alert = NSAlert(); alert.messageText = prior == nil ? "Add an agent profile" : "Edit agent profile"
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        editorRoots = roots; editorProvider = provider
        defer { editorRoots = nil; editorProvider = nil }
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        var updated = settings
        if let prior { updated.profiles.removeAll { $0.id == prior.id } }
        let kind = providers[provider.indexOfSelectedItem], label = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directories = roots.string.split(separator: "\n").map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
        do {
            let pricing = try JSONDecoder().decode([UsagePrice].self, from: Data(prices.string.utf8))
            updated.profiles.append(AgentProfile(id: prior?.id ?? (label == "default" ? ActivitySettings.defaultProfileID(kind) : UUID()), name: label, provider: kind, transcriptRoots: directories, pricing: pricing.isEmpty ? nil : pricing))
            save(updated)
        } catch { status.stringValue = "Pricing JSON could not be saved: " + error.localizedDescription }
    }
    @objc private func remove() {
        guard settings.profiles.indices.contains(table.selectedRow) else { return }
        let profile = settings.profiles[table.selectedRow], alert = NSAlert()
        alert.messageText = "Remove profile \(profile.name)?"; alert.informativeText = "Its directories will no longer be approved for future observations. Retained numeric usage follows the 90-day retention policy."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        var updated = settings; updated.profiles.removeAll { $0.id == profile.id }; save(updated)
    }
    private func save(_ value: ActivitySettings) {
        do { try value.validate() }
        catch { status.stringValue = error.localizedDescription; return }
        busy(true); status.stringValue = "Saving profile configuration…"
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { () -> Void in
                let response = try DaemonClient(endpoint: .localControlSocket).request(.activity(.configure(value)), timeout: 5)
                if case let .error(message) = response { throw ProfileError.refused(message) }
                guard case .ok = response else { throw ProfileError.unavailable }
            } }.value
            guard let self else { return }; busy(false)
            switch result {
            case .success:
                settings = value; table.reloadData(); SessionCoordinator.shared.settings.activity = value
                status.stringValue = "Profiles saved. Set HARNESS_AGENT_PROFILE to the profile name when launching its agent."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
}
private enum ProfileError: Error, LocalizedError {
    case unavailable, refused(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Local profile configuration is unavailable. Replace the application daemon to adopt the update; existing shells stay running."
        case .refused(let message): message
        }
    }
}
