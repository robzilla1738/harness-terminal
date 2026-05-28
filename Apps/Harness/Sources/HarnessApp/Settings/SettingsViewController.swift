import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class SettingsViewController: NSViewController, NSSearchFieldDelegate {
    private let themePopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontFamilyField = NSTextField()
    private let shellField = NSTextField()
    private let cwdField = NSTextField()
    private let opacitySlider = NSSlider()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let blurSlider = NSSlider()
    private let blurLabel = NSTextField(labelWithString: "")
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
    /// Every hex field is paired with a color well + reset button + settings key path,
    /// so one generic flow drives validation, live preview, and save for all of them.
    private var colorBindings: [ColorBinding] = []

    private struct ColorBinding {
        let field: NSTextField
        let well: NSColorWell
        let reset: NSButton
        let preview: ColorSamplePreview
        let keyPath: WritableKeyPath<HarnessSettings, String?>
        /// Where the chosen color shows up in the terminal. Drives the live
        /// sample so the user can see exactly what they're changing without
        /// hunting through the terminal for a bold word or selected text.
        let role: ColorSamplePreview.Role
        /// Closure to fetch the theme-derived value for this slot. When the override
        /// is unset, we still show this color in the well so the swatch is meaningful.
        let themeColor: () -> String?
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

        // Full 5%–100% range — power users want extreme translucency, and the
        // 5% floor only exists so an accidental zero doesn't strand an invisible
        // window. The settings window itself stays solid regardless.
        opacitySlider.minValue = 0.05
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityDidChange)
        opacitySlider.isContinuous = true
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacitySlider.toolTip = "Window background opacity (5%–100%)"

        // 0–100 covers no-blur through heavy frosted glass. libghostty caps the
        // effective amount internally, but exposing the full range matches user
        // intent for the "I want whatever I want" use case.
        blurSlider.minValue = 0
        blurSlider.maxValue = 100
        blurSlider.doubleValue = Double(settings.backgroundBlur)
        blurSlider.target = self
        blurSlider.action = #selector(blurDidChange)
        blurSlider.isContinuous = true
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        blurLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        blurLabel.textColor = .secondaryLabelColor
        blurSlider.toolTip = "Background blur radius in pixels (0 = none, 100 = heavy)"
        paddingXField.stringValue = String(format: "%.0f", settings.windowPaddingX)
        paddingYField.stringValue = String(format: "%.0f", settings.windowPaddingY)
        // Resolve theme colors lazily so swapping themes keeps placeholders fresh
        // without having to rebuild the bindings list.
        colorBindings = [
            ColorBinding(
                field: backgroundHexField, well: backgroundWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .background),
                keyPath: \.customBackgroundHex,
                role: .background,
                themeColor: { ThemeManager.backgroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: foregroundHexField, well: foregroundWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .foreground),
                keyPath: \.customForegroundHex,
                role: .foreground,
                themeColor: { ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: cursorHexField, well: cursorWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .cursor),
                keyPath: \.customCursorHex,
                role: .cursor,
                themeColor: { ThemeManager.cursorHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: cursorTextHexField, well: cursorTextWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .cursorText),
                keyPath: \.cursorTextHex,
                role: .cursorText,
                themeColor: { ThemeManager.cursorTextHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: selectionBgHexField, well: selectionBgWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .selectionBackground),
                keyPath: \.selectionBackgroundHex,
                role: .selectionBackground,
                themeColor: { ThemeManager.selectionBackgroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: selectionFgHexField, well: selectionFgWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .selectionForeground),
                keyPath: \.selectionForegroundHex,
                role: .selectionForeground,
                themeColor: { ThemeManager.selectionForegroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: boldHexField, well: boldWell, reset: makeResetButton(),
                preview: ColorSamplePreview(role: .bold),
                keyPath: \.boldColorHex,
                role: .bold,
                themeColor: { ThemeManager.boldHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
        ]
        for binding in colorBindings {
            let hex = settings.useCustomColors ? settings[keyPath: binding.keyPath] : nil
            binding.field.stringValue = hex ?? ""
            configureLiveAppearanceField(binding.field)
            configureColorWell(binding.well)
            configureResetButton(binding.reset)
            refreshColorBinding(binding)
        }
        // Second pass so each preview tile reflects the full context (the bold
        // sample needs to know the background even though it was created first).
        refreshAllPreviews()

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
        opacityRow.spacing = 10
        opacitySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let blurRow = NSStackView(views: [blurSlider, blurLabel])
        blurRow.orientation = .horizontal
        blurRow.spacing = 10
        blurSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        blurLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

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
            labeledRow("Window opacity", opacityRow),
            labeledRow("Window blur", blurRow),
            hexRow(
                title: "Background", subtitle: "Terminal canvas color",
                binding: colorBindings[0]
            ),
            hexRow(
                title: "Text", subtitle: "Default foreground for printed characters",
                binding: colorBindings[1]
            ),
            hexRow(
                title: "Cursor", subtitle: "Color of the block / beam cursor",
                binding: colorBindings[2]
            ),
            hexRow(
                title: "Text under cursor", subtitle: "Character color when the cursor sits on it",
                binding: colorBindings[3]
            ),
            hexRow(
                title: "Selection fill", subtitle: "Highlight background of selected text",
                binding: colorBindings[4]
            ),
            hexRow(
                title: "Selected text", subtitle: "Character color inside a selection",
                binding: colorBindings[5]
            ),
            hexRow(
                title: "Bold text", subtitle: "Color applied to any bold output",
                binding: colorBindings[6]
            ),
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

    private var sidebarButtons: [SettingsSidebarButton] = []
    private let settingsSearch = NSSearchField()
    /// Lookup table mapping section index → keywords (besides the section title)
    /// that match user-facing terms. Used by the sidebar search to also surface
    /// individual fields like "opacity" → Appearance.
    private static let sectionKeywords: [Int: [String]] = [
        0: ["theme", "color", "opacity", "blur", "padding", "cursor", "selection", "appearance", "background", "foreground", "transparent"],
        1: ["ansi", "palette", "swatch", "bright", "color"],
        2: ["terminal", "font", "shell", "directory", "scrollback", "blink", "copy", "session"],
        3: ["tmux", "prefix", "agent", "hook", "keybinding", "shortcut"],
        4: ["agent", "color", "codex", "claude", "cursor", "pi", "hermes", "openclaw"],
    ]

    private func settingsSidebar() -> NSView {
        let container = NSVisualEffectView()
        container.material = .underWindowBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "Theme · Terminal · Agents")
        subtitle.font = .systemFont(ofSize: 11.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        settingsSearch.placeholderString = "Filter sections…"
        settingsSearch.delegate = self
        settingsSearch.font = .systemFont(ofSize: 12)
        settingsSearch.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false

        sidebarButtons.removeAll()
        let entries: [(String, String)] = [
            ("Appearance", "paintbrush"),
            ("ANSI Palette", "swatchpalette"),
            ("Terminal", "terminal"),
            ("Tmux + Agents", "keyboard"),
            ("Agent Colors", "sparkles"),
        ]
        for (index, entry) in entries.enumerated() {
            let button = SettingsSidebarButton(title: entry.0, symbol: entry.1)
            button.tag = index
            button.isSelected = index == 0
            button.target = self
            button.action = #selector(jumpToSettingsSection(_:))
            buttons.addArrangedSubview(button)
            sidebarButtons.append(button)
        }

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(settingsSearch)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            settingsSearch.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            settingsSearch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            settingsSearch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: settingsSearch.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        return container
    }

    // NSSearchFieldDelegate — filter sidebar buttons in real-time. The matching
    // surfaces both exact title hits and per-section keyword hits ("opacity" →
    // Appearance), so users hunting for a single field still get the right
    // section highlighted.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === settingsSearch else { return }
        let query = settingsSearch.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        for button in sidebarButtons {
            if query.isEmpty {
                button.isHidden = false
                continue
            }
            let title = button.buttonTitle.lowercased()
            let keywords = Self.sectionKeywords[button.tag] ?? []
            let hits = title.contains(query) || keywords.contains(where: { $0.contains(query) })
            button.isHidden = !hits
        }
    }

    @objc private func jumpToSettingsSection(_ sender: SettingsSidebarButton) {
        for button in sidebarButtons { button.isSelected = (button === sender) }
        guard let scroll = settingsScrollView,
              let documentView = scroll.documentView,
              let anchor = sectionAnchors[sender.tag]
        else { return }
        documentView.layoutSubtreeIfNeeded()
        let y = max(anchor.frame.minY - 12, 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HarnessDesign.Motion.standard
            ctx.timingFunction = HarnessDesign.Motion.standardEase
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
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

    /// One row in the color section: stacked label + subtitle on the left, then the
    /// hex field, the color well, a live preview tile showing exactly *where* the
    /// color shows up in the terminal, and a clear button. The preview was the
    /// missing link before — users would change "Bold text" and assume nothing
    /// happened because the active pane had no bold output to repaint.
    private func hexRow(title: String, subtitle: String, binding: ColorBinding) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right

        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail

        let labelStack = NSStackView(views: [label, detail])
        labelStack.orientation = .vertical
        labelStack.alignment = .trailing
        labelStack.spacing = 1
        labelStack.widthAnchor.constraint(equalToConstant: 156).isActive = true

        binding.field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
        binding.field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        binding.field.usesSingleLineMode = true
        binding.field.toolTip = subtitle

        binding.preview.translatesAutoresizingMaskIntoConstraints = false
        binding.preview.widthAnchor.constraint(equalToConstant: 88).isActive = true
        binding.preview.heightAnchor.constraint(equalToConstant: 26).isActive = true
        binding.preview.toolTip = subtitle

        let row = NSStackView(views: [labelStack, binding.field, binding.well, binding.preview, binding.reset])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func makeResetButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Clear override")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = #selector(colorResetClicked(_:))
        button.toolTip = "Use theme color"
        return button
    }

    private func configureResetButton(_ button: NSButton) {
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
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

    private func formatBlur(_ value: Int) -> String {
        value == 0 ? "off" : "\(value) px"
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

    @objc private func blurDidChange() {
        let rounded = Int(blurSlider.doubleValue.rounded())
        blurLabel.stringValue = formatBlur(rounded)
        applyAppearancePreview()
    }

    @objc private func themeDidChange() {
        clearAllCustomColors()
        applyAppearancePreview()
        refreshColorPlaceholders()
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
        refreshColorBinding(binding)
        refreshAllPreviews()
        // Live well preview is free, but committing through the daemon on every
        // keystroke would spam the IPC socket and write settings.json on every
        // character. Push only when the field is either empty (clearing the
        // override) or fully valid — partially-typed hex codes don't need to
        // make it to the terminal until the user finishes typing.
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || normalizedHexOrNil(raw) != nil {
            applyAppearancePreview()
        }
    }

    private func configureColorWell(_ well: NSColorWell) {
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 30).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let binding = colorBindings.first(where: { $0.well === sender }) else { return }
        binding.field.stringValue = hexString(sender.color)
        refreshColorBinding(binding)
        // Every preview tile renders against the shared color context, so a
        // change to one color (e.g. background) needs to repaint all the
        // other previews too. Otherwise the bold sample would still show
        // the old background behind it.
        refreshAllPreviews()
        applyAppearancePreview()
    }

    @objc private func colorResetClicked(_ sender: NSButton) {
        guard let binding = colorBindings.first(where: { $0.reset === sender }) else { return }
        binding.field.stringValue = ""
        refreshColorBinding(binding)
        refreshAllPreviews()
        applyAppearancePreview()
    }

    /// Refresh validation, well color, preview, and reset-button enabled state for
    /// a binding. The well + preview always show the *effective* color (override if
    /// set, else theme), and the reset button only enables when there's something
    /// to clear. The preview also reflects neighboring colors (e.g. the "Selected
    /// text" sample needs the current selection-background to look right), so it
    /// re-resolves the whole context on every call.
    private func refreshColorBinding(_ binding: ColorBinding) {
        validateHexField(binding.field)
        let hasOverride = normalizedHexOrNil(binding.field.stringValue) != nil
        let effective = normalizedHexOrNil(binding.field.stringValue) ?? binding.themeColor()
        binding.well.color = effective.flatMap(NSColor.fromHex) ?? HarnessChrome.current.terminalBackground
        binding.reset.isEnabled = hasOverride
        binding.reset.alphaValue = hasOverride ? 1.0 : 0.25
        binding.preview.update(context: currentPreviewContext(), highlight: binding.role)
    }

    /// Snapshot of the current effective colors for the preview tiles. Each tile
    /// renders against this shared palette so e.g. the bold sample sits on the
    /// right background, the selection sample uses the right fill, etc.
    private func currentPreviewContext() -> ColorSamplePreview.Context {
        func resolve(_ binding: ColorBinding) -> NSColor? {
            let chosen = normalizedHexOrNil(binding.field.stringValue) ?? binding.themeColor()
            return chosen.flatMap(NSColor.fromHex)
        }
        return ColorSamplePreview.Context(
            background: resolve(colorBindings[0]) ?? .black,
            foreground: resolve(colorBindings[1]) ?? .white,
            cursor: resolve(colorBindings[2]) ?? .systemBlue,
            cursorText: resolve(colorBindings[3]) ?? .black,
            selectionBackground: resolve(colorBindings[4]) ?? NSColor.systemBlue.withAlphaComponent(0.5),
            selectionForeground: resolve(colorBindings[5]) ?? .white,
            bold: resolve(colorBindings[6]) ?? .white
        )
    }

    /// Push the current preview context to every preview tile. Used after any
    /// edit so all swatches stay in sync (changing the background also affects
    /// how every other sample looks).
    private func refreshAllPreviews() {
        let context = currentPreviewContext()
        for binding in colorBindings {
            binding.preview.update(context: context, highlight: binding.role)
        }
    }

    /// Refresh every binding's well + placeholder; used after the theme changes.
    private func refreshColorPlaceholders() {
        for binding in colorBindings {
            binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
            refreshColorBinding(binding)
        }
        refreshAllPreviews()
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
            refreshColorBinding(binding)
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
        blurSlider.doubleValue = 20
        blurLabel.stringValue = formatBlur(20)
        paddingXField.stringValue = "12"
        paddingYField.stringValue = "12"
        minContrastField.stringValue = "1.0"
        refreshAllPreviews()
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
        coordinator.settings.backgroundOpacity = HarnessSettings.clampedOpacity(Float(opacitySlider.doubleValue))
        coordinator.settings.backgroundBlur = HarnessSettings.clampedBlur(Int(blurSlider.doubleValue.rounded()))
        for binding in colorBindings {
            coordinator.settings[keyPath: binding.keyPath] = normalizedHexOrNil(binding.field.stringValue)
        }
        coordinator.settings.useCustomColors = hasCustomColorOverrides()
        coordinator.settings.minimumContrast = clampedContrast(minContrastField.stringValue)
        coordinator.settings.paletteHex = paletteHexValues
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        try? coordinator.settings.save()
        // Only round-trip the theme through the daemon when it has actually
        // changed — otherwise scrubbing a slider would fire a setTheme IPC per
        // tick. applySettingsToHosts() already refreshes chrome locally.
        if let selectedTheme = themePopup.titleOfSelectedItem,
           selectedTheme != coordinator.snapshot.themeName {
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
            let clamped = HarnessSettings.clampedOpacity(value)
            opacitySlider.doubleValue = Double(clamped)
            opacityLabel.stringValue = formatPercent(clamped)
        }
        if let value = imported.backgroundBlur {
            let clamped = HarnessSettings.clampedBlur(value)
            blurSlider.doubleValue = Double(clamped)
            blurLabel.stringValue = formatBlur(clamped)
        }
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
        coordinator.settings.backgroundOpacity = HarnessSettings.clampedOpacity(Float(opacitySlider.doubleValue))
        coordinator.settings.backgroundBlur = HarnessSettings.clampedBlur(Int(blurSlider.doubleValue.rounded()))
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
        for binding in colorBindings { refreshColorBinding(binding) }
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

/// Tiny "terminal-shaped" tile that paints a representative slice of the current
/// color settings, highlighting whichever role the row owns. Lets the user see
/// *exactly* what a setting affects — e.g. the "Selection fill" preview always
/// shows a sample with text selected, the "Bold text" preview shows bold output,
/// and so on. Solves the original "I changed Bold text and nothing happened"
/// confusion: now the change shows up here even if the live terminal has no
/// bold output to repaint.
@MainActor
final class ColorSamplePreview: NSView {
    enum Role {
        case background, foreground, cursor, cursorText
        case selectionBackground, selectionForeground, bold
    }

    struct Context {
        var background: NSColor
        var foreground: NSColor
        var cursor: NSColor
        var cursorText: NSColor
        var selectionBackground: NSColor
        var selectionForeground: NSColor
        var bold: NSColor
    }

    private let role: Role
    private var context: Context = .init(
        background: .black, foreground: .white, cursor: .systemBlue,
        cursorText: .black, selectionBackground: NSColor.systemBlue.withAlphaComponent(0.5),
        selectionForeground: .white, bold: .white
    )
    private var highlight: Role

    init(role: Role) {
        self.role = role
        self.highlight = role
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(context: Context, highlight: Role) {
        self.context = context
        self.highlight = highlight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        let cornerPath = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        cornerPath.addClip()

        // Always start with the background — every preview shows the terminal's
        // canvas color so the user can read the sample in real context.
        context.background.setFill()
        ctx.fill(rect)

        let baseFont = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let boldFont = NSFont(name: "Menlo-Bold", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)

        switch role {
        case .background:
            // Show the canvas only — that's literally what this color controls.
            let label = NSAttributedString(
                string: "abc",
                attributes: [.foregroundColor: context.foreground, .font: baseFont]
            )
            drawString(label, centeredIn: rect)

        case .foreground:
            let label = NSAttributedString(
                string: "Abc 123",
                attributes: [.foregroundColor: context.foreground, .font: baseFont]
            )
            drawString(label, centeredIn: rect)

        case .cursor:
            // Render a sample word with the cursor block beside the last char.
            let textWidth: CGFloat = 32
            let cursorWidth: CGFloat = 8
            let combinedWidth = textWidth + 2 + cursorWidth
            let originX = rect.midX - combinedWidth / 2
            let yCenter = rect.midY

            let label = NSAttributedString(
                string: "abc",
                attributes: [.foregroundColor: context.foreground, .font: baseFont]
            )
            let textRect = NSRect(x: originX, y: yCenter - 6.5, width: textWidth, height: 13)
            label.draw(in: textRect)

            let cursorRect = NSRect(x: originX + textWidth + 2, y: yCenter - 6, width: cursorWidth, height: 12)
            context.cursor.setFill()
            ctx.fill(cursorRect)

        case .cursorText:
            // Block cursor overlaying a character — the character is painted in
            // the "text under cursor" color so the user sees the inversion effect.
            let glyphSize: CGFloat = 11
            let cursorWidth: CGFloat = 9
            let yCenter = rect.midY

            let cursorRect = NSRect(x: rect.midX - cursorWidth / 2, y: yCenter - 6, width: cursorWidth, height: 12)
            context.cursor.setFill()
            ctx.fill(cursorRect)

            let charAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: context.cursorText,
                .font: NSFont(name: "Menlo", size: glyphSize) ?? .monospacedSystemFont(ofSize: glyphSize, weight: .regular),
            ]
            let glyph = NSAttributedString(string: "A", attributes: charAttrs)
            drawString(glyph, centeredIn: cursorRect)

        case .selectionBackground:
            // Show the highlight fill behind sample text.
            let selectionWidth: CGFloat = 56
            let selectionHeight: CGFloat = 16
            let selectionRect = NSRect(
                x: rect.midX - selectionWidth / 2,
                y: rect.midY - selectionHeight / 2,
                width: selectionWidth,
                height: selectionHeight
            )
            context.selectionBackground.setFill()
            NSBezierPath(roundedRect: selectionRect, xRadius: 2, yRadius: 2).fill()
            let label = NSAttributedString(
                string: "abcdef",
                attributes: [.foregroundColor: context.selectionForeground, .font: baseFont]
            )
            drawString(label, centeredIn: selectionRect)

        case .selectionForeground:
            // Same composition but emphasize the *text* inside the selection.
            let selectionWidth: CGFloat = 56
            let selectionHeight: CGFloat = 16
            let selectionRect = NSRect(
                x: rect.midX - selectionWidth / 2,
                y: rect.midY - selectionHeight / 2,
                width: selectionWidth,
                height: selectionHeight
            )
            context.selectionBackground.setFill()
            NSBezierPath(roundedRect: selectionRect, xRadius: 2, yRadius: 2).fill()
            let label = NSAttributedString(
                string: "abcdef",
                attributes: [.foregroundColor: context.selectionForeground, .font: baseFont]
            )
            drawString(label, centeredIn: selectionRect)

        case .bold:
            let label = NSAttributedString(
                string: "Bold",
                attributes: [.foregroundColor: context.bold, .font: boldFont]
            )
            drawString(label, centeredIn: rect)
        }
    }

    private func drawString(_ string: NSAttributedString, centeredIn rect: NSRect) {
        let size = string.size()
        let originX = rect.midX - size.width / 2
        let originY = rect.midY - size.height / 2
        string.draw(at: NSPoint(x: originX, y: originY))
    }
}

/// Sidebar row in the Settings window — SF Symbol + label, selectable, full-width
/// hover/active fills. Sits inside an `NSStackView`; uses its own layer chrome
/// instead of `NSButton`'s bezel so dark mode reads cleanly.
@MainActor
final class SettingsSidebarButton: NSControl {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    var isSelected = false { didSet { applyChrome() } }
    let buttonTitle: String

    init(title: String, symbol: String) {
        self.buttonTitle = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func applyChrome() {
        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
            iconView.contentTintColor = NSColor.controlAccentColor
            label.textColor = .labelColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            iconView.contentTintColor = .secondaryLabelColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            iconView.contentTintColor = .tertiaryLabelColor
            label.textColor = .secondaryLabelColor
        }
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
            win.styleMask = [.titled, .closable, .resizable]
            win.isRestorable = false
            win.minSize = NSSize(width: 720, height: 600)
            win.setContentSize(NSSize(width: 760, height: 720))
            window = win
        }
        // Match the terminal theme so native controls render in the right appearance.
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
