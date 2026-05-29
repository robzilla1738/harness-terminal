import AppKit
import HarnessCore

/// Left session rail — workspace pill, sessions list, and a quiet footer.
@MainActor
final class HarnessSidebarPanelViewController: NSViewController {
    private let chromeHeader = NSView()
    private let workspaceBar = NSView()
    private let workspacePill = WorkspacePillButton()
    private let notificationBell = NotificationBellButton()
    private let searchField = NSSearchField()
    /// Wraps the search field so it gets the same radius-7 elevated-surface chrome as
    /// the workspace pill and session cards (the bare NSSearchField is a capsule).
    private let searchContainer = NSView()
    private let sectionHeader = NSView()
    private let sectionLabel = NSTextField(labelWithString: "Sessions")
    private let sessionTable = NSTableView()
    private let settingsRow = SidebarSettingsRow()
    private let footer = NSView()
    private var sessionScroll: NSScrollView?
    private var workspaces: [Workspace] = []
    private var sessions: [SessionGroup] = []
    private var activeWorkspaceID: WorkspaceID?
    private var activeSessionID: SessionID?
    private var isProgrammaticSelection = false
    private var workspaceDropdown: WorkspaceSwitcherPanelView?
    private var workspaceDropdownMonitor: Any?
    /// Live filter text from the search field; empty shows all sessions.
    private var sessionFilter = ""
    /// Set by `MainSplitViewController` so the sidebar's Settings affordances toggle
    /// the inline Settings panel instead of opening a separate window.
    var onToggleSettings: (() -> Void)?

    /// Sessions after applying the search filter. Drag-reorder is disabled while a
    /// filter is active (see the data source), so callers that reorder still use the
    /// unfiltered `sessions`.
    private var displayedSessions: [SessionGroup] {
        let q = sessionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { sessionMatches($0, query: q) }
    }

    private func sessionMatches(_ session: SessionGroup, query: String) -> Bool {
        if session.name.lowercased().contains(query) { return true }
        for tab in session.tabs {
            if tab.title.lowercased().contains(query) { return true }
            if tab.cwd.lowercased().contains(query) { return true }
            if HarnessDesign.pathDisplayName(tab.cwd).lowercased().contains(query) { return true }
        }
        return false
    }

    override func loadView() {
        let root = NSView()
        HarnessDesign.applySidebarChrome(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChromeHeader()
        setupWorkspaceBar()
        setupSearchField()
        setupSectionHeader()
        setupFooter()
        setupSessionList()
        reload()
        applyChromeColors()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
    }

    func applyChromeColors() {
        HarnessDesign.applySidebarChrome(to: view)
        HarnessDesign.makeClear(chromeHeader)
        HarnessDesign.makeClear(workspaceBar)
        HarnessDesign.makeClear(sectionHeader)
        HarnessDesign.makeClear(footer)
        sectionLabel.textColor = HarnessDesign.chrome.textTertiary
        workspacePill.applyChrome()
        dismissWorkspaceDropdown()
        for case let button as SoftIconButton in footer.subviews {
            button.applyChrome()
        }
        settingsRow.applyChrome()
        applySearchChrome()
        sessionTable.reloadData()
    }

    private func setupChromeHeader() {
        chromeHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(chromeHeader)
        view.addSubview(chromeHeader)
        NSLayoutConstraint.activate([
            chromeHeader.topAnchor.constraint(equalTo: view.topAnchor),
            chromeHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeHeader.heightAnchor.constraint(equalToConstant: HarnessDesign.titlebarChromeHeight),
        ])
    }

    private func setupWorkspaceBar() {
        workspaceBar.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(workspaceBar)

        workspacePill.target = self
        workspacePill.action = #selector(showWorkspaceMenu)
        workspacePill.onMoreClick = { [weak self] anchor in
            self?.showActiveWorkspaceActions(from: anchor)
        }
        workspacePill.translatesAutoresizingMaskIntoConstraints = false

        notificationBell.translatesAutoresizingMaskIntoConstraints = false
        notificationBell.target = self
        notificationBell.action = #selector(notificationBellClicked)

        workspaceBar.addSubview(workspacePill)
        workspaceBar.addSubview(notificationBell)
        view.addSubview(workspaceBar)

        NSLayoutConstraint.activate([
            workspaceBar.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor),
            workspaceBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            workspaceBar.heightAnchor.constraint(equalToConstant: HarnessDesign.workspaceBarHeight),
            workspacePill.leadingAnchor.constraint(equalTo: workspaceBar.leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            workspacePill.trailingAnchor.constraint(equalTo: notificationBell.leadingAnchor, constant: -6),
            workspacePill.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            workspacePill.heightAnchor.constraint(equalToConstant: 30),
            notificationBell.trailingAnchor.constraint(equalTo: workspaceBar.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            notificationBell.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            notificationBell.widthAnchor.constraint(equalToConstant: 30),
            notificationBell.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @objc private func notificationBellClicked() {
        showNotificationsDropdown()
    }

    private var notificationsDropdown: NotificationDropdownPanelView?
    private var notificationsDropdownMonitor: Any?

    private func showNotificationsDropdown() {
        if notificationsDropdown != nil {
            dismissNotificationsDropdown()
            return
        }
        let coordinator = SessionCoordinator.shared
        let entries = coordinator.notificationsList()
        let dropdown = NotificationDropdownPanelView(
            entries: entries,
            onSelect: { [weak self] entry in
                self?.dismissNotificationsDropdown()
                coordinator.openNotification(entry)
            },
            onClearAll: { [weak self] in
                self?.dismissNotificationsDropdown()
                coordinator.clearAllNotifications()
            }
        )
        dropdown.alphaValue = 0
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.layer?.zPosition = 100
        view.addSubview(dropdown)
        notificationsDropdown = dropdown
        // Anchor leading + trailing to the sidebar's inset so the panel never
        // overshoots the sidebar (previous fixed-300-width trailing-anchored
        // panel had its left edge clip past the sidebar's leading bound).
        NSLayoutConstraint.activate([
            dropdown.topAnchor.constraint(equalTo: notificationBell.bottomAnchor, constant: 6),
            dropdown.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            dropdown.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            dropdown.heightAnchor.constraint(equalToConstant: dropdown.preferredHeight),
        ])
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropdown.animator().alphaValue = 1
        }
        installNotificationsDropdownMonitor()
    }

    private func dismissNotificationsDropdown() {
        notificationsDropdown?.removeFromSuperview()
        notificationsDropdown = nil
        if let monitor = notificationsDropdownMonitor {
            NSEvent.removeMonitor(monitor)
            notificationsDropdownMonitor = nil
        }
    }

    private func installNotificationsDropdownMonitor() {
        notificationsDropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let dropdown = self.notificationsDropdown else { return event }
            let point = dropdown.convert(event.locationInWindow, from: nil)
            if !dropdown.bounds.contains(point) {
                let bellPoint = self.notificationBell.convert(event.locationInWindow, from: nil)
                if !self.notificationBell.bounds.contains(bellPoint) {
                    self.dismissNotificationsDropdown()
                }
            }
            return event
        }
    }

    private func setupSectionHeader() {
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(sectionHeader)

        sectionLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        sectionLabel.stringValue = "SESSIONS"
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        sectionHeader.addSubview(sectionLabel)
        view.addSubview(sectionHeader)

        NSLayoutConstraint.activate([
            sectionHeader.topAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sectionHeader.heightAnchor.constraint(equalToConstant: 24),
            sectionLabel.leadingAnchor.constraint(equalTo: sectionHeader.leadingAnchor, constant: HarnessDesign.horizontalInset),
            sectionLabel.bottomAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: -4),
        ])
    }

    /// Warp-style "Search sessions…" field; filters the list live by name / cwd.
    private func setupSearchField() {
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = HarnessDesign.Radius.card
        searchContainer.layer?.cornerCurve = .continuous
        searchContainer.layer?.borderWidth = 1
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        // Borderless/clear field inside; the container owns the rounded-rect chrome so
        // the magnifier + text sit on our standardized surface (matching the pill).
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.placeholderString = "Search sessions…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)

        searchContainer.addSubview(searchField)
        view.addSubview(searchContainer)
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: workspaceBar.bottomAnchor, constant: 2),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: HarnessDesign.horizontalInset),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -HarnessDesign.horizontalInset),
            searchContainer.heightAnchor.constraint(equalToConstant: 30),

            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
        ])
    }

    private func applySearchChrome() {
        let c = HarnessChrome.current
        searchContainer.layer?.backgroundColor = c.surfaceElevated.cgColor
        searchContainer.layer?.borderColor = c.border.cgColor
    }

    @objc private func searchChanged() {
        sessionFilter = searchField.stringValue
        sessionTable.reloadData()
    }

    /// Reflect the inline Settings panel's visibility in the sidebar row's highlight.
    func setSettingsActive(_ active: Bool) {
        settingsRow.setActive(active)
    }

    private func setupSessionList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = HarnessDesign.sidebarWidth
        sessionTable.addTableColumn(column)
        sessionTable.headerView = nil
        sessionTable.backgroundColor = .clear
        sessionTable.rowHeight = HarnessDesign.sessionRowHeight
        sessionTable.intercellSpacing = NSSize(width: 0, height: HarnessDesign.rowSpacing)
        sessionTable.selectionHighlightStyle = .none
        sessionTable.focusRingType = .none
        sessionTable.style = .plain
        sessionTable.dataSource = self
        sessionTable.delegate = self
        sessionTable.doubleAction = #selector(sessionDoubleClick)
        sessionTable.target = self
        sessionTable.registerForDraggedTypes([Self.sessionRowPasteboardType])
        sessionTable.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = sessionTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        sessionScroll = scroll
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
    }

    /// One footer row: "⚙ Settings" (text + icon) on the left, a trimmed set of quick
    /// icons on the right — all on the same baseline. The redundant settings slider and
    /// the help icon were removed (Settings is now the labeled button).
    private func setupFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(footer)

        settingsRow.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.onClick = { [weak self] in self?.openSettings() }

        let newSession = HarnessDesign.softIconButton(symbol: "plus", tooltip: "New session")
        newSession.target = self
        newSession.action = #selector(addSession)

        let newWS = HarnessDesign.softIconButton(symbol: "folder.badge.plus", tooltip: "New workspace")
        newWS.target = self
        newWS.action = #selector(addWorkspace)

        let palette = HarnessDesign.softIconButton(symbol: "command", tooltip: "Command palette (⌘K)")
        palette.target = self
        palette.action = #selector(openPalette)

        footer.addSubview(settingsRow)
        footer.addSubview(newSession)
        footer.addSubview(newWS)
        footer.addSubview(palette)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: HarnessDesign.footerHeight + 6),

            settingsRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            settingsRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            settingsRow.heightAnchor.constraint(equalToConstant: 32),
            settingsRow.trailingAnchor.constraint(lessThanOrEqualTo: palette.leadingAnchor, constant: -8),

            palette.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            palette.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newWS.trailingAnchor.constraint(equalTo: palette.leadingAnchor, constant: -2),
            newWS.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newSession.trailingAnchor.constraint(equalTo: newWS.leadingAnchor, constant: -2),
            newSession.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    @objc func reload() {
        let snap = SessionCoordinator.shared.snapshot
        workspaces = snap.workspaces
        activeWorkspaceID = snap.activeWorkspaceID
        activeSessionID = snap.activeWorkspace?.activeSessionID
        sessions = snap.activeWorkspace?.sessions ?? []
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: sessions.count)
        sessionTable.reloadData()

        if let activeSessionID,
           let row = displayedSessions.firstIndex(where: { $0.id == activeSessionID })
        {
            isProgrammaticSelection = true
            sessionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isProgrammaticSelection = false
            sessionTable.scrollRowToVisible(row)
        }
    }

    /// Updates session card labels in place (title/cwd/branch/agent) without
    /// rebuilding the table — preserves selection + scroll position.
    func refreshMetadata() {
        let snap = SessionCoordinator.shared.snapshot
        let newSessions = snap.activeWorkspace?.sessions ?? []
        let activeID = snap.activeWorkspace?.activeSessionID
        // Structural changes still take the full reload path.
        if newSessions.map(\.id) != sessions.map(\.id) {
            reload()
            return
        }
        sessions = newSessions
        activeWorkspaceID = snap.activeWorkspaceID
        activeSessionID = activeID
        workspaces = snap.workspaces
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: sessions.count)
        let displayed = displayedSessions
        for row in 0 ..< displayed.count {
            if let cell = sessionTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCardRowView {
                cell.configure(session: displayed[row], isSelected: displayed[row].id == activeID)
            }
        }
    }

    @objc private func addWorkspace() {
        let count = SessionCoordinator.shared.snapshot.workspaces.count + 1
        SessionCoordinator.shared.addWorkspace(name: "Workspace \(count)")
    }

    /// Quick-actions menu opened from a row's ellipsis (inside the workspace
    /// dropdown). Just "Delete workspace…" — rename lives on the pill itself.
    fileprivate func confirmDeleteWorkspace(_ workspace: Workspace, anchor: NSView) {
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete workspace…", action: #selector(deleteWorkspaceFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = workspace.id
        menu.addItem(delete)
        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    /// Quick-actions menu opened from the workspace pill's ellipsis (top-level).
    /// Rename and Delete for the active workspace. Delete is disabled when this
    /// is the only workspace (you can't remove the last one).
    private func showActiveWorkspaceActions(from anchor: NSView) {
        guard let active = workspaces.first(where: { $0.id == activeWorkspaceID }) else { return }
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename workspace…", action: #selector(renameActiveWorkspace(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = active.id
        menu.addItem(rename)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete workspace…", action: #selector(deleteWorkspaceFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = active.id
        delete.isEnabled = workspaces.count > 1
        menu.addItem(delete)

        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    @objc private func renameActiveWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        alert.informativeText = "Enter a new name for \"\(workspace.name)\"."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = workspace.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        SessionCoordinator.shared.renameWorkspace(id: id, name: trimmed)
    }

    @objc private func deleteWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        dismissWorkspaceDropdown()
        let alert = NSAlert()
        alert.messageText = "Delete \"\(workspace.name)\"?"
        alert.informativeText = "All sessions and tabs in this workspace will be closed. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SessionCoordinator.shared.closeWorkspace(id: id)
        }
    }

    @objc private func addSession() {
        guard let activeWorkspaceID else { return }
        SessionCoordinator.shared.addSession(to: activeWorkspaceID)
    }

    @objc private func sessionDoubleClick() {
        selectSessionRow()
    }

    @objc private func showWorkspaceMenu() {
        if workspaceDropdown != nil {
            dismissWorkspaceDropdown()
            return
        }
        let dropdown = WorkspaceSwitcherPanelView(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            onSelect: { [weak self] id in
                self?.dismissWorkspaceDropdown()
                SessionCoordinator.shared.selectWorkspace(id)
            },
            onNew: { [weak self] in
                self?.dismissWorkspaceDropdown()
                self?.addWorkspace()
            },
            onDelete: { [weak self] workspace, anchor in
                self?.confirmDeleteWorkspace(workspace, anchor: anchor)
            }
        )
        dropdown.alphaValue = 0
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.layer?.zPosition = 100
        view.addSubview(dropdown)
        workspaceDropdown = dropdown
        NSLayoutConstraint.activate([
            dropdown.topAnchor.constraint(equalTo: workspacePill.bottomAnchor, constant: 6),
            dropdown.leadingAnchor.constraint(equalTo: workspacePill.leadingAnchor),
            dropdown.trailingAnchor.constraint(equalTo: workspacePill.trailingAnchor),
            dropdown.heightAnchor.constraint(equalToConstant: clampedDropdownHeight(dropdown.preferredHeight)),
        ])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropdown.animator().alphaValue = 1
        }
        installWorkspaceDropdownMonitor()
    }

    private func dismissWorkspaceDropdown() {
        workspaceDropdown?.removeFromSuperview()
        workspaceDropdown = nil
        if let workspaceDropdownMonitor {
            NSEvent.removeMonitor(workspaceDropdownMonitor)
            self.workspaceDropdownMonitor = nil
        }
    }

    private func installWorkspaceDropdownMonitor() {
        if let workspaceDropdownMonitor {
            NSEvent.removeMonitor(workspaceDropdownMonitor)
        }
        workspaceDropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let dropdown = self.workspaceDropdown else { return event }
            guard event.window === self.view.window else {
                self.dismissWorkspaceDropdown()
                return event
            }
            let point = event.locationInWindow
            let dropdownPoint = dropdown.convert(point, from: nil)
            let pillPoint = self.workspacePill.convert(point, from: nil)
            if dropdown.bounds.contains(dropdownPoint) || self.workspacePill.bounds.contains(pillPoint) {
                return event
            }
            self.dismissWorkspaceDropdown()
            return event
        }
    }

    /// Keep the workspace dropdown on-screen: never extend past the footer. If the
    /// ideal height doesn't fit, the dropdown scrolls internally.
    private func clampedDropdownHeight(_ preferred: CGFloat) -> CGFloat {
        let available = view.bounds.height
            - HarnessDesign.titlebarChromeHeight
            - HarnessDesign.workspaceBarHeight
            - HarnessDesign.footerHeight
            - 20
        return min(preferred, max(120, available))
    }

    @objc private func openPalette() {
        if let window = view.window {
            CommandPaletteController.present(relativeTo: window)
        }
    }

    @objc private func openSettings() {
        // Toggle the inline panel when the host wired it up; fall back to the
        // standalone window otherwise (e.g. if presented outside the main split).
        if let onToggleSettings {
            onToggleSettings()
        } else {
            SettingsWindowController.show()
        }
    }

    private func selectSessionRow() {
        let row = sessionTable.selectedRow
        let displayed = displayedSessions
        guard row >= 0, row < displayed.count, let activeWorkspaceID else { return }
        SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: displayed[row].id)
    }

    private func confirmCloseSession(_ session: SessionGroup) {
        let title = session.name.isEmpty ? sessionTitle(for: session) : session.name
        let alert = NSAlert()
        alert.messageText = "Close session \"\(title)\"?"
        alert.informativeText = session.tabs.count > 1
            ? "This will close \(session.tabs.count) tabs and their running shells."
            : "This will close the session and its running shell."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if activeSessionID != session.id, let activeWorkspaceID {
            SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: session.id)
        }
        SessionCoordinator.shared.closeActiveSession()
    }

    private func sessionTitle(for session: SessionGroup) -> String {
        guard let tab = session.activeTab ?? session.tabs.first else { return "Session" }
        return HarnessDesign.pathDisplayName(tab.cwd)
    }

    // MARK: - Session kebab menu

    /// Per-session actions popped from the card's ⋮ button (Warp-style). Items map
    /// to existing capabilities — rename via the `renameSession` IPC, close via
    /// `closeSession`, and clipboard copies handled locally.
    private func showSessionActions(for session: SessionGroup, anchor: NSView) {
        let menu = NSMenu()

        let rename = NSMenuItem(title: "Rename session…", action: #selector(renameSessionFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = session.id
        menu.addItem(rename)

        let copyCwd = NSMenuItem(title: "Copy working directory", action: #selector(copySessionCwd(_:)), keyEquivalent: "")
        copyCwd.target = self
        copyCwd.representedObject = session.id
        menu.addItem(copyCwd)

        let copyTitle = NSMenuItem(title: "Copy session title", action: #selector(copySessionTitle(_:)), keyEquivalent: "")
        copyTitle.target = self
        copyTitle.representedObject = session.id
        menu.addItem(copyTitle)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close session", action: #selector(closeSessionFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = session.id
        menu.addItem(close)

        if sessions.count > 1 {
            let closeOthers = NSMenuItem(title: "Close other sessions", action: #selector(closeOtherSessionsFromMenu(_:)), keyEquivalent: "")
            closeOthers.target = self
            closeOthers.representedObject = session.id
            menu.addItem(closeOthers)
        }

        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    private func session(for id: SessionID) -> SessionGroup? {
        sessions.first { $0.id == id }
    }

    @objc private func renameSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        let current = session.name.isEmpty ? sessionTitle(for: session) : session.name
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Enter a new name for this session."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = current
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        SessionCoordinator.shared.requestDaemon(.renameSession(sessionID: id, name: trimmed))
        SessionCoordinator.shared.syncFromDaemon()
    }

    @objc private func copySessionCwd(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id),
              let tab = session.activeTab ?? session.tabs.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.cwd, forType: .string)
    }

    @objc private func copySessionTitle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        let title = session.name.isEmpty ? sessionTitle(for: session) : session.name
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    @objc private func closeSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        confirmCloseSession(session)
    }

    @objc private func closeOtherSessionsFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let activeWorkspaceID else { return }
        let others = sessions.filter { $0.id != id }
        guard !others.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Close \(others.count) other session\(others.count == 1 ? "" : "s")?"
        alert.informativeText = "Their tabs and running shells will be closed. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Others")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for session in others {
            SessionCoordinator.shared.requestDaemon(.closeSession(sessionID: session.id))
        }
        SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: id)
        SessionCoordinator.shared.syncFromDaemon()
    }
}

extension HarnessSidebarPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    fileprivate static let sessionRowPasteboardType = NSPasteboard.PasteboardType("com.robert.harness.session-row")

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedSessions.count
    }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Reorder maps to the unfiltered list, so it's only meaningful with no
        // active filter (displayed rows == sessions then).
        guard sessionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.sessionRowPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        guard sessionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let workspaceID = activeWorkspaceID,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let raw = item.string(forType: Self.sessionRowPasteboardType),
              let from = Int(raw),
              from >= 0, from < sessions.count
        else { return false }
        // NSTableView reports the *gap* index; adjust so a downward move lands at
        // the slot just below the gap (drop above row 3 from row 1 → target 2).
        let target = from < row ? row - 1 : row
        guard target != from else { return false }
        SessionCoordinator.shared.reorderSession(
            workspaceID: workspaceID,
            sessionID: sessions[from].id,
            toIndex: target
        )
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = displayedSessions[row]
        let cell = SessionCardRowView()
        cell.configure(
            session: session,
            isSelected: session.id == SessionCoordinator.shared.snapshot.activeWorkspace?.activeSessionID
        )
        cell.onClose = { [weak self] in
            self?.confirmCloseSession(session)
        }
        cell.onMore = { [weak self] anchor in
            self?.showSessionActions(for: session, anchor: anchor)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        selectSessionRow()
    }
}

// MARK: - Workspace switcher

@MainActor
private final class WorkspaceSwitcherPanelView: NSView {
    private let workspaces: [Workspace]
    private let activeWorkspaceID: WorkspaceID?
    private let onSelect: (WorkspaceID) -> Void
    private let onNew: () -> Void
    private let onDelete: (Workspace, NSView) -> Void
    let preferredHeight: CGFloat

    init(
        workspaces: [Workspace],
        activeWorkspaceID: WorkspaceID?,
        onSelect: @escaping (WorkspaceID) -> Void,
        onNew: @escaping () -> Void,
        onDelete: @escaping (Workspace, NSView) -> Void
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.onSelect = onSelect
        self.onNew = onNew
        self.onDelete = onDelete
        self.preferredHeight = max(84, CGFloat(37 * workspaces.count + 50))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        // Shadow needs to escape the bounds, so the rounded fill lives on a masked
        // sublayer instead of clipping the whole view.
        layer?.masksToBounds = false
        let c = HarnessDesign.chrome
        layer?.backgroundColor = (c.sidebarBackground.blended(withFraction: c.isDark ? 0.06 : 0.04, of: c.textPrimary) ?? c.sidebarBackground).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.14).cgColor
        HarnessDesign.applyShadow(.overlay, to: layer)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for workspace in workspaces {
            let isLast = workspaces.count == 1
            let row = WorkspaceSwitcherRow(
                title: workspace.name,
                count: workspace.sessions.count,
                isActive: workspace.id == activeWorkspaceID,
                symbol: "square.stack.3d.up",
                canDelete: !isLast
            )
            row.onClick = { [onSelect] in onSelect(workspace.id) }
            row.onMoreClick = { [weak row, onDelete] in
                guard let row else { return }
                onDelete(workspace, row)
            }
            stack.addArrangedSubview(row)
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HarnessDesign.chrome.textPrimary.withAlphaComponent(0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)

        let newRow = WorkspaceSwitcherRow(
            title: "New Workspace...",
            count: nil,
            isActive: false,
            symbol: "folder.badge.plus"
        )
        newRow.onClick = onNew
        stack.addArrangedSubview(newRow)

        // Scrollable so a long workspace list stays on-screen when the caller clamps
        // the dropdown height (see clampedDropdownHeight).
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }
}

/// A row is a plain NSView, not an NSButton: NSButton's bezel `alignmentRectInsets`
/// offset it inside the stack view, which left the selected row floating off to one
/// side. A view fills the row width cleanly and we drive the click ourselves.
@MainActor
private final class WorkspaceSwitcherRow: NSView {
    var onClick: (() -> Void)?
    var onMoreClick: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private let active: Bool
    private let canDelete: Bool

    init(title: String, count: Int?, isActive: Bool, symbol: String, canDelete: Bool = true) {
        active = isActive
        self.canDelete = canDelete
        // `count` retained on the init signature so call sites don't have to
        // change; the visual badge has been removed for a cleaner row.
        _ = count
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toolTip = title

        // Ellipsis overflow button: shown on hover or when the row is active, so
        // the active row gets a clear "more actions" affordance without crowding
        // every row at rest.
        let moreConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(moreConfig)
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.isBordered = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.alphaValue = 0
        moreButton.isHidden = !canDelete

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(moreButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -6),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            moreButton.widthAnchor.constraint(equalToConstant: 22),
            moreButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyChrome()
    }

    @objc private func moreClicked() {
        onMoreClick?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // Capture the press (without forwarding) so this view receives the matching
    // mouseUp; the selection fires on up if the cursor is still inside the row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    private func applyChrome() {
        let c = HarnessDesign.chrome
        let selectedFill = c.accent.withAlphaComponent(c.isDark ? 0.14 : 0.11)
        layer?.backgroundColor = active
            ? selectedFill.cgColor
            : (isHovered ? c.textPrimary.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = 0
        icon.contentTintColor = active ? c.accent : c.textTertiary
        titleLabel.textColor = active || isHovered ? c.textPrimary : c.textSecondary
        moreButton.contentTintColor = c.textSecondary
        // Ellipsis is visible on the active row at rest and on any row when hovered.
        // Fade for polish — popping in is jarring next to the count label.
        let shouldShow = canDelete && (active || isHovered)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            moreButton.animator().alphaValue = shouldShow ? 1 : 0
        }
    }
}

// MARK: - Workspace pill

@MainActor
final class WorkspacePillButton: NSButton {
    var onMoreClick: ((NSView) -> Void)?

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let moreButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .inline
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        // Ellipsis: quick actions (rename, delete) without opening the workspace
        // dropdown first. Its own NSButton so the click is captured here instead
        // of falling through to the pill's primary action.
        let moreConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Workspace actions")?
            .withSymbolConfiguration(moreConfig)
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.isBordered = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.toolTip = "Workspace actions"

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(moreButton)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -4),
            moreButton.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 20),
            moreButton.heightAnchor.constraint(equalToConstant: 20),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])

        applyChrome()
    }

    @objc private func moreClicked() {
        onMoreClick?(moreButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func configure(name: String, count: Int) {
        // `count` retained in the signature for callers that still pass it; the
        // visual badge is gone (cleaner pill) but the parameter is kept to avoid
        // a churn-y signature change at every call site.
        _ = count
        nameLabel.stringValue = name
        toolTip = name
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.Radius.card
        layer?.borderWidth = 1
        layer?.borderColor = (isHovered ? c.borderStrong : c.border).cgColor
        let resting = c.surfaceElevated
        let hover = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.12)
        layer?.backgroundColor = (isHovered ? hover : resting).cgColor
        nameLabel.textColor = c.textPrimary
        icon.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
        chevron.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
        moreButton.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
    }
}

// MARK: - Session card

@MainActor
final class SessionCardRowView: NSView {
    var onClose: (() -> Void)?
    /// Fired by the ⋮ kebab — the anchor is the button, for menu positioning.
    var onMore: ((NSView) -> Void)?

    private let fill = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let agentChip = AgentChipView()
    private let moreButton = HoverIconButton()
    private let closeButton = HoverIconButton()
    private var isSelected = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = HarnessDesign.cornerRadius
        fill.layer?.cornerCurve = .continuous
        fill.layer?.borderWidth = 1
        fill.layer?.masksToBounds = false
        fill.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // The agent chip now carries the full tool name; let the title truncate to
        // make room rather than squeezing the chip.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        agentChip.translatesAutoresizingMaskIntoConstraints = false
        agentChip.isHidden = true

        let xConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close session")?
            .withSymbolConfiguration(xConfig)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .smallSquare
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        closeButton.layer?.cornerCurve = .continuous

        let kebabConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Session actions")?
            .withSymbolConfiguration(kebabConfig)
        moreButton.imagePosition = .imageOnly
        moreButton.isBordered = false
        moreButton.bezelStyle = .smallSquare
        moreButton.setButtonType(.momentaryChange)
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.alphaValue = 0
        moreButton.wantsLayer = true
        moreButton.layer?.cornerRadius = 8
        moreButton.layer?.cornerCurve = .continuous

        addSubview(fill)
        fill.addSubview(titleLabel)
        fill.addSubview(metaLabel)
        fill.addSubview(agentChip)
        fill.addSubview(moreButton)
        fill.addSubview(closeButton)

        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),

            titleLabel.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: fill.topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: agentChip.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            moreButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 16),
            moreButton.heightAnchor.constraint(equalToConstant: 16),

            agentChip.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -6),
            agentChip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            agentChip.heightAnchor.constraint(equalToConstant: 18),
            agentChip.widthAnchor.constraint(lessThanOrEqualToConstant: 120),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            // Meta sits on its own line below the title/controls, so it gets the full
            // card width — the cwd path was being clipped early against the close button.
            metaLabel.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: fill.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func configure(session: SessionGroup, isSelected: Bool) {
        let tab = session.activeTab ?? session.tabs.first ?? Tab()
        let folder = HarnessDesign.shortenPath(tab.cwd)
        let folderName = HarnessDesign.pathDisplayName(tab.cwd)
        let displayedAgentKind = tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)
        titleLabel.stringValue = session.name.isEmpty ? folderName : session.name
        toolTip = session.name.isEmpty ? folder : "\(session.name) — \(folder)"

        var metaParts: [String] = []
        if session.tabs.count > 1 {
            metaParts.append("\(session.tabs.count) tabs")
        }
        metaParts.append(folder)
        metaLabel.stringValue = metaParts.joined(separator: "  •  ")

        if let kind = displayedAgentKind {
            agentChip.configure(text: kind.displayName, hex: SessionCoordinator.shared.settings.agentColorHex(for: kind))
            agentChip.isHidden = false
        } else {
            agentChip.isHidden = true
        }

        setSelected(isSelected)
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func moreClicked() {
        onMore?(moreButton)
    }

    private func setSelected(_ selected: Bool) {
        isSelected = selected
        refresh()
    }

    private func refresh() {
        let c = HarnessDesign.chrome
        metaLabel.textColor = c.textTertiary
        if isSelected {
            // Selected row: theme-tinted fill + accent rim + resting elevation. The
            // fill is the accent at low alpha (legible on every theme) so the active
            // session reads instantly even at a glance.
            let selectedFill = c.accent.withAlphaComponent(c.isDark ? 0.13 : 0.10)
            fill.layer?.backgroundColor = selectedFill.cgColor
            fill.layer?.borderColor = c.focusRing.withAlphaComponent(c.isDark ? 0.48 : 0.52).cgColor
            HarnessDesign.applyShadow(.elevation1, to: fill.layer)
            titleLabel.textColor = c.textPrimary
            metaLabel.textColor = c.textSecondary
        } else if isHovered {
            fill.layer?.backgroundColor = c.rowHoverFill.cgColor
            fill.layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: fill.layer)
            titleLabel.textColor = c.textPrimary
        } else {
            fill.layer?.backgroundColor = NSColor.clear.cgColor
            fill.layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: fill.layer)
            titleLabel.textColor = c.textSecondary
        }
        // Controls appear only while the row is hovered (not merely selected); each
        // button then carries its own hover highlight via HoverIconButton.
        closeButton.alphaValue = isHovered ? 1 : 0
        closeButton.contentTintColor = c.textTertiary
        moreButton.alphaValue = isHovered ? 1 : 0
        moreButton.contentTintColor = c.textTertiary
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        // Cross-fade the hover state so cursor flicks across the list don't strobe.
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            refresh()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            refresh()
        }
    }
}

// MARK: - Settings row

/// Pinned "Settings" entry at the bottom of the sidebar (Warp-style). A plain view
/// (not NSButton — same reasoning as WorkspaceSwitcherRow: the bezel insets shift the
/// fill). Highlights while the inline Settings panel is showing.
@MainActor
final class SidebarSettingsRow: NSView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Settings")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.cornerRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Settings (⌘,)"

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Equality (not <=) so the row sizes to its content and reads as a compact
            // button in the footer rather than stretching the full sidebar width.
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ active: Bool) {
        isActive = active
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.cornerRadius
        if isActive {
            layer?.backgroundColor = c.accent.withAlphaComponent(c.isDark ? 0.13 : 0.10).cgColor
            icon.contentTintColor = c.accent
            label.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.rowHoverFill.cgColor
            icon.contentTintColor = c.textPrimary
            label.textColor = c.textPrimary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            icon.contentTintColor = c.textTertiary
            label.textColor = c.textSecondary
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }
}

// MARK: - Hover icon button

/// Tiny borderless icon button that highlights its own background when hovered —
/// used for the session card's ⋮ and × controls so hovering each gives feedback.
@MainActor
final class HoverIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateBackground() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        isBordered = false
        bezelStyle = .smallSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func updateBackground() {
        let c = HarnessDesign.chrome
        layer?.backgroundColor = (isHovered ? c.iconHoverFill : .clear).cgColor
    }
}

