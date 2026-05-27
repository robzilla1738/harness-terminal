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
        app.submenu?.addItem(NSMenuItem(title: "Quit Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(app)

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
                title: "Switch to Workspace \(index)",
                action: #selector(MenuTarget.selectWorkspaceNumber(_:)),
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
        main.addItem(view)

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

    @objc func selectWorkspaceNumber(_ sender: NSMenuItem) {
        let workspaces = SessionCoordinator.shared.snapshot.workspaces
        let index = sender.tag - 1
        guard index >= 0, index < workspaces.count else { return }
        SessionCoordinator.shared.selectWorkspace(workspaces[index].id)
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

    @objc func commandPalette() {
        if let window = NSApp.keyWindow {
            CommandPaletteController.present(relativeTo: window)
        }
    }

    @objc func openSettings() {
        SettingsWindowController.show()
    }

    @objc func toggleSidebar() {
        let sidebarVisible = !SessionCoordinator.shared.settings.sidebarVisible
        if let split = NSApp.keyWindow?.contentViewController as? MainSplitViewController {
            split.setSidebarVisible(sidebarVisible)
        }
    }

    @objc func zoomIn() {
        SessionCoordinator.shared.updateFontSize(delta: 1)
    }

    @objc func zoomOut() {
        SessionCoordinator.shared.updateFontSize(delta: -1)
    }

    @objc func installCLI() {
        CLIInstaller.install()
    }

    @objc func showAbout() {
        AboutPanelController.show()
    }
}
