import AppKit
import HarnessCore

/// GUI surfaces for the Phase 6/7 verbs that aren't pure IPC: `confirm-before`,
/// `display-menu`, `choose-*`, `lock-client`/`clock-mode`, and `display-popup`.
/// Each is a real, self-contained AppKit affordance (no stubs) anchored to the
/// key window.
@MainActor
enum Phase67UI {
    // MARK: confirm-before

    static func confirmBefore(prompt: String?, perform: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt ?? "Are you sure?"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { perform() }
    }

    // MARK: display-menu

    /// A small action target so `NSMenuItem`s can carry a `Command`.
    @MainActor
    private final class MenuActionTarget: NSObject {
        let command: Command
        init(_ command: Command) { self.command = command }
        @objc func fire() { try? MainExecutor.shared.execute(command) }
    }
    private static var menuTargets: [MenuActionTarget] = []

    static func presentMenu(items: [Command.MenuItem]) {
        let menu = NSMenu()
        menuTargets.removeAll()
        for entry in items {
            let target = MenuActionTarget(entry.command)
            menuTargets.append(target)
            let item = NSMenuItem(title: entry.title, action: #selector(MenuActionTarget.fire), keyEquivalent: entry.key ?? "")
            item.target = target
            menu.addItem(item)
        }
        popUp(menu)
    }

    static func presentChoose(scope: Command.ChooseScope, coordinator: SessionCoordinator) {
        let menu = NSMenu()
        menuTargets.removeAll()
        let snapshot = coordinator.snapshot
        switch scope {
        case .session, .tree, .client:
            for workspace in snapshot.workspaces {
                for session in workspace.sessions {
                    add(to: menu, title: "\(workspace.name) · \(session.name)",
                        command: .sequence([])) { coordinator.selectSession(workspaceID: workspace.id, sessionID: session.id) }
                }
            }
        case .window:
            if let workspace = snapshot.activeWorkspace, let session = workspace.activeSession {
                for tab in session.tabs {
                    add(to: menu, title: tab.title.isEmpty ? "(shell)" : tab.title,
                        command: .sequence([])) { coordinator.selectTab(workspaceID: workspace.id, tabID: tab.id) }
                }
            }
        case .buffer:
            if case let .buffers(buffers)? = coordinator.requestDaemon(.listBuffers) {
                for buffer in buffers {
                    add(to: menu, title: "\(buffer.name): \(buffer.preview)", command: .sequence([])) {
                        if let sid = coordinator.activeSurfaceID {
                            coordinator.requestDaemon(.pasteBuffer(surfaceID: sid.uuidString, name: buffer.name))
                        }
                    }
                }
            }
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "(nothing to choose)", action: nil, keyEquivalent: "")) }
        popUp(menu)
    }

    /// A closure-backed menu entry (the `Command` payload is unused here; the
    /// action closure does the work directly against the coordinator).
    @MainActor
    private final class ClosureTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
    private static var closureTargets: [ClosureTarget] = []

    private static func add(to menu: NSMenu, title: String, command: Command, action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        closureTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
    }

    private static func popUp(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let location = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    // MARK: lock-client / clock-mode

    private static var lockOverlay: OverlayWindow?
    private static var clockOverlay: OverlayWindow?

    static func lock() {
        guard lockOverlay == nil, let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let overlay = OverlayWindow(screen: screen, message: "Locked — press Enter to unlock", showsClock: false) {
            lockOverlay?.orderOut(nil); lockOverlay = nil
        }
        lockOverlay = overlay
        overlay.makeKeyAndOrderFront(nil)
    }

    static func toggleClock() {
        if let existing = clockOverlay { existing.orderOut(nil); clockOverlay = nil; return }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let overlay = OverlayWindow(screen: screen, message: nil, showsClock: true) {
            clockOverlay?.orderOut(nil); clockOverlay = nil
        }
        clockOverlay = overlay
        overlay.makeKeyAndOrderFront(nil)
    }

    // MARK: display-popup

    private static var popups: [PopupWindow] = []

    static func presentPopup(command: String?, coordinator: SessionCoordinator) {
        guard case let .surfaceID(surfaceID)? = coordinator.requestDaemon(.createSurface(cwd: coordinator.settings.defaultCWD, shell: nil)),
              let uuid = SurfaceID(uuidString: surfaceID)
        else { return }
        let host = coordinator.terminalHost(for: uuid, cwd: coordinator.settings.defaultCWD)
        let popup = PopupWindow(host: host, surfaceID: surfaceID) {
            _ = coordinator.requestDaemon(.closeSurface(surfaceID: surfaceID))
            popups.removeAll { $0.surfaceID == surfaceID }
        }
        popups.append(popup)
        popup.makeKeyAndOrderFront(nil)
        if let command, !command.isEmpty {
            _ = coordinator.requestDaemon(.send(surfaceID: surfaceID, text: command + "\n"))
        }
    }
}

// MARK: - Overlay window (lock / clock)

/// A borderless full-screen overlay that captures key input. Used by both
/// `lock-client` (press Enter to dismiss) and `clock-mode` (a live clock,
/// dismissed by any key).
@MainActor
private final class OverlayWindow: NSWindow {
    private let onDismiss: () -> Void
    private let showsClock: Bool
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    init(screen: NSScreen, message: String?, showsClock: Bool, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        self.showsClock = showsClock
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        level = .modalPanel
        let content = NSView(frame: screen.frame)
        content.wantsLayer = true
        label.font = .monospacedSystemFont(ofSize: showsClock ? 96 : 28, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = message ?? OverlayWindow.timeString()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        contentView = content
        if showsClock {
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.label.stringValue = OverlayWindow.timeString() }
            }
            self.timer = timer
        }
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // clock-mode: any key dismisses. lock: only Enter dismisses.
        if showsClock || event.keyCode == 36 /* Return */ {
            timer?.invalidate(); timer = nil
            onDismiss()
        }
    }

    private static func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Popup terminal window

@MainActor
private final class PopupWindow: NSPanel {
    let surfaceID: String
    private let onClose: () -> Void

    init(host: NSView, surfaceID: String, onClose: @escaping () -> Void) {
        self.surfaceID = surfaceID
        self.onClose = onClose
        let size = NSSize(width: 720, height: 420)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Popup"
        isFloatingPanel = true
        level = .floating
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        center()
        delegateProxy = WindowCloseProxy { [weak self] in self?.onClose() }
        delegate = delegateProxy
    }

    private var delegateProxy: WindowCloseProxy?
}

@MainActor
private final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
