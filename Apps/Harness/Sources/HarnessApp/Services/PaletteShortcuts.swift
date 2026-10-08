import AppKit
import HarnessCore

/// Shortcuts you give command-palette actions (right-click an action ▸ Change Shortcut…).
/// Stored in settings as action id → chord, shown in the palette, and run from anywhere in
/// the app by a key monitor that exists only while at least one is set.
@MainActor
final class PaletteShortcuts {
    static let shared = PaletteShortcuts()

    private var monitor: Any?
    private var bindings: [(shortcut: ParsedShortcut, actionID: String)] = []
    /// Off while the recorder panel listens, so the key being recorded isn't run.
    var paused = false

    /// Re-read settings and install or remove the monitor to match.
    func reload() {
        bindings = SessionCoordinator.shared.settings.paletteShortcuts.compactMap { id, raw in
            ParsedShortcut.parse(raw).map { ($0, id) }
        }
        if bindings.isEmpty {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
    }

    func shortcut(for actionID: String) -> ParsedShortcut? {
        bindings.first { $0.actionID == actionID }?.shortcut
    }

    /// Assign (or with nil, remove) the chord for an action. A chord moves off any other action.
    func set(_ raw: String?, for actionID: String) {
        var settings = SessionCoordinator.shared.settings
        if let raw {
            for (id, existing) in settings.paletteShortcuts where existing == raw { settings.paletteShortcuts[id] = nil }
        }
        settings.paletteShortcuts[actionID] = raw
        SessionCoordinator.shared.settings = settings
        try? settings.save()
        reload()
    }

    /// What else answers `shortcut` already: a menu item, or another palette action.
    func conflict(for shortcut: ParsedShortcut, excluding actionID: String) -> String? {
        if let other = bindings.first(where: { $0.shortcut == shortcut && $0.actionID != actionID }) {
            return CommandPaletteController.title(ofAction: other.actionID).map { "the palette action “\($0)”" }
        }
        return menuItem(matching: shortcut, in: NSApp.mainMenu).map { "the menu item “\($0)”" }
    }

    private func menuItem(matching shortcut: ParsedShortcut, in menu: NSMenu?) -> String? {
        for item in menu?.items ?? [] {
            if !item.keyEquivalent.isEmpty {
                // An uppercase key equivalent means Shift.
                var modifiers = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                if item.keyEquivalent.lowercased() == shortcut.key, modifiers == shortcut.modifiers { return item.title }
            }
            if let title = menuItem(matching: shortcut, in: item.submenu) { return title }
        }
        return nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !paused, let match = bindings.first(where: { $0.shortcut.matches(event) }) else { return event }
        CommandPaletteController.run(actionID: match.actionID)
        return nil
    }
}

/// "Press the new shortcut for …": records one chord for a palette action. Escape cancels;
/// Remove clears it. Warns before taking a chord something else uses.
@MainActor
final class ShortcutRecorderPanel: NSObject {
    private static var current: ShortcutRecorderPanel?

    static func present(actionID: String, title: String, over window: NSWindow?) {
        current?.close()
        let panel = ShortcutRecorderPanel(actionID: actionID, title: title)
        current = panel
        panel.show(over: window)
    }

    private let actionID: String
    private let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let chord = NSTextField(labelWithString: "Press a shortcut")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?

    private init(actionID: String, title: String) {
        self.actionID = actionID
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Shortcut for “\(title)”")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        chord.font = .systemFont(ofSize: 22, weight: .medium)
        if let existing = PaletteShortcuts.shared.shortcut(for: actionID) { chord.stringValue = existing.displayString }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.stringValue = "Press the new shortcut. Esc cancels."
        let remove = NSButton(title: "Remove Shortcut", target: self, action: #selector(removeShortcut))
        remove.bezelStyle = .rounded
        remove.isHidden = PaletteShortcuts.shared.shortcut(for: actionID) == nil
        let stack = NSStackView(views: [heading, chord, note, remove])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 16, bottom: 14, right: 16)
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        panel.contentView = stack
    }

    private func show(over window: NSWindow?) {
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        PaletteShortcuts.shared.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event) ?? event
        }
    }

    private var pending: String?

    private func record(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        if event.keyCode == 53 { close(); return nil } // Escape
        if event.keyCode == 36, let pending { // Return confirms a chord that needed a warning
            PaletteShortcuts.shared.set(pending, for: actionID)
            close()
            return nil
        }
        let modifiers = KeyRecorderView.keyModifiers(from: event.modifierFlags)
        guard !modifiers.isDisjoint(with: [.command, .control, .option]),
              let raw = ShortcutRecorderSerializer.serialize(raw: event.charactersIgnoringModifiers, modifiers: modifiers),
              let parsed = ParsedShortcut.parse(raw)
        else {
            note.stringValue = "Use ⌘, ⌃, or ⌥ with a key, so typing isn't caught."
            return nil
        }
        chord.stringValue = parsed.displayString
        if let taken = PaletteShortcuts.shared.conflict(for: parsed, excluding: actionID) {
            pending = raw
            note.stringValue = "\(parsed.displayString) is \(taken). Press Return to use it anyway, or another shortcut."
            return nil
        }
        PaletteShortcuts.shared.set(raw, for: actionID)
        close()
        return nil
    }

    @objc private func removeShortcut() {
        PaletteShortcuts.shared.set(nil, for: actionID)
        close()
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        PaletteShortcuts.shared.paused = false
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}
