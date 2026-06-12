import AppKit
import HarnessCore

@MainActor
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Harness")
        let aboutItem = NSMenuItem(title: "About Harness", action: #selector(MenuTarget.showAbout), keyEquivalent: "")
        aboutItem.target = MenuTarget.shared
        app.submenu?.addItem(aboutItem)
        app.submenu?.addItem(.separator())
        let checkUpdates = NSMenuItem(title: "Check for Updates…", action: SparkleUpdater.checkForUpdatesAction, keyEquivalent: "")
        checkUpdates.target = SparkleUpdater.shared.controller
        app.submenu?.addItem(checkUpdates)
        app.submenu?.addItem(.separator())
        let installItem = NSMenuItem(title: "Install harness-cli…", action: #selector(MenuTarget.installCLI), keyEquivalent: "")
        installItem.target = MenuTarget.shared
        app.submenu?.addItem(installItem)
        app.submenu?.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(MenuTarget.openSettings), keyEquivalent: ",")
        prefs.target = MenuTarget.shared
        app.submenu?.addItem(prefs)
        app.submenu?.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Harness", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.submenu?.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.submenu?.addItem(hideOthers)
        app.submenu?.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(NSMenuItem(title: "Quit Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(app)

        // Edit — standard responder-chain actions so Copy/Paste/Select All work in
        // the focused terminal (and any text field). Target nil routes through the
        // responder chain to whichever view is first responder.
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.addItem(redo)
        edit.submenu?.addItem(.separator())
        edit.submenu?.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.submenu?.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.submenu?.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.submenu?.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.submenu?.addItem(.separator())
        // Secure Keyboard Entry — process-global lock that stops other apps keylogging passphrases.
        // Checkmark state is driven by `MenuTarget.validateMenuItem`. Placed in Edit, like Terminal.app.
        let secureInput = NSMenuItem(title: "Secure Keyboard Entry", action: #selector(MenuTarget.toggleSecureKeyboardEntry), keyEquivalent: "")
        secureInput.target = MenuTarget.shared
        edit.submenu?.addItem(secureInput)
        main.addItem(edit)

        let workspace = NSMenuItem()
        workspace.submenu = NSMenu(title: "Session")
        let newSessionItem = NSMenuItem(title: "New Session", action: #selector(MenuTarget.newSession), keyEquivalent: "N")
        newSessionItem.keyEquivalentModifierMask = [.command, .shift]
        newSessionItem.target = MenuTarget.shared
        workspace.submenu?.addItem(newSessionItem)
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(MenuTarget.newTab), keyEquivalent: "t")
        newTabItem.target = MenuTarget.shared
        workspace.submenu?.addItem(newTabItem)
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(MenuTarget.closeTab), keyEquivalent: "w")
        closeTab.target = MenuTarget.shared
        workspace.submenu?.addItem(closeTab)
        let reopenTab = NSMenuItem(title: "Reopen Closed Tab", action: #selector(MenuTarget.reopenClosedTab), keyEquivalent: "T")
        reopenTab.keyEquivalentModifierMask = [.command]
        reopenTab.target = MenuTarget.shared
        workspace.submenu?.addItem(reopenTab)
        let closeSession = NSMenuItem(title: "Close Session", action: #selector(MenuTarget.closeSession), keyEquivalent: "W")
        closeSession.keyEquivalentModifierMask = [.command, .shift]
        closeSession.target = MenuTarget.shared
        workspace.submenu?.addItem(closeSession)
        workspace.submenu?.addItem(.separator())
        for index in 1...9 {
            let item = NSMenuItem(
                title: "Switch to Tab \(index)",
                action: #selector(MenuTarget.selectTabNumber(_:)),
                keyEquivalent: "\(index)"
            )
            item.tag = index
            item.target = MenuTarget.shared
            workspace.submenu?.addItem(item)
        }
        let prevTab = NSMenuItem(title: "Previous Tab", action: #selector(MenuTarget.previousTab), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = MenuTarget.shared
        workspace.submenu?.addItem(prevTab)
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(MenuTarget.nextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = MenuTarget.shared
        workspace.submenu?.addItem(nextTab)
        main.addItem(workspace)

        let view = NSMenuItem()
        view.submenu = NSMenu(title: "View")
        let splitHItem = NSMenuItem(title: "Split Horizontal", action: #selector(MenuTarget.splitH), keyEquivalent: "d")
        splitHItem.target = MenuTarget.shared
        view.submenu?.addItem(splitHItem)
        let splitVItem = NSMenuItem(title: "Split Vertical", action: #selector(MenuTarget.splitV), keyEquivalent: "D")
        splitVItem.keyEquivalentModifierMask = [.command, .shift]
        splitVItem.target = MenuTarget.shared
        view.submenu?.addItem(splitVItem)
        view.submenu?.addItem(.separator())
        let detachItem = NSMenuItem(title: "Detach Pane", action: #selector(MenuTarget.detachPane), keyEquivalent: "")
        detachItem.target = MenuTarget.shared
        view.submenu?.addItem(detachItem)
        let reattachItem = NSMenuItem(title: "Reattach Pane", action: #selector(MenuTarget.reattachPane), keyEquivalent: "")
        reattachItem.target = MenuTarget.shared
        view.submenu?.addItem(reattachItem)
        view.submenu?.addItem(.separator())
        let jumpItem = NSMenuItem(title: "Jump to Notification", action: #selector(MenuTarget.jumpNotification), keyEquivalent: "u")
        jumpItem.keyEquivalentModifierMask = [.command, .shift]
        jumpItem.target = MenuTarget.shared
        view.submenu?.addItem(jumpItem)
        let paletteItem = NSMenuItem(title: "Command Palette", action: #selector(MenuTarget.commandPalette), keyEquivalent: "k")
        paletteItem.target = MenuTarget.shared
        view.submenu?.addItem(paletteItem)
        let promptItem = NSMenuItem(title: "Command Prompt", action: #selector(MenuTarget.commandPrompt), keyEquivalent: ";")
        promptItem.keyEquivalentModifierMask = [.command]
        promptItem.target = MenuTarget.shared
        view.submenu?.addItem(promptItem)
        let findItem = NSMenuItem(title: "Find…", action: #selector(MenuTarget.find), keyEquivalent: "f")
        findItem.keyEquivalentModifierMask = [.command]
        findItem.target = MenuTarget.shared
        view.submenu?.addItem(findItem)
        view.submenu?.addItem(.separator())
        // Prompt navigation (OSC 133 shell-integration marks) — the Terminal.app/iTerm2
        // ⌘↑/⌘↓ convention. App-level key equivalents, so the tmux-default-empty `root`
        // key table stays empty (users can still rebind via `bind-key -T root`).
        let prevPrompt = NSMenuItem(
            title: "Previous Prompt", action: #selector(MenuTarget.previousPrompt),
            keyEquivalent: String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
        )
        prevPrompt.keyEquivalentModifierMask = [.command]
        prevPrompt.target = MenuTarget.shared
        view.submenu?.addItem(prevPrompt)
        let nextPrompt = NSMenuItem(
            title: "Next Prompt", action: #selector(MenuTarget.nextPrompt),
            keyEquivalent: String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
        )
        nextPrompt.keyEquivalentModifierMask = [.command]
        nextPrompt.target = MenuTarget.shared
        view.submenu?.addItem(nextPrompt)
        let selectLastOutput = NSMenuItem(
            title: "Select Last Command Output",
            action: #selector(MenuTarget.selectLastCommandOutput), keyEquivalent: "a"
        )
        selectLastOutput.keyEquivalentModifierMask = [.command, .shift]
        selectLastOutput.target = MenuTarget.shared
        view.submenu?.addItem(selectLastOutput)
        view.submenu?.addItem(.separator())
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(MenuTarget.toggleSidebar), keyEquivalent: "\\")
        sidebarItem.keyEquivalentModifierMask = [.command]
        sidebarItem.target = MenuTarget.shared
        view.submenu?.addItem(sidebarItem)
        let zoomIn = NSMenuItem(title: "Increase Font Size", action: #selector(MenuTarget.zoomIn), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        zoomIn.target = MenuTarget.shared
        view.submenu?.addItem(zoomIn)
        // ⌘= alias so zooming in doesn't require Shift to reach "+". Marked as an
        // alternate of the item above with the same modifier mask, so AppKit keeps
        // its key equivalent live without showing a duplicate menu row.
        let zoomInAlias = NSMenuItem(title: "Increase Font Size", action: #selector(MenuTarget.zoomIn), keyEquivalent: "=")
        zoomInAlias.keyEquivalentModifierMask = [.command]
        zoomInAlias.isAlternate = true
        zoomInAlias.target = MenuTarget.shared
        view.submenu?.addItem(zoomInAlias)
        let zoomOut = NSMenuItem(title: "Decrease Font Size", action: #selector(MenuTarget.zoomOut), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        zoomOut.target = MenuTarget.shared
        view.submenu?.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Reset Font Size", action: #selector(MenuTarget.zoomReset), keyEquivalent: "0")
        zoomReset.keyEquivalentModifierMask = [.command]
        zoomReset.target = MenuTarget.shared
        view.submenu?.addItem(zoomReset)
        main.addItem(view)

        // Remote — connect the GUI to a HarnessDaemon on another machine over an SSH tunnel.
        // The submenu is rebuilt on open (NSMenuDelegate) so it reflects saved hosts + which one
        // is currently connected.
        let remote = NSMenuItem()
        let remoteMenu = NSMenu(title: "Remote")
        remoteMenu.delegate = MenuTarget.shared
        remote.submenu = remoteMenu
        main.addItem(remote)

        // Window — standard macOS window management. Registered as windowsMenu so
        // AppKit auto-populates the open-windows list and the standard actions work.
        let window = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        window.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreen)
        // Non-native ("fast") full screen: fills the screen without the macOS Space animation.
        let fastFullScreen = NSMenuItem(
            title: "Toggle Fast Full Screen",
            action: #selector(MainWindowController.toggleNonNativeFullscreen(_:)),
            keyEquivalent: "f"
        )
        fastFullScreen.keyEquivalentModifierMask = [.command, .control, .shift]
        windowMenu.addItem(fastFullScreen)
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        main.addItem(window)
        NSApp.windowsMenu = windowMenu

        // Help
        let help = NSMenuItem()
        help.submenu = NSMenu(title: "Help")
        let welcome = NSMenuItem(title: "Welcome to Harness", action: #selector(MenuTarget.showOnboarding), keyEquivalent: "")
        welcome.target = MenuTarget.shared
        help.submenu?.addItem(welcome)
        let shortcuts = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(MenuTarget.showShortcuts), keyEquivalent: "/")
        shortcuts.keyEquivalentModifierMask = [.command]
        shortcuts.target = MenuTarget.shared
        help.submenu?.addItem(shortcuts)
        main.addItem(help)

        return main
    }
}

@MainActor
final class MenuTarget: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = MenuTarget()

    /// Enable Detach only when the active pane is attached, Reattach only when it's released.
    /// Every other MenuTarget item stays enabled (default true), preserving prior behavior.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(detachPane): return !SessionCoordinator.shared.activePaneIsDetached
        case #selector(reattachPane): return SessionCoordinator.shared.activePaneIsDetached
        case #selector(reopenClosedTab): return SessionCoordinator.shared.canReopenClosedTab
        case #selector(toggleSecureKeyboardEntry):
            menuItem.state = SessionCoordinator.shared.settings.secureKeyboardEntry ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: - Remote menu (rebuilt on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Remote" else { return }
        menu.removeAllItems()
        let add = NSMenuItem(title: "Add Remote Host…", action: #selector(addRemoteHost), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.addItem(.separator())

        let hosts = RemoteHostsService.shared.hosts()
        let active = RemoteHostsService.shared.activeHostName
        if hosts.isEmpty {
            let none = NSMenuItem(title: "No saved hosts", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for host in hosts {
                let item = NSMenuItem(
                    title: "\(host.name) — \(host.sshTarget)",
                    action: #selector(connectRemoteHost(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.name
                item.state = (host.name == active) ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let local = NSMenuItem(title: "Use Local Daemon", action: #selector(useLocalDaemon), keyEquivalent: "")
        local.target = self
        local.state = (active == nil) ? .on : .off
        menu.addItem(local)
    }

    @objc func addRemoteHost() {
        let alert = NSAlert()
        alert.messageText = "Add Remote Host"
        alert.informativeText = "Run HarnessDaemon on the remote machine (harness-cli install), "
            + "then connect to it over SSH."
        alert.addButton(withTitle: "Save & Connect")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        nameField.placeholderString = "Name (e.g. devbox)"
        let sshField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        sshField.placeholderString = "SSH target (user@host)"
        let sockField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        sockField.placeholderString = "Remote socket path"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(sshField)
        stack.addArrangedSubview(sockField)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssh = sshField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !ssh.isEmpty else { return }
        let socketPath = sockField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if socketPath.isEmpty {
            let warn = NSAlert()
            warn.messageText = "Remote socket path required"
            warn.informativeText = "Use the path shown by `harness-cli doctor` on the remote host."
            warn.runModal()
            return
        }
        RemoteHostsService.shared.addHost(
            RemoteHost(name: name, sshTarget: ssh, remoteSocketPath: socketPath))
        SessionCoordinator.shared.connectToRemote(named: name)
    }

    @objc func connectRemoteHost(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SessionCoordinator.shared.connectToRemote(named: name)
    }

    @objc func useLocalDaemon() {
        SessionCoordinator.shared.disconnectRemote()
    }

    @objc func newSession() {
        guard let id = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.addSession(to: id)
    }

    @objc func closeSession() {
        SessionCoordinator.shared.closeActiveSession()
    }

    @objc func newTab() {
        guard let id = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.addTab(to: id)
    }

    @objc func closeTab() {
        SessionCoordinator.shared.closeActiveTabWithConfirmation()
    }

    @objc func reopenClosedTab() {
        SessionCoordinator.shared.reopenLastClosedTab()
    }

    @objc func find() {
        SessionCoordinator.shared.toggleFindBar()
    }


    /// ⌘1–9 switch to the tab at that position in the active session.
    @objc func selectTabNumber(_ sender: NSMenuItem) {
        SessionCoordinator.shared.selectTab(atIndex: sender.tag - 1)
    }

    @objc func previousTab() {
        SessionCoordinator.shared.selectAdjacentTab(offset: -1)
    }

    @objc func nextTab() {
        SessionCoordinator.shared.selectAdjacentTab(offset: 1)
    }

    @objc func splitH() {
        SessionCoordinator.shared.splitActivePane(direction: .horizontal)
    }

    @objc func splitV() {
        SessionCoordinator.shared.splitActivePane(direction: .vertical)
    }

    @objc func detachPane() {
        SessionCoordinator.shared.detachActiveSurface()
    }

    @objc func reattachPane() {
        SessionCoordinator.shared.reattachActiveSurface()
    }

    @objc func jumpNotification() {
        SessionCoordinator.shared.jumpToLatestNotification()
    }

    @objc func previousPrompt() {
        SessionCoordinator.shared.jumpToPreviousPrompt()
    }

    @objc func nextPrompt() {
        SessionCoordinator.shared.jumpToNextPrompt()
    }

    @objc func selectLastCommandOutput() {
        SessionCoordinator.shared.selectLastCommandOutput()
    }

    @objc func showOnboarding() {
        OnboardingController.present()
    }

    @objc func showShortcuts() {
        PrefixCheatsheetWindow.shared.toggle()
    }

    @objc func commandPalette() {
        if let window = NSApp.keyWindow {
            CommandPaletteController.present(relativeTo: window)
        }
    }

    @objc func commandPrompt() {
        CommandPromptController.shared.present()
    }

    @objc func openSettings() {
        SettingsWindowController.show()
    }

    @objc func toggleSidebar() {
        if let split = NSApp.keyWindow?.contentViewController as? MainSplitViewController {
            split.toggleSidebar()
        }
    }

    @objc func zoomIn() {
        SessionCoordinator.shared.updateFontSize(delta: 1)
    }

    @objc func zoomOut() {
        SessionCoordinator.shared.updateFontSize(delta: -1)
    }

    @objc func zoomReset() {
        SessionCoordinator.shared.resetFontSize()
    }

    @objc func toggleSecureKeyboardEntry() {
        SessionCoordinator.shared.setSecureKeyboardEntry(!SessionCoordinator.shared.settings.secureKeyboardEntry)
    }

    @objc func installCLI() {
        CLIInstaller.install()
    }

    @objc func showAbout() {
        AboutPanelController.show()
    }
}
