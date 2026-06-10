import AppKit
import HarnessCore
import HarnessTerminalKit
import UserNotifications

@MainActor
final class SettingsViewController: NSViewController, NSFontChanging {
    private let appearanceModePopup = HarnessSelect(frame: .zero)
    private let themePopup = HarnessSelect(frame: .zero)
    private let systemLightThemePopup = HarnessSelect(frame: .zero)
    private let systemDarkThemePopup = HarnessSelect(frame: .zero)
    private var systemThemeRows: [NSView] = []
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
    private let restoreWindowSizeToggle = HarnessToggle(title: "Remember window size")
    private let experienceSegment = HarnessSegmented(frame: .zero)
    // Per-component overrides for the chrome the experience preset would otherwise bundle. Each is
    // tri-state (Auto / On / Off): Auto follows the selected preset; On/Off pin the component
    // independently, so e.g. a Plain terminal can show a status line without arming the prefix.
    private let prefixControlSegment = HarnessSegmented(frame: .zero)
    private let statusLineControlSegment = HarnessSegmented(frame: .zero)
    private let textRenderingSegment = HarnessSegmented(frame: .zero)
    private let offMainPipelineToggle = HarnessToggle(title: "Off-main render pipeline")
    private let liveResizeReflowToggle = HarnessToggle(title: "Real-time resize")
    private let experienceSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let cursorStyleSegment = HarnessSegmented(frame: .zero)
    private let cursorBlinkToggle = HarnessToggle(title: "Blinking cursor")
    private let copyOnSelectToggle = HarnessToggle(title: "Copy text to clipboard on selection")
    private let keepSessionsToggle = HarnessToggle(title: "Keep sessions running after the window closes")
    private let defaultTerminalButton = NSButton(title: "Set Harness as default terminal", target: nil, action: nil)
    private let defaultTerminalStatusField = NSTextField(wrappingLabelWithString: "")
    private let vividColorsToggle = HarnessToggle(title: "Vivid color rendering (Display P3 opt-in)")
    private let themeTerminalOutputToggle = HarnessToggle(title: "Apply theme colors to terminal output — off = canvas matches theme, output untouched")
    private let ligaturesToggle = HarnessToggle(title: "Programming ligatures (=>, !=, ->) for fonts that have them")
    private let promptGutterToggle = HarnessToggle(title: "Prompt gutter — green/red stripe marking command success (needs shell integration)")
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
    private let windowBorderHexField = HarnessTextField()
    private let windowBorderWell = HarnessSwatchWell(frame: .zero)
    private let windowBorderOpacitySlider = HarnessSlider(frame: .zero)
    private let windowBorderOpacityLabel = NSTextField(labelWithString: "")
    private let systemNotificationsToggle = HarnessToggle(title: "Show a macOS banner")
    private let notificationSoundToggle = HarnessToggle(title: "Play a sound")
    private let notchModeSegment = HarnessSegmented(frame: .zero)
    private let notchOpenOnHoverToggle = HarnessToggle(title: "Open when I hover near the macOS notch")
    /// One toggle per `NotificationEvent` ("which events notify me"). Built from the enum so a
    /// new case automatically gets a wired row. Lazy so its (main-actor) `HarnessToggle`
    /// construction runs at first access inside a method, not in a stored-property initializer.
    private lazy var eventToggles: [NotificationEvent: HarnessToggle] = {
        var toggles: [NotificationEvent: HarnessToggle] = [:]
        for event in NotificationEvent.allCases {
            toggles[event] = HarnessToggle(title: event.title)
        }
        return toggles
    }()
    private let commandFinishedThresholdField = HarnessTextField()
    private let notchSummaryLabel = NSTextField(wrappingLabelWithString: "")
    // QoL additions: resize overlay (T1), balanced padding (T2), minimum contrast (T5),
    // auto light/dark (T6), paste protection (E).
    private let resizeOverlaySegment = HarnessSegmented(frame: .zero)
    private let resizeOverlayPositionSegment = HarnessSegmented(frame: .zero)
    private let bellSegment = HarnessSegmented(frame: .zero)
    private let paddingBalanceToggle = HarnessToggle(title: "Center grid (distribute padding evenly)")
    private let minContrastSlider = HarnessSlider(frame: .zero)
    private let minContrastLabel = NSTextField(labelWithString: "")
    private let scrollMultiplierSlider = HarnessSlider(frame: .zero)
    private let scrollMultiplierLabel = NSTextField(labelWithString: "")
    private let mouseHideToggle = HarnessToggle(title: "Hide the mouse cursor while typing")
    private let pasteProtectionToggle = HarnessToggle(title: "Confirm risky pastes (multi-line or control characters)")
    private let boldIsBrightToggle = HarnessToggle(title: "Bold uses bright colors")
    private let notificationTestButton = NSButton(title: "Send Test Notification", target: nil, action: nil)
    private let notificationPermissionButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let notificationStatusField = NSTextField(labelWithString: "")
    private let pageContainer = NSView()
    private var pages: [Int: NSView] = [:]
    private var currentPage: Int = 0
    /// Group-card surfaces + hairline dividers, tracked so a live theme change can
    /// re-skin them (they're created inline by the `settingsGroup`/`groupDivider`
    /// factories rather than stored individually).
    private var groupSurfaces: [NSView] = []
    private var groupDividers: [NSView] = []
    /// Text-link buttons (accent baked into the attributed title) re-tinted on theme change.
    private var linkButtons: [NSButton] = []
    private var paletteWells: [HarnessSwatchWell] = []
    private var paletteHexValues: [String?] = Array(repeating: nil, count: 16)
    private var agentColorWells: [AgentKind: HarnessSwatchWell] = [:]
    private var agentIconViews: [AgentKind: NSImageView] = [:]
    private var colorBindings: [ColorBinding] = []
    private var keyRecorder: KeyRecorderView!
    private let quickTerminalToggle = HarnessToggle(title: "Enable quick terminal (global dropdown)")
    private var quickTerminalHotkeyRecorder: KeyRecorderView!
    /// Live "Installed ✓ / Install hooks" buttons keyed by agent (Agents page).
    private var hookButtons: [AgentKind: NSButton] = [:]

    private struct ColorBinding {
        let field: HarnessTextField
        let well: HarnessSwatchWell
        let reset: NSButton
        let keyPath: WritableKeyPath<HarnessSettings, String?>
        let themeColor: () -> String?
    }

    private enum ColorFormMetrics {
        static let swatchWidth: CGFloat = 42
        static let swatchHeight: CGFloat = 28
        static let labelWidth: CGFloat = 118
        static let fieldWidth: CGFloat = 116
        static let resetSlotWidth: CGFloat = 24
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
        .codex, .claudeCode, .cursor, .grok, .pi, .hermes,
        .openClaw, .openCode, .aider, .gemini, .goose,
    ]

    deinit {
        // A fresh controller is built on each open and the previous one is torn down; drop
        // its observers (the chrome-change observer + the per-field text-change observers
        // registered in `configureLiveAppearanceField`) so a closed window stops reacting.
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 660))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        layoutShell()
        showPage(0)
        observeChromeChanges()
    }

    // MARK: - Control configuration (initial state from settings)

    private func configureControls() {
        let coordinator = SessionCoordinator.shared
        let settings = coordinator.settings

        appearanceModePopup.removeAllItems()
        appearanceModePopup.addItems(withTitles: HarnessAppearanceMode.allCases.map(Self.appearanceModeTitle))
        appearanceModePopup.selectItem(withTitle: Self.appearanceModeTitle(settings.appearanceMode))
        systemLightThemePopup.selectItem(withTitle: settings.systemLightThemeName)
        systemDarkThemePopup.selectItem(withTitle: settings.systemDarkThemeName)
        updateSystemThemePickerAvailability()
        appearanceModePopup.target = self
        appearanceModePopup.action = #selector(appearanceTextDidCommit)

        populateThemePopup(themePopup, selectedThemeName: coordinator.snapshot.themeName)
        themePopup.target = self
        themePopup.action = #selector(themeDidChange)

        populateThemePopup(systemLightThemePopup, selectedThemeName: settings.systemLightThemeName)
        systemLightThemePopup.target = self
        systemLightThemePopup.action = #selector(systemLightThemeDidChange)

        populateThemePopup(systemDarkThemePopup, selectedThemeName: settings.systemDarkThemeName)
        systemDarkThemePopup.target = self
        systemDarkThemePopup.action = #selector(systemDarkThemeDidChange)

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
        opacitySlider.onCommit = { [weak self] in self?.flushAndApply() }
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
        blurSlider.onCommit = { [weak self] in self?.flushAndApply() }
        blurSlider.isContinuous = true
        blurLabel.stringValue = formatBlur(settings.backgroundBlur)
        blurLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        blurLabel.textColor = .secondaryLabelColor
        blurSlider.toolTip = "Backdrop blur for the whole window (terminal + chrome), 0–100 px."

        windowBorderOpacitySlider.minValue = 0
        windowBorderOpacitySlider.maxValue = 1
        windowBorderOpacitySlider.doubleValue = Double(settings.windowBorderOpacity)
        windowBorderOpacitySlider.target = self
        windowBorderOpacitySlider.action = #selector(windowBorderOpacityDidChange)
        windowBorderOpacitySlider.onCommit = { [weak self] in self?.flushAndApply() }
        windowBorderOpacitySlider.isContinuous = true
        windowBorderOpacityLabel.stringValue = formatPercent(settings.windowBorderOpacity)
        windowBorderOpacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        windowBorderOpacityLabel.textColor = .secondaryLabelColor
        windowBorderOpacitySlider.toolTip = "Faint hairline around the window edge — 0% hides it. Color in Colors ▸ Chrome."

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

        experienceSegment.setSegments(ExperienceMode.allCases.map(\.displayName))
        experienceSegment.selectItem(withTitle: settings.experienceMode.displayName)
        experienceSegment.target = self
        experienceSegment.action = #selector(experienceModeChanged)
        experienceSummaryLabel.font = .systemFont(ofSize: 11.5)
        experienceSummaryLabel.textColor = .secondaryLabelColor
        experienceSummaryLabel.stringValue = settings.experienceMode.summary

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
        defaultTerminalButton.target = self
        defaultTerminalButton.action = #selector(setDefaultTerminalClicked)
        defaultTerminalButton.bezelStyle = .rounded
        defaultTerminalButton.controlSize = .regular
        defaultTerminalStatusField.font = .systemFont(ofSize: 11.5)
        defaultTerminalStatusField.textColor = .secondaryLabelColor
        defaultTerminalStatusField.maximumNumberOfLines = 2
        refreshDefaultTerminalStatus()
        vividColorsToggle.state = settings.colorRendering == .vivid ? .on : .off
        vividColorsToggle.target = self
        vividColorsToggle.action = #selector(appearanceTextDidCommit)
        textRenderingSegment.setSegments(["Native", "Crisp", "Soft"])
        textRenderingSegment.selectItem(withTitle: textRenderingTitle(settings.textRendering))
        textRenderingSegment.target = self
        textRenderingSegment.action = #selector(appearanceTextDidCommit)
        themeTerminalOutputToggle.state = settings.applyThemeToTerminalOutput ? .on : .off
        themeTerminalOutputToggle.target = self
        themeTerminalOutputToggle.action = #selector(appearanceTextDidCommit)
        ligaturesToggle.state = settings.ligatures ? .on : .off
        ligaturesToggle.target = self
        ligaturesToggle.action = #selector(appearanceTextDidCommit)
        promptGutterToggle.state = settings.showPromptGutter ? .on : .off
        promptGutterToggle.target = self
        promptGutterToggle.action = #selector(appearanceTextDidCommit)

        transparentTitlebarToggle.state = settings.transparentTitlebar ? .on : .off
        transparentTitlebarToggle.target = self
        transparentTitlebarToggle.action = #selector(appearanceTextDidCommit)

        showStatusLineToggle.state = settings.showStatusLine ? .on : .off
        showStatusLineToggle.target = self
        showStatusLineToggle.action = #selector(appearanceTextDidCommit)

        sidebarVisibleToggle.state = settings.sidebarVisible ? .on : .off
        sidebarVisibleToggle.target = self
        sidebarVisibleToggle.action = #selector(sidebarVisibilityChanged)

        restoreWindowSizeToggle.state = settings.restoreWindowSize ? .on : .off
        restoreWindowSizeToggle.target = self
        restoreWindowSizeToggle.action = #selector(restoreWindowSizeChanged)

        // Optional Harness controls without switching experience mode, now decoupled into two
        // independent tri-states. Auto follows the preset; On/Off pin each via `prefixKeyEnabled` /
        // `statusLineEnabled`. The legacy umbrella `harnessControlsEnabled` is preserved on disk and
        // acts as the fallback when a component is Auto, so existing settings keep their behavior.
        prefixControlSegment.setSegments(["Auto", "On", "Off"])
        prefixControlSegment.selectItem(withTitle: harnessControlsTitle(settings.prefixKeyEnabled))
        prefixControlSegment.target = self
        prefixControlSegment.action = #selector(prefixControlChanged)

        statusLineControlSegment.setSegments(["Auto", "On", "Off"])
        statusLineControlSegment.selectItem(withTitle: harnessControlsTitle(settings.statusLineEnabled))
        statusLineControlSegment.target = self
        statusLineControlSegment.action = #selector(statusLineControlChanged)

        offMainPipelineToggle.state = settings.offMainParserFramePipeline ? .on : .off
        offMainPipelineToggle.target = self
        offMainPipelineToggle.action = #selector(appearanceTextDidCommit)

        liveResizeReflowToggle.state = settings.liveResizeReflow ? .on : .off
        liveResizeReflowToggle.target = self
        liveResizeReflowToggle.action = #selector(appearanceTextDidCommit)

        // Resize overlay (T1)
        resizeOverlaySegment.setSegments(["After first", "Always", "Never"])
        resizeOverlaySegment.selectItem(withTitle: resizeOverlayTitle(settings.resizeOverlay))
        resizeOverlaySegment.target = self
        resizeOverlaySegment.action = #selector(appearanceTextDidCommit)
        resizeOverlayPositionSegment.setSegments(["Center", "Top right", "Bottom right"])
        resizeOverlayPositionSegment.selectItem(withTitle: resizeOverlayPositionTitle(settings.resizeOverlayPosition))
        resizeOverlayPositionSegment.target = self
        resizeOverlayPositionSegment.action = #selector(appearanceTextDidCommit)
        bellSegment.setSegments(["Off", "Audible", "Visual", "Both"])
        bellSegment.selectItem(withTitle: bellModeTitle(settings.bellMode))
        bellSegment.target = self
        bellSegment.action = #selector(appearanceTextDidCommit)
        // Balanced padding (T2)
        paddingBalanceToggle.state = settings.windowPaddingBalance ? .on : .off
        paddingBalanceToggle.target = self
        paddingBalanceToggle.action = #selector(appearanceTextDidCommit)
        // Minimum contrast (T5)
        minContrastSlider.minValue = 1
        minContrastSlider.maxValue = 21
        minContrastSlider.doubleValue = settings.minimumContrast
        minContrastSlider.isContinuous = true
        minContrastSlider.target = self
        minContrastSlider.action = #selector(minContrastChanged)
        minContrastSlider.onCommit = { [weak self] in self?.flushAndApply() }
        updateMinContrastLabel()

        scrollMultiplierSlider.minValue = 0.1
        scrollMultiplierSlider.maxValue = 10
        scrollMultiplierSlider.doubleValue = settings.scrollMultiplier
        scrollMultiplierSlider.isContinuous = true
        scrollMultiplierSlider.target = self
        scrollMultiplierSlider.action = #selector(scrollMultiplierChanged)
        scrollMultiplierSlider.onCommit = { [weak self] in self?.flushAndApply() }
        updateScrollMultiplierLabel()

        mouseHideToggle.state = settings.mouseHideWhileTyping ? .on : .off
        mouseHideToggle.target = self
        mouseHideToggle.action = #selector(appearanceTextDidCommit)
        // Paste protection (E)
        pasteProtectionToggle.state = settings.pasteProtection ? .on : .off
        pasteProtectionToggle.target = self
        pasteProtectionToggle.action = #selector(appearanceTextDidCommit)
        boldIsBrightToggle.state = settings.boldIsBright ? .on : .off
        boldIsBrightToggle.target = self
        boldIsBrightToggle.action = #selector(appearanceTextDidCommit)
        // Per-event notification toggles ("which events notify me").
        for (event, toggle) in eventToggles {
            toggle.state = settings.isEventEnabled(event) ? .on : .off
            toggle.target = self
            toggle.action = #selector(appearanceTextDidCommit)
        }
        commandFinishedThresholdField.stringValue = String(settings.commandFinishedThresholdSeconds)
        commandFinishedThresholdField.target = self
        commandFinishedThresholdField.action = #selector(appearanceTextDidCommit)
        useThemeColorsButton.title = "Use Theme Colors"
        useThemeColorsButton.target = self
        useThemeColorsButton.action = #selector(useThemeColors)

        keyRecorder = KeyRecorderView(initial: settings.prefixKey)
        keyRecorder.onChange = { value in
            // Empty = disable the prefix entirely (honored via `effectivePrefixKey`); don't
            // silently snap back to Ctrl-A the way the old code did.
            SessionCoordinator.shared.settings.prefixKey = value
            try? SessionCoordinator.shared.settings.save()
            PrefixKeymap.shared.rebuildFromSettings()
        }

        quickTerminalToggle.state = settings.quickTerminalEnabled ? .on : .off
        quickTerminalToggle.target = self
        quickTerminalToggle.action = #selector(appearanceTextDidCommit)
        quickTerminalHotkeyRecorder = KeyRecorderView(initial: settings.quickTerminalHotkey)
        quickTerminalHotkeyRecorder.onChange = { value in
            SessionCoordinator.shared.settings.quickTerminalHotkey = value
            try? SessionCoordinator.shared.settings.save()
            QuickTerminalController.shared.rebuildFromSettings()
        }

        updateFontReadout()
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
            sidebar.widthAnchor.constraint(equalToConstant: 220),

            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        // Rebuild the Advanced page each time it's shown so it re-checks daemon reachability (and
        // re-fetches live option values): a daemon that was down when Settings opened may be back,
        // and vice-versa. The other pages are static enough to stay cached.
        if index == 5 { pages[5] = buildAdvancedPage() }
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
            case let v as HarnessSegmented: v.applyChrome()
            case let v as HarnessSelect: v.applyChrome()
            case let v as SettingsSidebarButton: v.applyChrome()
            default: break
            }
            reskinControls(in: sub)
        }
    }

    // MARK: - Sidebar

    private var sidebarButtons: [SettingsSidebarButton] = []
    private let settingsSearch = HarnessSearchField()
    private let sidebarTitleLabel = NSTextField(labelWithString: "Settings")
    private static let sectionKeywords: [Int: [String]] = [
        0: ["appearance", "theme", "system", "macos", "opacity", "blur", "padding", "window", "transparent", "titlebar", "sidebar", "restore", "remember", "size"],
        1: ["colors", "color", "background", "foreground", "cursor", "selection", "palette", "ansi", "vivid", "ligatures", "divider", "status", "soft", "native", "crisp", "rendering", "gamma"],
        2: ["terminal", "font", "shell", "directory", "scrollback", "blink", "copy", "session", "harness", "controls", "experience"],
        3: ["keys", "prefix", "binding", "keybinding", "shortcut"],
        4: ["agents", "agent", "color", "codex", "claude", "cursor", "pi", "hermes", "openclaw", "hook", "notification", "notify", "banner", "bell", "sound", "detection"],
        5: ["advanced", "options", "status", "mouse", "mode", "clipboard", "base-index", "renumber", "monitor", "rename", "repeat", "history", "pane", "border", "harness-cli", "set-option", "performance", "pipeline", "render", "identity", "term_program", "xtversion", "shift+enter", "kitty", "ghostty"],
    ]

    private func buildSidebar() -> NSView {
        // A plain layer-backed view carrying the same themed sidebar chrome (vibrancy +
        // tint) the main window's sidebar uses — never the system `.sidebar` material,
        // which adds a blue cast that breaks the deep-black look.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.applySidebarChrome(to: container)

        let title = sidebarTitleLabel
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = HarnessChrome.current.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false

        settingsSearch.placeholderString = "Search"
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
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            settingsSearch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
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

        useThemeColorsButton.title = "Use theme colors"
        styleAsLink(useThemeColorsButton)
        let resetDefaults = makeLinkButton("Reset to defaults", action: #selector(resetToDefaults))
        for link in [useThemeColorsButton, resetDefaults] {
            link.lineBreakMode = .byClipping
            link.setContentCompressionResistancePriority(.required, for: .horizontal)
            link.setContentHuggingPriority(.required, for: .horizontal)
        }
        for popup in [themePopup, systemLightThemePopup, systemDarkThemePopup] {
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }

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

        let windowBorderRow = NSStackView(views: [windowBorderOpacitySlider, windowBorderOpacityLabel])
        windowBorderRow.orientation = .horizontal
        windowBorderRow.spacing = 12
        windowBorderOpacitySlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        windowBorderOpacityLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        windowBorderOpacityLabel.alignment = .right

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

        let lightThemeRow = settingsRow("Light Theme", systemLightThemePopup)
        let darkThemeRow = settingsRow("Dark Theme", systemDarkThemePopup)
        systemThemeRows = [lightThemeRow, darkThemeRow]
        updateSystemThemePickerAvailability()

        let themeGroup = settingsGroup("Theme", [
            settingsRow("Appearance", appearanceModePopup),
            settingsRow("Theme", themePopup),
            lightThemeRow,
            darkThemeRow,
            settingsRow("", themeActions),
        ])
        let windowGroup = settingsGroup("Window", [
            settingsRow("Opacity", opacityRow),
            settingsRow("Blur", blurRow),
            settingsRow("Edge border", windowBorderRow,
                        hint: "Faint hairline around the window edge — 0% hides it."),
            settingsRow("Padding", paddingRow),
            settingsToggleRow("Center grid", paddingBalanceToggle,
                              hint: "Distribute leftover padding evenly so the grid is centered."),
            settingsRow("Resize overlay", resizeOverlaySegment,
                        hint: "Show the grid size while resizing the window."),
            settingsRow("Overlay position", resizeOverlayPositionSegment,
                        hint: "Where the resize overlay is drawn within the surface."),
            settingsRow("Bell", bellSegment,
                        hint: "Feedback when a program rings the bell (\\a). Visual = a brief flash."),
            settingsToggleRow("Transparent title bar", transparentTitlebarToggle),
            settingsToggleRow("Status line", showStatusLineToggle),
            settingsToggleRow("Sidebar", sidebarVisibleToggle),
            settingsToggleRow("Remember window size", restoreWindowSizeToggle,
                              hint: "Reopen at the last size and position."),
        ])

        let stack = NSStackView(views: [
            header,
            themeGroup,
            windowGroup,
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
        let colorsGroup = colorGrid(
            left: [
                ("Background", colorBindings[0]),
                ("Cursor", colorBindings[2]),
                ("Selection", colorBindings[4]),
                ("Bold", colorBindings[6]),
            ],
            right: [
                ("Foreground", colorBindings[1]),
                ("Cursor text", colorBindings[3]),
                ("Selection text", colorBindings[5]),
            ]
        )

        let minContrastRow = NSStackView(views: [minContrastSlider, minContrastLabel])
        minContrastRow.orientation = .horizontal
        minContrastRow.spacing = 12
        minContrastSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        minContrastLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        minContrastLabel.alignment = .right

        let renderingGroup = settingsGroup("Color rendering", [
            settingsToggleRow("Wide gamut", vividColorsToggle, hint: "Opt-in Display P3 conversion."),
            settingsRow("Text rendering", textRenderingSegment,
                        hint: "Glyph weight: Native, Crisp (lighter), or Soft (heavier)."),
            settingsRow("Minimum contrast", minContrastRow,
                        hint: "Lift dim text to a WCAG contrast ratio (1 = off)."),
            settingsToggleRow("Bold is bright", boldIsBrightToggle,
                              hint: "Bold text in colors 0–7 uses the bright palette (8–15)."),
            settingsToggleRow("Theme program output", themeTerminalOutputToggle),
            settingsToggleRow("Ligatures", ligaturesToggle),
            settingsToggleRow("Prompt gutter", promptGutterToggle),
        ])

        let chromeAccents = colorGrid(
            left: [("Divider lines", colorBindings[7]), ("Window border", colorBindings[9])],
            right: [("Status line text", colorBindings[8])]
        )

        let stack = NSStackView(views: [
            header,
            settingsGroup("Terminal colors", [colorsGroup]),
            renderingGroup,
            settingsGroup("ANSI palette", [buildPaletteSection()]),
            settingsGroup("Chrome", [chromeAccents]),
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
        let header = pageHeader(title: "Terminal", trailing: nil)

        let chooseFontButton = makeRoundedButton("Choose Font…", action: #selector(chooseFont))
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

        let fontGroup = settingsGroup("Font", settingsRows([
            ("Font", fontRow),
            ("Size", fontSizeField),
        ]))
        let shellGroup = settingsGroup("Shell", settingsRows([
            ("Shell", shellField),
            ("Default directory", cwdField),
        ]))
        let defaultTerminalGroup = settingsGroup("Default terminal", [
            settingsCaption("Use Harness for SSH/Telnet links, man-page links, and .command/.tool files."),
            leadingRow(defaultTerminalButton),
            defaultTerminalStatusField,
        ])
        let scrollMultiplierRow = NSStackView(views: [scrollMultiplierSlider, scrollMultiplierLabel])
        scrollMultiplierRow.orientation = .horizontal
        scrollMultiplierRow.spacing = 12
        scrollMultiplierSlider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scrollMultiplierLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        scrollMultiplierLabel.alignment = .right
        let behaviorGroup = settingsGroup("Behavior", [
            settingsRow("Cursor style", cursorStyleSegment),
            settingsRow("Scrollback", scrollbackField),
            settingsToggleRow("Blink cursor", cursorBlinkToggle),
            settingsToggleRow("Copy on select", copyOnSelectToggle),
            settingsToggleRow("Paste protection", pasteProtectionToggle),
            settingsRow("Scroll speed", scrollMultiplierRow,
                        hint: "Mouse-wheel / trackpad scroll multiplier (1× = native)."),
            settingsToggleRow("Hide cursor while typing", mouseHideToggle),
            settingsToggleRow("Keep sessions running", keepSessionsToggle),
        ])

        // Experience mode: how much of Harness is exposed (controls + default session
        // persistence). It governs terminal behavior, so it lives here rather than under
        // Appearance. The summary updates live so the choice is self-explanatory.
        experienceSegment.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let experienceContent = NSStackView(views: [experienceSegment, experienceSummaryLabel])
        experienceContent.orientation = .vertical
        experienceContent.alignment = .leading
        experienceContent.spacing = 8
        experienceSegment.widthAnchor.constraint(equalTo: experienceContent.widthAnchor).isActive = true
        let experienceGroup = settingsGroup("Experience", [
            experienceContent,
            settingsRow("Command prefix", prefixControlSegment,
                        hint: "Arm the prefix key. Auto follows the mode above."),
            settingsRow("Status line", statusLineControlSegment,
                        hint: "Show the bottom status band. Auto follows the mode above."),
        ])

        let stack = NSStackView(views: [
            header,
            experienceGroup,
            fontGroup,
            shellGroup,
            defaultTerminalGroup,
            behaviorGroup,
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

        let prefixGroup = settingsGroup("Prefix", [
            settingsRow("Prefix key", keyRecorder, hint: "Click to record a new shortcut. Esc cancels."),
        ])

        let quickTerminalGroup = settingsGroup("Quick Terminal", [
            settingsToggleRow("Enable", quickTerminalToggle),
            settingsRow("Hotkey", quickTerminalHotkeyRecorder,
                        hint: "Global shortcut that drops a terminal down from the top of the screen, even when Harness is in the background."),
        ])

        let stack = NSStackView(views: [header, prefixGroup, quickTerminalGroup])
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
        systemNotificationsToggle.action = #selector(systemNotificationsToggled)
        notificationSoundToggle.state = SessionCoordinator.shared.settings.notificationSoundEnabled ? .on : .off
        notificationSoundToggle.target = self
        notificationSoundToggle.action = #selector(appearanceTextDidCommit)
        notchModeSegment.setSegments(NotchVisibilityMode.allCases.map(notchModeTitle))
        notchModeSegment.selectItem(withTitle: notchModeTitle(SessionCoordinator.shared.settings.notchVisibilityMode))
        notchModeSegment.target = self
        notchModeSegment.action = #selector(notchSettingsChanged)
        notchOpenOnHoverToggle.state = SessionCoordinator.shared.settings.notchOpenOnHover ? .on : .off
        notchOpenOnHoverToggle.target = self
        notchOpenOnHoverToggle.action = #selector(notchSettingsChanged)
        notchSummaryLabel.font = .systemFont(ofSize: 11)
        notchSummaryLabel.textColor = .secondaryLabelColor
        notchSummaryLabel.stringValue = notchSummary(for: SessionCoordinator.shared.settings.notchVisibilityMode)

        notificationStatusField.font = .systemFont(ofSize: 11)
        notificationStatusField.textColor = .secondaryLabelColor
        notificationStatusField.lineBreakMode = .byWordWrapping
        notificationStatusField.maximumNumberOfLines = 2
        notificationTestButton.target = self
        notificationTestButton.action = #selector(sendTestNotification)
        notificationTestButton.bezelStyle = .rounded
        notificationTestButton.controlSize = .regular
        notificationPermissionButton.target = self
        notificationPermissionButton.action = #selector(openNotificationPermission)
        notificationPermissionButton.bezelStyle = .rounded
        notificationPermissionButton.controlSize = .regular
        let notifButtons = NSStackView(views: [notificationTestButton, notificationPermissionButton])
        notifButtons.orientation = .horizontal
        notifButtons.spacing = 10
        let notifStatusBlock = NSStackView(views: [notificationStatusField, leadingRow(notifButtons)])
        notifStatusBlock.orientation = .vertical
        notifStatusBlock.alignment = .leading
        notifStatusBlock.spacing = 10
        refreshNotificationStatus()
        commandFinishedThresholdField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        // "Which events notify me" — one row per NotificationEvent, in enum order. The
        // command-finished row carries its runtime threshold as a sub-row. State/target are
        // already wired in `configureControls` (the authoritative seed, so a flush can never
        // clobber settings with unseeded toggles); here we only lay out the rows.
        var eventRows: [NSView] = []
        for event in NotificationEvent.allCases {
            guard let toggle = eventToggles[event] else { continue }
            eventRows.append(settingsToggleRow(event.title, toggle, hint: event.detail))
            if event == .commandFinished {
                eventRows.append(settingsRow("Threshold (seconds)", commandFinishedThresholdField,
                                             hint: "Only commands that ran at least this long trigger the notification."))
            }
        }
        let notifyGroup = settingsGroup("Notify me about", eventRows)
        // "How notifications are delivered" — the two global channel toggles + permission status.
        let deliveryGroup = settingsGroup("Delivery", [
            settingsToggleRow("macOS banner", systemNotificationsToggle),
            settingsToggleRow("Sound", notificationSoundToggle),
            notifStatusBlock,
        ])
        let notchGroup = settingsGroup("Notch HUD", [
            settingsRow("Visibility", notchModeSegment, hint: "Automatic shows the notch in Agent Workspace only."),
            settingsToggleRow("Hover", notchOpenOnHoverToggle),
            notchSummaryLabel,
        ])

        let detectionCaption = settingsCaption("Harness identifies agents by walking each pane's process tree and matching the executables shown below — it works for any shell, no setup. Install hooks so an agent can ping you the moment it stops or needs input (the config is merged into the agent's own file and backed up first). Customize matching in agents.json.")
        let editAgents = makeRoundedButton("Edit agents.json…", action: #selector(openAgentsJSON))
        let detectionBox = NSStackView(views: [detectionCaption, leadingRow(editAgents)])
        detectionBox.orientation = .vertical
        detectionBox.alignment = .leading
        detectionBox.spacing = 12

        let reset = makeRoundedButton("Reset Agent Colors", action: #selector(resetAgentColors))

        let promptCaption = settingsCaption("Trouble with one-click install (or a tool Harness doesn't manage)? Copy this prompt and paste it into any coding agent/IDE running on this Mac — it will wire up its own Harness hook.")
        let promptPreview = NSTextField(wrappingLabelWithString: AgentHookInstaller.setupPrompt)
        promptPreview.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        promptPreview.textColor = .secondaryLabelColor
        promptPreview.isSelectable = true
        let copyPrompt = makeRoundedButton("Copy Setup Prompt", action: #selector(copySetupPrompt))
        let promptBox = NSStackView(views: [promptCaption, promptPreview, leadingRow(copyPrompt)])
        promptBox.orientation = .vertical
        promptBox.alignment = .leading
        promptBox.spacing = 12

        let stack = NSStackView(views: [
            header,
            notifyGroup,
            deliveryGroup,
            notchGroup,
            settingsGroup("Detection & hooks", [detectionBox]),
            settingsGroup("Set up via your IDE", [promptBox]),
            settingsGroup("Agents", Self.agentColorKinds.map(agentRow) + [leadingRow(reset)]),
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
        icon.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: 18)
        icon.contentTintColor = NSColor.fromHex(colorHex) ?? c.textSecondary
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        agentIconViews[kind] = icon

        let name = NSTextField(labelWithString: kind.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        let execs = NSTextField(labelWithString: executablesString(for: kind))
        execs.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        execs.textColor = .secondaryLabelColor
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
            let button = NSButton(title: installed ? "Reinstall Hooks" : "Install Hooks", target: self, action: #selector(installHooksClicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
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

    /// Pull the live macOS permission state into the caption so the user can tell whether the
    /// system is allowing alerts at all (the common reason agent notifications never appear).
    private func refreshNotificationStatus() {
        DesktopNotifier.authorizationStatus { [weak self] status in
            guard let self else { return }
            let text: String
            let needsAllow: Bool
            switch status {
            case .authorized, .provisional:
                text = "macOS is allowing notifications."
                needsAllow = false
            case .denied:
                text = "macOS is blocking notifications for Harness. Click below to allow them in System Settings ▸ Notifications."
                needsAllow = true
            case .notDetermined:
                text = "Notifications haven't been authorized yet. Send a test to grant them."
                needsAllow = true
            @unknown default:
                text = ""
                needsAllow = true
            }
            self.notificationStatusField.stringValue = text
            self.notificationPermissionButton.isHidden = !needsAllow
        }
    }

    @objc private func copySetupPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentHookInstaller.setupPrompt, forType: .string)
        Toast.show("Setup prompt copied — paste it into your IDE/agent", in: view)
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
    private var advDaemonReachable = true
    /// The daemon-backed controls (set-option surface), disabled when the daemon is unreachable.
    /// Excludes the performance toggles, which write local settings and stay usable offline.
    private var advDaemonControls: [NSControl] = []

    private func buildAdvancedPage() -> NSView {
        let header = pageHeader(title: "Advanced", trailing: nil)
        advDaemonControls.removeAll() // repopulated by the adv* factories below
        // The adv* controls are rebuilt on every Advanced-page show, so the prior batch's identifiers
        // are stale (keyed by ObjectIdentifier of freed controls). Clear the map alongside the control
        // list, otherwise it grows unbounded across reopens.
        advOptKeys.removeAll()
        loadAdvancedValues()
        // The performance toggles are member controls (not rebuilt by the adv* factories), so unlike
        // the daemon-backed controls they don't get refreshed by `loadAdvancedValues`. Re-read their
        // state from settings here so a rebuilt page reflects changes made since the last build.
        let perfSettings = SessionCoordinator.shared.settings
        offMainPipelineToggle.state = perfSettings.offMainParserFramePipeline ? .on : .off
        liveResizeReflowToggle.state = perfSettings.liveResizeReflow ? .on : .off

        let statusGroup = settingsGroup("Status bar", [
            settingsCaption("Format the bottom status bar (FormatString tokens like #{cwd_basename}, #{git_branch}, #{time:%H:%M}). The on/off switch is in Appearance ▸ Window."),
            settingsRow("Status position", advSegment("status-position", ["bottom", "top"])),
            settingsRow("Status left", advField("status-left", width: 260)),
            settingsRow("Status right", advField("status-right", width: 260)),
        ])

        let inputGroup = settingsGroup("Input", [
            settingsToggleRow("Mouse reporting", advToggle("mouse", "")),
            settingsRow("Copy-mode keys", advSegment("mode-keys", ["vi", "emacs"])),
            settingsToggleRow("OSC 52 clipboard", advToggle("set-clipboard", "")),
        ])

        let identityGroup = settingsGroup("Terminal identity", [
            settingsCaption("How Harness identifies itself to programs (TERM_PROGRAM + XTVERSION). Compatible reports a protocol-compatible identity so tools like Claude Code enable Shift+Enter immediately. Harness reports its true name and version. Applies to newly-opened panes."),
            settingsRow("Reported identity", advSegment(TerminalIdentity.optionKey, TerminalIdentity.Mode.allCases.map(\.rawValue))),
        ])

        let indexGroup = settingsGroup("Indexing", [
            settingsRow("Window base index", advSegment("base-index", ["0", "1"])),
            settingsRow("Pane base index", advSegment("pane-base-index", ["0", "1"])),
            settingsToggleRow("Renumber windows", advToggle("renumber-windows", "")),
        ])

        let titleGroup = settingsGroup("Titles & monitoring", [
            settingsToggleRow("Program tab titles", advToggle("allow-rename", "")),
            settingsToggleRow("Automatic rename", advToggle("automatic-rename", "")),
            settingsToggleRow("Monitor activity", advToggle("monitor-activity", "")),
            settingsToggleRow("Monitor bell", advToggle("monitor-bell", "")),
            settingsRow("Silence alert (s)", advField("monitor-silence", width: 80)),
        ])

        let lifecycleGroup = settingsGroup("Lifecycle", [
            settingsToggleRow("Remain on exit", advToggle("remain-on-exit", "")),
            settingsRow("Prefix repeat (ms)", advField("repeat-time", width: 100)),
            settingsRow("History limit", advField("history-limit", width: 120), hint: "Session scrollback; the renderer's own scrollback is in Terminal ▸ Behavior."),
        ])

        let borderGroup = settingsGroup("Pane borders", [
            settingsRow("Pane border labels", advSegment("pane-border-status", ["off", "top", "bottom"])),
            settingsRow("Border format", advField("pane-border-format", width: 260)),
        ])

        let performanceGroup = settingsGroup("Performance", [
            settingsToggleRow("Off-main render pipeline", offMainPipelineToggle,
                              hint: "Parse + build frames off the main thread. On is recommended."),
            settingsToggleRow("Real-time resize", liveResizeReflowToggle,
                              hint: "Reflow and redraw the running program live while dragging the "
                                  + "window edge, instead of on release. On is recommended."),
        ])

        let intro = settingsCaption("Power-user options shared with the harness-cli set-option command surface. Changes apply globally and persist immediately.")
        // When the daemon is unreachable these groups show builtin defaults, NOT the live state, and
        // a change can't be applied — so disable the daemon-backed controls and warn inline at the
        // top. The performance toggles (local settings) stay usable. Re-checked each time the page is
        // shown (see `showPage`). The set-option surface depends on the daemon, so it's gated here.
        if !advDaemonReachable {
            for control in advDaemonControls { control.isEnabled = false }
        }
        var views: [NSView] = [header, intro]
        if !advDaemonReachable {
            views.append(advUnreachableBanner())
        }
        views.append(contentsOf: [
            performanceGroup,
            statusGroup,
            inputGroup,
            identityGroup,
            indexGroup,
            titleGroup,
            lifecycleGroup,
            borderGroup,
        ])
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        return scrollWrap(stack)
    }

    /// Inline warning shown atop the Advanced page when the daemon is unreachable: the controls
    /// below show builtin defaults, not live state, and edits can't be applied. Uses the chrome's
    /// danger color so it reads as a real warning, consistent with the rest of Settings.
    private func advUnreachableBanner() -> NSView {
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 6
        banner.layer?.backgroundColor = HarnessChrome.current.danger.withAlphaComponent(0.12).cgColor
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = HarnessChrome.current.danger.withAlphaComponent(0.35).cgColor
        let label = NSTextField(wrappingLabelWithString:
            "Daemon unreachable — showing defaults; changes can't be applied.")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = HarnessChrome.current.danger
        label.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -9),
        ])
        return banner
    }

    private func loadAdvancedValues() {
        advValues.removeAll()
        for (key, value) in OptionStore.builtinDefaults { advValues[key] = value.stringValue }
        // `requestDaemon` returns nil when the daemon is unreachable. Distinguish that from a real
        // empty-options reply: only overlay (and mark reachable) on an actual `.options` response,
        // so an unreachable daemon renders builtin defaults that the page flags as not-live.
        if case let .options(entries)? = SessionCoordinator.shared.requestDaemon(.showOptions(scope: nil)) {
            for entry in entries where entry.scope == "global" { advValues[entry.key] = entry.value }
            advDaemonReachable = true
        } else {
            advDaemonReachable = false
        }
    }

    private func advToggle(_ key: String, _ title: String) -> HarnessToggle {
        let toggle = HarnessToggle(title: title)
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
        label.textColor = .secondaryLabelColor
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

    private func pageHeader(title: String, trailing: NSButton? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
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

    // MARK: - Grouped settings primitives

    /// One settings row: label column, flexible middle, trailing control.
    private func settingsRow(_ label: String, _ control: NSView, hint: String? = nil) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        func makeSpacer() -> NSView {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return spacer
        }

        if label.isEmpty {
            row.addArrangedSubview(control)
            row.addArrangedSubview(makeSpacer())
        } else {
            let titleLabel = NSTextField(labelWithString: label)
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.textColor = .labelColor
            titleLabel.alignment = .right
            titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
            titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let labelCol: NSView
            if let hint {
                let hintLabel = NSTextField(wrappingLabelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 11)
                hintLabel.textColor = .secondaryLabelColor
                hintLabel.alignment = .right
                hintLabel.preferredMaxLayoutWidth = 150
                let col = NSStackView(views: [titleLabel, hintLabel])
                col.orientation = .vertical
                col.alignment = .trailing
                col.spacing = 2
                labelCol = col
            } else {
                labelCol = titleLabel
            }
            row.addArrangedSubview(labelCol)
            row.addArrangedSubview(makeSpacer())
            row.addArrangedSubview(control)
        }
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }

    /// Convenience: build a list of `settingsRow`s from `(label, control)` pairs.
    private func settingsRows(_ items: [(String, NSView)]) -> [NSView] {
        items.map { settingsRow($0.0, $0.1) }
    }

    private func settingsToggleRow(_ title: String, _ toggle: HarnessToggle, hint: String? = nil) -> NSView {
        toggle.title = ""
        toggle.setAccessibilityLabel(title)
        return settingsRow(title, toggle, hint: hint)
    }

    private func settingsGroup(_ title: String?, _ rows: [NSView]) -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false

        if let title, !title.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            outer.addArrangedSubview(label)
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
            if index > 0 { rowStack.addArrangedSubview(groupDivider()) }
            rowStack.addArrangedSubview(paddedRow(content))
        }

        surface.addSubview(rowStack)
        outer.addArrangedSubview(surface)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: surface.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
        ])
        return outer
    }

    /// Uniform insets around one group row (content provides its own height).
    private func paddedRow(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
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
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        ])
        return wrap
    }

    private func colorGrid(
        left: [(title: String, binding: ColorBinding)],
        right: [(title: String, binding: ColorBinding)]
    ) -> NSView {
        let leftColumn = colorColumn(left)
        let rightColumn = colorColumn(right)
        let row = NSStackView(views: [leftColumn, rightColumn])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 28
        return row
    }

    private func colorColumn(_ items: [(title: String, binding: ColorBinding)]) -> NSView {
        let column = NSStackView(views: items.map { colorHexRow(title: $0.title, binding: $0.binding) })
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 10
        return column
    }

    /// `[swatch] Name [hex] [reset-slot]` with fixed subcolumns so every row aligns.
    private func colorHexRow(title: String, binding: ColorBinding) -> NSView {
        binding.field.widthAnchor.constraint(equalToConstant: ColorFormMetrics.fieldWidth).isActive = true
        binding.field.placeholderString = binding.themeColor()?.uppercased() ?? "—"
        binding.field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        binding.field.usesSingleLineMode = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: ColorFormMetrics.labelWidth).isActive = true

        let resetSlot = NSView()
        resetSlot.translatesAutoresizingMaskIntoConstraints = false
        binding.reset.translatesAutoresizingMaskIntoConstraints = false
        resetSlot.addSubview(binding.reset)
        NSLayoutConstraint.activate([
            resetSlot.widthAnchor.constraint(equalToConstant: ColorFormMetrics.resetSlotWidth),
            resetSlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            binding.reset.centerXAnchor.constraint(equalTo: resetSlot.centerXAnchor),
            binding.reset.centerYAnchor.constraint(equalTo: resetSlot.centerYAnchor),
        ])

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [binding.well, label, binding.field, resetSlot, spacer])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
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

        content.alignment = .leading
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 34),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -36),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -34),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
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
        button.contentTintColor = .tertiaryLabelColor
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

    private func updateFontReadout() {
        let s = SessionCoordinator.shared.settings
        fontReadout.stringValue = "\(s.fontFamily) · \(Int(s.fontSize.rounded()))pt"
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
        case .afterFirst: return "After first"
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
        case .topRight: return "Top right"
        case .bottomRight: return "Bottom right"
        }
    }

    private func resizeOverlayPositionValue(_ title: String?) -> ResizeOverlayPosition {
        switch title {
        case "Top right": return .topRight
        case "Bottom right": return .bottomRight
        default: return .center
        }
    }

    private func bellModeTitle(_ mode: BellMode) -> String {
        switch mode {
        case .off: return "Off"
        case .audible: return "Audible"
        case .visual: return "Visual"
        case .both: return "Both"
        }
    }

    private func bellModeValue(_ title: String?) -> BellMode {
        switch title {
        case "Off": return .off
        case "Audible": return .audible
        case "Both": return .both
        default: return .visual
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
        scrollMultiplierLabel.stringValue = abs(value - 1) < 0.05 ? "1.0× (native)" : String(format: "%.1f×", value)
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
        try? coordinator.settings.save()
        coordinator.applySettingsToHosts()
        syncAppearanceControlsFromSettings()
        refreshColorPlaceholders()
    }

    @objc private func systemDarkThemeDidChange() {
        guard let theme = systemDarkThemePopup.titleOfSelectedItem else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.settings.systemDarkThemeName = theme
        coordinator.settings.clearThemeColorOverrides()
        try? coordinator.settings.save()
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
        SessionCoordinator.shared.requestDaemon(.setKeepSessionsOnQuit(keep))
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
                defaultTerminalStatusField.stringValue = error.localizedDescription
            }
            defaultTerminalButton.isEnabled = true
            refreshDefaultTerminalStatus()
        }
    }

    private func refreshDefaultTerminalStatus() {
        let status = DefaultTerminalManager.status()
        defaultTerminalStatusField.stringValue = status.summary
        defaultTerminalButton.title = status.isDefault ? "Default terminal set" : "Set Harness as default terminal"
    }

    private var selectedAppearanceMode: HarnessAppearanceMode {
        let title = appearanceModePopup.titleOfSelectedItem ?? ""
        return HarnessAppearanceMode.allCases.first { Self.appearanceModeTitle($0) == title } ?? .theme
    }

    private func populateThemePopup(_ popup: HarnessSelect, selectedThemeName: String) {
        popup.removeAllItems()
        for name in ThemeManager.allThemeNames() {
            popup.addItem(withTitle: name)
        }
        popup.selectItem(withTitle: selectedThemeName)
    }

    private func updateSystemThemePickerAvailability() {
        let followsSystem = selectedAppearanceMode == .macOSSystem
        for row in systemThemeRows {
            row.isHidden = !followsSystem
        }
        systemLightThemePopup.isEnabled = followsSystem
        systemDarkThemePopup.isEnabled = followsSystem
    }

    private func syncSystemThemePickersFromSettings() {
        let settings = SessionCoordinator.shared.settings
        systemLightThemePopup.selectItem(withTitle: settings.systemLightThemeName)
        systemDarkThemePopup.selectItem(withTitle: settings.systemDarkThemeName)
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
        case .macOSSystem: return "Follow macOS Appearance"
        }
    }

    /// The selected experience mode, derived from the segment position.
    private var selectedExperienceMode: ExperienceMode {
        let cases = ExperienceMode.allCases
        let i = experienceSegment.selectedSegment
        return cases.indices.contains(i) ? cases[i] : .plain
    }

    private var selectedNotchVisibilityMode: NotchVisibilityMode {
        let cases = NotchVisibilityMode.allCases
        let i = notchModeSegment.selectedSegment
        return cases.indices.contains(i) ? cases[i] : .automatic
    }

    private func notchModeTitle(_ mode: NotchVisibilityMode) -> String {
        switch mode {
        case .automatic: return "Automatic"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    private func notchSummary(for mode: NotchVisibilityMode) -> String {
        switch mode {
        case .automatic:
            return "Automatic shows the top-center Agent HUD only in Agent Workspace. It passively summarizes sessions, agents, and hook-driven waiting state."
        case .on:
            return "The Agent HUD is always available at the top center of the main display as a session overview."
        case .off:
            return "The Agent HUD is disabled. Menu-bar sessions and normal notifications still work."
        }
    }

    @objc private func notchSettingsChanged() {
        notchSummaryLabel.stringValue = notchSummary(for: selectedNotchVisibilityMode)
        flushAndApply()
    }

    /// Switching mode re-gates the chrome (prefix + status line), sets the default
    /// session-persistence policy on the daemon, and refreshes the live surfaces — all on the
    /// one session core. `flushAndApply` persists the setting and posts the chrome-changed
    /// notification the status line + prefix react to.
    @objc private func experienceModeChanged() {
        let mode = selectedExperienceMode
        experienceSummaryLabel.stringValue = mode.summary
        flushAndApply()
        PrefixKeymap.shared.rebuildFromSettings()
        // Mode sets the default persistence: Plain is ephemeral (a clean quit closes its
        // sessions), the others keep sessions running. The user can still override via the
        // "Keep sessions running" toggle. Mirror the snapshot truth into that toggle so the
        // two controls stay consistent while the window is open.
        let keep = mode.persistsSessionsByDefault
        if SessionCoordinator.shared.requestDaemon(.setKeepSessionsOnQuit(keep)) != nil {
            // Record the live apply so the launch-time reconcile sees this mode as settled —
            // otherwise the next launch would treat the switch as a cross-launch mode change and
            // re-impose the default over any keep-on-quit override made after switching.
            AppDelegate.recordModePersistenceApplied(mode)
        }
        keepSessionsToggle.state = keep ? .on : .off
    }

    /// The per-component prefix override re-gates the prefix key independently of the status line
    /// (and of the experience mode). Mirrors the chrome-refresh path of `experienceModeChanged`.
    @objc private func prefixControlChanged() {
        SessionCoordinator.shared.settings.prefixKeyEnabled = selectedPrefixEnabled
        flushAndApply()
        PrefixKeymap.shared.rebuildFromSettings()
    }

    /// The per-component status-line override re-gates the bottom status band independently of the
    /// prefix. `flushAndApply` posts the chrome-changed notification `StatusLineView` reacts to.
    @objc private func statusLineControlChanged() {
        SessionCoordinator.shared.settings.statusLineEnabled = selectedStatusLineEnabled
        flushAndApply()
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
        updateSystemThemePickerAvailability()
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
        well.widthAnchor.constraint(equalToConstant: ColorFormMetrics.swatchWidth).isActive = true
        well.heightAnchor.constraint(equalToConstant: ColorFormMetrics.swatchHeight).isActive = true
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

    @objc private func resetAgentColors() {
        guard confirmDestructive(
            message: "Reset agent colors?",
            info: "All custom agent color overrides will be removed. This can't be undone.",
            confirmTitle: "Reset"
        ) else { return }
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
        windowBorderOpacitySlider.doubleValue = Double(settings.windowBorderOpacity)
        windowBorderOpacityLabel.stringValue = formatPercent(settings.windowBorderOpacity)
        paddingXField.stringValue = String(Int(settings.windowPaddingX.rounded()))
        paddingYField.stringValue = String(Int(settings.windowPaddingY.rounded()))
        fontFamilyField.stringValue = settings.fontFamily
        fontSizeField.stringValue = String(Int(settings.fontSize.rounded()))
        appearanceModePopup.selectItem(withTitle: Self.appearanceModeTitle(settings.appearanceMode))
        systemLightThemePopup.selectItem(withTitle: settings.systemLightThemeName)
        systemDarkThemePopup.selectItem(withTitle: settings.systemDarkThemeName)
        updateSystemThemePickerAvailability()
        experienceSegment.selectItem(withTitle: settings.experienceMode.displayName)
        experienceSummaryLabel.stringValue = settings.experienceMode.summary
        cursorStyleSegment.selectItem(withTitle: cursorStyleTitle(settings.cursorStyle))
        cursorBlinkToggle.state = settings.cursorBlink ? .on : .off
        copyOnSelectToggle.state = settings.copyOnSelect ? .on : .off
        keepSessionsToggle.state = SessionCoordinator.shared.snapshot.keepSessionsOnQuit ? .on : .off
        vividColorsToggle.state = settings.colorRendering == .vivid ? .on : .off
        textRenderingSegment.selectItem(withTitle: textRenderingTitle(settings.textRendering))
        themeTerminalOutputToggle.state = settings.applyThemeToTerminalOutput ? .on : .off
        ligaturesToggle.state = settings.ligatures ? .on : .off
        offMainPipelineToggle.state = settings.offMainParserFramePipeline ? .on : .off
        liveResizeReflowToggle.state = settings.liveResizeReflow ? .on : .off
        resizeOverlaySegment.selectItem(withTitle: resizeOverlayTitle(settings.resizeOverlay))
        resizeOverlayPositionSegment.selectItem(withTitle: resizeOverlayPositionTitle(settings.resizeOverlayPosition))
        bellSegment.selectItem(withTitle: bellModeTitle(settings.bellMode))
        paddingBalanceToggle.state = settings.windowPaddingBalance ? .on : .off
        minContrastSlider.doubleValue = settings.minimumContrast
        updateMinContrastLabel()
        scrollMultiplierSlider.doubleValue = settings.scrollMultiplier
        updateScrollMultiplierLabel()
        mouseHideToggle.state = settings.mouseHideWhileTyping ? .on : .off
        quickTerminalToggle.state = settings.quickTerminalEnabled ? .on : .off
        pasteProtectionToggle.state = settings.pasteProtection ? .on : .off
        boldIsBrightToggle.state = settings.boldIsBright ? .on : .off
        for (event, toggle) in eventToggles {
            toggle.state = settings.isEventEnabled(event) ? .on : .off
        }
        commandFinishedThresholdField.stringValue = String(settings.commandFinishedThresholdSeconds)
        showStatusLineToggle.state = settings.showStatusLine ? .on : .off
        sidebarVisibleToggle.state = settings.sidebarVisible ? .on : .off
        restoreWindowSizeToggle.state = settings.restoreWindowSize ? .on : .off
        prefixControlSegment.selectItem(withTitle: harnessControlsTitle(settings.prefixKeyEnabled))
        statusLineControlSegment.selectItem(withTitle: harnessControlsTitle(settings.statusLineEnabled))
        systemNotificationsToggle.state = settings.systemNotificationsEnabled ? .on : .off
        notificationSoundToggle.state = settings.notificationSoundEnabled ? .on : .off
        notchModeSegment.selectItem(withTitle: notchModeTitle(settings.notchVisibilityMode))
        notchOpenOnHoverToggle.state = settings.notchOpenOnHover ? .on : .off
        notchSummaryLabel.stringValue = notchSummary(for: settings.notchVisibilityMode)
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
    private func flushAndApply() {
        applySettingsLive()
        try? SessionCoordinator.shared.settings.save()
    }

    /// Push every field into HarnessSettings and apply it to the live surfaces, but DO NOT persist.
    /// Used on continuous slider drag ticks (60–120 Hz) so scrubbing never triggers a JSON encode +
    /// atomic write per tick; persistence happens once on the gesture's commit (`onCommit`). Every
    /// other control still goes through `flushAndApply`, which saves.
    private func applySettingsLive() {
        let coordinator = SessionCoordinator.shared
        coordinator.settings.backgroundOpacity = HarnessSettings.clampedOpacity(Float(opacitySlider.doubleValue))
        coordinator.settings.backgroundBlur = HarnessSettings.clampedBlur(Int(blurSlider.doubleValue.rounded()))
        coordinator.settings.windowBorderOpacity = max(0, min(1, Float(windowBorderOpacitySlider.doubleValue)))
        // Read every editable color from its control (bg/fg/cursor/cursor-text/
        // selection/bold + divider/status accents). nil = fall back to theme preset.
        for binding in colorBindings {
            coordinator.settings[keyPath: binding.keyPath] = normalizedHexOrNil(binding.field.stringValue)
        }
        coordinator.settings.paletteHex = HarnessSettings.normalizedPalette(paletteHexValues)
        coordinator.settings.transparentTitlebar = transparentTitlebarToggle.state == .on
        coordinator.settings.showStatusLine = showStatusLineToggle.state == .on
        coordinator.settings.sidebarVisible = sidebarVisibleToggle.state == .on
        coordinator.settings.restoreWindowSize = restoreWindowSizeToggle.state == .on
        coordinator.settings.windowPaddingX = HarnessSettings.clampedPadding(Float(paddingXField.stringValue) ?? 12)
        coordinator.settings.windowPaddingY = HarnessSettings.clampedPadding(Float(paddingYField.stringValue) ?? 12)
        let previousAppearanceMode = coordinator.settings.appearanceMode
        let nextAppearanceMode = selectedAppearanceMode
        coordinator.settings.appearanceMode = nextAppearanceMode
        if previousAppearanceMode != nextAppearanceMode {
            coordinator.settings.clearThemeColorOverrides()
            paletteHexValues = HarnessSettings.normalizedPalette(coordinator.settings.paletteHex)
            for (index, well) in paletteWells.enumerated() {
                well.color = paletteHexValues[index].flatMap(NSColor.fromHex)
                    ?? NSColor.fromHex(Self.defaultAnsiPalette[index]) ?? .gray
            }
            for binding in colorBindings {
                binding.field.stringValue = ""
                refreshColorBinding(binding)
            }
        }
        if previousAppearanceMode != .macOSSystem && nextAppearanceMode == .macOSSystem {
            Self.seedUnsetSystemThemeNames(settings: &coordinator.settings, selectedThemeName: coordinator.snapshot.themeName)
            syncSystemThemePickersFromSettings()
        }
        coordinator.settings.fontSize = HarnessSettings.clampedFontSize(Float(fontSizeField.stringValue) ?? 14)
        coordinator.settings.fontFamily = fontFamilyField.stringValue
        coordinator.settings.defaultShell = shellField.stringValue
        coordinator.settings.defaultCWD = cwdField.stringValue
        // `0` is the unlimited sentinel (kept verbatim); any other value is floored at 100 lines.
        let enteredScrollback = Int(scrollbackField.stringValue) ?? 10_000
        coordinator.settings.scrollbackLines = enteredScrollback == 0 ? 0 : max(100, enteredScrollback)
        coordinator.settings.cursorStyle = cursorStyleValue(cursorStyleSegment.titleOfSelectedItem)
        coordinator.settings.cursorBlink = cursorBlinkToggle.state == .on
        coordinator.settings.copyOnSelect = copyOnSelectToggle.state == .on
        coordinator.settings.systemNotificationsEnabled = systemNotificationsToggle.state == .on
        coordinator.settings.notificationSoundEnabled = notificationSoundToggle.state == .on
        coordinator.settings.notchVisibilityMode = selectedNotchVisibilityMode
        coordinator.settings.notchOpenOnHover = notchOpenOnHoverToggle.state == .on
        coordinator.settings.colorRendering = vividColorsToggle.state == .on ? .vivid : .accurate
        coordinator.settings.textRendering = textRenderingValue(textRenderingSegment.titleOfSelectedItem)
        coordinator.settings.applyThemeToTerminalOutput = themeTerminalOutputToggle.state == .on
        coordinator.settings.ligatures = ligaturesToggle.state == .on
        coordinator.settings.showPromptGutter = promptGutterToggle.state == .on
        coordinator.settings.offMainParserFramePipeline = offMainPipelineToggle.state == .on
        coordinator.settings.liveResizeReflow = liveResizeReflowToggle.state == .on
        coordinator.settings.resizeOverlay = resizeOverlayValue(resizeOverlaySegment.titleOfSelectedItem)
        coordinator.settings.resizeOverlayPosition = resizeOverlayPositionValue(resizeOverlayPositionSegment.titleOfSelectedItem)
        coordinator.settings.bellMode = bellModeValue(bellSegment.titleOfSelectedItem)
        coordinator.settings.scrollMultiplier = HarnessSettings.clampedScrollMultiplier(scrollMultiplierSlider.doubleValue)
        coordinator.settings.mouseHideWhileTyping = mouseHideToggle.state == .on
        coordinator.settings.quickTerminalEnabled = quickTerminalToggle.state == .on
        coordinator.settings.windowPaddingBalance = paddingBalanceToggle.state == .on
        coordinator.settings.minimumContrast = HarnessSettings.clampedContrast(minContrastSlider.doubleValue)
        coordinator.settings.pasteProtection = pasteProtectionToggle.state == .on
        coordinator.settings.boldIsBright = boldIsBrightToggle.state == .on
        for (event, toggle) in eventToggles {
            coordinator.settings.setEventEnabled(event, toggle.state == .on)
        }
        coordinator.settings.commandFinishedThresholdSeconds = max(1, Int(commandFinishedThresholdField.stringValue) ?? 10)
        // Reflect every clamped numeric field back into the UI so typing an out-of-range value
        // (fontSize "2", threshold "0", …) doesn't leave the field showing one number while the
        // setting — and the live terminals — silently use the clamped one. Non-numeric entries
        // reset to the persisted value the same way.
        reflectClamped(commandFinishedThresholdField, String(coordinator.settings.commandFinishedThresholdSeconds))
        reflectClamped(fontSizeField, String(format: "%.0f", coordinator.settings.fontSize))
        reflectClamped(paddingXField, String(format: "%.0f", coordinator.settings.windowPaddingX))
        reflectClamped(paddingYField, String(format: "%.0f", coordinator.settings.windowPaddingY))
        reflectClamped(scrollbackField, String(coordinator.settings.scrollbackLines))
        coordinator.settings.experienceMode = selectedExperienceMode
        coordinator.settings.prefixKeyEnabled = selectedPrefixEnabled
        coordinator.settings.statusLineEnabled = selectedStatusLineEnabled

        // Theme switching (and its color seeding) is handled by themeDidChange, so this only ever
        // pushes the current settings to the live surfaces — scrubbing a slider never fires a
        // setTheme IPC. Persistence is the caller's job (`flushAndApply` saves; drag ticks don't).
        coordinator.applySettingsToHosts()
        NotchPanelController.shared.refreshVisibility()
        QuickTerminalController.shared.rebuildFromSettings()
        updateFontReadout()
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
        layer?.cornerRadius = 6
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
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    func applyChrome() {
        let c = HarnessChrome.current
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

    static func show() {
        window?.close()
        let controller = SettingsViewController()
        let win = NSWindow(contentViewController: controller)
        win.title = "Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.titlebarAppearsTransparent = false
        win.titleVisibility = .visible
        win.isMovableByWindowBackground = false
        win.isRestorable = false
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 840, height: 600)
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
