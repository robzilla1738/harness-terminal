import AppKit
import HarnessCore

/// macOS menu-bar status item: the Harness mark, whose menu lists active agent
/// sessions and your sessions. All state comes from the daemon-backed snapshot
/// (`SessionCoordinator`), which owns session truth independently of the user's
/// shell — so the menu works identically for zsh, fish, bash, etc.
///
/// Owned by the `AppDelegate` for the app lifetime. The menu is rebuilt on each open
/// (`menuNeedsUpdate`) so it always reflects live state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = Self.markImage(pointSize: 17)
            button.imagePosition = .imageOnly
            button.toolTip = "Harness — sessions & agents"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let coordinator = SessionCoordinator.shared
        // Build from the snapshot that is already in memory.  The coordinator's snapshot is
        // kept current by the daemon's snapshot-push subscription (plus the 30 s safety
        // poll), so this will always reflect recent state without a blocking socket
        // round-trip on the menu-delegate path.
        //
        // We also kick a deferred refresh so the *next* open gets fresher data if the app
        // was idle past the refresh cadence. NOTE: syncFromDaemon is main-actor-bound, so
        // this Task only moves the IPC round-trip OFF the menu-open critical path (the menu
        // renders first; the sync runs on a later main-queue drain) — it does not move the
        // work off the main thread. Making the sync truly backgroundable means restructuring
        // SessionCoordinator's IPC, tracked as a follow-up; this removes the user-visible
        // menu-open stall, which was the bug.
        Task { @MainActor [weak coordinator] in
            coordinator?.syncFromDaemon(metadataOnly: true)
        }
        rebuild(menu, snapshot: coordinator.snapshot)
    }

    private func rebuild(_ menu: NSMenu, snapshot: SessionSnapshot) {
        menu.removeAllItems()

        addHeader("Active Agents", to: menu)
        let rows = activeAgentRows(snapshot)
        if rows.isEmpty {
            let none = NSMenuItem(title: "No active agents", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for row in rows { menu.addItem(agentItem(row)) }
        }

        menu.addItem(.separator())
        let openNotch = NSMenuItem(title: "Open Notch HUD", action: #selector(openNotchHUD), keyEquivalent: "")
        openNotch.target = self
        menu.addItem(openNotch)
        let closeNotch = NSMenuItem(title: "Close Notch HUD", action: #selector(closeNotchHUD), keyEquivalent: "")
        closeNotch.target = self
        menu.addItem(closeNotch)
        let notchSettings = NSMenuItem(title: "Notch HUD Settings…", action: #selector(openNotchSettings), keyEquivalent: "")
        notchSettings.target = self
        menu.addItem(notchSettings)

        menu.addItem(.separator())
        addHeader("Sessions", to: menu)
        let sessions = snapshot.workspaces.flatMap { ws in ws.sessions.map { (ws, $0) } }
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (workspace, session) in sessions {
                menu.addItem(sessionItem(workspace, session))
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Harness", action: #selector(openHarness), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    // MARK: - Item builders

    private func addHeader(_ text: String, to menu: NSMenu) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6,
        ])
        menu.addItem(item)
    }

    private func agentItem(_ row: AgentRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.kind.displayName, action: #selector(activate(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuRef(row.workspaceID, row.sessionID)
        let tint = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: row.kind)) ?? .secondaryLabelColor
        item.image = AgentIconRenderer.coloredOrMonogramImage(for: row.kind, size: 15, color: tint)

        let title = NSMutableAttributedString(string: row.kind.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        title.append(NSAttributedString(string: "   \(row.sessionName)", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = title
        if let badge = stateLabel(row.activity) {
            item.badge = NSMenuItemBadge(string: badge)
        }
        return item
    }

    private func sessionItem(_ workspace: Workspace, _ session: SessionGroup) -> NSMenuItem {
        let item = NSMenuItem(title: session.name, action: #selector(activate(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuRef(workspace.id, session.id)
        item.state = workspace.activeSessionID == session.id ? .on : .off

        let name = session.name.isEmpty ? sessionFolder(session) : session.name
        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
        ])
        let detail = sessionDetail(session)
        if !detail.isEmpty {
            title.append(NSAttributedString(string: "   \(detail)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        item.attributedTitle = title

        if let tab = session.activeTab ?? session.tabs.first,
           let kind = tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title) {
            let tint = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: kind)) ?? .secondaryLabelColor
            item.image = AgentIconRenderer.coloredOrMonogramImage(for: kind, size: 13, color: tint)
        }
        return item
    }

    // MARK: - Data

    private struct AgentRow {
        let workspaceID: WorkspaceID
        let sessionID: SessionID
        let kind: AgentKind
        let activity: AgentActivity
        let sessionName: String
    }

    /// One row per session that has a detected agent, carrying its highest-attention
    /// agent state. Sorted so sessions needing input (awaiting/errored) sit on top.
    private func activeAgentRows(_ snapshot: SessionSnapshot) -> [AgentRow] {
        var rows: [AgentRow] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                var best: (AgentKind, AgentActivity)?
                for tab in session.tabs {
                    guard let kind = tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title) else { continue }
                    let activity = tab.agent?.activity ?? (tab.status == .waiting ? .awaiting : .idle)
                    if best == nil || rank(activity) > rank(best!.1) { best = (kind, activity) }
                }
                if let best {
                    let name = session.name.isEmpty ? sessionFolder(session) : session.name
                    rows.append(AgentRow(workspaceID: workspace.id, sessionID: session.id,
                                         kind: best.0, activity: best.1, sessionName: name))
                }
            }
        }
        return rows.sorted { rank($0.activity) > rank($1.activity) }
    }

    private func rank(_ activity: AgentActivity) -> Int {
        switch activity {
        case .awaiting: return 3
        case .errored: return 2
        case .working: return 1
        case .idle: return 0
        }
    }

    private func stateLabel(_ activity: AgentActivity) -> String? {
        switch activity {
        case .awaiting: return "Awaiting"
        case .errored: return "Error"
        case .working: return "Working"
        case .idle: return nil
        }
    }

    private func sessionFolder(_ session: SessionGroup) -> String {
        guard let tab = session.activeTab ?? session.tabs.first else { return "Session" }
        let name = HarnessDesign.pathDisplayName(tab.cwd)
        return name.isEmpty ? "Session" : name
    }

    private func sessionDetail(_ session: SessionGroup) -> String {
        guard let tab = session.activeTab ?? session.tabs.first else { return "" }
        var parts: [String] = []
        if session.tabs.count > 1 { parts.append("\(session.tabs.count) tabs") }
        let folder = HarnessDesign.shortenPath(tab.cwd)
        if !folder.isEmpty { parts.append(folder) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Actions

    /// `representedObject` payload: a workspace, optionally narrowed to one session.
    private final class MenuRef {
        let workspace: WorkspaceID
        let session: SessionID?
        init(_ workspace: WorkspaceID, _ session: SessionID? = nil) {
            self.workspace = workspace
            self.session = session
        }
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuRef else { return }
        if let session = ref.session {
            SessionCoordinator.shared.selectSession(workspaceID: ref.workspace, sessionID: session)
        } else {
            SessionCoordinator.shared.selectWorkspace(ref.workspace)
        }
        bringToFront()
    }

    @objc private func openHarness() { bringToFront() }

    @objc private func openNotchHUD() {
        NotchPanelController.shared.openFromMenu()
    }

    @objc private func closeNotchHUD() {
        NotchPanelController.shared.closeFromMenu()
    }

    @objc private func openNotchSettings() {
        SettingsWindowController.show()
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    // MARK: - Status-item mark (the Harness two-squares logo, as a template)

    /// The Harness mark — two rounded squares on a "\" diagonal — rendered as a
    /// resolution-independent template so the menu bar tints it for light/dark.
    static func markImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let viewBox: CGFloat = 100
            let scale = min(rect.width, rect.height) / viewBox
            var transform = CGAffineTransform(
                translationX: rect.minX + (rect.width - viewBox * scale) / 2,
                y: rect.minY + (rect.height - viewBox * scale) / 2
            ).scaledBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.black.cgColor)
            // y-up: top-left square (high y) + bottom-right square (low y), overlapping
            // at the centre so they read as one connected mark.
            for shape in [CGRect(x: 9, y: 41, width: 50, height: 50),
                          CGRect(x: 41, y: 9, width: 50, height: 50)] {
                let path = CGPath(roundedRect: shape, cornerWidth: 16, cornerHeight: 16, transform: nil)
                if let scaled = path.copy(using: &transform) {
                    ctx.addPath(scaled)
                    ctx.fillPath()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
