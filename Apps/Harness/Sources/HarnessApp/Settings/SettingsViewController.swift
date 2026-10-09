import AppKit
import HarnessCore
import HarnessTerminalKit
import HarnessTheme
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class SettingsViewController: NSViewController, NSFontChanging {
    // Theme
    private let appearanceModeSegment = HarnessSegmented(frame: .zero)
    private let themePopup = HarnessSelect(frame: .zero)
    private let systemLightThemePopup = HarnessSelect(frame: .zero)
    private let systemDarkThemePopup = HarnessSelect(frame: .zero)
    private var appearanceModeRow: SettingsFormRow?
    private var themeRow: SettingsFormRow?
    private var lightThemeRow: SettingsFormRow?
    private var darkThemeRow: SettingsFormRow?
    // Window + panes
    private let opacitySlider = HarnessSlider(frame: .zero)
    private let opacityLabel = NSTextField(labelWithString: "")
    private let blurSlider = HarnessSlider(frame: .zero)
    private let blurLabel = NSTextField(labelWithString: "")
    private let windowBorderOpacitySlider = HarnessSlider(frame: .zero)
    private let windowBorderOpacityLabel = NSTextField(labelWithString: "")
    private let transparentTitlebarToggle = HarnessToggle(frame: .zero)
    private let machineIndicatorToggle = HarnessToggle(frame: .zero)
    private let sidebarVisibleToggle = HarnessToggle(frame: .zero)
    private let restoreWindowSizeToggle = HarnessToggle(frame: .zero)
    private let paneDensitySegment = HarnessSegmented(frame: .zero)
    private let paneHeadersToggle = HarnessToggle(frame: .zero)
    private let paneSpacingField = HarnessTextField()
    private let paddingXField = HarnessTextField()
    private let paddingYField = HarnessTextField()
    private let paddingBalanceToggle = HarnessToggle(frame: .zero)
    private let resizeOverlaySegment = HarnessSegmented(frame: .zero)
    private let resizeOverlayPositionSegment = HarnessSegmented(frame: .zero)
    private var resizeOverlayPositionRow: SettingsFormRow?
    // Colors
    private let backgroundHexField = HarnessTextField()
    private let foregroundHexField = HarnessTextField()
    private let cursorHexField = HarnessTextField()
    private let cursorTextHexField = HarnessTextField()
    private let selectionBgHexField = HarnessTextField()
    private let selectionFgHexField = HarnessTextField()
    private let boldHexField = HarnessTextField()
    private let dividerHexField = HarnessTextField()
    private let statusLineHexField = HarnessTextField()
    private let windowBorderHexField = HarnessTextField()
    private let backgroundWell = HarnessSwatchWell(frame: .zero)
    private let foregroundWell = HarnessSwatchWell(frame: .zero)
    private let cursorWell = HarnessSwatchWell(frame: .zero)
    private let cursorTextWell = HarnessSwatchWell(frame: .zero)
    private let selectionBgWell = HarnessSwatchWell(frame: .zero)
    private let selectionFgWell = HarnessSwatchWell(frame: .zero)
    private let boldWell = HarnessSwatchWell(frame: .zero)
    private let dividerWell = HarnessSwatchWell(frame: .zero)
    private let statusLineWell = HarnessSwatchWell(frame: .zero)
    private let windowBorderWell = HarnessSwatchWell(frame: .zero)
    private let minContrastSlider = HarnessSlider(frame: .zero)
    private let minContrastLabel = NSTextField(labelWithString: "")
    private let boldIsBrightToggle = HarnessToggle(frame: .zero)
    private let themeFitToggle = HarnessToggle(frame: .zero)
    private let themeTerminalOutputToggle = HarnessToggle(frame: .zero)
    private let vividColorsToggle = HarnessToggle(frame: .zero)
    // Terminal
    private let experienceSegment = HarnessSegmented(frame: .zero)
    private let experienceSummaryLabel = SettingsCaption(wrappingLabelWithString: "")
    // Per-component overrides for the chrome the experience preset would otherwise bundle. Each is
    // tri-state (Auto / On / Off): Auto follows the selected preset; On/Off pin the component
    // independently, so e.g. a Plain terminal can show a status line without arming the prefix.
    private let prefixControlSegment = HarnessSegmented(frame: .zero)
    private let statusLineControlSegment = HarnessSegmented(frame: .zero)
    private let fontSizeField = HarnessTextField()
    private let fontFamilyField = NSTextField() // backing store for the chosen font (not shown)
    private let fontReadout = NSTextField(labelWithString: "")
    private let textRenderingSegment = HarnessSegmented(frame: .zero)
    private let ligaturesToggle = HarnessToggle(frame: .zero)
    private let cursorStyleSegment = HarnessSegmented(frame: .zero)
    private let cursorBlinkToggle = HarnessToggle(frame: .zero)
    private let shellField = HarnessTextField()
    private let cwdField = HarnessTextField()
    private let inheritCWDToggle = HarnessToggle(frame: .zero)
    private let scrollbackField = HarnessTextField()
    private let scrollMultiplierSlider = HarnessSlider(frame: .zero)
    private let scrollMultiplierLabel = NSTextField(labelWithString: "")
    private let copyOnSelectToggle = HarnessToggle(frame: .zero)
    private let mouseHideToggle = HarnessToggle(frame: .zero)
    private let bellSegment = HarnessSegmented(frame: .zero)
    private let promptGutterToggle = HarnessToggle(frame: .zero)
    private let pasteProtectionToggle = HarnessToggle(frame: .zero)
    private let secureKeyboardToggle = HarnessToggle(frame: .zero)
    private let remoteControlToggle = HarnessToggle(frame: .zero)
    private let keepSessionsToggle = HarnessToggle(frame: .zero)
    private let defaultTerminalButton = NSButton(title: "Make Default", target: nil, action: nil)
    private var defaultTerminalRow: SettingsFormRow?
    // Keys
    private var keyRecorder: KeyRecorderView!
    private let optionKeySegment = HarnessSegmented(frame: .zero)
    private let quickTerminalToggle = HarnessToggle(frame: .zero)
    private var quickTerminalHotkeyRecorder: KeyRecorderView!
    // Notifications
    /// One toggle per `NotificationEvent` ("which events notify me"). Built from the enum so a
    /// new case automatically gets a wired row. Lazy so its (main-actor) `HarnessToggle`
    /// construction runs at first access inside a method, not in a stored-property initializer.
    private lazy var eventToggles: [NotificationEvent: HarnessToggle] = {
        var toggles: [NotificationEvent: HarnessToggle] = [:]
        for event in NotificationEvent.allCases {
            toggles[event] = HarnessToggle(frame: .zero)
        }
        return toggles
    }()
    private let commandFinishedThresholdField = HarnessTextField()
    private let systemNotificationsToggle = HarnessToggle(frame: .zero)
    private let notificationSoundToggle = HarnessToggle(frame: .zero)
    private let notificationTestButton = NSButton(title: "Send Test", target: nil, action: nil)
    private let notificationPermissionButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private var notificationStatusRow: SettingsFormRow?
    // Advanced
    private let offMainPipelineToggle = HarnessToggle(frame: .zero)
    private let liveResizeReflowToggle = HarnessToggle(frame: .zero)

    private let pageContainer = NSView()
    private var pages: [SettingsPane: NSView] = [:]
    /// The pane shown first; `SettingsWindowController.show(pane:)` sets it before the view loads.
    var initialPane: SettingsPane = .appearance
    private var currentPane: SettingsPane = .appearance
    /// Group-card surfaces + hairline dividers, tracked so a live theme change can
    /// re-skin them (they're created inline by the `settingsGroup` factory rather than
    /// stored individually).
    private var groupSurfaces: [NSView] = []
    private var groupDividers: [NSView] = []
    /// Text-link buttons (accent baked into the attributed title) re-tinted on theme change.
    private var linkButtons: [NSButton] = []
    private var paletteWells: [HarnessSwatchWell] = []
    private var paletteNote: NSTextField?
    private var paletteHexValues: [String?] = Array(repeating: nil, count: 16)
    private var colorBindings: [ColorBinding] = []
    /// Live "Install Hooks / Reinstall Hooks" buttons keyed by agent (Agents page).
    private var hookButtons: [AgentKind: NSButton] = [:]

    private struct ColorBinding {
        let field: HarnessTextField
        let well: HarnessSwatchWell
        let reset: NSButton
        let keyPath: WritableKeyPath<HarnessSettings, String?>
        let themeColor: () -> String?
    }

    private static let defaultAnsiPalette = ThemeManager.defaultBaselinePaletteHex
    private static let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]
    private static let agentKinds = AgentKind.allCases.filter { $0 != .generic }

    deinit {
        // A fresh controller is built on each open and the previous one is torn down; drop
        // its observers (the chrome-change observer + the per-field text-change observers
        // registered in `configureLiveAppearanceField`) so a closed window stops reacting.
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 680))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        layoutShell()
        showPage(initialPane)
        observeChromeChanges()
    }

    // MARK: - Control configuration (initial state from settings)

    private func configureControls() {
        let coordinator = SessionCoordinator.shared
        let settings = coordinator.settings

        appearanceModeSegment.setSegments(HarnessAppearanceMode.allCases.map(Self.appearanceModeTitle))
        appearanceModeSegment.selectItem(withTitle: Self.appearanceModeTitle(settings.appearanceMode))
        appearanceModeSegment.target = self
        appearanceModeSegment.action = #selector(appearanceTextDidCommit)

        populateThemePopup(themePopup, selectedThemeName: coordinator.snapshot.themeName)
        themePopup.target = self
        themePopup.action = #selector(themeDidChange)
        populateThemePopup(systemLightThemePopup, selectedThemeName: settings.systemLightThemeName)
        systemLightThemePopup.target = self
        systemLightThemePopup.action = #selector(systemLightThemeDidChange)
        populateThemePopup(systemDarkThemePopup, selectedThemeName: settings.systemDarkThemeName)
        systemDarkThemePopup.target = self
        systemDarkThemePopup.action = #selector(systemDarkThemeDidChange)

        configureSlider(opacitySlider, label: opacityLabel, range: 0.05 ... 1, value: Double(settings.backgroundOpacity),
                        action: #selector(opacityDidChange))
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        configureSlider(blurSlider, label: blurLabel, range: 0 ... 100, value: Double(settings.backgroundBlur),
                        action: #selector(blurDidChange))
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        configureSlider(windowBorderOpacitySlider, label: windowBorderOpacityLabel, range: 0 ... 1,
                        value: Double(settings.windowBorderOpacity), action: #selector(windowBorderOpacityDidChange))
        windowBorderOpacityLabel.stringValue = formatPercent(settings.windowBorderOpacity)
        configureSlider(minContrastSlider, label: minContrastLabel, range: 1 ... 21, value: settings.minimumContrast,
                        action: #selector(minContrastChanged))
        updateMinContrastLabel()
        configureSlider(scrollMultiplierSlider, label: scrollMultiplierLabel, range: 0.1 ... 10,
                        value: settings.scrollMultiplier, action: #selector(scrollMultiplierChanged))
        updateScrollMultiplierLabel()

        for (field, value) in [
            (paneSpacingField, String(format: "%.0f", settings.paneSpacing)),
            (paddingXField, String(format: "%.0f", settings.windowPaddingX)),
            (paddingYField, String(format: "%.0f", settings.windowPaddingY)),
            (fontSizeField, String(format: "%.0f", settings.fontSize)),
            (shellField, settings.defaultShell),
            (cwdField, settings.defaultCWD),
            (scrollbackField, String(settings.scrollbackLines)),
            (commandFinishedThresholdField, String(settings.commandFinishedThresholdSeconds)),
        ] {
            field.stringValue = value
            field.target = self
            field.action = #selector(appearanceTextDidCommit)
        }
        fontFamilyField.stringValue = settings.fontFamily

        colorBindings = [
            ColorBinding(
                field: backgroundHexField, well: backgroundWell, reset: makeResetButton(),
                keyPath: \.customBackgroundHex,
                themeColor: { Self.themePreview().canvasBackgroundHex }
            ),
            ColorBinding(
                field: foregroundHexField, well: foregroundWell, reset: makeResetButton(),
                keyPath: \.customForegroundHex,
                themeColor: { Self.themePreview().canvasForegroundHex }
            ),
            ColorBinding(
                field: cursorHexField, well: cursorWell, reset: makeResetButton(),
                keyPath: \.customCursorHex,
                themeColor: { Self.themePreview().cursorHex }
            ),
            ColorBinding(
                field: cursorTextHexField, well: cursorTextWell, reset: makeResetButton(),
                keyPath: \.cursorTextHex,
                themeColor: { Self.themePreview().cursorTextHex ?? Self.themePreview().canvasBackgroundHex }
            ),
            ColorBinding(
                field: selectionBgHexField, well: selectionBgWell, reset: makeResetButton(),
                keyPath: \.selectionBackgroundHex,
                themeColor: { Self.themePreview().selectionBackgroundHex }
            ),
            ColorBinding(
                field: selectionFgHexField, well: selectionFgWell, reset: makeResetButton(),
                keyPath: \.selectionForegroundHex,
                themeColor: { Self.themePreview().selectionForegroundHex }
            ),
            ColorBinding(
                field: boldHexField, well: boldWell, reset: makeResetButton(),
                keyPath: \.boldColorHex,
                themeColor: { ThemeManager.boldHex(themeName: Self.activeThemeName()) }
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
                        : Self.themePreview().canvasForegroundHex
                }
            ),
            ColorBinding(
                field: statusLineHexField, well: statusLineWell, reset: makeResetButton(),
                keyPath: \.statusLineHex,
                themeColor: { Self.themePreview().canvasForegroundHex }
            ),
            ColorBinding(
                field: windowBorderHexField, well: windowBorderWell, reset: makeResetButton(),
                keyPath: \.windowBorderHex,
                // Match MainWindowController.applyTransparency: white on dark themes, black on
                // light (opacity makes the hairline read as a faint grey).
                themeColor: { HarnessChrome.current.isDark ? "#FFFFFF" : "#000000" }
            ),
        ]
        for binding in colorBindings {
            // Every color is directly editable; an unset (nil) field falls back to
            // the active theme preset inside the resolver.
            binding.field.stringValue = settings[keyPath: binding.keyPath] ?? ""
            configureLiveAppearanceField(binding.field)
            configureColorWell(binding.well)
            refreshColorBinding(binding)
        }

        paletteHexValues = HarnessSettings.normalizedPalette(settings.paletteHex)
        buildPaletteWells()

        experienceSegment.setSegments(ExperienceMode.allCases.map(Self.experienceTitle))
        experienceSegment.selectedSegment = ExperienceMode.allCases.firstIndex(of: settings.experienceMode) ?? 0
        experienceSegment.target = self
        experienceSegment.action = #selector(experienceModeChanged)
        experienceSummaryLabel.font = .systemFont(ofSize: 11.5)
        experienceSummaryLabel.textColor = .secondaryLabelColor
        experienceSummaryLabel.stringValue = settings.experienceMode.summary(keepSessionsOnQuit: SessionCoordinator.shared.snapshot.keepSessionsOnQuit)

        // Optional Harness controls without switching experience mode, as two independent
        // tri-states. Auto follows the preset; On/Off pin each via `prefixKeyEnabled` /
        // `statusLineEnabled`. The legacy umbrella `harnessControlsEnabled` is preserved on disk and
        // acts as the fallback when a component is Auto, so existing settings keep their behavior.
        prefixControlSegment.setSegments(["Auto", "On", "Off"])
        prefixControlSegment.target = self
        prefixControlSegment.action = #selector(prefixControlChanged)
        statusLineControlSegment.setSegments(["Auto", "On", "Off"])
        statusLineControlSegment.target = self
        statusLineControlSegment.action = #selector(statusLineControlChanged)

        cursorStyleSegment.setSegments(["Block", "Beam", "Underline"])
        textRenderingSegment.setSegments(["Native", "Crisp", "Soft"])
        resizeOverlaySegment.setSegments(["After First", "Always", "Never"])
        resizeOverlayPositionSegment.setSegments(["Center", "Top Right", "Bottom Right"])
        bellSegment.setSegments(["Off", "Sound", "Flash", "Both"])
        optionKeySegment.setSegments(["Characters", "Meta", "Left Meta", "Right Meta"])
        paneDensitySegment.setSegments(["Comfortable", "Compact"])
        for segment in [cursorStyleSegment, textRenderingSegment, resizeOverlaySegment,
                        resizeOverlayPositionSegment, bellSegment, optionKeySegment, paneDensitySegment] {
            segment.target = self
            segment.action = #selector(appearanceTextDidCommit)
        }

        // Toggles that write straight through `applySettingsLive`.
        for toggle in [machineIndicatorToggle, cursorBlinkToggle, copyOnSelectToggle, vividColorsToggle, themeTerminalOutputToggle,
                       ligaturesToggle, promptGutterToggle, transparentTitlebarToggle, offMainPipelineToggle,
                       liveResizeReflowToggle, paddingBalanceToggle, mouseHideToggle, pasteProtectionToggle,
                       remoteControlToggle, boldIsBrightToggle, themeFitToggle, paneHeadersToggle,
                       inheritCWDToggle, quickTerminalToggle, notificationSoundToggle] + Array(eventToggles.values) {
            toggle.target = self
            toggle.action = #selector(appearanceTextDidCommit)
        }
        // Daemon-owned (not a HarnessSettings field) — reflects snapshot truth and
        // commits via IPC on its own action.
        keepSessionsToggle.target = self
        keepSessionsToggle.action = #selector(toggleKeepSessions)
        secureKeyboardToggle.target = self
        secureKeyboardToggle.action = #selector(secureKeyboardChanged)
        sidebarVisibleToggle.target = self
        sidebarVisibleToggle.action = #selector(sidebarVisibilityChanged)
        restoreWindowSizeToggle.target = self
        restoreWindowSizeToggle.action = #selector(restoreWindowSizeChanged)
        systemNotificationsToggle.target = self
        systemNotificationsToggle.action = #selector(systemNotificationsToggled)

        for button in [defaultTerminalButton, notificationTestButton, notificationPermissionButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        defaultTerminalButton.action = #selector(setDefaultTerminalClicked)
        notificationPermissionButton.isHidden = true // shown once macOS says it's blocking us
        notificationTestButton.action = #selector(sendTestNotification)
        notificationPermissionButton.action = #selector(openNotificationPermission)

        keyRecorder = KeyRecorderView(initial: settings.prefixKey, emptyTitle: "No prefix")
        keyRecorder.onChange = { value in
            // Empty = disable the prefix entirely (honored via `effectivePrefixKey`); don't
            // silently snap back to Ctrl-A the way the old code did.
            SettingsEditor.applyFromWindow(\.prefixKey, value, on: &SessionCoordinator.shared.settings)
            self.saveSettings()
            PrefixKeymap.shared.rebuildFromSettings()
        }
        quickTerminalHotkeyRecorder = KeyRecorderView(initial: settings.quickTerminalHotkey)
        quickTerminalHotkeyRecorder.onChange = { value in
            SettingsEditor.applyFromWindow(\.quickTerminalHotkey, value, on: &SessionCoordinator.shared.settings)
            self.saveSettings()
            QuickTerminalController.shared.rebuildFromSettings()
        }

        // Every other control's state comes from one place, so open and re-sync can't disagree.
        syncAppearanceControlsFromSettings()
    }

    private func configureSlider(
        _ slider: HarnessSlider, label: NSTextField, range: ClosedRange<Double>, value: Double, action: Selector
    ) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.onCommit = { [weak self] in self?.flushAndApply() }
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
    }

    // MARK: - Shell layout (sidebar + paged content)

    private func layoutShell() {
        view.wantsLayer = true
        view.layer?.backgroundColor = HarnessChrome.current.terminalBackground.cgColor

        let sidebar = buildSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Form.sidebarWidth),

            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        pages[.appearance] = buildAppearancePage()
        pages[.colors] = buildColorsPage()
        pages[.terminal] = buildTerminalPage()
        pages[.keys] = buildKeysPage()
        pages[.notifications] = buildNotificationsPage()
        pages[.agents] = buildAgentsPage()
        pages[.advanced] = buildAdvancedPage()
        updateDependentRows()
    }

    func showPage(_ pane: SettingsPane, refresh: Bool = true) {
        for button in sidebarButtons { button.isSelected = (button.tag == pane.rawValue) }
        for subview in pageContainer.subviews { subview.removeFromSuperview() }
        // Rebuild the Advanced page each time it's shown so it re-checks daemon reachability (and
        // re-fetches live option values): a daemon that was down when Settings opened may be back,
        // and vice-versa. The other pages are static enough to stay cached.
        if pane == .advanced, refresh { pages[.advanced] = buildAdvancedPage() }
        if pane == .notifications { refreshNotificationStatus() }
        guard let page = pages[pane] else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        currentPane = pane
    }

    // MARK: - Live theme re-skin

    /// Settings paints with `HarnessChrome.current`, so when the user switches theme (or
    /// edits bg/fg/cursor) from inside this window, observe the same chrome broadcast the
    /// main window uses and recolor every control + surface in step. Without this the
    /// Settings window would keep the palette it opened with.
    private func observeChromeChanges() {
        lastChromeSignature = chromeSignature()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chromeDidChange(_:)),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
    }

    @objc private func chromeDidChange(_ note: Notification) {
        guard note.userInfo?["chromeChanged"] as? Bool == true else { return }
        HarnessDesign.applySidebarChrome(to: sidebarContainer)
        // `flushAndApply` posts `chromeChanged` on every control action (including
        // continuous opacity/blur drags), but the palette only actually changes on a
        // theme or bg/fg/cursor edit. Skip the re-skin walk when the colors are identical
        // so dragging a slider doesn't churn every control on each tick.
        let signature = chromeSignature()
        guard signature != lastChromeSignature else { return }
        lastChromeSignature = signature
        let c = HarnessChrome.current
        view.layer?.backgroundColor = c.terminalBackground.cgColor
        sidebarTitleLabel.textColor = c.textPrimary
        // System-colored text labels track the window's light/dark appearance; updating it
        // re-renders them for free, so only surfaces + custom controls need explicit recolor.
        view.window?.appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
        view.window?.backgroundColor = c.terminalBackground
        for surface in groupSurfaces {
            surface.layer?.backgroundColor = c.surfaceElevated.cgColor
            surface.layer?.borderColor = c.border.cgColor
        }
        for divider in groupDividers { divider.layer?.backgroundColor = c.border.cgColor }
        // Re-skin every themed control. Cached pages are walked directly since only the
        // visible page is in the view tree.
        reskinControls(in: view)
        for page in pages.values { reskinControls(in: page) }
        // Re-tint links (their accent color is baked into the attributed title).
        for link in linkButtons { styleAsLink(link) }
        // Auto light/dark lands here as a chrome change too: the color wells/placeholder hex
        // read from the *theme*, so without a refresh they keep showing the old appearance's
        // palette until the window reopens.
        refreshColorPlaceholders()
    }

    private var lastChromeSignature: String?

    /// A cheap fingerprint of the palette colors that drive the control re-skin. Opacity /
    /// blur changes don't alter these, so they won't trigger a needless walk.
    private func chromeSignature() -> String {
        let c = HarnessChrome.current
        return [c.terminalBackground, c.textPrimary, c.accent]
            .map(hexString)
            .joined(separator: "|") + (c.isDark ? "·D" : "·L")
    }

    /// Recursively re-apply `applyChrome()` to every themed control under `root`.
    private func reskinControls(in root: NSView) {
        for sub in root.subviews {
            switch sub {
            case let v as HarnessTextField: v.applyChrome()
            case let v as HarnessSearchField: v.applyChrome()
            case let v as HarnessToggle: v.applyChrome()
            case let v as HarnessSlider: v.applyChrome()
            case let v as HarnessSwatchWell: v.applyChrome()
            case let v as IconTileView: v.applyChrome()
            case let v as HarnessSegmented: v.applyChrome()
            case let v as HarnessSelect: v.applyChrome()
            case let v as KeyRecorderView: v.applyChrome()
            case let v as SettingsSidebarButton: v.applyChrome()
            default: break
            }
            reskinControls(in: sub)
        }
    }

    // MARK: - Sidebar

    private let sidebarContainer = NSView()
    private var sidebarButtons: [SettingsSidebarButton] = []
    private let settingsSearch = HarnessSearchField()
    private let sidebarTitleLabel = NSTextField(labelWithString: "Settings")
    private let noResultsLabel = NSTextField(labelWithString: "No matching settings")

    private func buildSidebar() -> NSView {
        // A plain layer-backed view carrying the same themed sidebar chrome (vibrancy +
        // tint) the main window's sidebar uses — never the system `.sidebar` material,
        // which adds the system tint on top of the theme.
        let container = sidebarContainer
        container.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.applySidebarChrome(to: container)

        let title = sidebarTitleLabel
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = HarnessChrome.current.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false

        settingsSearch.placeholderString = "Search"
        settingsSearch.onChange = { [weak self] query in self?.filterSections(query) }
        settingsSearch.setAccessibilityLabel("Search settings")
        settingsSearch.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = HarnessDesign.Spacing.xxs
        buttons.translatesAutoresizingMaskIntoConstraints = false

        sidebarButtons.removeAll()
        for pane in SettingsPane.allCases {
            let button = SettingsSidebarButton(title: pane.title, symbol: pane.symbol)
            button.tag = pane.rawValue
            button.target = self
            button.action = #selector(sidebarItemClicked(_:))
            button.onArrow = { [weak self] delta in self?.moveSelection(by: delta) }
            buttons.addArrangedSubview(button)
            sidebarButtons.append(button)
        }

        noResultsLabel.font = .systemFont(ofSize: 12)
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.isHidden = true
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(settingsSearch)
        container.addSubview(buttons)
        container.addSubview(noResultsLabel)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            settingsSearch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            settingsSearch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            settingsSearch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: settingsSearch.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            noResultsLabel.topAnchor.constraint(equalTo: settingsSearch.bottomAnchor, constant: 18),
            noResultsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
        ])
        return container
    }

    /// Filter the sidebar by pane title and keywords. When the pane on screen drops out of the
    /// results, the first match takes its place, so the right side always shows a hit.
    private func filterSections(_ raw: String) {
        let query = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for button in sidebarButtons {
            guard !query.isEmpty, let pane = SettingsPane(rawValue: button.tag) else {
                button.isHidden = false
                continue
            }
            let hits = pane.title.lowercased().contains(query) || pane.keywords.contains { $0.contains(query) }
            button.isHidden = !hits
        }
        let visible = sidebarButtons.filter { !$0.isHidden }
        noResultsLabel.isHidden = !visible.isEmpty
        if !visible.contains(where: { $0.tag == currentPane.rawValue }),
           let first = visible.first, let pane = SettingsPane(rawValue: first.tag) {
            showPage(pane)
        }
    }

    /// ↑ / ↓ on a focused sidebar row move through the visible panes.
    private func moveSelection(by delta: Int) {
        let visible = sidebarButtons.filter { !$0.isHidden }
        guard let index = visible.firstIndex(where: { $0.tag == currentPane.rawValue }) else { return }
        let next = index + delta
        guard visible.indices.contains(next), let pane = SettingsPane(rawValue: visible[next].tag) else { return }
        showPage(pane)
        view.window?.makeFirstResponder(visible[next])
    }

    @objc private func sidebarItemClicked(_ sender: SettingsSidebarButton) {
        if let pane = SettingsPane(rawValue: sender.tag) { showPage(pane) }
    }

    // MARK: - Page: Appearance

    private func buildAppearancePage() -> NSView {
        for popup in [themePopup, systemLightThemePopup, systemDarkThemePopup] {
            popup.widthAnchor.constraint(equalToConstant: Form.wideControlWidth).isActive = true
        }
        let modeRow = settingsRow("Appearance", appearanceModeSegment)
        let themeRow = settingsRow("Theme", themePopup)
        let lightRow = settingsRow("Light theme", systemLightThemePopup)
        let darkRow = settingsRow("Dark theme", systemDarkThemePopup)
        appearanceModeRow = modeRow
        self.themeRow = themeRow
        lightThemeRow = lightRow
        darkThemeRow = darkRow
        let themeGroup = settingsGroup("Theme", [modeRow, themeRow, lightRow, darkRow])

        let windowGroup = settingsGroup("Window", [
            settingsRow("Opacity", sliderRow(opacitySlider, opacityLabel)),
            settingsRow("Blur", sliderRow(blurSlider, blurLabel), hint: "Frosts the desktop behind the window."),
            settingsRow("Border", sliderRow(windowBorderOpacitySlider, windowBorderOpacityLabel),
                        hint: "A hairline around the window edge. 0% hides it."),
            settingsRow("Transparent title bar", transparentTitlebarToggle),
            settingsRow("Show sidebar", sidebarVisibleToggle,
                        hint: "Sessions in a sidebar instead of tabs in the title bar. ⌘\\ switches."),
            settingsRow("Show machine indicator", machineIndicatorToggle,
                        hint: "Show this Mac or the remote host in the window controls."),
            settingsRow("Remember size and position", restoreWindowSizeToggle,
                        hint: "Reopen at your last size. When off, start at 100 columns × 30 rows."),
        ])

        paddingXField.widthAnchor.constraint(equalToConstant: Form.numberFieldWidth).isActive = true
        paddingYField.widthAnchor.constraint(equalToConstant: Form.numberFieldWidth).isActive = true
        paddingXField.setAccessibilityLabel("Horizontal padding")
        paddingYField.setAccessibilityLabel("Vertical padding")
        let paddingRow = hstack([paddingXField, unitLabel("×"), paddingYField, unitLabel("pt")], spacing: 6)
        paneSpacingField.widthAnchor.constraint(equalToConstant: Form.numberFieldWidth).isActive = true
        paneSpacingField.setAccessibilityLabel("Pane spacing")
        let panesGroup = settingsGroup("Panes", [
            settingsRow("Density", paneDensitySegment,
                        hint: "Comfortable sets panes apart as cards. Compact keeps them flush."),
            settingsRow("Pane spacing", hstack([paneSpacingField, unitLabel("pt")], spacing: 6),
                        hint: "Gap around and between panes. 0–24 pt; default \(Int(HarnessSettings.defaultPaneSpacing)). Comfortable only."),
            settingsRow("Pane headers", paneHeadersToggle,
                        hint: "Program, directory, and split buttons atop each pane. Comfortable only."),
            settingsRow("Padding", paddingRow, hint: "Space between the text and the pane edge."),
            settingsRow("Center the grid", paddingBalanceToggle,
                        hint: "Share leftover space evenly on every side."),
        ])

        let positionRow = settingsRow("Position", resizeOverlayPositionSegment)
        resizeOverlayPositionRow = positionRow
        let resizeGroup = settingsGroup("Resize", [
            settingsRow("Show size while resizing", resizeOverlaySegment,
                        hint: "After First skips the window opening."),
            positionRow,
        ])

        let restore = makeRoundedButton("Restore Defaults…", action: #selector(resetToDefaults))
        let footer = settingsFooterAction(restore, caption: "Resets appearance, colors, and font. Shell, keys, and agent settings stay.")

        return page("Appearance", [themeGroup, windowGroup, panesGroup, resizeGroup, footer])
    }

    // MARK: - Page: Colors

    private func buildColorsPage() -> NSView {
        // colorBindings 0–6 are the terminal colors; 7–9 are the chrome accents. The
        // selected theme seeds every one; the user can then edit any swatch.
        let names = ["Background", "Foreground", "Cursor", "Text under cursor", "Selection", "Selected text", "Bold text"]
        let terminalGroup = settingsGroup(
            "Terminal",
            zip(names, colorBindings.prefix(7)).map { colorRow($0, $1) },
            footer: "An empty field uses the theme's color. ↺ puts one color back."
        )

        let resetPalette = makeLinkButton("Reset", action: #selector(resetPalette))
        resetPalette.setAccessibilityLabel("Reset ANSI palette")
        let paletteGroup = settingsGroup("ANSI palette", [buildPaletteSection()], accessory: resetPalette)

        let chromeGroup = settingsGroup("Window chrome", [
            colorRow("Dividers", colorBindings[7]),
            colorRow("Status line text", colorBindings[8]),
            colorRow("Window border", colorBindings[9]),
        ])

        let legibilityGroup = settingsGroup("Legibility", [
            settingsRow("Minimum contrast", sliderRow(minContrastSlider, minContrastLabel),
                        hint: "Lifts dim text to this contrast ratio."),
            settingsRow("Bold is bright", boldIsBrightToggle, hint: "Bold text in colors 0–7 uses 8–15."),
            settingsRow("Fit program colors to theme", themeFitToggle,
                        hint: "Nudges unreadable program colors toward the theme. On in light mode by default."),
            settingsRow("Recolor program output", themeTerminalOutputToggle,
                        hint: "Programs' ANSI colors take the theme's palette. Off keeps them as written."),
            settingsRow("Wide color (Display P3)", vividColorsToggle, hint: "Richer color on P3 displays."),
        ])

        return page("Colors", accessory: themeFileMenu(),
                    [terminalGroup, paletteGroup, chromeGroup, legibilityGroup])
    }

    /// Colors ▸ Theme ▾: keep the colors on screen as a named theme in the theme menu, write
    /// them to a `.harnesstheme` file to share, or drop every edit back to the theme's colors.
    private func themeFileMenu() -> NSPopUpButton {
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.bezelStyle = .rounded
        menu.addItem(withTitle: "Theme")
        for (title, action) in [("Save as Theme…", #selector(saveAsTheme)), ("Export Theme…", #selector(exportTheme))] {
            menu.addItem(withTitle: title)
            menu.lastItem?.target = self
            menu.lastItem?.action = action
        }
        menu.menu?.addItem(.separator())
        menu.addItem(withTitle: "Revert to Theme Colors")
        menu.lastItem?.target = self
        menu.lastItem?.action = #selector(useThemeColors)
        menu.setAccessibilityLabel("Theme actions")
        return menu
    }

    @objc private func saveAsTheme() {
        let alert = NSAlert()
        alert.messageText = "Save these colors as a theme"
        alert.informativeText = "It joins the theme menu and is saved in your themes folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Theme name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try ThemeLibrary.saveCurrent(as: name)
            populateThemePopup(themePopup, selectedThemeName: name)
            Toast.show("Saved theme “\(name)”", in: view)
        } catch is ThemeLibrary.NameTaken {
            Toast.show("“\(name)” is a built-in theme; choose another name", in: view)
        } catch {
            Toast.show("Couldn't save the theme", in: view)
        }
    }

    @objc private func exportTheme() {
        let name = SessionCoordinator.shared.snapshot.themeName
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ThemeFileService.fileName(for: name)
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeDocument.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeLibrary.exportCurrent(to: url, named: url.deletingPathExtension().lastPathComponent)
            Toast.show("Exported \(url.lastPathComponent)", in: view)
        } catch {
            Toast.show("Couldn't export the theme", in: view)
        }
    }

    private func makeLinkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        styleAsLink(button)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func makeRoundedButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    private func styleAsLink(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        // The theme accent (derived from the cursor color) — never the macOS system blue.
        let link = HarnessChrome.current.accent
        let attr = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: link,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        button.attributedTitle = attr
        button.contentTintColor = link
        if !linkButtons.contains(where: { $0 === button }) { linkButtons.append(button) }
    }

    // MARK: - Page: Terminal

    private func buildTerminalPage() -> NSView {
        // Experience mode: how much of Harness is exposed (controls + default session
        // persistence). It governs terminal behavior, so it lives here rather than under
        // Appearance. The summary updates live so the choice is self-explanatory.
        experienceSegment.setAccessibilityLabel("Experience")
        let experienceContent = NSView()
        for part in [experienceSegment, experienceSummaryLabel] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            experienceContent.addSubview(part)
            part.leadingAnchor.constraint(equalTo: experienceContent.leadingAnchor).isActive = true
            part.trailingAnchor.constraint(equalTo: experienceContent.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            experienceSegment.topAnchor.constraint(equalTo: experienceContent.topAnchor),
            experienceSummaryLabel.topAnchor.constraint(equalTo: experienceSegment.bottomAnchor, constant: HarnessDesign.Spacing.md),
            experienceSummaryLabel.bottomAnchor.constraint(equalTo: experienceContent.bottomAnchor),
        ])
        let experienceGroup = settingsGroup("Experience", [
            experienceContent,
            settingsRow("Command prefix", prefixControlSegment, hint: "Auto follows the experience."),
            settingsRow("Status line", statusLineControlSegment, hint: "Auto follows the experience."),
        ])

        let chooseFontButton = makeRoundedButton("Choose…", action: #selector(chooseFont))
        chooseFontButton.setAccessibilityLabel("Choose font")
        fontReadout.textColor = .labelColor
        fontReadout.lineBreakMode = .byTruncatingTail
        fontReadout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontSizeField.widthAnchor.constraint(equalToConstant: Form.numberFieldWidth).isActive = true
        let fontGroup = settingsGroup("Font", [
            settingsRow("Font", hstack([fontReadout, chooseFontButton], spacing: 10)),
            settingsRow("Size", hstack([fontSizeField, unitLabel("pt")], spacing: 6), hint: "8–32 pt. ⌘+ and ⌘− change it too."),
            settingsRow("Text rendering", textRenderingSegment, hint: "Crisp draws glyphs lighter, Soft heavier."),
            settingsRow("Ligatures", ligaturesToggle, hint: "Joins => != -> in fonts that have them."),
        ])

        let cursorGroup = settingsGroup("Cursor", [
            settingsRow("Style", cursorStyleSegment),
            settingsRow("Blink", cursorBlinkToggle),
        ])

        shellField.widthAnchor.constraint(equalToConstant: Form.wideControlWidth).isActive = true
        cwdField.widthAnchor.constraint(equalToConstant: Form.wideControlWidth).isActive = true
        let shellGroup = settingsGroup("Shell", [
            settingsRow("Shell", shellField),
            settingsRow("Start in", cwdField, hint: "The directory a new session opens in."),
            settingsRow("New tabs use the current directory", inheritCWDToggle,
                        hint: "Off opens every tab in the directory above."),
        ])

        scrollbackField.widthAnchor.constraint(equalToConstant: Form.wideNumberFieldWidth).isActive = true
        let scrollGroup = settingsGroup("Scrolling", [
            settingsRow("Scrollback", hstack([scrollbackField, unitLabel("lines")], spacing: 6),
                        hint: "0 removes the line cap. Decoded history and raw output each retain up to 512 MiB per pane."),
            settingsRow("Scroll speed", sliderRow(scrollMultiplierSlider, scrollMultiplierLabel)),
        ])

        let inputGroup = settingsGroup("Input and output", [
            settingsRow("Copy on select", copyOnSelectToggle),
            settingsRow("Hide pointer while typing", mouseHideToggle),
            settingsRow("Bell", bellSegment, hint: "When a program rings the bell in the pane you're in."),
            settingsRow("Prompt marks", promptGutterToggle,
                        hint: "A green or red stripe beside each prompt for the last command. Needs shell integration."),
        ])

        let securityGroup = settingsGroup("Security", [
            settingsRow("Paste protection", pasteProtectionToggle,
                        hint: "Ask before pasting several lines or control characters."),
            settingsRow("Secure keyboard entry", secureKeyboardToggle,
                        hint: "Other apps can't read what you type while Harness is in front."),
            settingsRow("Remote control", remoteControlToggle,
                        hint: "Lets a client over an SSH tunnel run app actions. This Mac always can."),
        ])

        let defaultRow = settingsRow("Default terminal", defaultTerminalButton)
        defaultTerminalRow = defaultRow
        refreshDefaultTerminalStatus()
        let sessionsGroup = settingsGroup("Sessions", [
            settingsRow("Keep sessions running", keepSessionsToggle,
                        hint: "Sessions keep running after you quit, ready to reattach."),
            defaultRow,
        ])

        return page("Terminal", [experienceGroup, fontGroup, cursorGroup, shellGroup, scrollGroup,
                                 inputGroup, securityGroup, sessionsGroup])
    }

    // MARK: - Page: Keys

    private func buildKeysPage() -> NSView {
        let keyboardGroup = settingsGroup("Keyboard", [
            settingsRow("Prefix key", keyRecorder, hint: "Click, then press a shortcut. Clear it to turn the prefix off."),
            settingsRow("Option key", optionKeySegment,
                        hint: "Characters types what your layout gives (@, é). Meta sends Esc+key for Emacs and readline."),
        ], footer: "The prefix is armed when Terminal ▸ Experience ▸ Command prefix allows it.")

        let quickTerminalGroup = settingsGroup("Quick terminal", [
            settingsRow("Quick terminal", quickTerminalToggle,
                        hint: "A terminal that drops from the top of the screen, over any app."),
            settingsRow("Hotkey", quickTerminalHotkeyRecorder),
        ])

        let shortcuts = makeRoundedButton("Keyboard Shortcuts…", action: #selector(showKeyboardShortcuts))
        let footer = settingsFooterAction(shortcuts, caption: "Every shortcut, menu key, and binding in one list (⌘/).")

        return page("Keys", [keyboardGroup, quickTerminalGroup, footer])
    }

    @objc private func showKeyboardShortcuts() {
        KeyboardShortcutsWindow.shared.toggle()
    }

    // MARK: - Page: Notifications

    private func buildNotificationsPage() -> NSView {
        commandFinishedThresholdField.widthAnchor.constraint(equalToConstant: Form.numberFieldWidth).isActive = true
        // "Which events notify me" — one row per NotificationEvent, in enum order. The
        // command-finished row carries its runtime threshold as a sub-row. State/target are
        // wired in `configureControls` (the authoritative seed, so a flush can never clobber
        // settings with unseeded toggles); here we only lay out the rows.
        var eventRows: [NSView] = []
        for event in NotificationEvent.allCases {
            guard let toggle = eventToggles[event] else { continue }
            eventRows.append(settingsRow(event.title, toggle, hint: event.detail))
            if event == .commandFinished {
                eventRows.append(settingsRow("Threshold", hstack([commandFinishedThresholdField, unitLabel("seconds")], spacing: 6)))
            }
        }
        let notifyGroup = settingsGroup("Notify me when", eventRows,
                                        footer: "Only for panes you aren't looking at. Several at once arrive as one notification.")

        let statusRow = settingsRow("macOS permission", hstack([notificationTestButton, notificationPermissionButton], spacing: 8))
        notificationStatusRow = statusRow
        let deliveryGroup = settingsGroup("Delivery", [
            settingsRow("Show banners", systemNotificationsToggle),
            settingsRow("Play sound", notificationSoundToggle, hint: "Chimes even with banners off."),
            statusRow,
        ])
        refreshNotificationStatus()

        return page("Notifications", [notifyGroup, deliveryGroup])
    }

    @objc private func sendTestNotification() {
        DesktopNotifier.sendTest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshNotificationStatus() }
    }

    /// Toggling banners on is only meaningful if macOS is also allowing them. So when the user
    /// enables the setting, trigger the system permission prompt (or route to System Settings if
    /// already denied) — otherwise the toggle would silently produce nothing on a fresh install.
    @objc private func systemNotificationsToggled() {
        flushAndApply()
        if systemNotificationsToggle.state == .on {
            DesktopNotifier.requestOrOpenSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshNotificationStatus() }
    }

    @objc private func openNotificationPermission() {
        DesktopNotifier.requestOrOpenSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshNotificationStatus() }
    }

    /// Pull the live macOS permission state into the row so the user can tell whether the
    /// system is allowing alerts at all (the common reason agent notifications never appear).
    private func refreshNotificationStatus() {
        DesktopNotifier.authorizationStatus { [weak self] status in
            guard let self else { return }
            let text: String
            let needsAllow: Bool
            switch status {
            case .authorized, .provisional:
                text = "Allowed."
                needsAllow = false
            case .denied:
                text = "macOS is blocking Harness notifications. Allow them in System Settings ▸ Notifications."
                needsAllow = true
            case .notDetermined:
                text = "Not asked yet. Send a test to grant it."
                needsAllow = false
            @unknown default:
                text = ""
                needsAllow = true
            }
            self.notificationStatusRow?.hint = text
            self.notificationPermissionButton.isHidden = !needsAllow
        }
    }

    // MARK: - Page: Agents

    private func buildAgentsPage() -> NSView {
        let agentsGroup = settingsGroup(
            "Agents", Self.agentKinds.map(agentRow),
            footer: "Harness identifies these tools when you run them in a pane. Install each CLI separately. Where available, optional hooks report when the agent stops or needs input; Harness backs up existing hook configuration before changing it."
        )

        let detectionGroup = settingsGroup("Setup", [
            settingsRow("Detection rules", makeRoundedButton("Edit agents.json…", action: #selector(openAgentsJSON)),
                        hint: "Which executables count as each agent."),
            settingsRow("Setup prompt", makeRoundedButton("Copy Prompt", action: #selector(copySetupPrompt)),
                        hint: "For a tool without one-click hooks: paste it into the agent and it wires up its own."),
        ])

        return page("Agents", [agentsGroup, detectionGroup])
    }

    /// The same designed badge used by tabs, plus detection details and hook setup.
    private func agentRow(_ kind: AgentKind) -> NSView {
        let icon = IconTileView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.apply(.agent(kind))

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = .systemFont(ofSize: 13)
        name.textColor = .labelColor
        let execs = NSTextField(labelWithString: executablesString(for: kind))
        execs.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        execs.textColor = .secondaryLabelColor
        execs.lineBreakMode = .byTruncatingTail
        execs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textCol = NSStackView(views: [name, execs])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 1
        textCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 10
        trailing.setHuggingPriority(.required, for: .vertical)
        if AgentHookInstaller.canInstall(kind) {
            let health = AgentHookInstaller.health(agent: kind)
            let installed = health == .current || health == .outdated
            let button = NSButton(title: health == .outdated ? "Update Hooks" : installed ? "Reinstall Hooks" : "Install Hooks", target: self, action: #selector(installHooksClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setAccessibilityLabel("\(installed ? "Reinstall" : "Install") \(kind.displayName) hooks")
            button.toolTip = health.rawValue
            hookButtons[kind] = button
            trailing.addArrangedSubview(button)
        }

        let row = NSStackView(views: [icon, textCol, spacer(), trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func executablesString(for kind: AgentKind) -> String {
        let execs = AgentTable.default.entries.first { $0.kind == kind }?.executables ?? []
        return execs.isEmpty ? "—" : execs.joined(separator: ", ")
    }

    @objc private func copySetupPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentHookInstaller.setupPrompt, forType: .string)
        Toast.show("Setup prompt copied — paste it into your agent", in: view)
    }

    @objc private func installHooksClicked(_ sender: NSButton) {
        guard let kind = hookButtons.first(where: { $0.value === sender })?.key else { return }
        sender.title = "Installing…"
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
                    sender.title = "Reinstall Hooks"
                    sender.toolTip = result.backedUp.map { "Backed up your previous config to \($0.lastPathComponent)" }
                        ?? "Installed at \(result.path.path)"
                    if let host { Toast.show("Installed \(kind.displayName) hooks", in: host) }
                case .failure(let error):
                    sender.title = "Install Hooks"
                    sender.toolTip = "Failed: \(error.localizedDescription)"
                    if let host { Toast.show("Couldn't install \(kind.displayName) hooks", in: host) }
                }
            }
        }
    }

    // MARK: - Page: Advanced (harness-cli set-option surface)

    /// Daemon-owned `OptionStore` values, fetched on page build. Keyed by option name.
    private var advValues: [String: String] = [:]
    private enum AdvKind { case toggle, segment, field }
    private var advOptKeys: [ObjectIdentifier: (key: String, kind: AdvKind)] = [:]
    /// Whether the last `loadAdvancedValues` reached the daemon. False = the overlaid values are
    /// builtin defaults, NOT the live daemon state — so the page warns and disables its controls
    /// (a change couldn't be applied) instead of silently presenting defaults as if real.
    private var advDaemonReachable = false
    private var advLoading = false
    /// The daemon-backed controls (set-option surface), disabled when the daemon is unreachable.
    /// Excludes the performance toggles, which write local settings and stay usable offline.
    private var advDaemonControls: [NSControl] = []

    private func buildAdvancedPage(refresh: Bool = true) -> NSView {
        advDaemonControls.removeAll() // repopulated by the adv* factories below
        // The adv* controls are rebuilt on every Advanced-page show, so the prior batch's identifiers
        // are stale (keyed by ObjectIdentifier of freed controls). Clear the map alongside the control
        // list, otherwise it grows unbounded across reopens.
        advOptKeys.removeAll()
        if refresh { loadAdvancedValues() }
        // The performance toggles are member controls (not rebuilt by the adv* factories), so unlike
        // the daemon-backed controls they don't get refreshed by `loadAdvancedValues`. Re-read their
        // state from settings here so a rebuilt page reflects changes made since the last build.
        let perfSettings = SessionCoordinator.shared.settings
        offMainPipelineToggle.state = perfSettings.offMainParserFramePipeline ? .on : .off
        liveResizeReflowToggle.state = perfSettings.liveResizeReflow ? .on : .off

        let performanceGroup = settingsGroup("Performance", [
            settingsRow("Off-main render pipeline", offMainPipelineToggle,
                        hint: "Parse output and build frames off the main thread."),
            settingsRow("Real-time resize", liveResizeReflowToggle,
                        hint: "Reflow the running program while you drag the window edge."),
        ], footer: "Both are on by default; turn one off only to rule it out.")

        let statusGroup = settingsGroup("Status line", [
            settingsRow("Position", advSegment("status-position", ["bottom", "top"])),
            settingsRow("Left", advField("status-left", width: Form.wideControlWidth)),
            settingsRow("Right", advField("status-right", width: Form.wideControlWidth)),
        ], footer: "Format strings like #{cwd_basename}, #{git_branch}, #{time:%H:%M}. Show or hide it in Terminal ▸ Experience.")

        let inputGroup = settingsGroup("Input", [
            settingsRow("Mouse reporting", advToggle("mouse")),
            settingsRow("Copy-mode keys", advSegment("mode-keys", ["vi", "emacs"])),
            settingsRow("Word separators", advField("word-separators", width: Form.wideNumberFieldWidth),
                        hint: "Characters copy mode's w, b, and e stop at."),
            settingsRow("Programs can copy", advToggle("set-clipboard"), hint: "OSC 52 clipboard writes."),
            settingsRow("Programs can read the clipboard", advToggle("allow-clipboard-read"),
                        hint: "OSC 52 clipboard reads. Off by default."),
        ])

        let identityGroup = settingsGroup("Terminal identity", [
            settingsRow("Report as", advSegment(TerminalIdentity.optionKey, TerminalIdentity.Mode.allCases.map(\.rawValue))),
        ], footer: "What TERM_PROGRAM and XTVERSION say. Compatible lets tools like Claude Code turn on Shift+Enter right away; Harness reports its own name and version. Applies to new panes.")

        let indexGroup = settingsGroup("Numbering", [
            settingsRow("First window", advSegment("base-index", ["0", "1"])),
            settingsRow("First pane", advSegment("pane-base-index", ["0", "1"])),
            settingsRow("Renumber windows", advToggle("renumber-windows"), hint: "Close the gap when a window closes."),
        ])

        let titleGroup = settingsGroup("Titles and monitoring", [
            settingsRow("Programs set tab titles", advToggle("allow-rename")),
            settingsRow("Automatic rename", advToggle("automatic-rename"), hint: "Name tabs after the running program."),
            settingsRow("Monitor activity", advToggle("monitor-activity")),
            settingsRow("Monitor bell", advToggle("monitor-bell")),
            settingsRow("Silence alert", hstack([advField("monitor-silence", width: Form.numberFieldWidth), unitLabel("seconds")], spacing: 6),
                        hint: "0 turns it off."),
        ])

        let lifecycleGroup = settingsGroup("Lifecycle", [
            settingsRow("Remain on exit", advToggle("remain-on-exit"), hint: "Keep a pane on screen after its program exits."),
            settingsRow("Prefix repeat", hstack([advField("repeat-time", width: Form.numberFieldWidth), unitLabel("ms")], spacing: 6)),
            settingsRow("History limit", hstack([advField("history-limit", width: Form.wideNumberFieldWidth), unitLabel("lines")], spacing: 6),
                        hint: "The session's scrollback. The window's own is in Terminal ▸ Scrolling."),
        ])

        let borderGroup = settingsGroup("Pane borders", [
            settingsRow("Labels", advSegment("pane-border-status", ["off", "top", "bottom"])),
            settingsRow("Format", advField("pane-border-format", width: Form.wideControlWidth)),
        ])

        // When the daemon is unreachable these groups show builtin defaults, NOT the live state, and
        // a change can't be applied — so disable the daemon-backed controls and warn inline at the
        // top. The performance toggles (local settings) stay usable. Re-checked each time the page is
        // shown (see `showPage`). The set-option surface depends on the daemon, so it's gated here.
        if !advDaemonReachable {
            for control in advDaemonControls { control.isEnabled = false }
        }
        var sections: [NSView] = advDaemonReachable ? [] : [advUnreachableBanner()]
        sections += [performanceGroup, statusGroup, inputGroup, identityGroup, indexGroup,
                     titleGroup, lifecycleGroup, borderGroup]
        return page("Advanced", subtitle: "Options shared with harness-cli set-option. Changes apply everywhere at once.", sections)
    }

    /// Inline warning shown atop the Advanced page when the daemon is unreachable: the controls
    /// below show builtin defaults, not live state, and edits can't be applied. Uses the chrome's
    /// danger color so it reads as a real warning, consistent with the rest of Settings.
    private func advUnreachableBanner() -> NSView {
        let c = HarnessChrome.current
        // The danger hue is tuned for dark canvases; on paper it needs more ink to read.
        let ink = c.isDark ? c.danger : (c.danger.blended(withFraction: 0.4, of: .black) ?? c.danger)
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.cornerRadius = HarnessDesign.Radius.card
        banner.layer?.cornerCurve = .continuous
        banner.layer?.backgroundColor = c.danger.withAlphaComponent(0.12).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = c.danger.withAlphaComponent(0.35).cgColor
        let label = NSTextField(wrappingLabelWithString:
            "The daemon isn't reachable. These are the defaults, and changes can't be applied until it's back.")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: Form.rowInsetX),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -Form.rowInsetX),
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
        ])
        return banner
    }

    private func loadAdvancedValues() {
        guard !advLoading else { return }
        if advValues.isEmpty {
            for (key, value) in OptionStore.builtinDefaults { advValues[key] = value.stringValue }
        }
        advLoading = true
        SessionCoordinator.shared.requestDaemonAsync(.showOptions(scope: nil), refresh: false) { [weak self] response in
            guard let self else { return }
            self.advLoading = false
            if case let .options(entries)? = response {
                for entry in entries where entry.scope == "global" { self.advValues[entry.key] = entry.value }
                self.advDaemonReachable = true
            } else { self.advDaemonReachable = false }
            self.pages[.advanced] = self.buildAdvancedPage(refresh: false)
            if self.currentPane == .advanced { self.showPage(.advanced, refresh: false) }
        }
    }

    private func advToggle(_ key: String) -> HarnessToggle {
        let toggle = HarnessToggle(frame: .zero)
        let raw = (advValues[key] ?? "off").lowercased()
        toggle.state = (raw == "on" || raw == "true" || raw == "1") ? .on : .off
        toggle.target = self
        toggle.action = #selector(advChanged(_:))
        advOptKeys[ObjectIdentifier(toggle)] = (key, .toggle)
        advDaemonControls.append(toggle)
        return toggle
    }

    private func advSegment(_ key: String, _ values: [String]) -> HarnessSegmented {
        let segment = HarnessSegmented(frame: .zero)
        segment.setSegments(values.map { $0.capitalized })
        if let current = advValues[key] { segment.selectItem(withTitle: current.capitalized) }
        segment.target = self
        segment.action = #selector(advChanged(_:))
        advOptKeys[ObjectIdentifier(segment)] = (key, .segment)
        advDaemonControls.append(segment)
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
        advDaemonControls.append(field)
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
        SessionCoordinator.shared.requestDaemonAsync(DaemonSettingsControls.request(key: key, rawValue: rawValue))
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

    // MARK: - Form primitives

    /// One scrolling page: a title (with an optional trailing control and subtitle) over its
    /// groups, in a column that fills the pane up to `Form.maxWidth` and centers beyond it.
    private func page(_ title: String, subtitle: String? = nil, accessory: NSView? = nil, _ sections: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.setAccessibilityRole(.staticText)
        var headerViews: [NSView] = [titleLabel, spacer()]
        if let accessory { headerViews.append(accessory) }
        let header = hstack(headerViews, spacing: 12)
        var top: [NSView] = [header]
        if let subtitle { top.append(caption(subtitle)) }
        let headerBlock = NSStackView(views: top)
        headerBlock.orientation = .vertical
        headerBlock.alignment = .width
        headerBlock.spacing = HarnessDesign.Spacing.sm
        for part in top {
            part.leadingAnchor.constraint(equalTo: headerBlock.leadingAnchor).isActive = true
            part.trailingAnchor.constraint(equalTo: headerBlock.trailingAnchor).isActive = true
        }

        let stack = NSStackView(views: [headerBlock] + sections)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Form.groupSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in stack.arrangedSubviews {
            section.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            section.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        return scrollWrap(stack)
    }

    /// One settings row: title (and an optional hint under it) on the left, the control on the
    /// right. The control is labeled for VoiceOver with the row's title.
    @discardableResult
    private func settingsRow(_ title: String, _ control: NSView, hint: String? = nil) -> SettingsFormRow {
        labelForAccessibility(control, title)
        return SettingsFormRow(title: title, hint: hint, control: control)
    }

    /// VoiceOver names the first unlabeled control inside `view` after its row.
    private func labelForAccessibility(_ view: NSView, _ title: String) {
        if view is NSControl || view is KeyRecorderView {
            if (view.accessibilityLabel() ?? "").isEmpty { view.setAccessibilityLabel(title) }
            return
        }
        let first = view.subviews.first { sub in
            guard let control = sub as? NSControl else { return sub is KeyRecorderView }
            return (control as? NSTextField)?.isEditable ?? true
        }
        if let first { labelForAccessibility(first, title) }
    }

    /// `[swatch] [#hex] [↺]` for one editable color; ↺ only shows while the color is overridden.
    private func colorRow(_ title: String, _ binding: ColorBinding) -> NSView {
        binding.field.widthAnchor.constraint(equalToConstant: Form.hexFieldWidth).isActive = true
        binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
        binding.field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        binding.field.setAccessibilityLabel("\(title) hex")
        binding.well.setAccessibilityLabel("\(title) color")
        binding.well.toolTip = title
        binding.reset.setAccessibilityLabel("Use the theme's \(title.lowercased())")
        let resetSlot = NSView()
        resetSlot.translatesAutoresizingMaskIntoConstraints = false
        binding.reset.translatesAutoresizingMaskIntoConstraints = false
        resetSlot.addSubview(binding.reset)
        NSLayoutConstraint.activate([
            resetSlot.widthAnchor.constraint(equalToConstant: 20),
            resetSlot.heightAnchor.constraint(equalToConstant: 20),
            binding.reset.widthAnchor.constraint(equalToConstant: 18),
            binding.reset.heightAnchor.constraint(equalToConstant: 18),
            binding.reset.centerXAnchor.constraint(equalTo: resetSlot.centerXAnchor),
            binding.reset.centerYAnchor.constraint(equalTo: resetSlot.centerYAnchor),
        ])
        return SettingsFormRow(title: title, hint: nil, control: hstack([resetSlot, binding.field, binding.well], spacing: 8))
    }

    /// A rounded card of rows separated by inset hairlines, under an optional heading (with an
    /// optional trailing link) and over an optional footnote.
    private func settingsGroup(
        _ title: String?, _ rows: [NSView], accessory: NSView? = nil, footer: String? = nil
    ) -> NSView {
        let group = SettingsGroupView()
        if title != nil || accessory != nil {
            let label = NSTextField(labelWithString: title ?? "")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.setAccessibilityRole(.staticText)
            let header = hstack(accessory.map { [label, spacer(), $0] } ?? [label], spacing: 8)
            group.addArrangedSubview(header)
            group.setCustomSpacing(HarnessDesign.Spacing.md, after: header)
            header.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 2).isActive = true
            header.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -2).isActive = true
        }

        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = HarnessChrome.current.surfaceElevated.cgColor
        surface.layer?.cornerRadius = HarnessDesign.Radius.card
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = HarnessChrome.current.border.cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        groupSurfaces.append(surface)

        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 0
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, content) in rows.enumerated() {
            let divider = index > 0 ? groupDivider() : nil
            if let divider { rowStack.addArrangedSubview(divider) }
            let wrapper = paddedRow(content)
            rowStack.addArrangedSubview(wrapper)
            group.track(row: content, wrapper: wrapper, divider: divider)
        }
        // A vertical stack only matches its children's widths to each other; pin each to the card.
        for view in rowStack.arrangedSubviews {
            view.leadingAnchor.constraint(equalTo: rowStack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: rowStack.trailingAnchor).isActive = true
        }
        surface.addSubview(rowStack)
        group.addArrangedSubview(surface)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 2),
            rowStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -2),
            surface.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: group.trailingAnchor),
        ])

        if let footer {
            let note = caption(footer)
            group.setCustomSpacing(HarnessDesign.Spacing.sm, after: surface)
            group.addArrangedSubview(note)
            note.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 2).isActive = true
            note.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -2).isActive = true
        }
        return group
    }

    /// A button under the last group with a line saying what it does (Restore Defaults…).
    private func settingsFooterAction(_ button: NSButton, caption text: String) -> NSView {
        let note = caption(text)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = hstack([button, note], spacing: 12)
        row.alignment = .centerY
        return row
    }

    /// Uniform insets around one group row (content provides its own height).
    private func paddedRow(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Form.rowInsetY),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Form.rowInsetY),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Form.rowInsetX),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Form.rowInsetX),
        ])
        return container
    }

    private func groupDivider() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HarnessChrome.current.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        groupDividers.append(line)
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: Form.rowInsetX),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -Form.rowInsetX),
        ])
        return wrap
    }

    /// Show or hide one row of a group, dividers included.
    private func setRow(_ row: NSView?, hidden: Bool) {
        guard let row else { return }
        let group = sequence(first: row as NSView, next: { $0.superview }).first { $0 is SettingsGroupView } as? SettingsGroupView
        group?.setRow(row, hidden: hidden)
    }

    /// 16 ANSI swatches in two rows of eight that span the card, each over its index.
    private func buildPaletteSection() -> NSView {
        func paletteRow(_ range: Range<Int>) -> NSStackView {
            let row = NSStackView(views: range.map(paletteCell))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = HarnessDesign.Spacing.md
            row.alignment = .top
            return row
        }
        let note = caption("A light canvas uses the light theme's colors, so these follow the theme there.")
        paletteNote = note
        let group = NSStackView(views: [paletteRow(0 ..< 8), paletteRow(8 ..< 16), note])
        group.orientation = .vertical
        group.alignment = .width
        group.spacing = HarnessDesign.Spacing.lg
        for row in group.arrangedSubviews {
            row.leadingAnchor.constraint(equalTo: group.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: group.trailingAnchor).isActive = true
        }
        refreshPaletteWells()
        return group
    }

    private func paletteCell(_ index: Int) -> NSView {
        let label = NSTextField(labelWithString: "\(index)")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let cell = NSStackView(views: [paletteWells[index], label])
        cell.orientation = .vertical
        cell.spacing = HarnessDesign.Spacing.xs
        for part in cell.arrangedSubviews {
            part.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
            part.trailingAnchor.constraint(equalTo: cell.trailingAnchor).isActive = true
        }
        return cell
    }

    /// Wraps a page's content stack in a vertical scroll view so it remains reachable on
    /// shorter window heights.
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

        let fill = content.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -2 * Form.pageInsetX)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Form.pageInsetTop),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Form.pageInsetBottom),
            content.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: Form.pageInsetX),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: Form.maxWidth),
            fill,
        ])
        return scroll
    }

    private func sliderRow(_ slider: HarnessSlider, _ value: NSTextField) -> NSView {
        slider.widthAnchor.constraint(equalToConstant: Form.sliderWidth).isActive = true
        value.widthAnchor.constraint(equalToConstant: Form.sliderValueWidth).isActive = true
        return hstack([slider, value], spacing: 10)
    }

    private func hstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func unitLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = SettingsCaption(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeResetButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .shadowlessSquare
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle",
                               accessibilityDescription: "Use theme color")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(colorResetClicked(_:))
        button.toolTip = "Use the theme's color"
        return button
    }

    private func buildPaletteWells() {
        paletteWells.removeAll()
        for index in 0 ..< 16 {
            let well = HarnessSwatchWell(frame: .zero)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.heightAnchor.constraint(equalToConstant: 28).isActive = true
            well.color = paletteColor(index)
            well.target = self
            well.action = #selector(paletteWellChanged(_:))
            well.toolTip = "\(index) \(Self.ansiNames[index])"
            well.setAccessibilityLabel("ANSI \(index), \(Self.ansiNames[index])")
            paletteWells.append(well)
        }
    }

    /// What the panes paint with no color edits, through the renderer's own resolution, so the
    /// swatches show the light theme in Light mode and the matching half under Auto.
    private static func themePreview() -> TerminalHostResolvedAppearance {
        var base = SessionCoordinator.shared.settings
        base.clearThemeColorOverrides()
        return TerminalHostView.resolvedNativeAppearance(
            themeName: SessionCoordinator.shared.snapshot.themeName,
            settings: base,
            systemAppearance: HarnessChrome.current.isDark ? .dark : .light
        )
    }

    private static func activeThemeName() -> String {
        let settings = SessionCoordinator.shared.settings
        return ThemeManager.activeThemeName(
            themeName: SessionCoordinator.shared.snapshot.themeName,
            appearanceMode: settings.appearanceMode,
            systemAppearance: HarnessChrome.current.isDark ? .dark : .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName
        )
    }

    /// A light canvas paints the light theme's ANSI colors and ignores palette edits, so the
    /// swatches show those and stay read-only there.
    private var paletteIsEditable: Bool {
        HarnessChrome.current.isDark || SessionCoordinator.shared.settings.appearanceMode == .theme
    }

    /// The swatch for one ANSI slot: the edit if there is one, else what the panes paint.
    private func paletteColor(_ index: Int) -> NSColor {
        let hex = (paletteIsEditable ? paletteHexValues[index] : nil)
            ?? Self.themePreview().outputPaletteHex[index]
            ?? Self.defaultAnsiPalette[index]
        return NSColor.fromHex(hex) ?? .gray
    }

    private func refreshPaletteWells() {
        let editable = paletteIsEditable
        for (index, well) in paletteWells.enumerated() {
            well.color = paletteColor(index)
            well.isEnabled = editable
        }
        paletteNote?.isHidden = editable
    }

    // MARK: - Formatting / utilities

    private func formatPercent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func formatBlur(_ value: Int) -> String {
        value == 0 ? "Off" : "\(value) pt"
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

    private func textRenderingTitle(_ value: TerminalTextRenderingMode) -> String {
        switch value {
        case .crisp: return "Crisp"
        case .soft: return "Soft"
        case .native: return "Native"
        }
    }

    private func textRenderingValue(_ title: String?) -> TerminalTextRenderingMode {
        switch title {
        case "Crisp": return .crisp
        case "Soft": return .soft
        default: return .native
        }
    }

    /// Tri-state mapping for the optional Harness-controls override: Auto = `nil`
    /// (follow the experience mode), On/Off force `true`/`false`.
    private func harnessControlsTitle(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "On"
        case .some(false): return "Off"
        case .none: return "Auto"
        }
    }

    /// Tri-state segment title → `Bool?` override (Auto = nil). Shared by the prefix and status
    /// line segments since both map Auto/On/Off the same way.
    private func tristateOverride(from segment: HarnessSegmented) -> Bool? {
        switch segment.titleOfSelectedItem {
        case "On": return true
        case "Off": return false
        default: return nil
        }
    }

    private var selectedPrefixEnabled: Bool? { tristateOverride(from: prefixControlSegment) }
    private var selectedStatusLineEnabled: Bool? { tristateOverride(from: statusLineControlSegment) }

    /// The chosen family, set in itself so the row previews the font.
    private func updateFontReadout() {
        let family = SessionCoordinator.shared.settings.fontFamily
        fontReadout.stringValue = family
        fontReadout.font = NSFont(name: family, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private static func experienceTitle(_ mode: ExperienceMode) -> String {
        switch mode {
        case .plain: return "Plain"
        case .persistent: return "Persistent"
        case .full: return "Full"
        case .agent: return "Agent"
        }
    }

    // MARK: - Live apply

    // The four continuous sliders apply live on every drag tick but persist only once on commit
    // (`onCommit`, wired in setup), so scrubbing never spams a JSON encode + atomic write per frame.

    @objc private func opacityDidChange() {
        opacityLabel.stringValue = formatPercent(Float(opacitySlider.doubleValue))
        applySettingsLive()
    }

    @objc private func blurDidChange() {
        let rounded = Int(blurSlider.doubleValue.rounded())
        blurLabel.stringValue = formatBlur(rounded)
        applySettingsLive()
    }

    @objc private func windowBorderOpacityDidChange() {
        windowBorderOpacityLabel.stringValue = formatPercent(Float(windowBorderOpacitySlider.doubleValue))
        applySettingsLive()
    }

    @objc private func themeDidChange() {
        guard let theme = themePopup.titleOfSelectedItem else { return }
        // A theme is a starting preset: seed the full editable color set, then
        // mirror it into the controls so the user edits from the theme's values.
        SessionCoordinator.shared.setTheme(theme)
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
    }

    private func resizeOverlayTitle(_ mode: ResizeOverlayMode) -> String {
        switch mode {
        case .afterFirst: return "After First"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    private func resizeOverlayValue(_ title: String?) -> ResizeOverlayMode {
        switch title {
        case "Always": return .always
        case "Never": return .never
        default: return .afterFirst
        }
    }

    private func resizeOverlayPositionTitle(_ position: ResizeOverlayPosition) -> String {
        switch position {
        case .center: return "Center"
        case .topRight: return "Top Right"
        case .bottomRight: return "Bottom Right"
        }
    }

    private func resizeOverlayPositionValue(_ title: String?) -> ResizeOverlayPosition {
        switch title {
        case "Top Right": return .topRight
        case "Bottom Right": return .bottomRight
        default: return .center
        }
    }

    private func bellModeTitle(_ mode: BellMode) -> String {
        switch mode {
        case .off: return "Off"
        case .audible: return "Sound"
        case .visual: return "Flash"
        case .both: return "Both"
        }
    }

    private func bellModeValue(_ title: String?) -> BellMode {
        switch title {
        case "Off": return .off
        case "Sound": return .audible
        case "Both": return .both
        default: return .visual
        }
    }

    private func optionKeyTitle(_ mode: OptionAsMetaMode) -> String {
        switch mode {
        case .composed: return "Characters"
        case .meta: return "Meta"
        case .leftMetaOnly: return "Left Meta"
        case .rightMetaOnly: return "Right Meta"
        }
    }

    private func optionKeyValue(_ title: String?) -> OptionAsMetaMode {
        switch title {
        case "Meta": return .meta
        case "Left Meta": return .leftMetaOnly
        case "Right Meta": return .rightMetaOnly
        default: return .composed
        }
    }

    private func updateMinContrastLabel() {
        let value = minContrastSlider.doubleValue
        minContrastLabel.stringValue = value <= 1.01 ? "Off" : String(format: "%.1f:1", value)
    }

    @objc private func minContrastChanged() {
        updateMinContrastLabel()
        applySettingsLive()
    }

    private func updateScrollMultiplierLabel() {
        let value = scrollMultiplierSlider.doubleValue
        scrollMultiplierLabel.stringValue = String(format: "%.1f×", value)
    }

    @objc private func scrollMultiplierChanged() {
        updateScrollMultiplierLabel()
        applySettingsLive()
    }

    @objc private func systemLightThemeDidChange() {
        guard let theme = systemLightThemePopup.titleOfSelectedItem else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.settings.systemLightThemeName = theme
        coordinator.settings.clearThemeColorOverrides()
        saveSettings()
        coordinator.applySettingsToHosts()
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
    }

    @objc private func systemDarkThemeDidChange() {
        guard let theme = systemDarkThemePopup.titleOfSelectedItem else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.settings.systemDarkThemeName = theme
        coordinator.settings.clearThemeColorOverrides()
        saveSettings()
        coordinator.applySettingsToHosts()
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
    }

    /// Re-seed all colors from the currently selected theme, discarding manual
    /// edits ("Reset to theme").
    @objc private func useThemeColors() {
        SessionCoordinator.shared.setTheme(SessionCoordinator.shared.snapshot.themeName)
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
    }

    @objc private func toggleKeepSessions() {
        let keep = keepSessionsToggle.state == .on
        keepSessionsToggle.isEnabled = false
        SessionCoordinator.shared.requestDaemonAsync(.setKeepSessionsOnQuit(keep)) { [weak self] response in
            guard let self else { return }
            let effective = response == nil ? SessionCoordinator.shared.snapshot.keepSessionsOnQuit : keep
            self.keepSessionsToggle.isEnabled = true
            self.keepSessionsToggle.state = effective ? .on : .off
            self.experienceSummaryLabel.stringValue = SessionCoordinator.shared.settings.experienceMode.summary(keepSessionsOnQuit: effective)
        }
    }

    @objc private func setDefaultTerminalClicked() {
        defaultTerminalButton.isEnabled = false
        defaultTerminalButton.title = "Setting…"
        Task { @MainActor in
            do {
                try await DefaultTerminalManager.setAsDefault()
                Toast.show("Harness is now the default terminal", in: view)
            } catch {
                Toast.show("Couldn't set default terminal", in: view)
            }
            refreshDefaultTerminalStatus()
        }
    }

    private func refreshDefaultTerminalStatus() {
        let status = DefaultTerminalManager.status()
        defaultTerminalRow?.hint = status.summary
        defaultTerminalButton.title = status.isDefault ? "Default" : "Make Default"
        defaultTerminalButton.isEnabled = !status.isDefault
    }

    private var selectedAppearanceMode: HarnessAppearanceMode {
        let title = appearanceModeSegment.titleOfSelectedItem ?? ""
        return HarnessAppearanceMode.allCases.first { Self.appearanceModeTitle($0) == title } ?? .theme
    }

    /// Resolve the default and renamed presets to their current catalog names.
    private static func themeMenuName(_ name: String) -> String {
        name == ThemeManager.defaultDisplayName ? ThemeManager.defaultThemeName
            : HarnessThemeCatalog.theme(named: name)?.name ?? name
    }

    private func populateThemePopup(_ popup: HarnessSelect, selectedThemeName: String) {
        popup.removeAllItems()
        popup.addItems(withTitles: ThemeManager.allThemeNames().filter { $0 != ThemeManager.defaultDisplayName })
        popup.featuredCount = ThemeManager.featuredThemes.count
        popup.searchPlaceholder = "Search themes"
        popup.selectItem(withTitle: Self.themeMenuName(selectedThemeName))
    }

    /// Show only the theme pickers the appearance mode uses: one theme for Theme, the light
    /// theme for Light, both halves for Auto.
    private func updateSystemThemePickerAvailability() {
        let mode = selectedAppearanceMode
        let followsSystem = mode == .macOSSystem
        setRow(themeRow, hidden: mode != .theme)
        setRow(lightThemeRow, hidden: mode == .theme)
        setRow(darkThemeRow, hidden: !followsSystem)
        systemLightThemePopup.isEnabled = mode != .theme
        systemDarkThemePopup.isEnabled = followsSystem
        switch mode {
        case .theme: appearanceModeRow?.hint = "One theme, light or dark, whatever macOS is set to."
        case .light: appearanceModeRow?.hint = "Always the light theme."
        case .macOSSystem: appearanceModeRow?.hint = "Switches between the light and dark theme with macOS."
        }
    }

    /// Rows whose control only means something given another setting dim or hide with it.
    private func updateDependentRows() {
        updateSystemThemePickerAvailability()
        setRow(resizeOverlayPositionRow, hidden: resizeOverlaySegment.titleOfSelectedItem == "Never")
        paneSpacingField.isEnabled = paneDensitySegment.titleOfSelectedItem != "Compact"
        paneHeadersToggle.isEnabled = paneDensitySegment.titleOfSelectedItem != "Compact"
        commandFinishedThresholdField.isEnabled = eventToggles[.commandFinished]?.state == .on
        quickTerminalHotkeyRecorder?.alphaValue = quickTerminalToggle.state == .on ? 1 : 0.45
    }

    private func syncSystemThemePickersFromSettings() {
        let settings = SessionCoordinator.shared.settings
        systemLightThemePopup.selectItem(withTitle: Self.themeMenuName(settings.systemLightThemeName))
        systemDarkThemePopup.selectItem(withTitle: Self.themeMenuName(settings.systemDarkThemeName))
    }

    /// Static (not instance) so tests can exercise the real seeding rule without
    /// instantiating the view controller.
    static func seedUnsetSystemThemeNames(settings: inout HarnessSettings, selectedThemeName: String) {
        if settings.systemLightThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.systemLightThemeName = ThemeManager.defaultSystemLightThemeName
        }
        if settings.systemDarkThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           ThemeManager.allThemeNames().contains(selectedThemeName) {
            settings.systemDarkThemeName = selectedThemeName
        }
    }

    private static func appearanceModeTitle(_ mode: HarnessAppearanceMode) -> String {
        switch mode {
        case .theme: return "Theme"
        case .light: return "Light"
        case .macOSSystem: return "Auto"
        }
    }

    /// The selected experience mode, derived from the segment position.
    private var selectedExperienceMode: ExperienceMode {
        let cases = ExperienceMode.allCases
        let i = experienceSegment.selectedSegment
        return cases.indices.contains(i) ? cases[i] : .plain
    }

    /// Switching mode re-gates the chrome (prefix + status line), sets the default
    /// session-persistence policy on the daemon, and refreshes the live surfaces — all on the
    /// one session core. `flushAndApply` persists the setting and posts the chrome-changed
    /// notification the status line + prefix react to.
    @objc private func experienceModeChanged() {
        let mode = selectedExperienceMode
        experienceSummaryLabel.stringValue = mode.summary(keepSessionsOnQuit: mode.persistsSessionsByDefault)
        flushAndApply()
        PrefixKeymap.shared.rebuildFromSettings()
        // Mode sets the default persistence: Plain is ephemeral (a clean quit closes its
        // sessions), the others keep sessions running. The user can still override via the
        // "Keep sessions running" toggle. Mirror the snapshot truth into that toggle so the
        // two controls stay consistent while the window is open.
        let keep = mode.persistsSessionsByDefault
        keepSessionsToggle.isEnabled = false
        SessionCoordinator.shared.requestDaemonAsync(.setKeepSessionsOnQuit(keep)) { [weak self] response in
            guard let self else { return }
            if response != nil { AppDelegate.recordModePersistenceApplied(mode) }
            let effective = response == nil ? SessionCoordinator.shared.snapshot.keepSessionsOnQuit : keep
            self.keepSessionsToggle.isEnabled = true
            self.keepSessionsToggle.state = effective ? .on : .off
            self.experienceSummaryLabel.stringValue = self.selectedExperienceMode.summary(keepSessionsOnQuit: effective)
        }
    }

    /// The per-component prefix override re-gates the prefix key independently of the status line
    /// (and of the experience mode). Mirrors the chrome-refresh path of `experienceModeChanged`.
    @objc private func prefixControlChanged() {
        SettingsEditor.applyFromWindow(\.prefixKeyEnabled, selectedPrefixEnabled, on: &SessionCoordinator.shared.settings)
        flushAndApply()
        PrefixKeymap.shared.rebuildFromSettings()
    }

    /// The per-component status-line override re-gates the bottom status band independently of the
    /// prefix. `flushAndApply` posts the chrome-changed notification `StatusLineView` reacts to.
    /// This one control owns the status line: Auto and On also clear the older `showStatusLine`
    /// switch, which used to sit on the Appearance page and hid the band on its own.
    @objc private func statusLineControlChanged() {
        let choice = selectedStatusLineEnabled
        SettingsEditor.applyFromWindow(\.statusLineEnabled, choice, on: &SessionCoordinator.shared.settings)
        if choice != false {
            SettingsEditor.applyFromWindow(\.showStatusLine, true, on: &SessionCoordinator.shared.settings)
        }
        flushAndApply()
    }

    @objc private func secureKeyboardChanged() {
        SessionCoordinator.shared.setSecureKeyboardEntry(secureKeyboardToggle.state == .on)
    }

    /// "Remember window size" applies to the live main window immediately, not just on the
    /// next launch: enabling it arms frame autosave (and snapshots the current frame so the
    /// very next quit/relaunch restores it); disabling it stops autosaving. Without this the
    /// toggle would appear to do nothing until two launches later. `MainWindowController.init`
    /// performs the launch-time restore using the same autosave name.
    @objc private func restoreWindowSizeChanged() {
        flushAndApply()
        let enabled = restoreWindowSizeToggle.state == .on
        for window in NSApp.windows where window.contentViewController is MainSplitViewController {
            if enabled {
                window.setFrameAutosaveName(MainWindowController.frameAutosaveName)
                window.saveFrame(usingName: MainWindowController.frameAutosaveName)
            } else {
                // Empty name disables autosaving; the stored frame is ignored next launch
                // because `restoreWindowSize` is now false.
                window.setFrameAutosaveName("")
            }
        }
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
        // A hex field that committed non-empty-but-invalid text wrote `nil` (drop to theme) into
        // settings, yet the field still shows the rejected red text. Re-sync every hex field to the
        // resolved on-disk state so the UI never silently disagrees with what was actually saved.
        resyncColorFieldsFromSettings()
        updateDependentRows()
    }

    /// Write each color field back from the resolved setting it produced, then refresh its swatch.
    /// Invalid input resolved to `nil` → the field clears (the override dropped to the theme); valid
    /// input round-trips to its normalized form. Keeps the form honest after a commit.
    private func resyncColorFieldsFromSettings() {
        let settings = SessionCoordinator.shared.settings
        for binding in colorBindings {
            let resolved = settings[keyPath: binding.keyPath] ?? ""
            if binding.field.stringValue != resolved {
                binding.field.stringValue = resolved
            }
            refreshColorBinding(binding)
        }
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
        well.widthAnchor.constraint(equalToConstant: Form.swatchWidth).isActive = true
        well.heightAnchor.constraint(equalToConstant: Form.swatchHeight).isActive = true
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

    private func refreshColorPlaceholders() {
        for binding in colorBindings {
            binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
            refreshColorBinding(binding)
        }
        refreshPaletteWells()
    }

    @objc private func paletteWellChanged(_ sender: HarnessSwatchWell) {
        guard let index = paletteWells.firstIndex(where: { $0 === sender }) else { return }
        paletteHexValues[index] = hexString(sender.color)
        flushAndApply()
    }

    /// Modal confirm for a destructive, instantly-applied reset. Mirrors the sidebar's delete/close
    /// alerts. Returns true only when the user explicitly confirms.
    private func confirmDestructive(message: String, info: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func resetPalette() {
        paletteHexValues = Array(repeating: nil, count: 16)
        refreshPaletteWells()
        flushAndApply()
    }

    /// Every control's state from the store: on open, after a theme change or reset, and when
    /// the command palette writes while this window is open.
    private func syncAppearanceControlsFromSettings() {
        let settings = SessionCoordinator.shared.settings
        func on(_ value: Bool) -> NSControl.StateValue { value ? .on : .off }
        opacitySlider.doubleValue = Double(settings.backgroundOpacity)
        opacityLabel.stringValue = formatPercent(settings.backgroundOpacity)
        blurSlider.doubleValue = Double(settings.backgroundBlur)
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        windowBorderOpacitySlider.doubleValue = Double(settings.windowBorderOpacity)
        windowBorderOpacityLabel.stringValue = formatPercent(settings.windowBorderOpacity)
        paneSpacingField.stringValue = String(format: "%.0f", settings.paneSpacing)
        paddingXField.stringValue = String(Int(settings.windowPaddingX.rounded()))
        paddingYField.stringValue = String(Int(settings.windowPaddingY.rounded()))
        fontFamilyField.stringValue = settings.fontFamily
        fontSizeField.stringValue = String(Int(settings.fontSize.rounded()))
        updateFontReadout()
        shellField.stringValue = settings.defaultShell
        cwdField.stringValue = settings.defaultCWD
        scrollbackField.stringValue = String(settings.scrollbackLines)
        appearanceModeSegment.selectItem(withTitle: Self.appearanceModeTitle(settings.appearanceMode))
        syncSystemThemePickersFromSettings()
        experienceSegment.selectedSegment = ExperienceMode.allCases.firstIndex(of: settings.experienceMode) ?? 0
        experienceSummaryLabel.stringValue = settings.experienceMode.summary(keepSessionsOnQuit: SessionCoordinator.shared.snapshot.keepSessionsOnQuit)
        prefixControlSegment.selectItem(withTitle: harnessControlsTitle(settings.prefixKeyEnabled))
        // The older `showStatusLine` switch hides the band on its own; show that as Off here.
        statusLineControlSegment.selectItem(withTitle: settings.showStatusLine ? harnessControlsTitle(settings.statusLineEnabled) : "Off")
        cursorStyleSegment.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorBlinkToggle.state = on(settings.cursorBlink)
        copyOnSelectToggle.state = on(settings.copyOnSelect)
        keepSessionsToggle.state = on(SessionCoordinator.shared.snapshot.keepSessionsOnQuit)
        vividColorsToggle.state = on(settings.colorRendering == .vivid)
        textRenderingSegment.selectItem(withTitle: textRenderingTitle(settings.textRendering))
        themeTerminalOutputToggle.state = on(settings.applyThemeToTerminalOutput)
        ligaturesToggle.state = on(settings.ligatures)
        promptGutterToggle.state = on(settings.showPromptGutter)
        offMainPipelineToggle.state = on(settings.offMainParserFramePipeline)
        liveResizeReflowToggle.state = on(settings.liveResizeReflow)
        resizeOverlaySegment.selectItem(withTitle: resizeOverlayTitle(settings.resizeOverlay))
        resizeOverlayPositionSegment.selectItem(withTitle: resizeOverlayPositionTitle(settings.resizeOverlayPosition))
        bellSegment.selectItem(withTitle: bellModeTitle(settings.bellMode))
        optionKeySegment.selectItem(withTitle: optionKeyTitle(settings.optionAsMeta))
        paddingBalanceToggle.state = on(settings.windowPaddingBalance)
        minContrastSlider.doubleValue = settings.minimumContrast
        updateMinContrastLabel()
        scrollMultiplierSlider.doubleValue = settings.scrollMultiplier
        updateScrollMultiplierLabel()
        mouseHideToggle.state = on(settings.mouseHideWhileTyping)
        quickTerminalToggle.state = on(settings.quickTerminalEnabled)
        pasteProtectionToggle.state = on(settings.pasteProtection)
        secureKeyboardToggle.state = on(settings.secureKeyboardEntry)
        remoteControlToggle.state = on(settings.remoteControl)
        inheritCWDToggle.state = on(settings.windowInheritCWD)
        boldIsBrightToggle.state = on(settings.boldIsBright)
        themeFitToggle.state = on(settings.effectiveThemeFit(appearanceIsLight: !HarnessChrome.current.isDark))
        paneDensitySegment.selectItem(withTitle: settings.paneDensity == .compact ? "Compact" : "Comfortable")
        paneHeadersToggle.state = on(settings.paneHeaders)
        for (event, toggle) in eventToggles {
            toggle.state = on(settings.isEventEnabled(event))
        }
        commandFinishedThresholdField.stringValue = String(settings.commandFinishedThresholdSeconds)
        transparentTitlebarToggle.state = on(settings.transparentTitlebar)
        sidebarVisibleToggle.state = on(settings.sidebarVisible)
        machineIndicatorToggle.state = on(settings.showMachineIndicator)
        restoreWindowSizeToggle.state = on(settings.restoreWindowSize)
        systemNotificationsToggle.state = on(settings.systemNotificationsEnabled)
        notificationSoundToggle.state = on(settings.notificationSoundEnabled)
        for binding in colorBindings {
            binding.field.stringValue = settings[keyPath: binding.keyPath] ?? ""
            refreshColorBinding(binding)
        }
        paletteHexValues = HarnessSettings.normalizedPalette(settings.paletteHex)
        refreshPaletteWells()
        updateDependentRows()
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
        field.textColor = valid ? HarnessChrome.current.textPrimary : HarnessChrome.current.danger
    }

    @objc private func resetToDefaults() {
        guard confirmDestructive(
            message: "Reset appearance to defaults?",
            info: "Colors, palette, font, padding, and other visual settings will be restored to their defaults. This can't be undone.",
            confirmTitle: "Reset"
        ) else { return }
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
    private func saveSettings() {
        do { try SessionCoordinator.shared.settings.save() }
        catch { DisplayMessage.show("Could not save settings.json: \(error.localizedDescription). Check disk space and permissions.") }
    }

    private func flushAndApply() {
        applySettingsLive()
        saveSettings()
    }

    /// Settings window path into the shared writer. The palette calls `applyFromPalette`.
    private func write<T>(_ keyPath: WritableKeyPath<HarnessSettings, T>, _ value: T) {
        SettingsEditor.applyFromWindow(keyPath, value, on: &SessionCoordinator.shared.settings)
    }

    /// A palette write landed while this window is open. Pull the store back into the controls
    /// so the close-flush does not overwrite it with the old control values.
    func adoptExternalSettingsWrite() {
        syncAppearanceControlsFromSettings()
    }

    /// Push every field into HarnessSettings and apply it to the live surfaces, but DO NOT persist.
    /// Used on continuous slider drag ticks (60–120 Hz) so scrubbing never triggers a JSON encode +
    /// atomic write per tick; persistence happens once on the gesture's commit (`onCommit`). Every
    /// other control still goes through `flushAndApply`, which saves.
    private func applySettingsLive() {
        let coordinator = SessionCoordinator.shared
        write(\.backgroundOpacity, HarnessSettings.clampedOpacity(Float(opacitySlider.doubleValue)))
        write(\.backgroundBlur, HarnessSettings.clampedBlur(Int(blurSlider.doubleValue.rounded())))
        write(\.windowBorderOpacity, max(0, min(1, Float(windowBorderOpacitySlider.doubleValue))))
        // Read every editable color from its control (bg/fg/cursor/cursor-text/
        // selection/bold + divider/status accents). nil = fall back to theme preset.
        for binding in colorBindings {
            write(binding.keyPath, normalizedHexOrNil(binding.field.stringValue))
        }
        write(\.paletteHex, HarnessSettings.normalizedPalette(paletteHexValues))
        write(\.transparentTitlebar, transparentTitlebarToggle.state == .on)
        write(\.sidebarVisible, sidebarVisibleToggle.state == .on)
        write(\.showMachineIndicator, machineIndicatorToggle.state == .on)
        write(\.restoreWindowSize, restoreWindowSizeToggle.state == .on)
        write(\.paneSpacing, HarnessSettings.clampedPaneSpacing(Double(paneSpacingField.stringValue) ?? 4))
        write(\.windowPaddingX, HarnessSettings.clampedPadding(Float(paddingXField.stringValue) ?? 12))
        write(\.windowPaddingY, HarnessSettings.clampedPadding(Float(paddingYField.stringValue) ?? 12))
        let previousAppearanceMode = coordinator.settings.appearanceMode
        let nextAppearanceMode = selectedAppearanceMode
        write(\.appearanceMode, nextAppearanceMode)
        if previousAppearanceMode != nextAppearanceMode {
            coordinator.settings.clearThemeColorOverrides()
            paletteHexValues = HarnessSettings.normalizedPalette(coordinator.settings.paletteHex)
            for binding in colorBindings {
                binding.field.stringValue = ""
                refreshColorBinding(binding)
            }
        }
        if previousAppearanceMode != .macOSSystem && nextAppearanceMode == .macOSSystem {
            Self.seedUnsetSystemThemeNames(settings: &coordinator.settings, selectedThemeName: coordinator.snapshot.themeName)
            syncSystemThemePickersFromSettings()
        }
        if previousAppearanceMode != .light && nextAppearanceMode == .light {
            Self.seedUnsetSystemThemeNames(settings: &coordinator.settings, selectedThemeName: coordinator.snapshot.themeName)
            syncSystemThemePickersFromSettings()
        }
        write(\.fontSize, HarnessSettings.clampedFontSize(Float(fontSizeField.stringValue) ?? 14))
        write(\.fontFamily, fontFamilyField.stringValue)
        write(\.defaultShell, shellField.stringValue)
        write(\.defaultCWD, cwdField.stringValue)
        write(\.windowInheritCWD, inheritCWDToggle.state == .on)
        // `0` is the unlimited sentinel (kept verbatim); any other value is floored at 100 lines.
        let enteredScrollback = Int(scrollbackField.stringValue) ?? 10_000
        write(\.scrollbackLines, enteredScrollback == 0 ? 0 : max(100, enteredScrollback))
        write(\.cursorStyle, cursorStyleValue(cursorStyleSegment.titleOfSelectedItem))
        write(\.cursorBlink, cursorBlinkToggle.state == .on)
        write(\.copyOnSelect, copyOnSelectToggle.state == .on)
        write(\.systemNotificationsEnabled, systemNotificationsToggle.state == .on)
        write(\.notificationSoundEnabled, notificationSoundToggle.state == .on)
        write(\.colorRendering, vividColorsToggle.state == .on ? .vivid : .accurate)
        write(\.textRendering, textRenderingValue(textRenderingSegment.titleOfSelectedItem))
        write(\.applyThemeToTerminalOutput, themeTerminalOutputToggle.state == .on)
        write(\.ligatures, ligaturesToggle.state == .on)
        write(\.showPromptGutter, promptGutterToggle.state == .on)
        write(\.offMainParserFramePipeline, offMainPipelineToggle.state == .on)
        write(\.liveResizeReflow, liveResizeReflowToggle.state == .on)
        write(\.resizeOverlay, resizeOverlayValue(resizeOverlaySegment.titleOfSelectedItem))
        write(\.resizeOverlayPosition, resizeOverlayPositionValue(resizeOverlayPositionSegment.titleOfSelectedItem))
        write(\.bellMode, bellModeValue(bellSegment.titleOfSelectedItem))
        write(\.scrollMultiplier, HarnessSettings.clampedScrollMultiplier(scrollMultiplierSlider.doubleValue))
        write(\.mouseHideWhileTyping, mouseHideToggle.state == .on)
        write(\.optionAsMeta, optionKeyValue(optionKeySegment.titleOfSelectedItem))
        write(\.quickTerminalEnabled, quickTerminalToggle.state == .on)
        write(\.windowPaddingBalance, paddingBalanceToggle.state == .on)
        write(\.minimumContrast, HarnessSettings.clampedContrast(minContrastSlider.doubleValue))
        write(\.pasteProtection, pasteProtectionToggle.state == .on)
        write(\.remoteControl, remoteControlToggle.state == .on)
        write(\.boldIsBright, boldIsBrightToggle.state == .on)
        write(\.themeFit, ThemeFitPolicy.stored(
            toggleOn: themeFitToggle.state == .on,
            appearanceIsLight: !HarnessChrome.current.isDark
        ))
        write(\.paneDensity, paneDensitySegment.titleOfSelectedItem == "Compact" ? .compact : .comfortable)
        write(\.paneHeaders, paneHeadersToggle.state == .on)
        for (event, toggle) in eventToggles {
            SettingsEditor.setEvent(event, toggle.state == .on, on: &coordinator.settings)
        }
        write(\.commandFinishedThresholdSeconds, max(1, Int(commandFinishedThresholdField.stringValue) ?? 10))
        // Reflect every clamped numeric field back into the UI so typing an out-of-range value
        // (fontSize "2", threshold "0", …) doesn't leave the field showing one number while the
        // setting — and the live terminals — silently use the clamped one. Non-numeric entries
        // reset to the persisted value the same way.
        reflectClamped(commandFinishedThresholdField, String(coordinator.settings.commandFinishedThresholdSeconds))
        reflectClamped(fontSizeField, String(format: "%.0f", coordinator.settings.fontSize))
        reflectClamped(paneSpacingField, String(format: "%.0f", coordinator.settings.paneSpacing))
        reflectClamped(paddingXField, String(format: "%.0f", coordinator.settings.windowPaddingX))
        reflectClamped(paddingYField, String(format: "%.0f", coordinator.settings.windowPaddingY))
        reflectClamped(scrollbackField, String(coordinator.settings.scrollbackLines))
        write(\.experienceMode, selectedExperienceMode)

        // Theme switching (and its color seeding) is handled by themeDidChange, so this only ever
        // pushes the current settings to the live surfaces — scrubbing a slider never fires a
        // setTheme IPC. Persistence is the caller's job (`flushAndApply` saves; drag ticks don't).
        coordinator.applySettingsToHosts()
        QuickTerminalController.shared.rebuildFromSettings()
        updateFontReadout()
        // An appearance flip changes which theme the panes paint; re-preview it.
        if previousAppearanceMode != nextAppearanceMode {
            refreshColorPlaceholders()
            refreshPaletteWells()
        }
    }

    /// Rewrite a numeric field only when its committed text differs from the clamped setting —
    /// the UI must never show a value the terminals aren't actually using.
    private func reflectClamped(_ field: NSTextField, _ clamped: String) {
        if field.stringValue != clamped { field.stringValue = clamped }
    }

    /// Safety net for the apply-only/persist-on-commit split (#89): continuous sliders apply live on
    /// every drag tick but only persist in `HarnessSlider.mouseUp → onCommit`. If a drag never gets
    /// its mouse-up (window closed programmatically mid-drag, a modal steals the gesture, the app
    /// deactivates mid-track), the live-applied value would never be saved. Flushing on teardown
    /// guarantees the visible state is the persisted state. `flushAndApply` is idempotent (read
    /// controls → settings → save), so a redundant call after a normal commit is harmless.
    func persistPendingState() {
        flushAndApply()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        persistPendingState()
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

/// A wrapping caption that takes its width from its constraints: it re-wraps to the width it
/// was given after each layout pass, so a footnote never clips its last line.
@MainActor
private final class SettingsCaption: NSTextField {
    override func layout() {
        super.layout()
        guard bounds.width > 0, abs(preferredMaxLayoutWidth - bounds.width) > 0.5 else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// Settings layout metrics, on the `HarnessDesign` spacing scale.
private enum Form {
    static let sidebarWidth: CGFloat = 220
    static let maxWidth: CGFloat = 680
    static let pageInsetX: CGFloat = 32
    static let pageInsetTop: CGFloat = 30
    static let pageInsetBottom: CGFloat = 36
    static let groupSpacing: CGFloat = HarnessDesign.Spacing.xxl
    static let rowInsetX: CGFloat = HarnessDesign.Spacing.xl
    static let rowInsetY: CGFloat = 9
    static let rowMinHeight: CGFloat = 26
    static let labelGap: CGFloat = HarnessDesign.Spacing.xl
    static let hintMaxWidth: CGFloat = 340
    static let wideControlWidth: CGFloat = 240
    static let sliderWidth: CGFloat = 190
    static let sliderValueWidth: CGFloat = 44
    static let numberFieldWidth: CGFloat = 56
    static let wideNumberFieldWidth: CGFloat = 96
    static let hexFieldWidth: CGFloat = 84
    static let swatchWidth: CGFloat = 40
    static let swatchHeight: CGFloat = 24
}

/// One row of a settings card: the title (with an optional hint under it) on the left, the
/// control on the right, vertically centered. The hint wraps in whatever room the control
/// leaves, so a long hint never pushes the control out of its column.
@MainActor
private final class SettingsFormRow: NSView {
    private let titleLabel: NSTextField
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let control: NSView

    var hint: String? {
        get { hintLabel.isHidden ? nil : hintLabel.stringValue }
        set {
            hintLabel.stringValue = newValue ?? ""
            hintLabel.isHidden = (newValue ?? "").isEmpty
            needsLayout = true
        }
    }

    init(title: String, hint: String?, control: NSView) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.isSelectable = false
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.isSelectable = false
        for label in [titleLabel, hintLabel] {
            label.preferredMaxLayoutWidth = Form.hintMaxWidth
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        self.hint = hint

        let text = NSStackView(views: [titleLabel, hintLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(text)
        addSubview(control)

        let collapse = heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .fittingSizeCompression
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Form.rowMinHeight),
            collapse,
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: Form.labelGap),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Wrap the text to the room left of the control. Wrapping labels size from
    /// `preferredMaxLayoutWidth`, so it follows the row's real width after each pass.
    override func layout() {
        super.layout()
        let room = max(80, min(Form.hintMaxWidth, control.frame.minX - Form.labelGap))
        guard abs(hintLabel.preferredMaxLayoutWidth - room) > 0.5 else { return }
        hintLabel.preferredMaxLayoutWidth = room
        titleLabel.preferredMaxLayoutWidth = room
        super.layout()
    }
}

/// A heading, a card of rows, and a footnote. Tracks each row's wrapper and the hairline
/// above it, so a row can hide without leaving a doubled or dangling divider.
@MainActor
private final class SettingsGroupView: NSStackView {
    private var entries: [(row: NSView, wrapper: NSView, divider: NSView?)] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = HarnessDesign.Spacing.md
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func track(row: NSView, wrapper: NSView, divider: NSView?) {
        entries.append((row, wrapper, divider))
    }

    func setRow(_ row: NSView, hidden: Bool) {
        guard let entry = entries.first(where: { $0.row === row }) else { return }
        entry.wrapper.isHidden = hidden
        var anyVisible = false
        for entry in entries {
            entry.divider?.isHidden = entry.wrapper.isHidden || !anyVisible
            if !entry.wrapper.isHidden { anyVisible = true }
        }
    }
}

@MainActor
final class SettingsSidebarButton: NSControl {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private var isFocused = false { didSet { applyChrome() } }
    var isSelected = false { didSet { applyChrome(); setAccessibilityValue(isSelected) } }
    let buttonTitle: String
    /// ↑ (-1) / ↓ (+1) while the row has keyboard focus.
    var onArrow: ((Int) -> Void)?

    init(title: String, symbol: String) {
        self.buttonTitle = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
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
        press()
    }

    override var acceptsFirstResponder: Bool { HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func accessibilityPerformPress() -> Bool { press(); return true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onArrow?(-1)
        case 125: onArrow?(1)
        case 36, 49: press()
        default: super.keyDown(with: event)
        }
    }

    private func press() {
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        layer?.borderWidth = isFocused ? 2 : 0
        layer?.borderColor = c.focusRing.withAlphaComponent(0.85).cgColor
        if isSelected {
            layer?.backgroundColor = c.rowSelectedFill.cgColor
            iconView.contentTintColor = c.accent
            label.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.rowHoverFill.cgColor
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
    /// Retained for the window's lifetime so its `windowWillClose` flush actually fires (NSWindow
    /// holds the delegate weakly). Closing the prior window drops the old proxy.
    private static var closeProxy: SettingsWindowCloseProxy?

    static func reloadIfOpen() {
        (window?.contentViewController as? SettingsViewController)?.adoptExternalSettingsWrite()
    }

    static func show(pane: SettingsPane = .appearance) {
        window?.close()
        let controller = SettingsViewController()
        controller.initialPane = pane
        let win = NSWindow(contentViewController: controller)
        win.title = "Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.backgroundColor = HarnessChrome.current.terminalBackground
        win.isMovableByWindowBackground = false
        win.isRestorable = false
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 840, height: 600)
        // Tab walks the controls top to bottom as laid out on the visible page.
        win.autorecalculatesKeyViewLoop = true
        win.setContentSize(NSSize(width: 940, height: 680))
        // Persist on close (incl. via the titlebar button) so a slider drag that never got its
        // mouse-up still saves its live-applied value (#89). Mirrors `viewWillDisappear`; both are
        // safe to fire because `persistPendingState` is idempotent.
        let proxy = SettingsWindowCloseProxy { [weak controller] in controller?.persistPendingState() }
        win.delegate = proxy
        closeProxy = proxy
        window = win
        // Match the active theme's light/dark so the native titlebar + any system-colored
        // text track the themed chrome (mirrors MainWindowController).
        win.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Thin `NSWindowDelegate` that flushes the settings controller's pending state when the settings
/// window closes. Kept separate from the view controller so the controller doesn't have to be the
/// window's delegate (it isn't responsible for window lifecycle), and retained by
/// `SettingsWindowController` since NSWindow holds its delegate weakly.
@MainActor
final class SettingsWindowCloseProxy: NSObject, NSWindowDelegate {
    private let onWillClose: () -> Void
    init(onWillClose: @escaping () -> Void) { self.onWillClose = onWillClose }
    func windowWillClose(_ notification: Notification) { onWillClose() }
}

/// The Settings window's sidebar panes, in sidebar order.
enum SettingsPane: Int, CaseIterable {
    case appearance, colors, terminal, keys, notifications, agents, advanced

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .colors: return "Colors"
        case .terminal: return "Terminal"
        case .keys: return "Keys"
        case .notifications: return "Notifications"
        case .agents: return "Agents"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .colors: return "paintpalette"
        case .terminal: return "terminal"
        case .keys: return "keyboard"
        case .notifications: return "bell.badge"
        case .agents: return "sparkles"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// Extra words the sidebar search matches besides the title.
    var keywords: [String] {
        switch self {
        case .appearance:
            return ["theme", "system", "macos", "opacity", "blur", "padding", "window", "transparent", "titlebar", "sidebar", "restore", "remember", "size"]
        case .colors:
            return ["color", "background", "foreground", "cursor", "selection", "palette", "ansi", "vivid", "ligatures", "divider", "status", "soft", "native", "crisp", "rendering", "gamma"]
        case .terminal:
            return ["font", "shell", "directory", "scrollback", "blink", "copy", "session", "harness", "controls", "experience"]
        case .keys:
            return ["prefix", "binding", "keybinding", "shortcut", "option", "meta", "alt", "compose", "accent", "esc"]
        case .notifications:
            return ["notify", "banner", "alert", "bell", "sound", "blocked", "failed", "error", "done", "finished", "permission"]
        case .agents:
            return ["agent", "icons", "codex", "claude", "cursor", "pi", "hermes", "openclaw", "hook", "detection"]
        case .advanced:
            return ["options", "status", "mouse", "mode", "clipboard", "base-index", "renumber", "monitor", "rename", "repeat", "history", "pane", "border", "harness-cli", "set-option", "performance", "pipeline", "render", "identity", "term_program", "xtversion", "shift+enter", "kitty", "ghostty"]
        }
    }
}
