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
        main.addItem(edit)

        let workspace = NSMenuItem()
        workspace.submenu = NSMenu(title: "Workspace")
        let newWorkspaceItem = NSMenuItem(title: "New Workspace", action: #selector(MenuTarget.newWorkspace), keyEquivalent: "N")
        newWorkspaceItem.keyEquivalentModifierMask = [.command, .shift]
        newWorkspaceItem.target = MenuTarget.shared
        workspace.submenu?.addItem(newWorkspaceItem)
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(MenuTarget.newTab), keyEquivalent: "t")
        newTabItem.target = MenuTarget.shared
        workspace.submenu?.addItem(newTabItem)
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(MenuTarget.closeTab), keyEquivalent: "w")
        closeTab.target = MenuTarget.shared
        workspace.submenu?.addItem(closeTab)
        let closeWS = NSMenuItem(title: "Close Workspace", action: #selector(MenuTarget.closeWorkspace), keyEquivalent: "W")
        closeWS.keyEquivalentModifierMask = [.command, .shift]
        closeWS.target = MenuTarget.shared
        workspace.submenu?.addItem(closeWS)
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
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(MenuTarget.toggleSidebar), keyEquivalent: "\\")
        sidebarItem.keyEquivalentModifierMask = [.command]
        sidebarItem.target = MenuTarget.shared
        view.submenu?.addItem(sidebarItem)
        let zoomIn = NSMenuItem(title: "Increase Font Size", action: #selector(MenuTarget.zoomIn), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        zoomIn.target = MenuTarget.shared
        view.submenu?.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Decrease Font Size", action: #selector(MenuTarget.zoomOut), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        zoomOut.target = MenuTarget.shared
        view.submenu?.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Reset Font Size", action: #selector(MenuTarget.zoomReset), keyEquivalent: "0")
        zoomReset.keyEquivalentModifierMask = [.command]
        zoomReset.target = MenuTarget.shared
        view.submenu?.addItem(zoomReset)
        main.addItem(view)

        // Window — standard macOS window management. Registered as windowsMenu so
        // AppKit auto-populates the open-windows list and the standard actions work.
        let window = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        window.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
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
final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    @objc func newWorkspace() {
        SessionCoordinator.shared.addWorkspace(
            name: "Workspace \(SessionCoordinator.shared.snapshot.workspaces.count + 1)"
        )
    }

    @objc func newTab() {
        guard let id = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.addTab(to: id)
    }

    @objc func closeTab() {
        SessionCoordinator.shared.closeActiveTabWithConfirmation()
    }

    @objc func closeWorkspace() {
        SessionCoordinator.shared.closeActiveWorkspace()
    }

    /// ⌘1–9 switch to the tab at that position in the active session (Ghostty-style).
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

    @objc func jumpNotification() {
        SessionCoordinator.shared.jumpToLatestNotification()
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

    @objc func installCLI() {
        CLIInstaller.install()
    }

    @objc func showAbout() {
        AboutPanelController.show()
    }
}
