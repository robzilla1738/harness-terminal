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
    private let backgroundWell = NSColorWell()
    private let foregroundWell = NSColorWell()
    private let cursorWell = NSColorWell()
    private let useThemeColorsButton = NSButton()
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
    private let cursorStylePopup = NSPopUpButton()
    private let cursorBlinkToggle = NSButton(
        checkboxWithTitle: "Blinking cursor",
        target: nil,
        action: nil
    )
    private let copyOnSelectToggle = NSButton(
        checkboxWithTitle: "Copy text to clipboard on selection",
        target: nil,
        action: nil
    )
    // Extra customizable colors (highlight, bold, cursor text).
    private let selectionBgHexField = NSTextField()
    private let selectionFgHexField = NSTextField()
    private let boldHexField = NSTextField()
    private let cursorTextHexField = NSTextField()
    private let selectionBgWell = NSColorWell()
    private let selectionFgWell = NSColorWell()
    private let boldWell = NSColorWell()
    private let cursorTextWell = NSColorWell()
    private let minContrastField = NSTextField()
    private weak var settingsScrollView: NSScrollView?
    private var sectionAnchors: [Int: NSView] = [:]
    // 16 ANSI palette swatches + their working override values (nil = use theme).
    private var paletteWells: [NSColorWell] = []
    private var paletteHexValues: [String?] = Array(repeating: nil, count: 16)
    private var agentColorWells: [AgentKind: NSColorWell] = [:]
    private var agentColorPreviews: [AgentKind: AgentChipView] = [:]
    /// Every hex field is paired with a color well and a settings key path, so one
    /// generic flow drives validation, live preview, and save for all of them.
    private var colorBindings: [ColorBinding] = []

    private struct ColorBinding {
        let field: NSTextField
        let well: NSColorWell
        let keyPath: WritableKeyPath<HarnessSettings, String?>
    }

    /// xterm-style defaults shown in palette swatches until the user overrides a slot.
    private static let defaultAnsiPalette = [
        "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
        "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
    ]
    private static let ansiNames = [
        "0 Black", "1 Red", "2 Green", "3 Yellow", "4 Blue", "5 Magenta", "6 Cyan", "7 White",
        "8 Bright Black", "9 Bright Red", "10 Bright Green", "11 Bright Yellow",
        "12 Bright Blue", "13 Bright Magenta", "14 Bright Cyan", "15 Bright White",
    ]
    private static let agentColorKinds: [AgentKind] = [
        .codex, .claudeCode, .cursor, .pi, .hermes,
        .openClaw, .aider, .gemini, .goose, .generic,
    ]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 680))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let coordinator = SessionCoordinator.shared
        let settings = coordinator.settings

        themePopup.removeAllItems()
        for name in ThemeManager.allThemeNames() {
            themePopup.addItem(withTitle: name)
        }
        themePopup.selectItem(withTitle: coordinator.snapshot.themeName)
        themePopup.target = self
        themePopup.action = #selector(themeDidChange)

        fontSizeField.stringValue = String(format: "%.0f", settings.fontSize)
        fontFamilyField.stringValue = settings.fontFamily
        shellField.stringValue = settings.defaultShell
        cwdField.stringValue = settings.defaultCWD

        opacitySlider.minValue = 0.05
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityDidChange)
        opacitySlider.isContinuous = true
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor

        blurField.stringValue = String(settings.backgroundBlur)
        blurField.target = self
        blurField.action = #selector(appearanceTextDidCommit)
        paddingXField.stringValue = String(format: "%.0f", settings.windowPaddingX)
        paddingYField.stringValue = String(format: "%.0f", settings.windowPaddingY)
        colorBindings = [
            ColorBinding(field: backgroundHexField, well: backgroundWell, keyPath: \.customBackgroundHex),
            ColorBinding(field: foregroundHexField, well: foregroundWell, keyPath: \.customForegroundHex),
            ColorBinding(field: cursorHexField, well: cursorWell, keyPath: \.customCursorHex),
            ColorBinding(field: cursorTextHexField, well: cursorTextWell, keyPath: \.cursorTextHex),
            ColorBinding(field: selectionBgHexField, well: selectionBgWell, keyPath: \.selectionBackgroundHex),
            ColorBinding(field: selectionFgHexField, well: selectionFgWell, keyPath: \.selectionForegroundHex),
            ColorBinding(field: boldHexField, well: boldWell, keyPath: \.boldColorHex),
        ]
        for binding in colorBindings {
            let hex = settings.useCustomColors ? settings[keyPath: binding.keyPath] : nil
            binding.field.stringValue = hex ?? ""
            configureLiveAppearanceField(binding.field)
            configureColorWell(binding.well, hex: hex)
            validateHexField(binding.field)
        }

        minContrastField.stringValue = String(format: "%.1f", settings.minimumContrast)
        minContrastField.target = self
        minContrastField.action = #selector(appearanceTextDidCommit)

        paletteHexValues = settings.useCustomColors
            ? HarnessSettings.normalizedPalette(settings.paletteHex)
            : Array(repeating: nil, count: 16)
        buildPaletteWells()
        buildAgentColorWells(settings: settings)

        prefixKeyField.stringValue = settings.prefixKey
        scrollbackField.stringValue = String(settings.scrollbackLines)

        cursorStylePopup.addItems(withTitles: ["Block", "Beam", "Underline"])
        cursorStylePopup.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off

        keepSessionsToggle.state = coordinator.keepSessionsOnQuit ? .on : .off
        transparentTitlebarToggle.state = settings.transparentTitlebar ? .on : .off
        transparentTitlebarToggle.target = self
        transparentTitlebarToggle.action = #selector(appearanceTextDidCommit)

        useThemeColorsButton.title = "Use Theme Colors"
        useThemeColorsButton.target = self
        useThemeColorsButton.action = #selector(useThemeColors)
        useThemeColorsButton.bezelStyle = .rounded

        let opacityRow = NSStackView(views: [opacitySlider, opacityLabel])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        opacitySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let appearanceSection = sectionLabel("Appearance")
        let paletteSectionLabel = sectionLabel("ANSI Palette")
        let terminalSection = sectionLabel("Terminal")
        let tmuxSection = sectionLabel("Tmux + Agents")
        let agentColorsSection = sectionLabel("Agent Colors")
        sectionAnchors = [
            0: appearanceSection,
            1: paletteSectionLabel,
            2: terminalSection,
            3: tmuxSection,
            4: agentColorsSection,
        ]

        let stack = NSStackView(views: [
            appearanceSection,
            labeledRow("Theme", themePopup),
            colorButtonsRow(),
            labeledRow("Background opacity", opacityRow),
            labeledRow("Background blur", blurField),
            hexRow("Background color", backgroundHexField, backgroundWell),
            hexRow("Foreground color", foregroundHexField, foregroundWell),
            hexRow("Cursor color", cursorHexField, cursorWell),
            hexRow("Cursor text", cursorTextHexField, cursorTextWell),
            hexRow("Selection background", selectionBgHexField, selectionBgWell),
            hexRow("Selection text", selectionFgHexField, selectionFgWell),
            hexRow("Bold text color", boldHexField, boldWell),
            labeledRow("Minimum contrast", minContrastField),
            labeledRow("Padding X", paddingXField),
            labeledRow("Padding Y", paddingYField),
            transparentTitlebarToggle,
            spacer(8),
            paletteSectionLabel,
            paletteSection(),
            spacer(8),
            terminalSection,
            labeledRow("Font size", fontSizeField),
            labeledRow("Font family", fontFamilyField),
            labeledRow("Default shell", shellField),
            labeledRow("Default directory", cwdField),
            labeledRow("Scrollback lines", scrollbackField),
            labeledRow("Cursor style", cursorStylePopup),
            cursorBlinkToggle,
            copyOnSelectToggle,
            keepSessionsToggle,
            spacer(8),
            tmuxSection,
            labeledRow("Prefix key", prefixKeyField),
            agentsRow(),
            spacer(8),
            agentColorsSection,
            agentColorsSectionView(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable body so the entire settings list stays reachable on any window
        // height; the action buttons stay pinned in a footer below the scroll area.
        let documentView = SettingsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        settingsScrollView = scroll

        let sidebar = settingsSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        view.addSubview(scroll)

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
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),

            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            // Document view tracks the content width (no horizontal scroll); its height
            // grows with the stack, which is what makes the body scroll when it overflows.
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -22),

            saveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            importButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            importButton.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 22),
        ])
    }

    private func settingsSidebar() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.12).cgColor

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "Search"
        search.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for (index, label) in ["Appearance", "ANSI Palette", "Terminal", "Tmux + Agents", "Agent Colors"].enumerated() {
            let button = NSButton(title: label, target: self, action: #selector(jumpToSettingsSection(_:)))
            button.tag = index
            button.alignment = .left
            button.bezelStyle = .rounded
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            buttons.addArrangedSubview(button)
        }

        container.addSubview(title)
        container.addSubview(search)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
        return container
    }

    @objc private func jumpToSettingsSection(_ sender: NSButton) {
        guard let scroll = settingsScrollView,
              let documentView = scroll.documentView,
              let anchor = sectionAnchors[sender.tag]
        else { return }
        documentView.layoutSubtreeIfNeeded()
        let y = max(anchor.frame.minY - 12, 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
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

    /// A labeled hex field paired with a native color-well swatch/picker.
    private func hexRow(_ title: String, _ field: NSTextField, _ well: NSColorWell) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let row = NSStackView(views: [label, field, well])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    /// "Use Theme Colors" + "Reset to Defaults", indented to align with the fields.
    private func colorButtonsRow() -> NSView {
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        reset.bezelStyle = .rounded
        let buttons = NSStackView(views: [useThemeColorsButton, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [indent, buttons])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func agentsRow() -> NSView {
        let button = NSButton(title: "Edit agents.json…", target: self, action: #selector(openAgentsJSON))
        button.bezelStyle = .rounded
        return labeledRow("Agent table", button)
    }

    private func buildPaletteWells() {
        paletteWells.removeAll()
        for index in 0 ..< 16 {
            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 30).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.color = paletteHexValues[index].flatMap(NSColor.fromHex)
                ?? NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
            well.target = self
            well.action = #selector(paletteWellChanged(_:))
            well.toolTip = Self.ansiNames[index]
            paletteWells.append(well)
        }
    }

    private func buildAgentColorWells(settings: HarnessSettings) {
        agentColorWells.removeAll()
        for kind in Self.agentColorKinds {
            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.color = NSColor.fromHex(settings.agentColorHex(for: kind)) ?? .gray
            well.target = self
            well.action = #selector(agentColorWellChanged(_:))
            well.toolTip = kind.displayName
            agentColorWells[kind] = well
        }
    }

    /// Two rows of 8 ANSI swatches (0–7 normal, 8–15 bright) plus a reset button.
    private func paletteSection() -> NSView {
        let caption = NSTextField(labelWithString: "0–7 normal · 8–15 bright · click a swatch to override the theme")
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = .tertiaryLabelColor

        func paletteRow(_ range: Range<Int>) -> NSStackView {
            let row = NSStackView(views: range.map(paletteCell))
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }
        let grid = NSStackView(views: [paletteRow(0 ..< 8), paletteRow(8 ..< 16)])
        grid.orientation = .vertical
        grid.spacing = 6
        grid.alignment = .leading

        let reset = NSButton(title: "Reset palette", target: self, action: #selector(resetPalette))
        reset.bezelStyle = .rounded

        let section = NSStackView(views: [caption, grid, reset])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    private func paletteCell(_ index: Int) -> NSView {
        let label = NSTextField(labelWithString: "\(index)")
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        let cell = NSStackView(views: [paletteWells[index], label])
        cell.orientation = .vertical
        cell.spacing = 2
        cell.alignment = .centerX
        return cell
    }

    private func agentColorsSectionView() -> NSView {
        let rows = Self.agentColorKinds.map(agentColorRow)
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8

        let reset = NSButton(title: "Reset agent colors", target: self, action: #selector(resetAgentColors))
        reset.bezelStyle = .rounded

        let section = NSStackView(views: [grid, reset])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        return section
    }

    private func agentColorRow(_ kind: AgentKind) -> NSView {
        let label = NSTextField(labelWithString: kind.displayName)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let preview = AgentChipView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 18).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 126).isActive = true
        preview.configure(text: kind.displayName, hex: SessionCoordinator.shared.settings.agentColorHex(for: kind))
        agentColorPreviews[kind] = preview

        let row = NSStackView(views: [label, agentColorWells[kind] ?? NSView(), preview])
        row.orientation = .horizontal
        row.spacing = 12
        return row
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

    /// Map the saved Ghostty `cursor-style` value to a friendly popup title.
    private func cursorStyleTitle(_ value: String) -> String {
        switch value {
        case "bar": return "Beam"
        case "underline": return "Underline"
        default: return "Block"
        }
    }

    /// Inverse of `cursorStyleTitle` — popup title back to the Ghostty value.
    private func cursorStyleValue(_ title: String?) -> String {
        switch title {
        case "Beam": return "bar"
        case "Underline": return "underline"
        default: return "block"
        }
    }

    @objc private func opacityDidChange() {
        opacityLabel.stringValue = formatPercent(Float(opacitySlider.doubleValue))
        applyAppearancePreview()
    }

    @objc private func themeDidChange() {
        clearAllCustomColors()
        applyAppearancePreview()
    }

    @objc private func useThemeColors() {
        clearAllCustomColors()
        applyAppearancePreview()
    }

    @objc private func appearanceTextDidCommit() {
        applyAppearancePreview()
    }

    @objc private func appearanceTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField,
              let binding = colorBindings.first(where: { $0.field === field })
        else { return }
        validateHexField(field)
        if let color = NSColor.fromHex(field.stringValue) {
            binding.well.color = color
        }
        applyAppearancePreview()
    }

    private func configureColorWell(_ well: NSColorWell, hex: String?) {
        well.color = hex.flatMap(NSColor.fromHex) ?? HarnessChrome.current.terminalBackground
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let binding = colorBindings.first(where: { $0.well === sender }) else { return }
        binding.field.stringValue = hexString(sender.color)
        validateHexField(binding.field)
        applyAppearancePreview()
    }

    @objc private func paletteWellChanged(_ sender: NSColorWell) {
        guard let index = paletteWells.firstIndex(where: { $0 === sender }) else { return }
        paletteHexValues[index] = hexString(sender.color)
        applyAppearancePreview()
    }

    @objc private func agentColorWellChanged(_ sender: NSColorWell) {
        guard let kind = agentColorWells.first(where: { $0.value === sender })?.key else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.settings.agentColorOverrides[kind.rawValue] = hexString(sender.color)
        coordinator.settings.agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(coordinator.settings.agentColorOverrides)
        agentColorPreviews[kind]?.configure(text: kind.displayName, hex: coordinator.settings.agentColorHex(for: kind))
        try? coordinator.settings.save()
        coordinator.applySettingsToHosts()
    }

    @objc private func resetAgentColors() {
        let coordinator = SessionCoordinator.shared
        coordinator.settings.agentColorOverrides.removeAll()
        for (kind, well) in agentColorWells {
            well.color = NSColor.fromHex(coordinator.settings.agentColorHex(for: kind)) ?? .gray
            agentColorPreviews[kind]?.configure(text: kind.displayName, hex: coordinator.settings.agentColorHex(for: kind))
        }
        try? coordinator.settings.save()
        coordinator.applySettingsToHosts()
    }

    @objc private func resetPalette() {
        for (index, well) in paletteWells.enumerated() {
            paletteHexValues[index] = nil
            well.color = NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
        }
        applyAppearancePreview()
    }

    /// Drop every custom color override (singular colors + palette) back to "use theme".
    private func clearAllCustomColors() {
        for binding in colorBindings {
            binding.field.stringValue = ""
            validateHexField(binding.field)
            binding.well.color = HarnessChrome.current.terminalBackground
        }
        for (index, well) in paletteWells.enumerated() {
            paletteHexValues[index] = nil
            well.color = NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
        }
    }

    private func hexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Tint the field red when its contents aren't a valid hex color (empty is fine —
    /// that means "use theme colors"). Replaces the previous silent rejection.
    private func validateHexField(_ field: NSTextField) {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = raw.isEmpty || normalizedHexOrNil(raw) != nil
        field.textColor = valid ? .controlTextColor : .systemRed
    }

    @objc private func resetToDefaults() {
        clearAllCustomColors()
        opacitySlider.doubleValue = 0.85
        opacityLabel.stringValue = formatPercent(0.85)
        blurField.stringValue = "0"
        paddingXField.stringValue = "12"
        paddingYField.stringValue = "12"
        minContrastField.stringValue = "1.0"
        applyAppearancePreview()
    }

    private func configureLiveAppearanceField(_ field: NSTextField) {
        field.target = self
        field.action = #selector(appearanceTextDidCommit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceTextDidChange(_:)),
            name: NSControl.textDidChangeNotification,
            object: field
        )
    }

    private func applyAppearancePreview() {
        let coordinator = SessionCoordinator.shared
        coordinator.settings.backgroundOpacity = Float(opacitySlider.doubleValue)
        coordinator.settings.backgroundBlur = Int(blurField.stringValue) ?? coordinator.settings.backgroundBlur
        for binding in colorBindings {
            coordinator.settings[keyPath: binding.keyPath] = normalizedHexOrNil(binding.field.stringValue)
        }
        coordinator.settings.useCustomColors = hasCustomColorOverrides()
        coordinator.settings.minimumContrast = clampedContrast(minContrastField.stringValue)
        coordinator.settings.paletteHex = paletteHexValues
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        try? coordinator.settings.save()
        if let selectedTheme = themePopup.titleOfSelectedItem {
            coordinator.setTheme(selectedTheme, clearColorOverrides: false)
        } else {
            coordinator.applySettingsToHosts()
        }
    }

    /// Clamp the contrast field to Ghostty's accepted range (1 = off … 21 = max).
    private func clampedContrast(_ raw: String) -> Double {
        guard let value = Double(raw) else { return 1 }
        return min(21, max(1, value))
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
        // Ghostty import covers bg/fg/cursor; the extended colors + palette reset to theme.
        for field in [selectionBgHexField, selectionFgHexField, boldHexField, cursorTextHexField] {
            field.stringValue = ""
            validateHexField(field)
        }
        minContrastField.stringValue = "1.0"
        for (index, well) in paletteWells.enumerated() {
            paletteHexValues[index] = nil
            well.color = NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
        }
        syncColorWellsFromFields()
        if let value = imported.themeName {
            themePopup.selectItem(withTitle: value)
        }
        let coordinator = SessionCoordinator.shared
        let existingAgentColors = coordinator.settings.agentColorOverrides
        coordinator.settings = HarnessSettings.makeDefaults(imported: imported)
        coordinator.settings.agentColorOverrides = existingAgentColors
        try? coordinator.settings.save()
        if let theme = imported.themeName {
            coordinator.setTheme(theme)
        }
        coordinator.applySettingsToHosts()
    }

    @objc private func save() {
        let coordinator = SessionCoordinator.shared
        let selectedTheme = themePopup.titleOfSelectedItem
        coordinator.settings.fontSize = Float(fontSizeField.stringValue) ?? 14
        coordinator.settings.fontFamily = fontFamilyField.stringValue
        coordinator.settings.defaultShell = shellField.stringValue
        coordinator.settings.defaultCWD = cwdField.stringValue
        coordinator.settings.backgroundOpacity = Float(opacitySlider.doubleValue)
        coordinator.settings.backgroundBlur = Int(blurField.stringValue) ?? 0
        coordinator.settings.windowPaddingX = Float(paddingXField.stringValue) ?? 12
        coordinator.settings.windowPaddingY = Float(paddingYField.stringValue) ?? 12
        for binding in colorBindings {
            coordinator.settings[keyPath: binding.keyPath] = normalizedHexOrNil(binding.field.stringValue)
        }
        coordinator.settings.useCustomColors = hasCustomColorOverrides()
        coordinator.settings.minimumContrast = clampedContrast(minContrastField.stringValue)
        coordinator.settings.paletteHex = paletteHexValues
        coordinator.settings.ghosttyConfigSignature = GhosttyConfigImporter.load()?.signature
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        coordinator.settings.prefixKey = prefixKeyField.stringValue.isEmpty ? "ctrl-a" : prefixKeyField.stringValue
        coordinator.settings.scrollbackLines = max(100, Int(scrollbackField.stringValue) ?? 10_000)
        coordinator.settings.cursorStyle = cursorStyleValue(cursorStylePopup.titleOfSelectedItem)
        coordinator.settings.cursorBlink = cursorBlinkToggle.state == .on
        coordinator.settings.copyOnSelect = copyOnSelectToggle.state == .on
        try? coordinator.settings.save()
        if let selectedTheme {
            coordinator.setTheme(selectedTheme)
        }
        coordinator.setKeepSessionsOnQuit(keepSessionsToggle.state == .on)
        coordinator.applySettingsToHosts()
        PrefixKeymap.shared.rebuildFromSettings()
        view.window?.close()
    }

    private func normalizedHexOrNil(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard cleaned.count == 6,
              cleaned.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return "#\(cleaned)"
    }

    private func hasCustomColorOverrides() -> Bool {
        colorBindings.contains { normalizedHexOrNil($0.field.stringValue) != nil }
            || paletteHexValues.contains { $0 != nil }
    }

    private func syncColorWellsFromFields() {
        for binding in colorBindings {
            if let hex = normalizedHexOrNil(binding.field.stringValue),
               let color = NSColor.fromHex(hex) {
                binding.well.color = color
            } else {
                binding.well.color = HarnessChrome.current.terminalBackground
            }
            validateHexField(binding.field)
        }
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

/// Top-origin document view for the settings scroll area, so content lays out from
/// the top and the scroll view starts scrolled to the first section.
@MainActor
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
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
            win.isRestorable = false
            win.setContentSize(NSSize(width: 580, height: 680))
            window = win
        }
        // Match the terminal theme so native controls render in the right appearance.
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
