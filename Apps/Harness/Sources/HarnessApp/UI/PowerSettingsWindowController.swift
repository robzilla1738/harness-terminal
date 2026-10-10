import AppKit
import HarnessCore

@MainActor
final class PowerSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let working = HarnessToggle(title: "Keep working agents awake on AC power")
    private let battery = HarnessToggle(title: "Also allow this on battery power")
    private let grace = HarnessTextField(string: "30")
    private let mode = HarnessSelect()
    private let status = NSTextField(wrappingLabelWithString: "Loading daemon power status…")
    private var save: NSButton!
    private var timer: Timer?
    private var pending = false
    private var capable = false
    private var initialized = false
    private var closed = false
    var onClose: (() -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Agent Power Policy"
        super.init(window: window); window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let caption = NSTextField(wrappingLabelWithString: "The daemon holds an idle-sleep assertion while agents work, including when the app is closed. Manual sleep, logout, and reboot still interrupt local execution.")
        root.addArrangedSubview(caption); root.addArrangedSubview(working); root.addArrangedSubview(battery)
        let graceRow = NSStackView(views: [NSTextField(labelWithString: "Release grace (seconds)"), grace]); graceRow.spacing = 10
        grace.widthAnchor.constraint(equalToConstant: 80).isActive = true; grace.setAccessibilityLabel("Idle sleep release grace in seconds")
        root.addArrangedSubview(graceRow)
        mode.addItems(withTitles: ["Auto", "On", "Off"]); mode.selectItem(withTitle: "Auto"); mode.widthAnchor.constraint(equalToConstant: 100).isActive = true; mode.target = self; mode.action = #selector(changeAwakeMode)
        mode.setAccessibilityLabel("Temporary idle sleep override")
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "Override until auto or service restart"), mode]); modeRow.spacing = 10
        root.addArrangedSubview(modeRow)
        let detail = NSTextField(wrappingLabelWithString: "On still respects battery restrictions. Auto follows working agents and the grace period. Off releases the assertion.")
        root.addArrangedSubview(detail)
        save = HarnessToolPage.button("Save policy", target: self, action: #selector(savePolicy), primary: true); root.addArrangedSubview(save)
        root.addArrangedSubview(status)
        for field in [caption, detail, status] { field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }
        window.contentView = root; HarnessToolPage.group(root, title: "While agents work", views: [working, battery, graceRow]); HarnessToolPage.group(root, title: "Temporary override", views: [modeRow, detail]); HarnessToolPage.install(in: window, title: "Power", subtitle: "Keep active work awake while respecting your battery.", symbol: "bolt", content: root); window.center(); setBusy(true)
        request(.status)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.request(.status) }
        }
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; timer?.invalidate(); timer = nil; onClose?() }
    private func setBusy(_ busy: Bool) {
        for button: NSControl? in [working, battery, save, mode] { button?.isEnabled = capable && !busy }
        grace.isEnabled = capable && !busy
    }
    @objc private func changeAwakeMode() { request(.mode(mode.titleOfSelectedItem == "On" ? .on : mode.titleOfSelectedItem == "Off" ? .off : .auto)) }
    @objc private func savePolicy() {
        var value = PowerSettings(); value.keepWorkingAgentsAwake = working.state == .on; value.allowOnBattery = battery.state == .on
        guard let seconds = Double(grace.stringValue) else { status.stringValue = "Enter a grace period from zero to 3600 seconds."; return }
        value.graceSeconds = seconds
        do { try value.validate() } catch { status.stringValue = error.localizedDescription; return }
        request(.configure(value))
    }
    private func request(_ operation: PowerOperation) {
        guard !closed, !pending else { return }; pending = true
        let updatesForm: Bool
        switch operation { case .status: updatesForm = !initialized; default: updatesForm = true; setBusy(true) }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { Result { () -> AwakeStatus in
                let client = DaemonClient(endpoint: .localControlSocket)
                guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 1), stats.supports(DaemonStats.powerManagement) else {
                    throw PowerUIError.refused("Power controls require an updated application daemon. Replace it while preserving existing shells.")
                }
                let response = try client.request(.activity(.power(operation)), timeout: 5)
                if case let .error(message) = response { throw PowerUIError.refused(message) }
                guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }
                return try JSONDecoder().decode(AwakeStatus.self, from: Data(json.utf8))
            } }.value
            guard let self, !closed else { return }; pending = false
            switch result {
            case .success(let value):
                capable = value.source != .unsupported; initialized = true
                if updatesForm {
                    working.state = value.settings.keepWorkingAgentsAwake ? .on : .off
                    battery.state = value.settings.allowOnBattery ? .on : .off
                    grace.stringValue = String(value.settings.graceSeconds)
                    SessionCoordinator.shared.settings.power = value.settings
                }
                mode.selectItem(withTitle: value.mode == .on ? "On" : value.mode == .off ? "Off" : "Auto")
                var text = "Power: \(value.source.rawValue). Idle-sleep assertion \(value.assertionActive ? "active" : "released"). Working agents: \(value.workingAgents)."
                if let seconds = value.lastSleepSeconds { text += " Last observed sleep: \(Int(seconds)) seconds; local execution paused." }
                if let error = value.unavailable { text += " " + error }
                status.stringValue = text
            case .failure(let error): status.stringValue = error.localizedDescription
            }
            setBusy(false)
        }
    }
}
private enum PowerUIError: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { if case let .refused(message) = self { message } else { nil } }
}
