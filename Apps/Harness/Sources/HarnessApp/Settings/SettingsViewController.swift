import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class SettingsViewController: NSViewController {
    private let themePopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontFamilyField = NSTextField()
    private let shellField = NSTextField()
    private let cwdField = NSTextField()
    private let opacitySlider = NSSlider()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let blurField = NSTextField()
    private let paddingXField = NSTextField()
    private let paddingYField = NSTextField()
    private let backgroundHexField = NSTextField()
    private let foregroundHexField = NSTextField()
    private let cursorHexField = NSTextField()
    private let prefixKeyField = NSTextField()
    private let scrollbackField = NSTextField()
    private let keepSessionsToggle = NSButton(
        checkboxWithTitle: "Keep sessions running when Harness quits",
        target: nil,
        action: nil
    )
    private let transparentTitlebarToggle = NSButton(
        checkboxWithTitle: "Transparent title bar",
        target: nil,
        action: nil
    )

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 590))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let coordinator = SessionCoordinator.shared
        let settings = coordinator.settings

        themePopup.removeAllItems()
        for name in ThemeManager.featuredThemes {
            themePopup.addItem(withTitle: name)
        }
        themePopup.selectItem(withTitle: coordinator.snapshot.themeName)

        fontSizeField.stringValue = String(format: "%.0f", settings.fontSize)
        fontFamilyField.stringValue = settings.fontFamily
        shellField.stringValue = settings.defaultShell
        cwdField.stringValue = settings.defaultCWD

        opacitySlider.minValue = 0.3
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityDidChange)
        opacitySlider.isContinuous = true
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor

        blurField.stringValue = String(settings.backgroundBlur)
        paddingXField.stringValue = String(format: "%.0f", settings.windowPaddingX)
        paddingYField.stringValue = String(format: "%.0f", settings.windowPaddingY)
        backgroundHexField.stringValue = settings.customBackgroundHex ?? ""
        foregroundHexField.stringValue = settings.customForegroundHex ?? ""
        cursorHexField.stringValue = settings.customCursorHex ?? ""
        prefixKeyField.stringValue = settings.prefixKey
        scrollbackField.stringValue = String(settings.scrollbackLines)

        keepSessionsToggle.state = coordinator.keepSessionsOnQuit ? .on : .off
        transparentTitlebarToggle.state = settings.transparentTitlebar ? .on : .off

        let opacityRow = NSStackView(views: [opacitySlider, opacityLabel])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        opacitySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [
            sectionLabel("Appearance"),
            labeledRow("Theme", themePopup),
            labeledRow("Background opacity", opacityRow),
            labeledRow("Background blur", blurField),
            labeledRow("Background color", backgroundHexField),
            labeledRow("Foreground color", foregroundHexField),
            labeledRow("Cursor color", cursorHexField),
            labeledRow("Padding X", paddingXField),
            labeledRow("Padding Y", paddingYField),
            transparentTitlebarToggle,
            spacer(8),
            sectionLabel("Terminal"),
            labeledRow("Font size", fontSizeField),
            labeledRow("Font family", fontFamilyField),
            labeledRow("Default shell", shellField),
            labeledRow("Default directory", cwdField),
            labeledRow("Scrollback lines", scrollbackField),
            keepSessionsToggle,
            spacer(8),
            sectionLabel("Tmux + Agents"),
            labeledRow("Prefix key", prefixKeyField),
            agentsRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
        ])

        let importButton = NSButton(title: "Re-import from Ghostty", target: self, action: #selector(reimportGhostty))
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(importButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            importButton.bottomAnchor.constraint(equalTo: saveButton.bottomAnchor),
            importButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
        ])
    }

    private func labeledRow(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 12
        if field is NSTextField {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        }
        return row
    }

    private func agentsRow() -> NSView {
        let button = NSButton(title: "Edit agents.json…", target: self, action: #selector(openAgentsJSON))
        button.bezelStyle = .rounded
        return labeledRow("Agent table", button)
    }

    private func sectionLabel(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let s = NSView()
        s.heightAnchor.constraint(equalToConstant: height).isActive = true
        return s
    }

    private func formatPercent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    @objc private func opacityDidChange() {
        opacityLabel.stringValue = formatPercent(Float(opacitySlider.doubleValue))
    }

    @objc private func reimportGhostty() {
        guard let imported = GhosttyConfigImporter.load() else {
            let alert = NSAlert()
            alert.messageText = "No Ghostty config found"
            alert.informativeText = "Looked in ~/.config/ghostty/config and ~/Library/Application Support/com.mitchellh.ghostty/config."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        if let value = imported.fontFamily { fontFamilyField.stringValue = value }
        if let value = imported.fontSize { fontSizeField.stringValue = String(format: "%.0f", value) }
        if let value = imported.defaultShell { shellField.stringValue = value }
        if let value = imported.backgroundOpacity {
            opacitySlider.doubleValue = Double(value)
            opacityLabel.stringValue = formatPercent(value)
        }
        if let value = imported.backgroundBlur { blurField.stringValue = String(value) }
        if let value = imported.windowPaddingX { paddingXField.stringValue = String(format: "%.0f", value) }
        if let value = imported.windowPaddingY { paddingYField.stringValue = String(format: "%.0f", value) }
        if let value = imported.backgroundHex { backgroundHexField.stringValue = value }
        if let value = imported.foregroundHex { foregroundHexField.stringValue = value }
        if let value = imported.cursorColorHex { cursorHexField.stringValue = value }
        if let value = imported.themeName {
            themePopup.selectItem(withTitle: value)
        }
        let coordinator = SessionCoordinator.shared
        coordinator.settings = HarnessSettings.makeDefaults(imported: imported)
        try? coordinator.settings.save()
        if let theme = imported.themeName {
            coordinator.setTheme(theme)
        }
        coordinator.applySettingsToHosts()
    }

    @objc private func save() {
        let coordinator = SessionCoordinator.shared
        if let theme = themePopup.titleOfSelectedItem {
            coordinator.setTheme(theme)
        }
        coordinator.settings.fontSize = Float(fontSizeField.stringValue) ?? 14
        coordinator.settings.fontFamily = fontFamilyField.stringValue
        coordinator.settings.defaultShell = shellField.stringValue
        coordinator.settings.defaultCWD = cwdField.stringValue
        coordinator.settings.backgroundOpacity = Float(opacitySlider.doubleValue)
        coordinator.settings.backgroundBlur = Int(blurField.stringValue) ?? 0
        coordinator.settings.windowPaddingX = Float(paddingXField.stringValue) ?? 12
        coordinator.settings.windowPaddingY = Float(paddingYField.stringValue) ?? 12
        coordinator.settings.customBackgroundHex = normalizedHexOrNil(backgroundHexField.stringValue)
        coordinator.settings.customForegroundHex = normalizedHexOrNil(foregroundHexField.stringValue)
        coordinator.settings.customCursorHex = normalizedHexOrNil(cursorHexField.stringValue)
        coordinator.settings.ghosttyConfigSignature = GhosttyConfigImporter.load()?.signature
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        coordinator.settings.prefixKey = prefixKeyField.stringValue.isEmpty ? "ctrl-a" : prefixKeyField.stringValue
        coordinator.settings.scrollbackLines = max(100, Int(scrollbackField.stringValue) ?? 10_000)
        coordinator.setKeepSessionsOnQuit(keepSessionsToggle.state == .on)
        try? coordinator.settings.save()
        coordinator.applySettingsToHosts()
        PrefixKeymap.shared.rebuildFromSettings()
        view.window?.close()
    }

    private func normalizedHexOrNil(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    }

    @objc private func openAgentsJSON() {
        let url = HarnessPaths.applicationSupport.appendingPathComponent("agents.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            // Seed it with the defaults so the user sees a useful starting point.
            let defaults = AgentTable.default
            if let data = try? JSONEncoder().encode(defaults) {
                try? data.write(to: url, options: .atomic)
            }
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = SettingsViewController()
            let win = NSWindow(contentViewController: controller)
            win.title = "Harness Settings"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 560, height: 610))
            window = win
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
