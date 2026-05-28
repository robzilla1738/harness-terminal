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
        indicator.present(near: NSApp.keyWindow, prefix: prefix.displayString)
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

    /// Human-readable glyph form, e.g. `⌃A`, for the prefix indicator.
    var displayString: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key.uppercased()
    }
}

@MainActor
final class PrefixIndicatorWindow {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "⌃A")

    func present(near keyWindow: NSWindow?, prefix: String) {
        let panel = window ?? makePanel()
        window = panel
        label.stringValue = prefix
        guard let parent = keyWindow else {
            panel.orderOut(nil)
            return
        }
        let frame = parent.frame
        let size = NSSize(width: 76, height: 30)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 28,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFront(nil)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.entrance) { _ in
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let window else { return }
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.exit) { _ in
            window.animator().alphaValue = 0
        } completion: {
            window.orderOut(nil)
        }
    }

    private func makePanel() -> NSWindow {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 76, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let host = HarnessOverlayBackground()
        host.frame = panel.contentLayoutRect

        label.font = HarnessDesign.Typography.kbd
        label.textColor = HarnessChrome.current.accent
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.contentView.centerYAnchor),
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
            dismiss()
            return
        }
        if window == nil { window = build() }
        guard let window else { return }
        window.center()
        window.alphaValue = 0
        window.orderFront(nil)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.entrance) { _ in
            window.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let window else { return }
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.exit) { _ in
            window.animator().alphaValue = 0
        } completion: {
            window.orderOut(nil)
        }
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
        let rowHeight: CGFloat = 24
        let width: CGFloat = 320
        let height = CGFloat(entries.count) * rowHeight + 56

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isRestorable = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let overlay = HarnessOverlayBackground()
        overlay.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let header = NSTextField(labelWithString: "PREFIX")
        header.font = HarnessDesign.Typography.sectionLabel
        header.textColor = HarnessChrome.current.textTertiary
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (key, action) in entries {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: action)
            label.font = .systemFont(ofSize: 12)
            label.textColor = HarnessChrome.current.textSecondary
            label.translatesAutoresizingMaskIntoConstraints = false
            let kbd = NSTextField(labelWithString: key)
            kbd.font = HarnessDesign.Typography.kbd
            kbd.textColor = HarnessChrome.current.accent
            kbd.alignment = .right
            kbd.translatesAutoresizingMaskIntoConstraints = false
            kbd.setContentHuggingPriority(.required, for: .horizontal)
            row.addSubview(label)
            row.addSubview(kbd)
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: rowHeight),
                row.widthAnchor.constraint(equalTo: stack.widthAnchor),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                kbd.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                kbd.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                kbd.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                label.trailingAnchor.constraint(lessThanOrEqualTo: kbd.leadingAnchor, constant: -HarnessDesign.Spacing.lg),
            ])
        }

        let content = overlay.contentView
        content.addSubview(header)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: HarnessDesign.Spacing.lg),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HarnessDesign.Spacing.sm),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -HarnessDesign.Spacing.lg),
        ])

        panel.contentView = overlay
        return panel
    }
}
