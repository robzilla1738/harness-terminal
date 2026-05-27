import AppKit
import HarnessCore

/// tmux-style prefix keymap. Listens globally for the configured prefix
/// (default `Ctrl-A`); after the prefix fires, the next keystroke is consumed
/// and routed through `bindings`. Press `?` while armed to see the cheatsheet.
@MainActor
final class PrefixKeymap {
    static let shared = PrefixKeymap()

    private var monitor: Any?
    private var armed = false
    private var prefix: ParsedShortcut = .controlA
    private var indicator: PrefixIndicatorWindow?

    private init() {}

    func install() {
        rebuildFromSettings()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func rebuildFromSettings() {
        let raw = SessionCoordinator.shared.settings.prefixKey
        prefix = ParsedShortcut.parse(raw) ?? .controlA
    }

    /// Returns nil to swallow the event or the original event to forward it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if armed {
            consume(event: event)
            return nil
        }
        if prefix.matches(event) {
            arm()
            return nil
        }
        return event
    }

    private func arm() {
        armed = true
        showIndicator()
        // Auto-disarm after 2 seconds so users aren't surprised later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.disarm()
        }
    }

    private func disarm() {
        armed = false
        hideIndicator()
    }

    private func consume(event: NSEvent) {
        defer { disarm() }
        guard let chars = event.charactersIgnoringModifiers else { return }
        let key = chars.lowercased()
        let coordinator = SessionCoordinator.shared
        switch key {
        case "c":
            coordinator.openTabInActiveWorkspace()
        case "%":
            coordinator.splitActivePane(direction: .vertical)
        case "\"":
            coordinator.splitActivePane(direction: .horizontal)
        case "x":
            coordinator.killActivePane()
        case "z":
            coordinator.zoomActivePane()
        case "o":
            coordinator.cycleActivePane(forward: true)
        case ";":
            coordinator.cycleActivePane(forward: false)
        case "[":
            coordinator.toggleCopyMode()
        case "d":
            coordinator.detachActiveSurface()
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let idx = Int(key) {
                coordinator.selectWorkspace(byIndex: idx)
            }
        case ",":
            coordinator.beginRenameActiveTab()
        case "?":
            PrefixCheatsheetWindow.shared.toggle()
        case "r":
            coordinator.reimportFromGhostty()
        default:
            NSSound.beep()
        }
    }

    private func showIndicator() {
        let indicator = self.indicator ?? PrefixIndicatorWindow()
        self.indicator = indicator
        indicator.present(near: NSApp.keyWindow)
    }

    private func hideIndicator() {
        indicator?.dismiss()
    }
}

struct ParsedShortcut: Equatable {
    var modifiers: NSEvent.ModifierFlags
    var key: String

    static let controlA = ParsedShortcut(modifiers: .control, key: "a")

    static func parse(_ raw: String) -> ParsedShortcut? {
        let parts = raw.lowercased().split(separator: "-").map(String.init)
        guard let last = parts.last else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for component in parts.dropLast() {
            switch component {
            case "ctrl", "control": modifiers.insert(.control)
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        return ParsedShortcut(modifiers: modifiers, key: last)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // Mask out caps lock + numeric noise — only the four real modifiers count.
        let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return event.modifierFlags.intersection(mask) == modifiers && chars == key
    }
}

@MainActor
final class PrefixIndicatorWindow {
    private var window: NSWindow?

    func present(near keyWindow: NSWindow?) {
        let panel = window ?? makePanel()
        window = panel
        guard let parent = keyWindow else {
            panel.orderOut(nil)
            return
        }
        let frame = parent.frame
        let size = NSSize(width: 90, height: 28)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 24,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        panel.orderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func makePanel() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 90, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let host = NSView(frame: panel.contentLayoutRect)
        host.wantsLayer = true
        host.layer?.cornerRadius = 6
        host.layer?.backgroundColor = HarnessChrome.current.surfaceElevated.withAlphaComponent(0.95).cgColor
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = HarnessChrome.current.borderStrong.cgColor

        let label = NSTextField(labelWithString: "Prefix")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = HarnessChrome.current.accent
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        panel.contentView = host
        return panel
    }
}

@MainActor
final class PrefixCheatsheetWindow {
    static let shared = PrefixCheatsheetWindow()
    private var window: NSWindow?
    private init() {}

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        if window == nil { window = build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let entries: [(String, String)] = [
            ("c", "New tab"),
            ("%", "Split vertically"),
            ("\"", "Split horizontally"),
            ("x", "Kill pane"),
            ("z", "Zoom toggle"),
            ("o", "Next pane"),
            (";", "Previous pane"),
            ("[", "Copy mode"),
            ("d", "Detach"),
            ("0–9", "Select workspace"),
            (",", "Rename tab"),
            ("r", "Re-import Ghostty"),
            ("?", "Toggle this cheatsheet"),
        ]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: CGFloat(entries.count) * 24 + 48),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Prefix Cheatsheet"
        panel.isFloatingPanel = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (key, action) in entries {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            let kbd = NSTextField(labelWithString: key)
            kbd.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            kbd.textColor = HarnessChrome.current.accent
            kbd.setContentHuggingPriority(.required, for: .horizontal)
            kbd.widthAnchor.constraint(equalToConstant: 56).isActive = true
            let label = NSTextField(labelWithString: action)
            label.font = .systemFont(ofSize: 12)
            label.textColor = HarnessChrome.current.textPrimary
            row.addArrangedSubview(kbd)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }

        let content = NSView(frame: panel.contentLayoutRect)
        content.wantsLayer = true
        content.layer?.backgroundColor = HarnessChrome.current.surfaceElevated.cgColor
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panel.contentView = content
        return panel
    }
}
