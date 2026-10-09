import AppKit
import HarnessCore

@MainActor
final class AgentInboxPanelView: NSView {
    let preferredHeight: CGFloat = 380
    private let filter = NSSegmentedControl(labels: ["Needs Attention", "All Activity"], trackingMode: .selectOne, target: nil, action: nil)
    private let rows = NSStackView()
    private var renderedRows: [String: [String]] = [:]
    private var renderedFilter = -1
    private var renderedColors = ""
    private let onSelect: (HostedAttention) -> Void

    init(needsAttention: Bool = false, onSelect: @escaping (HostedAttention) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        let chrome = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.backgroundColor = (chrome.terminalBackground.blended(withFraction: chrome.isDark ? 0.12 : 0.04, of: chrome.textPrimary) ?? chrome.sidebarBackground).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = chrome.textSecondary.withAlphaComponent(0.4).cgColor
        HarnessDesign.applyShadow(.overlay, to: layer)
        filter.selectedSegment = needsAttention ? 0 : 1
        filter.target = self
        filter.action = #selector(refresh)
        filter.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedStackHost()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filter)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NotificationBus.shared.snapshotChanged, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func refresh() {
        let chrome = HarnessDesign.chrome
        appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        layer?.backgroundColor = (chrome.terminalBackground.blended(withFraction: chrome.isDark ? 0.12 : 0.04, of: chrome.textPrimary) ?? chrome.sidebarBackground).cgColor
        layer?.borderColor = chrome.textSecondary.withAlphaComponent(0.4).cgColor
        let items = SessionCoordinator.shared.attentionList().filter {
            filter.selectedSegment == 1 || $0.entry.activity.rank.needsYou || ($0.entry.activity.unread && $0.entry.activity.rank == .done)
        }
        let coordinator = SessionCoordinator.shared
        let legacyHosts = coordinator.connectedOwners.filter { owner in
            coordinator.snapshot(for: owner).workspaces.flatMap(\.sessions).flatMap(\.tabs).contains {
                ($0.agent != nil || $0.notificationText != nil) && $0.rootPane.allLeaves().allSatisfy { $0.activity == nil }
            }
        }
        var signatures = Dictionary(uniqueKeysWithValues: items.map { item in
            let activity = item.entry.activity
            return (item.id, [item.entry.sessionName, item.entry.tabTitle, String(describing: activity.rank),
                             activity.message ?? "", activity.mark?.app ?? "", activity.agent?.kind.rawValue ?? "",
                             String(activity.unread), String(activity.isSnoozed), String(item.connected)])
        })
        signatures["legacy"] = legacyHosts
        let colors = chrome.textPrimary.description + chrome.textSecondary.description
        guard signatures != renderedRows || renderedFilter != filter.selectedSegment || renderedColors != colors else { return }
        renderedRows = signatures; renderedFilter = filter.selectedSegment; renderedColors = colors
        let focused = (window?.firstResponder as? ActivityRowButton)?.item.id
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !legacyHosts.isEmpty {
            let notice = NSTextField(wrappingLabelWithString: "Update the daemon on \(legacyHosts.joined(separator: ", ")) for per-pane activity.")
            notice.textColor = chrome.textSecondary
            rows.addArrangedSubview(notice)
        }
        if items.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: filter.selectedSegment == 0 ? "Nothing needs your attention." : "Agent activity and program reports will appear here.")
            empty.textColor = HarnessDesign.chrome.textSecondary
            rows.addArrangedSubview(empty)
        }
        for item in items {
            let row = ActivityRowButton(item: item, onSelect: onSelect)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -16).isActive = true
            if item.id == focused { window?.makeFirstResponder(row) }
        }
    }
}

@MainActor
private final class ActivityRowButton: NSButton {
    let item: HostedAttention
    private let onSelect: (HostedAttention) -> Void

    init(item: HostedAttention, onSelect: @escaping (HostedAttention) -> Void) {
        self.item = item
        self.onSelect = onSelect
        super.init(frame: .zero)
        let activity = item.entry.activity
        let name = activity.mark?.app ?? activity.agent?.kind.displayName ?? item.entry.tabTitle
        let labels: [AttentionRank: String] = [.idle: "Idle", .working: "Working", .done: "Finished", .error: "Failed", .blocked: "Blocked", .waiting: "Needs input"]
        let status = item.connected ? labels[activity.rank] ?? "Idle" : "Disconnected · last known activity"
        let origin = activity.mark?.fromRealReport == true ? "Reported by program" : (activity.notification != nil ? "Notification" : "Inferred activity")
        let detail = activity.message ?? origin
        let context = "\(item.hostName) · \(item.entry.sessionName) · \(item.entry.tabTitle)"
        let text = NSMutableAttributedString(string: "\(activity.unread ? "• " : "")\(name) · \(status)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: HarnessDesign.chrome.textPrimary,
        ])
        text.append(NSAttributedString(string: "\(detail)\n\(context)\(activity.isSnoozed ? " · Snoozed" : "")", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: HarnessDesign.chrome.textSecondary,
        ]))
        attributedTitle = text
        alignment = .left
        isBordered = false
        cell?.wraps = true
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = "\(detail)\n\(context)\n\(origin) · \(AgentListFormatter.age(from: activity.updatedAt))\nRight-click for notification options"
        setAccessibilityLabel("\(name), \(status), \(context)")
        target = self
        action = #selector(openPane)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 70).isActive = true
        let menu = NSMenu()
        for (title, selector, tag) in [
            ("Open Pane", #selector(openPane), 0),
            ("Mark Read", #selector(markRead), 0),
            ("Snooze for 15 Minutes", #selector(snooze(_:)), 15),
            ("Snooze for One Hour", #selector(snooze(_:)), 60),
            ("Resume Notifications", #selector(snooze(_:)), 0),
        ] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openPane() { onSelect(item) }
    @objc private func markRead() { SessionCoordinator.shared.markAttentionRead(item) }
    @objc private func snooze(_ sender: NSMenuItem) { SessionCoordinator.shared.snoozeAttention(item, minutes: sender.tag) }
}
