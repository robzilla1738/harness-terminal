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
    /// Whoever is recording a chord right now (the recorder panel, a Settings key recorder);
    /// shortcuts are off while any is, so the key being recorded isn't run.
    private var pausedBy: Set<ObjectIdentifier> = []

    func setPaused(_ paused: Bool, by owner: AnyObject) {
        if paused { pausedBy.insert(ObjectIdentifier(owner)) } else { pausedBy.remove(ObjectIdentifier(owner)) }
    }

    /// Re-read settings and install or remove the monitor to match. Call after settings change.
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
        SessionCoordinator.shared.saveSettings()
        reload()
    }

    /// What else answers `shortcut` already: another palette action, the prefix key, a
    /// no-prefix (`bind -n`) binding, or a menu item.
    func conflict(for shortcut: ParsedShortcut, excluding actionID: String) -> String? {
        if let other = bindings.first(where: { $0.shortcut == shortcut && $0.actionID != actionID }) {
            return CommandPaletteController.title(ofAction: other.actionID).map { "the palette action “\($0)”" }
        }
        if let prefix = SessionCoordinator.shared.settings.effectivePrefixKey, ParsedShortcut.parse(prefix) == shortcut {
            return "the prefix key"
        }
        if let root = KeybindingsService.shared.bindings(in: .root).first(where: { Self.rootSpec($0.spec, matches: shortcut) }) {
            return "the no-prefix binding “\(root.note ?? root.command.shortDescription)”"
        }
        return menuItem(matching: shortcut, in: NSApp.mainMenu).map { "the menu item “\($0)”" }
    }

    /// Root-table specs are built from the typed character, so Shift lives in the key (`C`,
    /// `+`) rather than in the modifiers; compare on that footing.
    private static func rootSpec(_ spec: KeySpec, matches shortcut: ParsedShortcut) -> Bool {
        guard let key = ShortcutRecorderSerializer.canonicalKey(spec.key) else { return false }
        var root = ParsedShortcut(spec: KeySpec(key: key, modifiers: spec.modifiers))
        var chord = shortcut
        if spec.key.count == 1, !ShortcutRecorderSerializer.isNamedKey(key) {
            if spec.key != key { root.modifiers.insert(.shift) } // an uppercase letter
            else if key.lowercased() == key.uppercased() { chord.modifiers.remove(.shift) } // a symbol
        }
        return root == chord
    }

    private func menuItem(matching shortcut: ParsedShortcut, in menu: NSMenu?) -> String? {
        for item in menu?.items ?? [] {
            if !item.keyEquivalent.isEmpty {
                // An uppercase key equivalent means Shift.
                var modifiers = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
                if ShortcutRecorderSerializer.keyName(forCharacters: item.keyEquivalent.lowercased()) == shortcut.key,
                   modifiers == shortcut.modifiers { return item.title }
            }
            if let title = menuItem(matching: shortcut, in: item.submenu) { return title }
        }
        return nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard pausedBy.isEmpty, let match = bindings.first(where: { $0.shortcut.matches(event) }) else { return event }
        CommandPaletteController.run(actionID: match.actionID)
        return nil
    }
}

/// "Press the new shortcut for …": records one chord for a palette action. Escape cancels;
/// Remove clears it. Warns before taking a chord something else uses.
@MainActor
final class ShortcutRecorderPanel: NSObject, NSWindowDelegate {
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
        panel.delegate = self
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
        PaletteShortcuts.shared.setPaused(true, by: self)
        PrefixKeymap.shared.setShortcutRecordingActive(true)
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
              let raw = ShortcutRecorderSerializer.serialize(keyCode: event.keyCode, raw: event.charactersIgnoringModifiers, modifiers: modifiers),
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

    /// Clicking back into another window abandons the recording rather than leaving every
    /// palette shortcut off behind a panel that's now out of sight.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func close() {
        panel.delegate = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        PaletteShortcuts.shared.setPaused(false, by: self)
        PrefixKeymap.shared.setShortcutRecordingActive(false)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}
