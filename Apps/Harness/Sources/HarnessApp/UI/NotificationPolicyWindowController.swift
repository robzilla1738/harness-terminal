import AppKit
import HarnessCore

@MainActor
final class NotificationPolicyWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var policy = NotificationPolicySettings()
    private let speech = HarnessToggle(title: "Speak minimal agent state aloud")
    private let quiet = HarnessToggle(title: "Enable quiet hours for every delivery channel")
    private let zone = HarnessTextField(string: TimeZone.current.identifier)
    private let start = HarnessTextField(string: "22:00"), end = HarnessTextField(string: "07:00")
    private let burst = HarnessTextField(string: "1"), expiry = HarnessTextField(string: "120")
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Loading local notification policy…")
    private var actions: [NSButton] = []
    private var pending = false, closed = false
    var onClose: (() -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Notification Policy"; window.minSize = NSSize(width: 700, height: 600)
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let caption = NSTextField(wrappingLabelWithString: "External delivery and speech require opt-in. Destinations receive minimal state by default. Desktop banners and chimes use the controls in Notifications settings; those and every external sink share this policy. Use the Board to mute an execution or snooze a pane.")
        root.addArrangedSubview(caption); root.addArrangedSubview(speech); root.addArrangedSubview(quiet)
        zone.setAccessibilityLabel("Quiet hours timezone"); start.setAccessibilityLabel("Quiet hours start, HH:mm"); end.setAccessibilityLabel("Quiet hours end, HH:mm")
        start.widthAnchor.constraint(equalToConstant: 75).isActive = true; end.widthAnchor.constraint(equalToConstant: 75).isActive = true
        let quietRow = NSStackView(views: [NSTextField(labelWithString: "Timezone"), zone, NSTextField(labelWithString: "From"), start, NSTextField(labelWithString: "to"), end]); quietRow.spacing = 8
        root.addArrangedSubview(quietRow)
        let quietHint = NSTextField(wrappingLabelWithString: "Use an IANA timezone such as America/Chicago. Equal start and end times mean quiet all day. Delivery expires rather than waiting until quiet hours end.")
        root.addArrangedSubview(quietHint)
        burst.widthAnchor.constraint(equalToConstant: 65).isActive = true; expiry.widthAnchor.constraint(equalToConstant: 65).isActive = true
        burst.setAccessibilityLabel("Burst coalescing seconds"); expiry.setAccessibilityLabel("Delivery expiry seconds")
        let timing = NSStackView(views: [NSTextField(labelWithString: "Coalesce bursts (seconds)"), burst, NSTextField(labelWithString: "Delivery expires after (seconds)"), expiry]); timing.spacing = 8
        root.addArrangedSubview(timing)
        for (id, title, width) in [("name", "Destination", 180.0), ("kind", "Protocol", 100), ("enabled", "Delivery", 85), ("content", "Included content", 285)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false; table.setAccessibilityLabel("External notification destinations")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true; root.addArrangedSubview(scroll)
        for (title, action) in [("Add Destination…", #selector(addDestination)), ("Edit…", #selector(editDestination)), ("Remove", #selector(removeDestination)), ("Save Policy", #selector(applyPolicy)), ("Refresh Status", #selector(refreshStatus))] {
            let button = HarnessToolPage.button(title, target: self, action: action); actions.append(button)
        }
        let row = HarnessToolPage.actionRows(actions)
        root.addArrangedSubview(row)
        let details = NSTextField(wrappingLabelWithString: "ntfy and Pushover use their own payloads. A generic webhook receives Harness JSON and requires a compatible receiver; it does not automatically work with Slack or Telegram. Receiver URLs and tokens stay in Keychain on macOS. Linux stores credentials in an owner-only directory and does not label them encrypted.")
        root.addArrangedSubview(details); root.addArrangedSubview(status)
        for view in [caption, quietRow, quietHint, timing, scroll, details, status] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        window.contentView = root; HarnessToolPage.group(root, title: "Quiet hours", views: [quiet, quietRow, quietHint]); HarnessToolPage.group(root, title: "Delivery", views: [speech, timing]); HarnessToolPage.group(root, title: "Destinations", views: [scroll, row]); HarnessToolPage.group(root, title: "Protocols and privacy", views: [details], collapsible: true); HarnessToolPage.install(in: window, title: "Notification policy", subtitle: "Choose where updates arrive and when to stay quiet.", symbol: "bell", content: root); window.center(); refreshStatus()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { policy.sinks.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard policy.sinks.indices.contains(row) else { return nil }; let sink = policy.sinks[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return sink.name
        case "kind": return sink.kind.rawValue
        case "enabled": return sink.enabled ? "Enabled" : "Off"
        default: return "State" + (sink.includeMessages ? ", messages" : "") + (sink.includeRepository ? ", repository" : "")
        }
    }
    private func setBusy(_ value: Bool) { pending = value; updateActions(); table.isEnabled = !value }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        for button in actions {
            let needsSelection = button.action == #selector(editDestination) || button.action == #selector(removeDestination)
            button.isEnabled = !pending && (!needsSelection || policy.sinks.indices.contains(table.selectedRow))
        }
    }
    @objc private func refreshStatus() {
        guard !pending else { return }; setBusy(true)
        Task { @MainActor [weak self] in
            let result = await Task.detached { Result { () -> NotificationPolicyStatus in
                let client = DaemonClient(endpoint: .localControlSocket)
                guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.notificationPolicy) else { throw NotificationUIError.unavailable }
                let response = try client.request(.activity(.notifications(.status)), timeout: 2)
                return try Self.decode(response)
            } }.value
            guard let self, !closed else { return }; setBusy(false)
            switch result {
            case .success(let value):
                policy = value.settings; speech.state = policy.speech ? .on : .off; quiet.state = policy.quietHours == nil ? .off : .on
                if let hours = policy.quietHours { zone.stringValue = hours.timeZone; start.stringValue = Self.time(hours.startMinute); end.stringValue = Self.time(hours.endMinute) }
                burst.stringValue = String(policy.burstSeconds); expiry.stringValue = String(policy.deliveryExpirySeconds); table.reloadData(); updateActions()
                status.stringValue = value.unavailable ?? value.diagnostics.suffix(3).map { $0.outcome }.joined(separator: "; ")
                if status.stringValue.isEmpty { status.stringValue = "No recent delivery diagnostics. External delivery remains off until you enable a destination." }
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    private func formPolicy() throws -> NotificationPolicySettings {
        var value = policy; value.speech = speech.state == .on
        guard let seconds = Double(burst.stringValue), let lifetime = Double(expiry.stringValue) else { throw NotificationPolicyError.invalid }
        value.burstSeconds = seconds; value.deliveryExpirySeconds = lifetime
        if quiet.state == .on {
            value.quietHours = NotificationQuietHours(timeZone: zone.stringValue, startMinute: try Self.minute(start.stringValue), endMinute: try Self.minute(end.stringValue))
        } else { value.quietHours = nil }
        try value.validate(); return value
    }
    @objc private func applyPolicy() {
        do { savePolicy(try formPolicy()) } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func addDestination() { editSink(nil) }
    @objc private func editDestination() { guard policy.sinks.indices.contains(table.selectedRow) else { return }; editSink(policy.sinks[table.selectedRow]) }
    @objc private func removeDestination() {
        guard policy.sinks.indices.contains(table.selectedRow) else { return }; let sink = policy.sinks[table.selectedRow]
        let alert = NSAlert(); alert.messageText = "Remove \(sink.name)?"
        alert.informativeText = "Queued deliveries will be cancelled. Remove its credentials too when they are no longer referenced by Harness configuration."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        do { var value = try formPolicy(); value.sinks.removeAll { $0.id == sink.id }; savePolicy(value, obsoleteReference: sink.credentialReference) }
        catch { status.stringValue = error.localizedDescription }
    }
    private func editSink(_ prior: NotificationSink?) {
        let kinds = NotificationSinkKind.allCases, name = HarnessTextField(string: prior?.name ?? "")
        let kind = HarnessSelect(); kind.addItems(withTitles: kinds.map(\.rawValue)); kind.selectItem(at: kinds.firstIndex(of: prior?.kind ?? .ntfy) ?? 0); kind.isEnabled = prior == nil
        let server = HarnessTextField(string: prior?.endpoint ?? "https://ntfy.sh"), topic = HarnessTextField(string: prior?.topic ?? "")
        let receiver = HarnessSecureTextField(string: ""), token = HarnessSecureTextField(string: ""), user = HarnessSecureTextField(string: "")
        receiver.placeholderString = prior?.credentialReference == nil ? "HTTPS webhook receiver" : "Leave blank to keep saved receiver"
        token.placeholderString = "Leave blank to keep saved credentials"; user.placeholderString = "Pushover user key"
        let enabled = HarnessToggle(title: "Enable external delivery to this destination"); enabled.state = prior?.enabled == true ? .on : .off
        let messages = HarnessToggle(title: "Include captured messages and titles"); messages.state = prior?.includeMessages == true ? .on : .off
        let repository = HarnessToggle(title: "Include repository/directory details"); repository.state = prior?.includeRepository == true ? .on : .off
        let interval = HarnessTextField(string: String(prior?.minimumInterval ?? 15))
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 6
        for (label, field) in [("Name", name), ("Protocol", kind as NSView), ("ntfy HTTPS server", server), ("ntfy topic", topic), ("Generic webhook HTTPS receiver (protected)", receiver), ("Token / optional webhook bearer", token), ("Pushover user key", user), ("Minimum interval between requests (seconds)", interval)] {
            form.addArrangedSubview(NSTextField(labelWithString: label)); form.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 520).isActive = true; field.setAccessibilityLabel(label)
        }
        for view in [enabled, messages, repository] { form.addArrangedSubview(view) }
        form.frame = NSRect(x: 0, y: 0, width: 520, height: 510)
        let alert = NSAlert(); alert.messageText = prior == nil ? "Add notification destination" : "Edit \(prior!.name)"
        alert.informativeText = "Enable only after reviewing the destination and content categories. Pushover uses api.pushover.net. For a webhook, supply the receiver URL again when replacing its credentials. Messages and repository details can contain private information."
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            let selected = kinds[kind.indexOfSelectedItem]
            var sink = NotificationSink(id: prior?.id ?? UUID(), name: name.stringValue, kind: selected, endpoint: selected == .ntfy ? server.stringValue : "", topic: selected == .ntfy ? topic.stringValue : nil,
                credentialReference: prior?.credentialReference, enabled: enabled.state == .on, includeMessages: messages.state == .on, includeRepository: repository.state == .on,
                minimumInterval: Double(interval.stringValue) ?? -1)
            var credentials: [String: String]?
            if selected == .pushover, !token.stringValue.isEmpty || !user.stringValue.isEmpty {
                guard !token.stringValue.isEmpty, !user.stringValue.isEmpty else { throw NotificationPolicyError.credential }
                credentials = ["token": token.stringValue, "user": user.stringValue]
            } else if selected == .webhook, !receiver.stringValue.isEmpty || !token.stringValue.isEmpty {
                guard !receiver.stringValue.isEmpty else { throw NotificationPolicyError.endpoint }
                credentials = ["endpoint": receiver.stringValue]
                if !token.stringValue.isEmpty { credentials?["token"] = token.stringValue }
            } else if selected == .ntfy, !token.stringValue.isEmpty { credentials = ["token": token.stringValue] }
            if credentials != nil { sink.credentialReference = UUID() }
            try sink.validate()
            var value = try formPolicy(); value.sinks.removeAll { $0.id == sink.id }; value.sinks.append(sink); try value.validate()
            savePolicy(value, credentials: credentials, newReference: credentials == nil ? nil : sink.credentialReference,
                obsoleteReference: prior?.credentialReference == sink.credentialReference ? nil : prior?.credentialReference)
        } catch { status.stringValue = error.localizedDescription }
    }
    private func savePolicy(_ value: NotificationPolicySettings, credentials: [String: String]? = nil, newReference: UUID? = nil, obsoleteReference: UUID? = nil) {
        guard !pending else { return }; setBusy(true)
        Task { @MainActor [weak self] in
            let result = await Task.detached { Result { () -> (NotificationPolicyStatus, String?) in
                if let credentials, let newReference { try CredentialStore.save(credentials, reference: newReference, allowInteraction: true) }
                do {
                    let response = try DaemonClient(endpoint: .localControlSocket).request(.activity(.notifications(.configure(value))), timeout: 5)
                    let status = try Self.decode(response)
                    var cleanup: String?
                    if let obsoleteReference {
                        do { try Self.removeUnreferencedCredential(obsoleteReference) }
                        catch { cleanup = "Policy saved; unused credential \(obsoleteReference.uuidString) could not be removed. Use notifications credential-remove after checking its references." }
                    }
                    return (status, cleanup)
                } catch {
                    let original = error
                    if let newReference {
                        do { try Self.removeUnreferencedCredential(newReference) }
                        catch { throw NotificationUIError.refused(original.localizedDescription + " Unused credential \(newReference.uuidString) could not be removed; check its references before removing it.") }
                    }
                    throw original
                }
            } }.value
            guard let self, !closed else { return }; setBusy(false)
            switch result {
            case .success(let (saved, cleanup)):
                policy = saved.settings; table.reloadData()
                let coordinator = SessionCoordinator.shared
                coordinator.settings.notificationPolicy = saved.settings
                coordinator.settings.systemNotificationsEnabled = saved.settings.banners
                coordinator.settings.notificationSoundEnabled = saved.settings.chimes
                coordinator.settings.notificationEvents = saved.settings.events
                status.stringValue = cleanup ?? "Policy saved. External payloads use the categories you selected; pending delivery expires rather than replaying indefinitely."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    nonisolated private static func decode(_ response: IPCResponse) throws -> NotificationPolicyStatus {
        if case let .error(message) = response { throw NotificationUIError.refused(message) }
        guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }
        return try JSONDecoder().decode(NotificationPolicyStatus.self, from: Data(json.utf8))
    }
    nonisolated private static func removeUnreferencedCredential(_ reference: UUID) throws {
        guard let bytes = try PrivateFile.read(HarnessPaths.settingsURL) else { return }
        let root = try JSONSerialization.jsonObject(with: bytes)
        func references(_ object: Any) -> Bool {
            if let values = object as? [String: Any] {
                if let value = values["credentialReference"] as? String, UUID(uuidString: value) == reference { return true }
                return values.values.contains(where: references)
            }
            if let values = object as? [Any] { return values.contains(where: references) }
            return false
        }
        if !references(root) { try CredentialStore.remove(reference, allowInteraction: true) }
    }
    private static func minute(_ value: String) throws -> Int {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { throw NotificationPolicyError.quietHours }
        return hour * 60 + minute
    }
    private static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}
private enum NotificationUIError: Error, LocalizedError {
    case unavailable, refused(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Notification policy requires an updated application daemon. Replace it while preserving existing shells."
        case let .refused(message): message
        }
    }
}
