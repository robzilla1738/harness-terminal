import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class SettingsViewController: NSViewController, NSSearchFieldDelegate, NSFontChanging {
    private let themePopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let fontFamilyField = NSTextField()
    private let fontReadout = NSTextField(labelWithString: "")
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
    private let scrollbackField = NSTextField()
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
    private let selectionBgHexField = NSTextField()
    private let selectionFgHexField = NSTextField()
    private let boldHexField = NSTextField()
    private let cursorTextHexField = NSTextField()
    private let dividerHexField = NSTextField()
    private let statusLineHexField = NSTextField()
    private let selectionBgWell = NSColorWell()
    private let selectionFgWell = NSColorWell()
    private let boldWell = NSColorWell()
    private let cursorTextWell = NSColorWell()
    private let dividerWell = NSColorWell()
    private let statusLineWell = NSColorWell()
    private let systemNotificationsToggle = NSButton()
    private let minContrastField = NSTextField()
    private let livePreview = LiveTerminalPreview()
    private let pageContainer = NSView()
    private var pages: [Int: NSView] = [:]
    private var currentPage: Int = 0
    private var paletteWells: [NSColorWell] = []
    private var paletteHexValues: [String?] = Array(repeating: nil, count: 16)
    private var agentColorWells: [AgentKind: NSColorWell] = [:]
    private var agentColorPreviews: [AgentKind: AgentChipView] = [:]
    private var colorBindings: [ColorBinding] = []
    private var keyRecorder: KeyRecorderView!

    private struct ColorBinding {
        let field: NSTextField
        let well: NSColorWell
        let reset: NSButton
        let keyPath: WritableKeyPath<HarnessSettings, String?>
        let themeColor: () -> String?
    }

    private static let defaultAnsiPalette = [
        ThemeManager.defaultBaselinePaletteHex[0],
        ThemeManager.defaultBaselinePaletteHex[1],
        ThemeManager.defaultBaselinePaletteHex[2],
        ThemeManager.defaultBaselinePaletteHex[3],
        ThemeManager.defaultBaselinePaletteHex[4],
        ThemeManager.defaultBaselinePaletteHex[5],
        ThemeManager.defaultBaselinePaletteHex[6],
        ThemeManager.defaultBaselinePaletteHex[7],
        ThemeManager.defaultBaselinePaletteHex[8],
        ThemeManager.defaultBaselinePaletteHex[9],
        ThemeManager.defaultBaselinePaletteHex[10],
        ThemeManager.defaultBaselinePaletteHex[11],
        ThemeManager.defaultBaselinePaletteHex[12],
        ThemeManager.defaultBaselinePaletteHex[13],
        ThemeManager.defaultBaselinePaletteHex[14],
        ThemeManager.defaultBaselinePaletteHex[15],
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 660))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        layoutShell()
        showPage(0)
        refreshLivePreview()
    }

    // MARK: - Control configuration (initial state from settings)

    private func configureControls() {
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
        fontSizeField.target = self
        fontSizeField.action = #selector(appearanceTextDidCommit)
        fontFamilyField.stringValue = settings.fontFamily
        shellField.stringValue = settings.defaultShell
        shellField.target = self
        shellField.action = #selector(appearanceTextDidCommit)
        cwdField.stringValue = settings.defaultCWD
        cwdField.target = self
        cwdField.action = #selector(appearanceTextDidCommit)

        // 5%–100% range; 5% floor prevents an invisible window if someone slams to 0.
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

        blurSlider.minValue = 0
        blurSlider.maxValue = 100
        blurSlider.doubleValue = Double(settings.backgroundBlur)
        blurSlider.target = self
        blurSlider.action = #selector(blurDidChange)
        blurSlider.isContinuous = true
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        blurLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        blurLabel.textColor = .secondaryLabelColor
        blurSlider.toolTip = "Terminal backdrop blur (Ghostty); applied to the terminal surface, not the whole window."

        paddingXField.stringValue = String(format: "%.0f", settings.windowPaddingX)
        paddingXField.target = self
        paddingXField.action = #selector(appearanceTextDidCommit)
        paddingYField.stringValue = String(format: "%.0f", settings.windowPaddingY)
        paddingYField.target = self
        paddingYField.action = #selector(appearanceTextDidCommit)

        colorBindings = [
            ColorBinding(
                field: backgroundHexField, well: backgroundWell, reset: makeResetButton(),
                keyPath: \.customBackgroundHex,
                themeColor: { ThemeManager.backgroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: foregroundHexField, well: foregroundWell, reset: makeResetButton(),
                keyPath: \.customForegroundHex,
                themeColor: { ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: cursorHexField, well: cursorWell, reset: makeResetButton(),
                keyPath: \.customCursorHex,
                themeColor: { ThemeManager.cursorHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: cursorTextHexField, well: cursorTextWell, reset: makeResetButton(),
                keyPath: \.cursorTextHex,
                themeColor: { ThemeManager.cursorTextHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: selectionBgHexField, well: selectionBgWell, reset: makeResetButton(),
                keyPath: \.selectionBackgroundHex,
                themeColor: { ThemeManager.selectionBackgroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: selectionFgHexField, well: selectionFgWell, reset: makeResetButton(),
                keyPath: \.selectionForegroundHex,
                themeColor: { ThemeManager.selectionForegroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: boldHexField, well: boldWell, reset: makeResetButton(),
                keyPath: \.boldColorHex,
                themeColor: { ThemeManager.boldHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            // Window-chrome accents: the hairline dividers and the status line text.
            // Always honored — not gated by `useCustomColors` — since these are pure
            // chrome and the user explicitly opted in by setting a hex.
            ColorBinding(
                field: dividerHexField, well: dividerWell, reset: makeResetButton(),
                keyPath: \.dividerHex,
                themeColor: { ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
            ColorBinding(
                field: statusLineHexField, well: statusLineWell, reset: makeResetButton(),
                keyPath: \.statusLineHex,
                themeColor: { ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
        ]
        for binding in colorBindings {
            // Divider + status line read regardless of useCustomColors; everything else
            // stays gated by it so the theme picker can wipe color overrides cleanly.
            let isChromeAccent = binding.keyPath == \.dividerHex || binding.keyPath == \.statusLineHex
            let hex = (settings.useCustomColors || isChromeAccent)
                ? settings[keyPath: binding.keyPath]
                : nil
            binding.field.stringValue = hex ?? ""
            configureLiveAppearanceField(binding.field)
            configureColorWell(binding.well)
            configureResetButton(binding.reset)
            refreshColorBinding(binding)
        }

        minContrastField.stringValue = String(format: "%.1f", settings.minimumContrast)
        minContrastField.target = self
        minContrastField.action = #selector(appearanceTextDidCommit)

        paletteHexValues = Array(repeating: nil, count: 16)
        buildPaletteWells()
        buildAgentColorWells(settings: settings)

        scrollbackField.stringValue = String(settings.scrollbackLines)
        scrollbackField.target = self
        scrollbackField.action = #selector(appearanceTextDidCommit)

        cursorStylePopup.removeAllItems()
        cursorStylePopup.addItems(withTitles: ["Block", "Beam", "Underline"])
        cursorStylePopup.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorStylePopup.target = self
        cursorStylePopup.action = #selector(appearanceTextDidCommit)
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        cursorBlinkToggle.target = self
        cursorBlinkToggle.action = #selector(appearanceTextDidCommit)
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off
        copyOnSelectToggle.target = self
        copyOnSelectToggle.action = #selector(appearanceTextDidCommit)

        transparentTitlebarToggle.state = settings.transparentTitlebar ? .on : .off
        transparentTitlebarToggle.target = self
        transparentTitlebarToggle.action = #selector(appearanceTextDidCommit)

        useThemeColorsButton.title = "Use Theme Colors"
        useThemeColorsButton.target = self
        useThemeColorsButton.action = #selector(useThemeColors)
        useThemeColorsButton.bezelStyle = .rounded

        keyRecorder = KeyRecorderView(initial: settings.prefixKey)
        keyRecorder.onChange = { [weak self] value in
            SessionCoordinator.shared.settings.prefixKey = value.isEmpty ? "ctrl-a" : value
            try? SessionCoordinator.shared.settings.save()
            PrefixKeymap.shared.rebuildFromSettings()
            self?.refreshLivePreview()
        }

        updateFontReadout()
    }

    // MARK: - Shell layout (sidebar + paged content)

    private func layoutShell() {
        let sidebar = buildSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainer)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),

            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -12),

            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
        ])

        pages[0] = buildAppearancePage()
        pages[1] = buildTerminalPage()
        pages[2] = buildPrefixPage()
        pages[3] = buildAgentColorsPage()
    }

    private func showPage(_ index: Int) {
        for button in sidebarButtons { button.isSelected = (button.tag == index) }
        for subview in pageContainer.subviews { subview.removeFromSuperview() }
        guard let page = pages[index] else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        currentPage = index
    }

    // MARK: - Sidebar

    private var sidebarButtons: [SettingsSidebarButton] = []
    private let settingsSearch = NSSearchField()
    private static let sectionKeywords: [Int: [String]] = [
        0: ["theme", "opacity", "blur", "padding", "appearance", "background", "foreground", "transparent"],
        1: ["terminal", "font", "shell", "directory", "scrollback", "blink", "copy", "session"],
        2: ["prefix", "binding", "keybinding", "shortcut", "agent", "hook"],
        3: ["agent", "color", "codex", "claude", "cursor", "pi", "hermes", "openclaw"],
    ]

    private func buildSidebar() -> NSView {
        let container = NSVisualEffectView()
        container.material = .underWindowBackground
        container.blendingMode = .behindWindow
        container.state = .followsWindowActiveState

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false

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
            ("Terminal", "terminal"),
            ("Prefix + Agents", "keyboard"),
            ("Agent Colors", "sparkles"),
        ]
        for (index, entry) in entries.enumerated() {
            let button = SettingsSidebarButton(title: entry.0, symbol: entry.1)
            button.tag = index
            button.isSelected = index == 0
            button.target = self
            button.action = #selector(sidebarItemClicked(_:))
            buttons.addArrangedSubview(button)
            sidebarButtons.append(button)
        }

        container.addSubview(title)
        container.addSubview(settingsSearch)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            settingsSearch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            settingsSearch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            settingsSearch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: settingsSearch.bottomAnchor, constant: 14),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        return container
    }

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

    @objc private func sidebarItemClicked(_ sender: SettingsSidebarButton) {
        showPage(sender.tag)
    }

    // MARK: - Page: Appearance

    private func buildAppearancePage() -> NSView {
        // Ghostty config is imported automatically as the default theme on first
        // launch (and whenever its signature changes). No manual button — the
        // user's Ghostty config IS the default.
        let header = pageHeader(title: "Appearance", trailing: nil)

        livePreview.translatesAutoresizingMaskIntoConstraints = false

        // Theme picker is the primary control. Use Theme Colors / Reset to Defaults
        // are secondary and styled as link buttons so the row reads cleanly.
        useThemeColorsButton.title = "Use theme colors"
        styleAsLink(useThemeColorsButton)
        let resetDefaults = makeLinkButton("Reset to defaults", action: #selector(resetToDefaults))
        let themeRow = NSStackView(views: [themePopup, useThemeColorsButton, resetDefaults])
        themeRow.orientation = .horizontal
        themeRow.spacing = 14
        themeRow.alignment = .centerY
        themePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let opacityRow = NSStackView(views: [opacitySlider, opacityLabel])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 12
        opacitySlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        opacityLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        opacityLabel.alignment = .right

        let blurRow = NSStackView(views: [blurSlider, blurLabel])
        blurRow.orientation = .horizontal
        blurRow.spacing = 12
        blurSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        blurLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        blurLabel.alignment = .right

        paddingXField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        paddingYField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let paddingRow = NSStackView(views: [
            paddingXField,
            NSTextField(labelWithString: "×"),
            paddingYField,
            NSTextField(labelWithString: "pt"),
        ])
        paddingRow.orientation = .horizontal
        paddingRow.spacing = 6
        paddingRow.alignment = .centerY

        let windowGroup = formGrid(rows: [
            ("Theme", themeRow),
            ("Opacity", opacityRow),
            ("Blur", blurRow),
            ("Padding", paddingRow),
            ("", transparentTitlebarToggle),
        ])

        // Chrome accent rows: dividers + status line text. These are colorBindings
        // indices 7 and 8 since I appended them after the 7 terminal colors.
        let dividerRow = colorHexRow(title: "Divider lines", binding: colorBindings[7])
        let statusRow = colorHexRow(title: "Status line text", binding: colorBindings[8])
        let chromeAccents = NSStackView(views: [dividerRow, statusRow])
        chromeAccents.orientation = .horizontal
        chromeAccents.spacing = 28
        chromeAccents.alignment = .top
        chromeAccents.distribution = .fillEqually

        let stack = NSStackView(views: [
            header,
            livePreview,
            sectionHeading("Window"),
            windowGroup,
            sectionHeading("Chrome"),
            chromeAccents,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        return scrollWrap(stack)
    }

    private func makeLinkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        styleAsLink(button)
        return button
    }

    private func styleAsLink(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        let title = button.title
        let attr = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        button.attributedTitle = attr
        button.contentTintColor = .controlAccentColor
    }

    // MARK: - Page: Terminal

    private func buildTerminalPage() -> NSView {
        let header = pageHeader(title: "Terminal", trailing: nil)

        let chooseFont = NSButton(title: "Choose Font…", target: self, action: #selector(chooseFont))
        chooseFont.bezelStyle = .rounded
        fontReadout.font = .systemFont(ofSize: 12)
        fontReadout.textColor = .secondaryLabelColor
        let fontRow = NSStackView(views: [chooseFont, fontReadout])
        fontRow.orientation = .horizontal
        fontRow.spacing = 12
        fontRow.alignment = .centerY

        fontSizeField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        shellField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        cwdField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        scrollbackField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let fontGroup = formGrid(rows: [
            ("Font", fontRow),
            ("Size", fontSizeField),
        ])

        let shellGroup = formGrid(rows: [
            ("Shell", shellField),
            ("Default directory", cwdField),
        ])

        let behaviorGroup = formGrid(rows: [
            ("Cursor style", cursorStylePopup),
            ("Scrollback", scrollbackField),
            ("", cursorBlinkToggle),
            ("", copyOnSelectToggle),
        ])

        let stack = NSStackView(views: [
            header,
            sectionHeading("Font"),
            fontGroup,
            sectionHeading("Shell"),
            shellGroup,
            sectionHeading("Behavior"),
            behaviorGroup,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Page: Prefix + Agents

    private func buildPrefixPage() -> NSView {
        let header = pageHeader(title: "Prefix + Agents", trailing: nil)

        let prefixHint = NSTextField(labelWithString: "Click to record a new shortcut. Esc cancels.")
        prefixHint.font = .systemFont(ofSize: 11.5)
        prefixHint.textColor = .secondaryLabelColor

        let editAgents = NSButton(title: "Edit agents.json…", target: self, action: #selector(openAgentsJSON))
        editAgents.bezelStyle = .rounded

        systemNotificationsToggle.title = "Show system notifications when an agent needs attention"
        systemNotificationsToggle.setButtonType(.switch)
        systemNotificationsToggle.state = SessionCoordinator.shared.settings.systemNotificationsEnabled ? .on : .off
        systemNotificationsToggle.target = self
        systemNotificationsToggle.action = #selector(appearanceTextDidCommit)

        let prefixGroup = formGrid(rows: [
            ("Prefix key", keyRecorder),
            ("", prefixHint),
        ])
        let agentGroup = formGrid(rows: [
            ("Agent table", editAgents),
        ])
        let notificationsGroup = formGrid(rows: [
            ("", systemNotificationsToggle),
        ])

        let stack = NSStackView(views: [
            header,
            sectionHeading("Prefix"),
            prefixGroup,
            sectionHeading("Agents"),
            agentGroup,
            sectionHeading("Notifications"),
            notificationsGroup,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Page: Agent Colors

    private func buildAgentColorsPage() -> NSView {
        let header = pageHeader(title: "Agent Colors", trailing: nil)
        let caption = NSTextField(labelWithString: "Per-agent chip color shown in sidebar/tab pills.")
        caption.font = .systemFont(ofSize: 11.5)
        caption.textColor = .secondaryLabelColor

        // Two-column agent grid.
        let halves = Self.agentColorKinds.chunked(into: (Self.agentColorKinds.count + 1) / 2)
        let columns = halves.map { kinds -> NSStackView in
            let rows = kinds.map(agentColorRow)
            let s = NSStackView(views: rows)
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 8
            return s
        }
        let grid = NSStackView(views: columns)
        grid.orientation = .horizontal
        grid.spacing = 28
        grid.alignment = .top

        let reset = NSButton(title: "Reset agent colors", target: self, action: #selector(resetAgentColors))
        reset.bezelStyle = .rounded

        let stack = NSStackView(views: [header, caption, grid, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Layout helpers

    private func pageHeader(title: String, trailing: NSButton?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.addArrangedSubview(titleLabel)
        if let trailing {
            trailing.bezelStyle = .rounded
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(spacer)
            stack.addArrangedSubview(trailing)
        }
        return stack
    }

    private func sectionHeading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// Right-aligned label column + control column, like macOS System Settings.
    private func formGrid(rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            grid.addRow(with: [label, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 130
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    /// `[swatch] Name [hex] [↺]` — consistent width pattern so every row aligns.
    private func colorHexRow(title: String, binding: ColorBinding) -> NSView {
        binding.field.widthAnchor.constraint(equalToConstant: 92).isActive = true
        binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
        binding.field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        binding.field.usesSingleLineMode = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let row = NSStackView(views: [binding.well, label, binding.field, binding.reset])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    /// Wraps a page's content stack in a vertical scroll view so it remains
    /// reachable on shorter window heights without forcing every section to
    /// scroll all together.
    private func scrollWrap(_ content: NSStackView) -> NSView {
        let documentView = SettingsFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ])
        return scroll
    }

    private func makeResetButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle",
                               accessibilityDescription: "Reset to theme color")
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

    private func buildPaletteWells() {
        paletteWells.removeAll()
        for index in 0 ..< 16 {
            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 40).isActive = true
            well.heightAnchor.constraint(equalToConstant: 32).isActive = true
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

    private func paletteCell(_ index: Int) -> NSView {
        let label = NSTextField(labelWithString: "\(index)")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        let cell = NSStackView(views: [paletteWells[index], label])
        cell.orientation = .vertical
        cell.spacing = 4
        cell.alignment = .centerX
        return cell
    }

    private func agentColorRow(_ kind: AgentKind) -> NSView {
        let label = NSTextField(labelWithString: kind.displayName)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let preview = AgentChipView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 18).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 126).isActive = true
        preview.configure(text: kind.displayName, hex: SessionCoordinator.shared.settings.agentColorHex(for: kind))
        agentColorPreviews[kind] = preview

        let row = NSStackView(views: [agentColorWells[kind] ?? NSView(), label, preview])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    // MARK: - Formatting / utilities

    private func formatPercent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formatBlur(_ value: Int) -> String {
        value == 0 ? "off" : "\(value) px"
    }

    private func cursorStyleTitle(_ value: String) -> String {
        switch value {
        case "bar": return "Beam"
        case "underline": return "Underline"
        default: return "Block"
        }
    }

    private func cursorStyleValue(_ title: String?) -> String {
        switch title {
        case "Beam": return "bar"
        case "Underline": return "underline"
        default: return "block"
        }
    }

    private func updateFontReadout() {
        let s = SessionCoordinator.shared.settings
        fontReadout.stringValue = "\(s.fontFamily) · \(Int(s.fontSize.rounded()))pt"
    }

    // MARK: - Live apply

    @objc private func opacityDidChange() {
        opacityLabel.stringValue = formatPercent(Float(opacitySlider.doubleValue))
        flushAndApply()
    }

    @objc private func blurDidChange() {
        let rounded = Int(blurSlider.doubleValue.rounded())
        blurLabel.stringValue = formatBlur(rounded)
        flushAndApply()
    }

    @objc private func themeDidChange() {
        if themePopup.titleOfSelectedItem == ThemeManager.defaultDisplayName {
            // "Default" bundles the Ghostty-stock visual baseline. Reset settings,
            // then mirror every reset value into its control so the subsequent
            // flushAndApply (which reads controls back) doesn't clobber the reset.
            SessionCoordinator.shared.settings.applyGhosttyDefaults(imported: GhosttyConfigImporter.load())
            syncAppearanceControlsFromSettings()
            flushAndApply()
            refreshColorPlaceholders()
            return
        }
        clearAllCustomColors()
        flushAndApply()
        refreshColorPlaceholders()
    }

    @objc private func useThemeColors() {
        clearAllCustomColors()
        flushAndApply()
    }

    @objc private func appearanceTextDidCommit() {
        flushAndApply()
    }

    @objc private func appearanceTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField,
              let binding = colorBindings.first(where: { $0.field === field })
        else { return }
        refreshColorBinding(binding)
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || normalizedHexOrNil(raw) != nil {
            flushAndApply()
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
        flushAndApply()
    }

    @objc private func colorResetClicked(_ sender: NSButton) {
        guard let binding = colorBindings.first(where: { $0.reset === sender }) else { return }
        binding.field.stringValue = ""
        refreshColorBinding(binding)
        flushAndApply()
    }

    private func refreshColorBinding(_ binding: ColorBinding) {
        validateHexField(binding.field)
        let hasOverride = normalizedHexOrNil(binding.field.stringValue) != nil
        let effective = normalizedHexOrNil(binding.field.stringValue) ?? binding.themeColor()
        binding.well.color = effective.flatMap(NSColor.fromHex) ?? HarnessChrome.current.terminalBackground
        binding.reset.isHidden = !hasOverride
    }

    /// Resolve the live context the shared preview tile renders against.
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

    private func currentPalette() -> [NSColor] {
        let themed = ThemeManager.paletteHex(themeName: SessionCoordinator.shared.snapshot.themeName)
        return (0 ..< 16).map { idx -> NSColor in
            if let override = paletteHexValues[idx], let color = NSColor.fromHex(override) { return color }
            if idx < themed.count, let hex = themed[idx], let color = NSColor.fromHex(hex) { return color }
            return NSColor.fromHex(Self.defaultAnsiPalette[idx]) ?? .gray
        }
    }

    private func refreshLivePreview() {
        let s = SessionCoordinator.shared.settings
        let style: LiveTerminalPreview.CursorStyle
        switch s.cursorStyle {
        case "bar": style = .beam
        case "underline": style = .underline
        default: style = .block
        }
        livePreview.update(LiveTerminalPreview.State(
            colors: currentPreviewContext(),
            palette: currentPalette(),
            fontName: s.fontFamily,
            fontSize: CGFloat(s.fontSize),
            opacity: CGFloat(s.backgroundOpacity),
            cursorStyle: style,
            cursorBlink: s.cursorBlink
        ))
    }

    private func refreshColorPlaceholders() {
        for binding in colorBindings {
            binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
            refreshColorBinding(binding)
        }
    }

    @objc private func paletteWellChanged(_ sender: NSColorWell) {
        guard let index = paletteWells.firstIndex(where: { $0 === sender }) else { return }
        paletteHexValues[index] = hexString(sender.color)
        flushAndApply()
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
        flushAndApply()
    }

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

    private func syncAppearanceControlsFromSettings() {
        let settings = SessionCoordinator.shared.settings
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        blurSlider.doubleValue = Double(settings.backgroundBlur)
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        paddingXField.stringValue = String(Int(settings.windowPaddingX.rounded()))
        paddingYField.stringValue = String(Int(settings.windowPaddingY.rounded()))
        minContrastField.stringValue = String(format: "%.1f", settings.minimumContrast)
        fontFamilyField.stringValue = settings.fontFamily
        fontSizeField.stringValue = String(Int(settings.fontSize.rounded()))
        cursorStylePopup.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off
        for binding in colorBindings {
            let isChromeAccent = binding.keyPath == \.dividerHex || binding.keyPath == \.statusLineHex
            let hex = isChromeAccent ? settings[keyPath: binding.keyPath] : nil
            binding.field.stringValue = hex ?? ""
            refreshColorBinding(binding)
        }
        paletteHexValues = Array(repeating: nil, count: 16)
        for (index, well) in paletteWells.enumerated() {
            well.color = paletteHexValues[index].flatMap(NSColor.fromHex)
                ?? NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
        }
    }

    private func hexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func validateHexField(_ field: NSTextField) {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = raw.isEmpty || normalizedHexOrNil(raw) != nil
        field.textColor = valid ? .controlTextColor : .systemRed
    }

    @objc private func resetToDefaults() {
        SessionCoordinator.shared.settings.applyGhosttyDefaults(imported: GhosttyConfigImporter.load())
        syncAppearanceControlsFromSettings()
        flushAndApply()
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

    /// Single flush — push every field into HarnessSettings, save, and apply
    /// to the live terminal/window. Called from every control's action so the
    /// settings window behaves entirely live.
    private func flushAndApply() {
        let coordinator = SessionCoordinator.shared
        coordinator.settings.backgroundOpacity = HarnessSettings.clampedOpacity(Float(opacitySlider.doubleValue))
        coordinator.settings.backgroundBlur = HarnessSettings.clampedBlur(Int(blurSlider.doubleValue.rounded()))
        coordinator.settings.dividerHex = normalizedHexOrNil(dividerHexField.stringValue)
        coordinator.settings.statusLineHex = normalizedHexOrNil(statusLineHexField.stringValue)
        coordinator.settings.useCustomColors = false
        coordinator.settings.selectionBackgroundHex = nil
        coordinator.settings.selectionForegroundHex = nil
        coordinator.settings.boldColorHex = nil
        coordinator.settings.cursorTextHex = nil
        coordinator.settings.minimumContrast = 1
        coordinator.settings.paletteHex = Array(repeating: nil, count: 16)
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        coordinator.settings.windowPaddingX = Float(paddingXField.stringValue) ?? 12
        coordinator.settings.windowPaddingY = Float(paddingYField.stringValue) ?? 12
        coordinator.settings.fontSize = Float(fontSizeField.stringValue) ?? 14
        coordinator.settings.fontFamily = fontFamilyField.stringValue
        coordinator.settings.defaultShell = shellField.stringValue
        coordinator.settings.defaultCWD = cwdField.stringValue
        coordinator.settings.scrollbackLines = max(100, Int(scrollbackField.stringValue) ?? 10_000)
        coordinator.settings.cursorStyle = cursorStyleValue(cursorStylePopup.titleOfSelectedItem)
        coordinator.settings.cursorBlink = cursorBlinkToggle.state == .on
        coordinator.settings.copyOnSelect = copyOnSelectToggle.state == .on
        coordinator.settings.systemNotificationsEnabled = systemNotificationsToggle.state == .on
        try? coordinator.settings.save()

        // Only round-trip the theme through the daemon when it has actually changed —
        // otherwise scrubbing a slider would fire setTheme IPC every tick.
        if let selectedTheme = themePopup.titleOfSelectedItem,
           selectedTheme != coordinator.snapshot.themeName {
            coordinator.setTheme(selectedTheme, clearColorOverrides: false)
        } else {
            coordinator.applySettingsToHosts()
        }
        updateFontReadout()
        refreshLivePreview()
    }

    private func clampedContrast(_ raw: String) -> Double {
        guard let value = Double(raw) else { return 1 }
        return min(21, max(1, value))
    }


    @objc private func closeWindow() {
        flushAndApply()
        view.window?.close()
    }

    // MARK: - Font picker (Terminal page)

    @objc private func chooseFont() {
        let current = NSFont(name: SessionCoordinator.shared.settings.fontFamily,
                             size: CGFloat(SessionCoordinator.shared.settings.fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(SessionCoordinator.shared.settings.fontSize), weight: .regular)
        let fontManager = NSFontManager.shared
        fontManager.target = self
        fontManager.setSelectedFont(current, isMultiple: false)
        let panel = fontManager.fontPanel(true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender else { return }
        let base = NSFont(name: fontFamilyField.stringValue,
                          size: CGFloat(Float(fontSizeField.stringValue) ?? 14))
            ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
        let converted = manager.convert(base)
        fontFamilyField.stringValue = converted.familyName ?? converted.fontName
        fontSizeField.stringValue = String(format: "%.0f", converted.pointSize)
        flushAndApply()
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
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
        // Divider + status line are chrome accents — they're allowed to be set
        // without flipping `useCustomColors` on, which would otherwise also
        // override the terminal palette.
        let chromeAccentPaths: [WritableKeyPath<HarnessSettings, String?>] = [\.dividerHex, \.statusLineHex]
        let terminalColors = colorBindings.contains {
            normalizedHexOrNil($0.field.stringValue) != nil && !chromeAccentPaths.contains($0.keyPath)
        }
        return terminalColors || paletteHexValues.contains { $0 != nil }
    }

    private func syncColorWellsFromFields() {
        for binding in colorBindings { refreshColorBinding(binding) }
    }

    @objc private func openAgentsJSON() {
        let url = HarnessPaths.applicationSupport.appendingPathComponent("agents.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaults = AgentTable.default
            if let data = try? JSONEncoder().encode(defaults) {
                try? data.write(to: url, options: .atomic)
            }
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

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
}

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
            win.minSize = NSSize(width: 820, height: 600)
            win.setContentSize(NSSize(width: 880, height: 660))
            window = win
        }
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
