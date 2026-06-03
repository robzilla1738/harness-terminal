import AppKit
import HarnessCore

/// Left session rail — workspace pill, sessions list, and a quiet footer.
@MainActor
final class HarnessSidebarPanelViewController: NSViewController {
    private let chromeHeader = NSView()
    private let workspaceBar = NSView()
    private let workspacePill = WorkspacePillButton()
    private let notificationBell = NotificationBellButton()
    /// Collapses the sidebar (⌘\). Lives at the sidebar's top-trailing edge, against
    /// the divider; when the sidebar is collapsed it's gone with it (re-open via ⌘\).
    /// Flat `.plain` style + 30×30 so it matches the neighbouring notification bell.
    private let sidebarToggleButton = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    /// Plain editable field (not `NSSearchField`): a borderless `NSSearchField` collapses
    /// its built-in search-button cell when it becomes first responder, which shifts the
    /// text/insertion-point left over the placeholder and drops the magnifier — the
    /// "messes up on click" glitch. A bare `NSTextField` + a static magnifier image view
    /// has no such cell to collapse, so focus is rock-steady.
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    /// Wraps the search field so it gets the same radius-7 elevated-surface chrome as
    /// the workspace pill and session cards.
    private let searchContainer = NSView()
    private let sectionHeader = NSView()
    private let sectionLabel = NSTextField(labelWithString: "Sessions")
    private let sessionTable = NSTableView()
    private let footer = NSView()
    /// Opens the Agent Inbox popover (every running agent, waiting first). Stored so
    /// the popover can anchor to it. Created in `setupFooter`.
    private let agentsButton = HarnessDesign.softIconButton(symbol: "sparkles", tooltip: "Agents")
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

    override func viewDidLayout() {
        super.viewDidLayout()
        syncSessionColumnWidth()
    }

    func applyChromeColors() {
        HarnessDesign.applySidebarChrome(to: view)
        HarnessDesign.makeClear(chromeHeader)
        HarnessDesign.makeClear(workspaceBar)
        HarnessDesign.makeClear(sectionHeader)
        HarnessDesign.makeClear(footer)
        sectionLabel.textColor = HarnessDesign.chrome.textTertiary
        workspacePill.applyChrome()
        sidebarToggleButton.applyChrome()
        dismissWorkspaceDropdown()
        for case let button as SoftIconButton in footer.subviews {
            button.applyChrome()
        }
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

    /// The sidebar header row: the search field with the notification bell + sidebar toggle
    /// to its right. Workspaces are deliberately not surfaced here (single active workspace);
    /// the switcher machinery stays dormant so it can be re-enabled later. The search field
    /// itself is added in `setupSearchField` (it slots into the leading space of this row).
    private func setupWorkspaceBar() {
        workspaceBar.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(workspaceBar)

        notificationBell.translatesAutoresizingMaskIntoConstraints = false
        notificationBell.target = self
        notificationBell.action = #selector(notificationBellClicked)

        sidebarToggleButton.setSymbol("sidebar.left", accessibilityDescription: "Toggle sidebar", pointSize: 13, weight: .medium)
        sidebarToggleButton.toolTip = "Hide sidebar (⌘\\)"
        sidebarToggleButton.target = self
        sidebarToggleButton.action = #selector(sidebarToggleClicked)
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false

        workspaceBar.addSubview(notificationBell)
        workspaceBar.addSubview(sidebarToggleButton)
        view.addSubview(workspaceBar)

        NSLayoutConstraint.activate([
            workspaceBar.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor),
            workspaceBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            workspaceBar.heightAnchor.constraint(equalToConstant: HarnessDesign.workspaceBarHeight),
            // Toggle pinned to the trailing edge (against the divider); 30×30 like the bell.
            sidebarToggleButton.trailingAnchor.constraint(equalTo: workspaceBar.trailingAnchor, constant: -HarnessDesign.horizontalInset),
            sidebarToggleButton.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: 30),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: 30),
            notificationBell.trailingAnchor.constraint(equalTo: sidebarToggleButton.leadingAnchor, constant: -6),
            notificationBell.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            notificationBell.widthAnchor.constraint(equalToConstant: 30),
            notificationBell.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @objc private func sidebarToggleClicked() {
        (view.window?.contentViewController as? MainSplitViewController)?.toggleSidebar()
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
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        dropdown.layer?.zPosition = 100

        // Float the panel over the window's content view rather than inside the narrow
        // sidebar: anchored to the sidebar it was clipped at the divider (cut off) and its
        // body text was squeezed into ~190pt. Hosted on the content view it can use a
        // comfortable fixed width and overhang the terminal, fully visible. Frame-positioned
        // just below the bell; it dismisses on any outside click so it needn't track resizes.
        let host = view.window?.contentView ?? view
        let width: CGFloat = 300
        let height = dropdown.preferredHeight
        let bell = host.convert(notificationBell.bounds, from: notificationBell)
        var originX = bell.minX
        originX = min(originX, host.bounds.maxX - width - 8)
        originX = max(8, originX)
        // The content view is not flipped (y grows upward), so the panel sits below the bell
        // when its top edge is the bell's bottom edge.
        let originY = bell.minY - 6 - height
        dropdown.frame = NSRect(x: originX, y: originY, width: width, height: height)
        host.addSubview(dropdown)
        notificationsDropdown = dropdown
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

    @objc private func agentsButtonClicked() {
        showAgentsInbox()
    }

    private var agentsInbox: AgentInboxPanelView?
    private var agentsInboxMonitor: Any?

    /// Float the Agent Inbox over the window's content view, anchored just above the
    /// footer's agents button. Mirrors `showNotificationsDropdown`'s presentation so the
    /// two panels feel identical; dismisses on any outside click.
    private func showAgentsInbox() {
        if agentsInbox != nil {
            dismissAgentsInbox()
            return
        }
        let coordinator = SessionCoordinator.shared
        let inbox = AgentInboxPanelView(
            agents: coordinator.agentsList(),
            onSelect: { [weak self] agent in
                self?.dismissAgentsInbox()
                coordinator.openAgent(agent)
            }
        )
        inbox.alphaValue = 0
        inbox.translatesAutoresizingMaskIntoConstraints = true
        inbox.layer?.zPosition = 100

        let host = view.window?.contentView ?? view
        let width: CGFloat = 300
        let height = inbox.preferredHeight
        let button = host.convert(agentsButton.bounds, from: agentsButton)
        var originX = button.minX
        originX = min(originX, host.bounds.maxX - width - 8)
        originX = max(8, originX)
        // Footer sits at the bottom; the content view is not flipped (y grows upward), so
        // the panel sits *above* the button when its bottom edge is just above the button.
        let originY = button.maxY + 6
        inbox.frame = NSRect(x: originX, y: originY, width: width, height: height)
        host.addSubview(inbox)
        agentsInbox = inbox
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            inbox.animator().alphaValue = 1
        }
        installAgentsInboxMonitor()
    }

    private func dismissAgentsInbox() {
        agentsInbox?.removeFromSuperview()
        agentsInbox = nil
        if let monitor = agentsInboxMonitor {
            NSEvent.removeMonitor(monitor)
            agentsInboxMonitor = nil
        }
    }

    private func installAgentsInboxMonitor() {
        agentsInboxMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let inbox = self.agentsInbox else { return event }
            let point = inbox.convert(event.locationInWindow, from: nil)
            if !inbox.bounds.contains(point) {
                let buttonPoint = self.agentsButton.convert(event.locationInWindow, from: nil)
                if !self.agentsButton.bounds.contains(buttonPoint) {
                    self.dismissAgentsInbox()
                }
            }
            return event
        }
    }

    private func setupSectionHeader() {
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(sectionHeader)

        sectionLabel.font = HarnessDesign.Typography.sectionLabel
        sectionLabel.stringValue = "SESSIONS"
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        sectionHeader.addSubview(sectionLabel)
        view.addSubview(sectionHeader)

        NSLayoutConstraint.activate([
            sectionHeader.topAnchor.constraint(equalTo: workspaceBar.bottomAnchor),
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

        // Static magnifier accessory; the container owns the rounded-rect chrome so the
        // icon + text sit on our standardized surface (matching the pill).
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil
        )
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.contentTintColor = HarnessChrome.current.textSecondary

        // Borderless/clear single-line editable field; live filtering via the delegate
        // (`controlTextDidChange`), not a target/action (which only fires on Enter).
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.usesSingleLineMode = true
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.font = HarnessDesign.Typography.sidebarLabel
        searchField.focusRingType = .none
        searchField.delegate = self

        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)
        // The search field lives in the header row, expanding from the leading edge up to the
        // notification bell + sidebar toggle on the right.
        workspaceBar.addSubview(searchContainer)
        NSLayoutConstraint.activate([
            searchContainer.leadingAnchor.constraint(equalTo: workspaceBar.leadingAnchor, constant: HarnessDesign.horizontalInset),
            searchContainer.trailingAnchor.constraint(equalTo: notificationBell.leadingAnchor, constant: -8),
            searchContainer.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 30),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
        ])
    }

    private func applySearchChrome() {
        let c = HarnessChrome.current
        searchContainer.layer?.backgroundColor = c.surfaceElevated.cgColor
        // Defined card rim to match the workspace pill + session cards (one component family).
        searchContainer.layer?.borderColor = c.borderStrong.cgColor
        // Typed text + placeholder share the standardized label font, and the
        // placeholder uses the same resting color as the workspace name so the two
        // header rows read as identical type.
        searchField.textColor = c.textPrimary
        searchIcon.contentTintColor = c.textSecondary
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search sessions…",
            attributes: [
                .foregroundColor: c.textSecondary,
                .font: HarnessDesign.Typography.sidebarLabel,
            ]
        )
    }

    private func searchChanged() {
        sessionFilter = searchField.stringValue
        sessionTable.reloadData()
    }

    private func setupSessionList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = HarnessDesign.sidebarWidth
        column.resizingMask = .autoresizingMask
        sessionTable.addTableColumn(column)
        sessionTable.headerView = nil
        sessionTable.backgroundColor = .clear
        sessionTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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

    private func syncSessionColumnWidth() {
        guard let column = sessionTable.tableColumns.first else { return }
        let width = sessionScroll?.contentView.bounds.width ?? view.bounds.width
        let clamped = max(1, width)
        guard abs(column.width - clamped) > 0.5 else { return }
        column.width = clamped
    }

    /// One footer row: "⚙ Settings" (text + icon) on the left, a trimmed set of quick
    /// icons on the right — all on the same baseline. The redundant settings slider and
    /// the help icon were removed (Settings is now the labeled button).
    private func setupFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(footer)

        // Settings is now just a gear icon button, identical in style to the +/⌘ buttons.
        let settings = HarnessDesign.softIconButton(symbol: "gearshape", tooltip: "Settings (⌘,)")
        settings.target = self
        settings.action = #selector(openSettings)

        let newSession = HarnessDesign.softIconButton(symbol: "plus", tooltip: "New session")
        newSession.target = self
        newSession.action = #selector(addSession)

        // No "new workspace" control: the app runs a single workspace for now, and without a
        // switcher a second workspace would strand the user with no way back.
        let palette = HarnessDesign.softIconButton(symbol: "command", tooltip: "Command palette (⌘K)")
        palette.target = self
        palette.action = #selector(openPalette)

        agentsButton.target = self
        agentsButton.action = #selector(agentsButtonClicked)

        footer.addSubview(settings)
        footer.addSubview(agentsButton)
        footer.addSubview(newSession)
        footer.addSubview(palette)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: HarnessDesign.footerHeight + 6),

            // Settings on the leading edge; the agents/new-session/palette actions on the trailing.
            settings.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HarnessDesign.horizontalInset),
            settings.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            palette.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            palette.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newSession.trailingAnchor.constraint(equalTo: palette.leadingAnchor, constant: -2),
            newSession.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            agentsButton.trailingAnchor.constraint(equalTo: newSession.leadingAnchor, constant: -2),
            agentsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
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
        SettingsWindowController.show()
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

    /// Per-session actions shown on right-click of a session card (Warp-style).
    /// Items map to existing capabilities — rename via the `renameSession` IPC,
    /// close via `closeSession`, and clipboard copies handled locally. Returned for
    /// AppKit to position at the cursor (no manual `popUp`).
    private func sessionActionsMenu(for session: SessionGroup) -> NSMenu {
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

        // Pin a session to survive a clean quit even in Plain mode (and the reverse). When
        // keep-on-quit is globally on this is moot — everything survives — so only offer it
        // when the global switch is off, otherwise the checkmark would lie.
        if !SessionCoordinator.shared.snapshot.keepSessionsOnQuit {
            let pin = NSMenuItem(title: "Keep running after quit", action: #selector(toggleSessionPersistent(_:)), keyEquivalent: "")
            pin.target = self
            pin.representedObject = session.id
            pin.state = session.persistent ? .on : .off
            menu.addItem(pin)
            menu.addItem(.separator())
        }

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

        return menu
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

    @objc private func toggleSessionPersistent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        SessionCoordinator.shared.requestDaemon(.setSessionPersistent(sessionID: id, persistent: !session.persistent))
        SessionCoordinator.shared.syncFromDaemon()
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

extension HarnessSidebarPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        searchChanged()
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
        cell.onContextMenu = { [weak self] in
            self?.sessionActionsMenu(for: session)
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
        titleLabel.font = HarnessDesign.Typography.sidebarLabel
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

        nameLabel.font = HarnessDesign.Typography.sidebarLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // All header glyphs share one weight (.medium) so the icon set reads as a
        // single uniform pack rather than a mix of semibold/medium symbols.
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        // Ellipsis: quick actions (rename, delete) without opening the workspace
        // dropdown first. Its own NSButton so the click is captured here instead
        // of falling through to the pill's primary action.
        let moreConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
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
        // Defined card rim (matches the session-card "side tab" look) rather than the
        // near-invisible hairline; brightens further on hover.
        layer?.borderColor = (isHovered ? c.focusRing.withAlphaComponent(c.isDark ? 0.45 : 0.50) : c.borderStrong).cgColor
        let resting = c.surfaceElevated
        let hover = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.12)
        layer?.backgroundColor = (isHovered ? hover : resting).cgColor
        // Resting color matches the search placeholder (textSecondary); brightens to
        // primary on hover — same resting/active rule used by every other label.
        nameLabel.textColor = isHovered ? c.textPrimary : c.textSecondary
        icon.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
        chevron.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
        moreButton.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
    }
}

// MARK: - Session card

@MainActor
final class SessionCardRowView: NSView {
    /// Builds the right-click actions menu for this row (rename, close, …). Shown
    /// via `menu(for:)` — the row no longer carries inline ⋮ / × buttons.
    var onContextMenu: (() -> NSMenu?)?

    private let fill = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let agentChip = AgentChipView()
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

        titleLabel.font = HarnessDesign.Typography.sidebarLabel
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // The agent chip now carries the full tool name; let the title truncate to
        // make room rather than squeezing the chip.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.usesSingleLineMode = true
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        agentChip.translatesAutoresizingMaskIntoConstraints = false
        agentChip.isHidden = true

        addSubview(fill)
        fill.addSubview(titleLabel)
        fill.addSubview(metaLabel)
        fill.addSubview(agentChip)

        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),

            titleLabel.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: fill.topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: agentChip.leadingAnchor, constant: -6),

            // No inline controls anymore — the agent chip sits flush to the card's
            // trailing edge (actions moved to the right-click menu).
            agentChip.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            agentChip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            agentChip.heightAnchor.constraint(equalToConstant: 18),
            agentChip.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            // Meta sits on its own line below the title/controls, so it gets the full
            // card width — the cwd path was being clipped early against the close button.
            metaLabel.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: fill.bottomAnchor, constant: -6),
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
            agentChip.configure(kind: kind, hex: SessionCoordinator.shared.settings.agentColorHex(for: kind))
            agentChip.isHidden = false
        } else {
            agentChip.isHidden = true
        }

        setSelected(isSelected)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?()
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

