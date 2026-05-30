import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class SettingsViewController: NSViewController, NSFontChanging {
    private let themePopup = HarnessSelect(frame: .zero)
    private let fontSizeField = HarnessTextField()
    private let fontFamilyField = NSTextField() // backing store for the chosen font (not shown)
    private let fontReadout = NSTextField(labelWithString: "")
    private let shellField = HarnessTextField()
    private let cwdField = HarnessTextField()
    private let opacitySlider = HarnessSlider(frame: .zero)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let blurSlider = HarnessSlider(frame: .zero)
    private let blurLabel = NSTextField(labelWithString: "")
    private let paddingXField = HarnessTextField()
    private let paddingYField = HarnessTextField()
    private let backgroundHexField = HarnessTextField()
    private let foregroundHexField = HarnessTextField()
    private let cursorHexField = HarnessTextField()
    private let backgroundWell = HarnessSwatchWell(frame: .zero)
    private let foregroundWell = HarnessSwatchWell(frame: .zero)
    private let cursorWell = HarnessSwatchWell(frame: .zero)
    private let useThemeColorsButton = NSButton()
    private let scrollbackField = HarnessTextField()
    private let transparentTitlebarToggle = HarnessToggle(title: "Transparent title bar")
    private let showStatusLineToggle = HarnessToggle(title: "Show status line (bottom bar)")
    private let sidebarVisibleToggle = HarnessToggle(title: "Show sidebar")
    private let cursorStyleSegment = HarnessSegmented(frame: .zero)
    private let cursorBlinkToggle = HarnessToggle(title: "Blinking cursor")
    private let copyOnSelectToggle = HarnessToggle(title: "Copy text to clipboard on selection")
    private let keepSessionsToggle = HarnessToggle(title: "Keep sessions running after the window closes")
    private let vividColorsToggle = HarnessToggle(title: "Vivid colors (Display P3) — off = accurate sRGB")
    private let linearBlendingToggle = HarnessToggle(title: "Gamma-correct text blending")
    private let themeTerminalOutputToggle = HarnessToggle(title: "Apply theme colors to terminal output — off = canvas matches theme, output untouched")
    private let ligaturesToggle = HarnessToggle(title: "Programming ligatures (=>, !=, ->) for fonts that have them")
    private let selectionBgHexField = HarnessTextField()
    private let selectionFgHexField = HarnessTextField()
    private let boldHexField = HarnessTextField()
    private let cursorTextHexField = HarnessTextField()
    private let dividerHexField = HarnessTextField()
    private let statusLineHexField = HarnessTextField()
    private let selectionBgWell = HarnessSwatchWell(frame: .zero)
    private let selectionFgWell = HarnessSwatchWell(frame: .zero)
    private let boldWell = HarnessSwatchWell(frame: .zero)
    private let cursorTextWell = HarnessSwatchWell(frame: .zero)
    private let dividerWell = HarnessSwatchWell(frame: .zero)
    private let statusLineWell = HarnessSwatchWell(frame: .zero)
    private let systemNotificationsToggle = HarnessToggle(title: "Push notification when an agent stops or needs input")
    private let notificationSoundToggle = HarnessToggle(title: "Play a chime with notifications")
    private let livePreview = LiveTerminalPreview()
    private let pageContainer = NSView()
    private var pages: [Int: NSView] = [:]
    private var currentPage: Int = 0
    private var paletteWells: [HarnessSwatchWell] = []
    private var paletteHexValues: [String?] = Array(repeating: nil, count: 16)
    private var agentColorWells: [AgentKind: HarnessSwatchWell] = [:]
    private var agentIconViews: [AgentKind: NSImageView] = [:]
    private var colorBindings: [ColorBinding] = []
    private var keyRecorder: KeyRecorderView!
    /// Live "Installed ✓ / Install hooks" buttons keyed by agent (Agents page).
    private var hookButtons: [AgentKind: HarnessPillButton] = [:]

    private struct ColorBinding {
        let field: HarnessTextField
        let well: HarnessSwatchWell
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
        .openClaw, .openCode, .aider, .gemini, .goose,
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
        blurSlider.toolTip = "Backdrop blur for the whole window (terminal + chrome), 0–100 px."

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
                // Match MainSplitViewController.resolvedDividerColor: #1E1E1E on dark themes.
                themeColor: {
                    HarnessChrome.current.isDark
                        ? HarnessChromePalette.defaultDarkDividerHex
                        : ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName)
                }
            ),
            ColorBinding(
                field: statusLineHexField, well: statusLineWell, reset: makeResetButton(),
                keyPath: \.statusLineHex,
                themeColor: { ThemeManager.foregroundHex(themeName: SessionCoordinator.shared.snapshot.themeName) }
            ),
        ]
        for binding in colorBindings {
            // Every color is directly editable; an unset (nil) field falls back to
            // the active theme preset inside the resolver.
            let hex = settings[keyPath: binding.keyPath]
            binding.field.stringValue = hex ?? ""
            configureLiveAppearanceField(binding.field)
            configureColorWell(binding.well)
            configureResetButton(binding.reset)
            refreshColorBinding(binding)
        }

        paletteHexValues = HarnessSettings.normalizedPalette(settings.paletteHex)
        buildPaletteWells()
        buildAgentColorWells(settings: settings)

        scrollbackField.stringValue = String(settings.scrollbackLines)
        scrollbackField.target = self
        scrollbackField.action = #selector(appearanceTextDidCommit)

        cursorStyleSegment.setSegments(["Block", "Beam", "Underline"])
        cursorStyleSegment.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorStyleSegment.target = self
        cursorStyleSegment.action = #selector(appearanceTextDidCommit)
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        cursorBlinkToggle.target = self
        cursorBlinkToggle.action = #selector(appearanceTextDidCommit)
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off
        copyOnSelectToggle.target = self
        copyOnSelectToggle.action = #selector(appearanceTextDidCommit)
        // Daemon-owned (not a HarnessSettings field) — reflects snapshot truth and
        // commits via IPC on its own action.
        keepSessionsToggle.state = SessionCoordinator.shared.snapshot.keepSessionsOnQuit ? .on : .off
        keepSessionsToggle.target = self
        keepSessionsToggle.action = #selector(toggleKeepSessions)
        vividColorsToggle.state = settings.vividColors ? .on : .off
        vividColorsToggle.target = self
        vividColorsToggle.action = #selector(appearanceTextDidCommit)
        linearBlendingToggle.state = settings.linearBlending ? .on : .off
        linearBlendingToggle.target = self
        linearBlendingToggle.action = #selector(appearanceTextDidCommit)
        themeTerminalOutputToggle.state = settings.applyThemeToTerminalOutput ? .on : .off
        themeTerminalOutputToggle.target = self
        themeTerminalOutputToggle.action = #selector(appearanceTextDidCommit)
        ligaturesToggle.state = settings.ligatures ? .on : .off
        ligaturesToggle.target = self
        ligaturesToggle.action = #selector(appearanceTextDidCommit)

        transparentTitlebarToggle.state = settings.transparentTitlebar ? .on : .off
        transparentTitlebarToggle.target = self
        transparentTitlebarToggle.action = #selector(appearanceTextDidCommit)

        showStatusLineToggle.state = settings.showStatusLine ? .on : .off
        showStatusLineToggle.target = self
        showStatusLineToggle.action = #selector(appearanceTextDidCommit)

        sidebarVisibleToggle.state = settings.sidebarVisible ? .on : .off
        sidebarVisibleToggle.target = self
        sidebarVisibleToggle.action = #selector(sidebarVisibilityChanged)

        useThemeColorsButton.title = "Use Theme Colors"
        useThemeColorsButton.target = self
        useThemeColorsButton.action = #selector(useThemeColors)

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
        // The right-hand content area paints the theme canvas so the window reads as
        // one surface with the app (cards lift off it); the left nav is glassy chrome.
        view.wantsLayer = true
        view.layer?.backgroundColor = HarnessChrome.current.terminalBackground.cgColor

        let sidebar = buildSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainer)

        let doneButton = HarnessPillButton(title: "Done", kind: .secondary)
        doneButton.target = self
        doneButton.action = #selector(closeWindow)
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),

            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -10),

            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        pages[0] = buildAppearancePage()
        pages[1] = buildColorsPage()
        pages[2] = buildTerminalPage()
        pages[3] = buildKeysPage()
        pages[4] = buildAgentsPage()
        pages[5] = buildAdvancedPage()
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
    private let settingsSearch = HarnessSearchField()
    private static let sectionKeywords: [Int: [String]] = [
        0: ["appearance", "theme", "opacity", "blur", "padding", "window", "transparent", "titlebar", "sidebar"],
        1: ["colors", "color", "background", "foreground", "cursor", "selection", "palette", "ansi", "vivid", "ligatures", "divider", "status"],
        2: ["terminal", "font", "shell", "directory", "scrollback", "blink", "copy", "session"],
        3: ["keys", "prefix", "binding", "keybinding", "shortcut"],
        4: ["agents", "agent", "color", "codex", "claude", "cursor", "pi", "hermes", "openclaw", "hook", "notification", "detection"],
        5: ["advanced", "options", "status", "mouse", "mode", "clipboard", "base-index", "renumber", "monitor", "rename", "repeat", "history", "pane", "border", "tmux"],
    ]

    private func buildSidebar() -> NSView {
        // Theme-aware glass rail (real Liquid Glass on macOS 26) instead of the raw
        // system vibrancy + label colors, so the nav matches the app chrome.
        let container = NSView()
        container.wantsLayer = true
        HarnessDesign.applySidebarChrome(to: container)

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = HarnessChrome.current.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false

        settingsSearch.placeholderString = "Filter sections…"
        settingsSearch.onChange = { [weak self] query in self?.filterSections(query) }
        settingsSearch.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false

        sidebarButtons.removeAll()
        let entries: [(String, String)] = [
            ("Appearance", "paintbrush"),
            ("Colors", "paintpalette"),
            ("Terminal", "terminal"),
            ("Keys", "keyboard"),
            ("Agents", "sparkles"),
            ("Advanced", "slider.horizontal.3"),
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
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            settingsSearch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            settingsSearch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            settingsSearch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: settingsSearch.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        return container
    }

    private func filterSections(_ raw: String) {
        let query = raw.lowercased().trimmingCharacters(in: .whitespaces)
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
        let header = pageHeader(title: "Appearance", trailing: nil)
        livePreview.translatesAutoresizingMaskIntoConstraints = false

        useThemeColorsButton.title = "Use theme colors"
        styleAsLink(useThemeColorsButton)
        let resetDefaults = makeLinkButton("Reset to defaults", action: #selector(resetToDefaults))
        for link in [useThemeColorsButton, resetDefaults] {
            link.lineBreakMode = .byClipping
            link.setContentCompressionResistancePriority(.required, for: .horizontal)
            link.setContentHuggingPriority(.required, for: .horizontal)
        }
        themePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

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

        let themeActions = NSStackView(views: [useThemeColorsButton, resetDefaults])
        themeActions.orientation = .horizontal
        themeActions.spacing = 16
        themeActions.alignment = .centerY

        let themeGroup = formGrid(rows: [
            ("Theme", themePopup),
            ("", themeActions),
        ])
        let windowGroup = formGrid(rows: [
            ("Opacity", opacityRow),
            ("Blur", blurRow),
            ("Padding", paddingRow),
            ("", transparentTitlebarToggle),
            ("", showStatusLineToggle),
            ("", sidebarVisibleToggle),
        ])

        let stack = NSStackView(views: [
            header,
            livePreview,
            sectionCard("Theme", themeGroup),
            sectionCard("Window", windowGroup),
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Page: Colors

    private func buildColorsPage() -> NSView {
        let header = pageHeader(title: "Colors", trailing: nil)

        // colorBindings 0–6 are the terminal colors; 7–8 are the chrome accents. The
        // selected theme seeds every one; the user can then edit any swatch.
        let colorsGroup = NSStackView(views: [
            colorPairRow(colorHexRow(title: "Background", binding: colorBindings[0]),
                         colorHexRow(title: "Foreground", binding: colorBindings[1])),
            colorPairRow(colorHexRow(title: "Cursor", binding: colorBindings[2]),
                         colorHexRow(title: "Cursor text", binding: colorBindings[3])),
            colorPairRow(colorHexRow(title: "Selection", binding: colorBindings[4]),
                         colorHexRow(title: "Selection text", binding: colorBindings[5])),
            colorPairRow(colorHexRow(title: "Bold", binding: colorBindings[6]),
                         NSView()),
        ])
        colorsGroup.orientation = .vertical
        colorsGroup.alignment = .width
        colorsGroup.spacing = 10

        let renderingGroup = formGrid(rows: [
            ("", vividColorsToggle),
            ("", linearBlendingToggle),
            ("", themeTerminalOutputToggle),
            ("", ligaturesToggle),
        ])

        let chromeAccents = colorPairRow(
            colorHexRow(title: "Divider lines", binding: colorBindings[7]),
            colorHexRow(title: "Status line text", binding: colorBindings[8])
        )

        let stack = NSStackView(views: [
            header,
            sectionCard("Terminal colors", colorsGroup),
            sectionCard("Color rendering", renderingGroup),
            sectionCard("ANSI palette", buildPaletteSection()),
            sectionCard("Chrome", chromeAccents),
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
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
        // Monochrome link: the foreground color, never the system blue accent.
        let link = HarnessChrome.current.textPrimary
        let attr = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: link,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        button.attributedTitle = attr
        button.contentTintColor = link
    }

    // MARK: - Page: Terminal

    private func buildTerminalPage() -> NSView {
        let header = pageHeader(title: "Terminal", trailing: nil)

        let chooseFontButton = HarnessPillButton(title: "Choose font…", kind: .secondary)
        chooseFontButton.target = self
        chooseFontButton.action = #selector(chooseFont)
        fontReadout.font = .systemFont(ofSize: 12)
        fontReadout.textColor = .secondaryLabelColor
        let fontRow = NSStackView(views: [chooseFontButton, fontReadout])
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
            ("Cursor style", cursorStyleSegment),
            ("Scrollback", scrollbackField),
            ("", cursorBlinkToggle),
            ("", copyOnSelectToggle),
            ("", keepSessionsToggle),
        ])

        let stack = NSStackView(views: [
            header,
            sectionCard("Font", fontGroup),
            sectionCard("Shell", shellGroup),
            sectionCard("Behavior", behaviorGroup),
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Page: Keys

    private func buildKeysPage() -> NSView {
        let header = pageHeader(title: "Keys", trailing: nil)

        let prefixHint = NSTextField(labelWithString: "Click to record a new shortcut. Esc cancels.")
        prefixHint.font = .systemFont(ofSize: 11.5)
        prefixHint.textColor = .secondaryLabelColor

        let prefixGroup = formGrid(rows: [
            ("Prefix key", keyRecorder),
            ("", prefixHint),
        ])

        let stack = NSStackView(views: [header, sectionCard("Prefix", prefixGroup)])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    // MARK: - Page: Agents

    private func buildAgentsPage() -> NSView {
        let header = pageHeader(title: "Agents", trailing: nil)

        systemNotificationsToggle.state = SessionCoordinator.shared.settings.systemNotificationsEnabled ? .on : .off
        systemNotificationsToggle.target = self
        systemNotificationsToggle.action = #selector(appearanceTextDidCommit)
        notificationSoundToggle.state = SessionCoordinator.shared.settings.notificationSoundEnabled ? .on : .off
        notificationSoundToggle.target = self
        notificationSoundToggle.action = #selector(appearanceTextDidCommit)

        let notificationsGroup = formGrid(rows: [
            ("", systemNotificationsToggle),
            ("", notificationSoundToggle),
        ])

        let detectionCaption = settingsCaption("Harness identifies agents by walking each pane's process tree and matching the executables shown below — it works for any shell, no setup. Install hooks so an agent can ping you the moment it stops or needs input (the config is merged into the agent's own file and backed up first). Customize matching in agents.json.")
        let editAgents = HarnessPillButton(title: "Edit agents.json…", kind: .secondary)
        editAgents.target = self
        editAgents.action = #selector(openAgentsJSON)
        let detectionBox = NSStackView(views: [detectionCaption, leadingRow(editAgents)])
        detectionBox.orientation = .vertical
        detectionBox.alignment = .leading
        detectionBox.spacing = 12

        let agentRows = NSStackView(views: Self.agentColorKinds.map(agentRow))
        agentRows.orientation = .vertical
        agentRows.alignment = .width
        agentRows.spacing = 12

        let reset = HarnessPillButton(title: "Reset agent colors", kind: .secondary)
        reset.target = self
        reset.action = #selector(resetAgentColors)
        let agentsBox = NSStackView(views: [agentRows, leadingRow(reset)])
        agentsBox.orientation = .vertical
        agentsBox.alignment = .width
        agentsBox.spacing = 14

        let stack = NSStackView(views: [
            header,
            sectionCard("Notifications", notificationsGroup),
            sectionCard("Detection & hooks", detectionBox),
            sectionCard("Agents", agentsBox),
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    /// One per-agent row: brand icon + name + the executables it matches + a color-override
    /// swatch + a one-click "Install hooks" button (with installed status) where supported.
    private func agentRow(_ kind: AgentKind) -> NSView {
        let c = HarnessChrome.current
        let colorHex = SessionCoordinator.shared.settings.agentColorHex(for: kind)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        // Brand mark when one exists, else a tinted monogram (e.g. Aider) — never a blank slot.
        icon.image = AgentIconRenderer.templateImage(for: kind, size: 18)
            ?? AgentIconRenderer.monogramTemplate(kind.chip, size: 18)
        icon.contentTintColor = NSColor.fromHex(colorHex) ?? c.textSecondary
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        agentIconViews[kind] = icon

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = c.textPrimary
        let execs = NSTextField(labelWithString: executablesString(for: kind))
        execs.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        execs.textColor = c.textTertiary
        execs.lineBreakMode = .byTruncatingTail
        let textCol = NSStackView(views: [name, execs])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 1

        let leading = NSStackView(views: [icon, textCol])
        leading.orientation = .horizontal
        leading.alignment = .centerY
        leading.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 10
        if let well = agentColorWells[kind] { trailing.addArrangedSubview(well) }
        if AgentHookInstaller.canInstall(kind) {
            let installed = AgentHookInstaller.isInstalled(agent: kind)
            let button = HarnessPillButton(title: installed ? "Reinstall hooks" : "Install hooks", kind: .secondary)
            button.target = self
            button.action = #selector(installHooksClicked(_:))
            hookButtons[kind] = button
            trailing.addArrangedSubview(button)
        }

        let row = NSStackView(views: [leading, spacer, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func executablesString(for kind: AgentKind) -> String {
        let execs = AgentTable.default.entries.first { $0.kind == kind }?.executables ?? []
        return execs.isEmpty ? "—" : execs.joined(separator: ", ")
    }

    private func retintAgentIcon(_ kind: AgentKind) {
        let hex = SessionCoordinator.shared.settings.agentColorHex(for: kind)
        agentIconViews[kind]?.contentTintColor = NSColor.fromHex(hex) ?? HarnessChrome.current.textSecondary
    }

    @objc private func installHooksClicked(_ sender: HarnessPillButton) {
        guard let kind = hookButtons.first(where: { $0.value === sender })?.key else { return }
        sender.setTitleText("Installing…")
        sender.isEnabled = false
        // File I/O off-main; weak captures so a closed Settings window isn't kept alive.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak sender] in
            let outcome = Result { try AgentHookInstaller.install(agent: kind) }
            DispatchQueue.main.async {
                guard let sender else { return }
                sender.isEnabled = true
                let host = self?.view
                switch outcome {
                case .success(let result):
                    sender.setTitleText("Reinstall hooks")
                    sender.toolTip = result.backedUp.map { "Backed up your previous config to \($0.lastPathComponent)" }
                        ?? "Installed at \(result.path.path)"
                    if let host { Toast.show("Installed \(kind.displayName) hooks", in: host) }
                case .failure(let error):
                    sender.setTitleText("Install hooks")
                    sender.toolTip = "Failed: \(error.localizedDescription)"
                    if let host { Toast.show("Couldn't install \(kind.displayName) hooks", in: host) }
                }
            }
        }
    }

    // MARK: - Page: Advanced (tmux-style options)

    /// Daemon-owned `OptionStore` values, fetched on page build. Keyed by option name.
    private var advValues: [String: String] = [:]
    private enum AdvKind { case toggle, segment, field }
    private var advOptKeys: [ObjectIdentifier: (key: String, kind: AdvKind)] = [:]

    private func buildAdvancedPage() -> NSView {
        let header = pageHeader(title: "Advanced", trailing: nil)
        loadAdvancedValues()

        let statusGroup = formGrid(rows: [
            ("Status position", advSegment("status-position", ["bottom", "top"])),
            ("Status left", advField("status-left", width: 260)),
            ("Status right", advField("status-right", width: 260)),
        ])
        let statusBox = NSStackView(views: [
            settingsCaption("Format the bottom status bar (FormatString tokens like #{cwd_basename}, #{git_branch}, #{time:%H:%M}). The on/off switch is in Appearance ▸ Window."),
            statusGroup,
        ])
        statusBox.orientation = .vertical
        statusBox.alignment = .width
        statusBox.spacing = 10

        let inputGroup = formGrid(rows: [
            ("", advToggle("mouse", "Mouse reporting")),
            ("Copy-mode keys", advSegment("mode-keys", ["vi", "emacs"])),
            ("", advToggle("set-clipboard", "Programs may set the system clipboard (OSC 52)")),
        ])

        let indexGroup = formGrid(rows: [
            ("Window base index", advSegment("base-index", ["0", "1"])),
            ("Pane base index", advSegment("pane-base-index", ["0", "1"])),
            ("", advToggle("renumber-windows", "Renumber windows after one closes")),
        ])

        let titleGroup = formGrid(rows: [
            ("", advToggle("allow-rename", "Allow programs to rename a tab (OSC title)")),
            ("", advToggle("automatic-rename", "Automatic tab rename from the running command")),
            ("", advToggle("monitor-activity", "Flag a background tab on new output")),
            ("", advToggle("monitor-bell", "Flag a background tab on a terminal bell")),
            ("Silence alert (s)", advField("monitor-silence", width: 80)),
        ])

        let lifecycleGroup = formGrid(rows: [
            ("", advToggle("remain-on-exit", "Keep a dead pane so it can be respawned")),
            ("Prefix repeat (ms)", advField("repeat-time", width: 100)),
            ("History limit", advField("history-limit", width: 120)),
        ])
        let lifecycleBox = NSStackView(views: [
            lifecycleGroup,
            settingsCaption("History limit is the multiplexer scrollback; the renderer's own scrollback is in Terminal ▸ Behavior."),
        ])
        lifecycleBox.orientation = .vertical
        lifecycleBox.alignment = .width
        lifecycleBox.spacing = 8

        let borderGroup = formGrid(rows: [
            ("Pane border labels", advSegment("pane-border-status", ["off", "top", "bottom"])),
            ("Border format", advField("pane-border-format", width: 260)),
        ])

        let stack = NSStackView(views: [
            header,
            settingsCaption("Power-user options shared with the harness-cli set-option / tmux command surface. Changes apply globally and persist immediately."),
            sectionCard("Status bar", statusBox),
            sectionCard("Input", inputGroup),
            sectionCard("Indexing", indexGroup),
            sectionCard("Titles & monitoring", titleGroup),
            sectionCard("Lifecycle", lifecycleBox),
            sectionCard("Pane borders", borderGroup),
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    private func loadAdvancedValues() {
        advValues.removeAll()
        for (key, value) in OptionStore.builtinDefaults { advValues[key] = value.stringValue }
        if case let .options(entries)? = SessionCoordinator.shared.requestDaemon(.showOptions(scope: nil)) {
            for entry in entries where entry.scope == "global" { advValues[entry.key] = entry.value }
        }
    }

    private func advToggle(_ key: String, _ title: String) -> HarnessToggle {
        let toggle = HarnessToggle(title: title)
        let raw = (advValues[key] ?? "off").lowercased()
        toggle.state = (raw == "on" || raw == "true" || raw == "1") ? .on : .off
        toggle.target = self
        toggle.action = #selector(advChanged(_:))
        advOptKeys[ObjectIdentifier(toggle)] = (key, .toggle)
        return toggle
    }

    private func advSegment(_ key: String, _ values: [String]) -> HarnessSegmented {
        let segment = HarnessSegmented(frame: .zero)
        segment.setSegments(values.map { $0.capitalized })
        if let current = advValues[key] { segment.selectItem(withTitle: current.capitalized) }
        segment.target = self
        segment.action = #selector(advChanged(_:))
        advOptKeys[ObjectIdentifier(segment)] = (key, .segment)
        return segment
    }

    private func advField(_ key: String, width: CGFloat) -> HarnessTextField {
        let field = HarnessTextField()
        field.stringValue = advValues[key] ?? ""
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.target = self
        field.action = #selector(advChanged(_:))
        advOptKeys[ObjectIdentifier(field)] = (key, .field)
        return field
    }

    @objc private func advChanged(_ sender: NSObject) {
        guard let entry = advOptKeys[ObjectIdentifier(sender)] else { return }
        let raw: String
        switch entry.kind {
        case .toggle: raw = (sender as? HarnessToggle)?.state == .on ? "on" : "off"
        case .segment: raw = (sender as? HarnessSegmented)?.titleOfSelectedItem?.lowercased() ?? ""
        case .field: raw = (sender as? NSTextField)?.stringValue ?? ""
        }
        setDaemonOption(key: entry.key, rawValue: raw)
    }

    private func setDaemonOption(key: String, rawValue: String) {
        SessionCoordinator.shared.requestDaemon(.setOption(scope: "global", target: nil, key: key, rawValue: rawValue))
        advValues[key] = rawValue
        HarnessOptions.reloadFromDisk()
        // Nudge the status line + chrome to re-read the new option value.
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: ["revision": SessionCoordinator.shared.snapshot.revision,
                       "structureChanged": false,
                       "chromeChanged": false,
                       "metadataOnly": true]
        )
    }

    private func settingsCaption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = HarnessChrome.current.textTertiary
        return label
    }

    /// Wrap a control so it sits flush-left in a `.width`-aligned stack (trailing spacer).
    private func leadingRow(_ control: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [control, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    // MARK: - Layout helpers

    private func pageHeader(title: String, trailing: HarnessPillButton? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = HarnessChrome.current.textPrimary
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.addArrangedSubview(titleLabel)
        if let trailing {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(spacer)
            stack.addArrangedSubview(trailing)
        }
        return stack
    }

    /// macOS System-Settings-style grouped card: a rounded elevated surface holding
    /// an optional uppercased title and the section's content, theme-aware.
    private func sectionCard(_ title: String?, _ content: NSView) -> NSView {
        let c = HarnessChrome.current
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = c.surfaceElevated.cgColor
        card.layer?.cornerRadius = HarnessDesign.Radius.card
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = c.border.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        // .width so width-dependent content (color pair rows, form grids) lays out to
        // the full card width rather than collapsing to intrinsic size.
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let title {
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = c.textTertiary
            stack.addArrangedSubview(label)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(content)

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func sectionHeading(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        // Pin the label to the leading edge in its own container so the heading is
        // always flush-left, with a little breathing room above to separate sections.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Right-aligned label column + control column, like macOS System Settings.
    private func formGrid(rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 13
        grid.columnSpacing = 16
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            grid.addRow(with: [label, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
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

    /// Two color rows side by side, matching the chrome-accent pair layout.
    private func colorPairRow(_ first: NSView, _ second: NSView) -> NSStackView {
        let row = NSStackView(views: [first, second])
        row.orientation = .horizontal
        row.spacing = 28
        row.alignment = .top
        row.distribution = .fillEqually
        return row
    }

    /// 16 ANSI swatches in two rows of eight plus a reset link.
    private func buildPaletteSection() -> NSView {
        let topRow = NSStackView(views: (0 ..< 8).map(paletteCell))
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .top
        let bottomRow = NSStackView(views: (8 ..< 16).map(paletteCell))
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.alignment = .top
        let resetLink = makeLinkButton("Reset palette", action: #selector(resetPalette))
        let group = NSStackView(views: [topRow, bottomRow, resetLink])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 10
        return group
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
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // `.width` alignment on a vertical NSStackView does NOT reliably stretch children to
        // the stack's full width — it sizes them equal to each other. Pin every section flush
        // to the content's leading+trailing so headers/cards fill the column uniformly and
        // left-align (no right-shift, no ragged widths).
        content.alignment = .leading
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
        for section in content.arrangedSubviews {
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        return scroll
    }

    private func makeResetButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .shadowlessSquare
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle",
                               accessibilityDescription: "Reset to theme color")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = HarnessChrome.current.textTertiary
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
            let well = HarnessSwatchWell(frame: .zero)
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
            let well = HarnessSwatchWell(frame: .zero)
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
        guard let theme = themePopup.titleOfSelectedItem else { return }
        // A theme is a starting preset: seed the full editable color set, then
        // mirror it into the controls so the user edits from the theme's values.
        SessionCoordinator.shared.setTheme(theme)
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
        refreshLivePreview()
    }

    /// Re-seed all colors from the currently selected theme, discarding manual
    /// edits ("Reset to theme").
    @objc private func useThemeColors() {
        SessionCoordinator.shared.setTheme(SessionCoordinator.shared.snapshot.themeName)
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
        refreshLivePreview()
    }

    @objc private func toggleKeepSessions() {
        let keep = keepSessionsToggle.state == .on
        SessionCoordinator.shared.requestDaemon(.setKeepSessionsOnQuit(keep))
    }

    /// "Show sidebar" applies live to the main window's split (which also persists the
    /// setting), so the sidebar slides immediately rather than only on the next launch.
    @objc private func sidebarVisibilityChanged() {
        let visible = sidebarVisibleToggle.state == .on
        for window in NSApp.windows {
            if let split = window.contentViewController as? MainSplitViewController {
                split.setSidebarVisible(visible, animated: true)
            }
        }
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

    private func configureColorWell(_ well: HarnessSwatchWell) {
        well.target = self
        well.action = #selector(colorWellChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 30).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @objc private func colorWellChanged(_ sender: HarnessSwatchWell) {
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
        let c = HarnessChrome.current
        return ColorSamplePreview.Context(
            background: resolve(colorBindings[0]) ?? c.terminalBackground,
            foreground: resolve(colorBindings[1]) ?? c.textPrimary,
            cursor: resolve(colorBindings[2]) ?? c.accent,
            cursorText: resolve(colorBindings[3]) ?? c.terminalBackground,
            selectionBackground: resolve(colorBindings[4]) ?? c.textPrimary.withAlphaComponent(0.25),
            selectionForeground: resolve(colorBindings[5]) ?? c.textPrimary,
            bold: resolve(colorBindings[6]) ?? c.textPrimary
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
            blur: CGFloat(s.backgroundBlur),
            cursorStyle: style,
            cursorBlink: s.cursorBlink,
            padding: CGFloat(s.windowPaddingX)
        ))
    }

    private func refreshColorPlaceholders() {
        for binding in colorBindings {
            binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
            refreshColorBinding(binding)
        }
    }

    @objc private func paletteWellChanged(_ sender: HarnessSwatchWell) {
        guard let index = paletteWells.firstIndex(where: { $0 === sender }) else { return }
        paletteHexValues[index] = hexString(sender.color)
        flushAndApply()
    }

    @objc private func agentColorWellChanged(_ sender: HarnessSwatchWell) {
        guard let kind = agentColorWells.first(where: { $0.value === sender })?.key else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.settings.agentColorOverrides[kind.rawValue] = hexString(sender.color)
        coordinator.settings.agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(coordinator.settings.agentColorOverrides)
        retintAgentIcon(kind)
        try? coordinator.settings.save()
        coordinator.applySettingsToHosts()
    }

    @objc private func resetAgentColors() {
        let coordinator = SessionCoordinator.shared
        coordinator.settings.agentColorOverrides.removeAll()
        for (kind, well) in agentColorWells {
            well.color = NSColor.fromHex(coordinator.settings.agentColorHex(for: kind)) ?? .gray
            retintAgentIcon(kind)
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

    private func syncAppearanceControlsFromSettings() {
        let settings = SessionCoordinator.shared.settings
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        blurSlider.doubleValue = Double(settings.backgroundBlur)
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        paddingXField.stringValue = String(Int(settings.windowPaddingX.rounded()))
        paddingYField.stringValue = String(Int(settings.windowPaddingY.rounded()))
        fontFamilyField.stringValue = settings.fontFamily
        fontSizeField.stringValue = String(Int(settings.fontSize.rounded()))
        cursorStyleSegment.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off
        keepSessionsToggle.state = SessionCoordinator.shared.snapshot.keepSessionsOnQuit ? .on : .off
        vividColorsToggle.state = settings.vividColors ? .on : .off
        linearBlendingToggle.state = settings.linearBlending ? .on : .off
        themeTerminalOutputToggle.state = settings.applyThemeToTerminalOutput ? .on : .off
        ligaturesToggle.state = settings.ligatures ? .on : .off
        showStatusLineToggle.state = settings.showStatusLine ? .on : .off
        sidebarVisibleToggle.state = settings.sidebarVisible ? .on : .off
        systemNotificationsToggle.state = settings.systemNotificationsEnabled ? .on : .off
        notificationSoundToggle.state = settings.notificationSoundEnabled ? .on : .off
        for binding in colorBindings {
            binding.field.stringValue = settings[keyPath: binding.keyPath] ?? ""
            refreshColorBinding(binding)
        }
        paletteHexValues = HarnessSettings.normalizedPalette(settings.paletteHex)
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
        SessionCoordinator.shared.settings.resetToImportedConfig(imported: TerminalConfigImporter.load())
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
        // Read every editable color from its control (bg/fg/cursor/cursor-text/
        // selection/bold + divider/status accents). nil = fall back to theme preset.
        for binding in colorBindings {
            coordinator.settings[keyPath: binding.keyPath] = normalizedHexOrNil(binding.field.stringValue)
        }
        coordinator.settings.paletteHex = HarnessSettings.normalizedPalette(paletteHexValues)
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        coordinator.settings.showStatusLine = showStatusLineToggle.state == .on
        coordinator.settings.sidebarVisible = sidebarVisibleToggle.state == .on
        coordinator.settings.windowPaddingX = Float(paddingXField.stringValue) ?? 12
        coordinator.settings.windowPaddingY = Float(paddingYField.stringValue) ?? 12
        coordinator.settings.fontSize = Float(fontSizeField.stringValue) ?? 14
        coordinator.settings.fontFamily = fontFamilyField.stringValue
        coordinator.settings.defaultShell = shellField.stringValue
        coordinator.settings.defaultCWD = cwdField.stringValue
        coordinator.settings.scrollbackLines = max(100, Int(scrollbackField.stringValue) ?? 10_000)
        coordinator.settings.cursorStyle = cursorStyleValue(cursorStyleSegment.titleOfSelectedItem)
        coordinator.settings.cursorBlink = cursorBlinkToggle.state == .on
        coordinator.settings.copyOnSelect = copyOnSelectToggle.state == .on
        coordinator.settings.systemNotificationsEnabled = systemNotificationsToggle.state == .on
        coordinator.settings.notificationSoundEnabled = notificationSoundToggle.state == .on
        coordinator.settings.vividColors = vividColorsToggle.state == .on
        coordinator.settings.linearBlending = linearBlendingToggle.state == .on
        coordinator.settings.applyThemeToTerminalOutput = themeTerminalOutputToggle.state == .on
        coordinator.settings.ligatures = ligaturesToggle.state == .on
        try? coordinator.settings.save()

        // Theme switching (and its color seeding) is handled by themeDidChange, so
        // flushAndApply only ever pushes the current settings to the live surfaces —
        // scrubbing a slider never fires a setTheme IPC.
        coordinator.applySettingsToHosts()
        updateFontReadout()
        refreshLivePreview()
    }

    /// When presented inline (as a panel inside the main window) the host sets this
    /// so "Done"/Esc dismisses the panel instead of closing the whole window.
    var onClose: (() -> Void)?

    @objc private func closeWindow() {
        flushAndApply()
        if let onClose {
            onClose()
        } else {
            view.window?.close()
        }
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
        // Monochrome selection (no system blue): a subtle foreground-tinted fill.
        let c = HarnessChrome.current
        if isSelected {
            layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.12 : 0.10).cgColor
            iconView.contentTintColor = c.textPrimary
            label.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.textPrimary.withAlphaComponent(0.06).cgColor
            iconView.contentTintColor = c.textSecondary
            label.textColor = c.textPrimary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            iconView.contentTintColor = c.textTertiary
            label.textColor = c.textSecondary
        }
    }
}

/// Settings opens as a standard, movable, closable macOS window on top of the main
/// window (not embedded). A fresh controller is built on each open so the window always
/// reflects the current theme/settings; any previously open instance is closed first.
@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        window?.close()
        let controller = SettingsViewController()
        let win = NSWindow(contentViewController: controller)
        win.title = "Harness Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.isRestorable = false
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 820, height: 600)
        win.setContentSize(NSSize(width: 880, height: 660))
        // `onClose` left nil → SettingsViewController.closeWindow() falls through to
        // `view.window?.close()`, so Done/Esc dismisses this popup.
        window = win
        win.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
