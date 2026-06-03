import Foundation

public enum TerminalColorRenderingMode: String, Codable, Sendable {
    case accurate
    case vivid
}

public enum TerminalColorGamut: String, Codable, Sendable {
    case sRGB = "srgb"
    case displayP3 = "display-p3"
    case auto

    public static func resolved(
        renderingMode: TerminalColorRenderingMode,
        requested: TerminalColorGamut
    ) -> TerminalColorGamut {
        switch renderingMode {
        case .accurate:
            // Accurate mode is the authored sRGB identity path regardless of the stored gamut.
            return .sRGB
        case .vivid:
            // This task's wide-gamut path is explicit Display-P3 output.
            return .displayP3
        }
    }
}

public enum TerminalTextRenderingMode: String, Codable, Sendable {
    case native
    case crisp
    case soft

    public var glyphGamma: Float {
        switch self {
        case .native: return 1.0
        case .crisp: return 0.8
        case .soft: return 1.15
        }
    }
}

/// When the live grid-size overlay ("120 × 32") is shown while resizing the window (Ghostty's
/// `resize-overlay`). `afterFirst` (default) skips the overlay on the terminal's first sizing
/// (opening a window isn't a resize) but shows it on every interactive resize after.
public enum ResizeOverlayMode: String, Codable, Sendable, CaseIterable {
    case afterFirst = "after-first"
    case always
    case never
}

/// Where the resize overlay is drawn within the surface.
public enum ResizeOverlayPosition: String, Codable, Sendable, CaseIterable {
    case center
    case topRight = "top-right"
    case bottomRight = "bottom-right"
}

private enum LegacyHarnessSettingsCodingKeys: String, CodingKey {
    case tmuxControlsEnabled
}

public struct HarnessSettings: Codable, Sendable, Equatable {
    public var fontSize: Float
    public var fontFamily: String
    public var defaultShell: String
    public var defaultCWD: String
    public var transparentTitlebar: Bool
    public var sidebarVisible: Bool
    /// Restore the main window's size + position across launches. When false (default),
    /// the window opens at its built-in default size, centered. Window-level only — the
    /// frame is persisted via `NSWindow.setFrameAutosaveName`.
    public var restoreWindowSize: Bool
    public var backgroundOpacity: Float
    public var backgroundBlur: Int
    public var windowPaddingX: Float
    public var windowPaddingY: Float
    /// Custom hex (`#rrggbb`) overrides imported from terminal config when present.
    /// `nil` means "use the active theme color".
    public var customBackgroundHex: String?
    public var customForegroundHex: String?
    public var customCursorHex: String?
    /// Signature of the terminal config last imported into these defaults.
    /// Used to migrate stale early settings without overwriting later manual edits.
    public var importedConfigSignature: String?
    /// Prefix key (default `ctrl-a`). Format: `mod1-mod2-key`,
    /// where mod is `ctrl|cmd|opt|shift`. Set empty string to disable.
    public var prefixKey: String
    /// Number of lines kept in scrollback per pane (passed to the renderer + RealPty).
    public var scrollbackLines: Int
    /// Cursor shape: `block`, `bar`, or `underline` (`cursor-style`).
    public var cursorStyle: String
    /// Whether the text cursor blinks (`cursor-style-blink`).
    public var cursorBlink: Bool
    /// Copy a mouse selection to the clipboard automatically (`copy-on-select`).
    public var copyOnSelect: Bool
    /// Terminal color overrides (terminal parity). `nil` = derive from the active
    /// theme preset. Applied by the native renderer.
    public var selectionBackgroundHex: String?
    public var selectionForegroundHex: String?
    public var boldColorHex: String?
    public var cursorTextHex: String?
    /// 16 ANSI palette overrides (`palette N=#hex`). `nil` slots fall back to the
    /// active theme preset. Seeded from a theme, importable from terminal config.
    public var paletteHex: [String?]
    /// Per-agent brand color overrides keyed by `AgentKind.rawValue`.
    /// Missing keys use the built-in agent default.
    public var agentColorOverrides: [String: String]
    /// Color of the 1px hairline divider between sidebar and content (and any
    /// other in-window divider line). nil → derive from the theme.
    public var dividerHex: String?
    /// Color of the bottom status line's text. nil → derive from the theme.
    public var statusLineHex: String?
    /// Fire a macOS system notification when an agent transitions to `waiting`
    /// (e.g. Codex needs approval, Claude completed a task). When false, the
    /// in-window bell badge still updates but the OS notification banner is
    /// suppressed.
    public var systemNotificationsEnabled: Bool
    /// Play a sound ("chime") with agent notifications. When `systemNotificationsEnabled`
    /// is on, the banner carries the sound; when banners are off but this is on, Harness
    /// plays an in-app chime so an agent stopping / needing input is still audible.
    public var notificationSoundEnabled: Bool
    /// Controls the top-center Agent Notch HUD. `.automatic` shows it only for Agent Workspace.
    public var notchVisibilityMode: NotchVisibilityMode
    /// Open the Agent Notch HUD when the pointer intentionally hovers over it.
    public var notchOpenOnHover: Bool
    /// Terminal color interpretation. `.accurate` is the authored sRGB identity path.
    /// `.vivid` opts into Display-P3 conversion plus a capped saturation lift.
    public var colorRendering: TerminalColorRenderingMode {
        didSet {
            let legacyValue = colorRendering == .vivid
            if vividColors != legacyValue { vividColors = legacyValue }
        }
    }
    /// Stored for future gamut policy. Accurate mode currently resolves to sRGB; vivid mode
    /// resolves to Display-P3.
    public var colorGamut: TerminalColorGamut
    /// Text antialiasing coverage mode. This only maps to glyph coverage gamma; it never
    /// participates in RGB conversion.
    public var textRendering: TerminalTextRenderingMode {
        didSet {
            let legacyValue = textRendering == .crisp
            if linearBlending != legacyValue { linearBlending = legacyValue }
        }
    }
    /// Legacy compatibility field. Kept in sync with `colorRendering` so old configs and
    /// existing callers preserve behavior while new code uses the explicit mode.
    public var vividColors: Bool {
        didSet {
            let mode: TerminalColorRenderingMode = vividColors ? .vivid : .accurate
            if colorRendering != mode { colorRendering = mode }
        }
    }
    /// Legacy compatibility field. `true` maps to `.crisp`; `false` maps to `.native`.
    public var linearBlending: Bool {
        didSet {
            let mode: TerminalTextRenderingMode = linearBlending ? .crisp : .native
            if textRendering != mode { textRendering = mode }
        }
    }
    /// When true, the active theme's 16 ANSI colors recolor terminal *output* too. Default
    /// false: the canvas (default bg/fg/cursor) always follows the
    /// theme so it matches the chrome, but program output keeps untouched/default ANSI
    /// colors — programs render their true colors over a themed, optionally translucent
    /// canvas.
    public var applyThemeToTerminalOutput: Bool
    /// Programming-font ligatures (e.g. `=>`, `!=`, `->`) via CoreText run shaping. On by
    /// default; turn off for the fastest one-glyph-per-cell path.
    public var ligatures: Bool
    /// Moves terminal byte ingestion (VT parse) and frame building to a per-surface serial worker
    /// queue, keeping only AppKit/Metal presentation on the main thread — so heavy output never
    /// contends with input handling, scrolling, or layout. **Default on.** Safe because the
    /// emulator is confined to that serial queue (every main-thread reader snapshots via
    /// `queue.sync`), stale builds are dropped by a render-generation tag, and the row-reuse cache
    /// is queue-owned. An explicitly stored `false` is honored (opt-out).
    public var offMainParserFramePipeline: Bool
    /// Draw the OSC 133 prompt gutter — a per-row stripe in the left margin marking shell
    /// prompts (green = success, red = failure). Off by default; the marks still power
    /// jump-to-prompt either way, so this only controls the stripe's visibility.
    public var showPromptGutter: Bool
    /// Show the bottom status line (workspace · git · clock). When false the band is
    /// hidden and the terminal split extends to the window bottom. Read by
    /// `StatusLineView.refresh` (alongside the `status` option and `showsHarnessControls`).
    public var showStatusLine: Bool
    /// The user-facing experience (Plain / Persistent / Full / Agent). Drives which chrome
    /// is shown, the default session-persistence policy, and onboarding copy — all on top of
    /// the same daemon session core. See `ExperienceMode`.
    public var experienceMode: ExperienceMode
    /// Explicit override for Harness controls visibility (prefix key + status line). `nil` derives
    /// from `experienceMode`. Lets a Persistent/Agent user opt into the prefix and status line
    /// without switching to Full Terminal, or a Full Terminal user turn the controls off without
    /// changing modes.
    public var harnessControlsEnabled: Bool?
    /// When the live resize dimensions overlay ("120 × 32") is shown while resizing the window.
    public var resizeOverlay: ResizeOverlayMode
    /// Where the resize overlay is positioned within the surface.
    public var resizeOverlayPosition: ResizeOverlayPosition
    /// Distribute the leftover sub-cell space evenly so the grid is centered, instead of parking
    /// the remainder at the bottom-right edge (Ghostty's `window-padding-balance`).
    public var windowPaddingBalance: Bool
    /// Minimum WCAG contrast ratio (1…21) forced between a cell's foreground and its background.
    /// 1 = off (no adjustment). Imported from a terminal config's `minimum-contrast`.
    public var minimumContrast: Double
    /// When both are set, the active theme follows the macOS system appearance: `lightThemeName`
    /// under Light, `darkThemeName` under Dark. nil = off (the single `themeName` is used).
    public var lightThemeName: String?
    public var darkThemeName: String?
    /// Confirm before pasting text containing newlines / control characters when the program has
    /// not enabled bracketed paste — guards against blind multi-line command execution.
    public var pasteProtection: Bool
    /// Post a desktop notification when a command that ran longer than
    /// `commandFinishedThresholdSeconds` finishes in an unfocused pane (uses OSC 133 timing).
    public var commandFinishedNotifications: Bool
    public var commandFinishedThresholdSeconds: Int

    /// Whether Harness controls (prefix-key handling, prefix indicator, and status line)
    /// should be active. The explicit override wins; otherwise the mode decides. The single
    /// gate consulted by `PrefixKeymap`, `StatusLineView`, and onboarding so they never drift.
    public var showsHarnessControls: Bool {
        harnessControlsEnabled ?? experienceMode.showsHarnessControlsByDefault
    }

    /// The prefix shortcut string to actually arm, or `nil` to disable the prefix entirely.
    /// `nil` when Harness controls are hidden or when the user blanked the prefix in
    /// Settings — fixes the old bug where an empty `prefixKey` silently fell back to Ctrl-A.
    public var effectivePrefixKey: String? {
        guard showsHarnessControls else { return nil }
        let trimmed = prefixKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(
        // First-run "out of the box" look (a fresh install with no imported config):
        // translucent + blurred canvas, Nerd Font, roomy padding, copy-on-select on.
        fontSize: Float = 16,
        fontFamily: String = "JetBrainsMono Nerd Font",
        defaultShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        defaultCWD: String = FileManager.default.homeDirectoryForCurrentUser.path,
        transparentTitlebar: Bool = true,
        sidebarVisible: Bool = true,
        restoreWindowSize: Bool = false,
        backgroundOpacity: Float = 0.63,
        backgroundBlur: Int = 16,
        windowPaddingX: Float = 14,
        windowPaddingY: Float = 14,
        customBackgroundHex: String? = nil,
        customForegroundHex: String? = nil,
        customCursorHex: String? = nil,
        importedConfigSignature: String? = nil,
        prefixKey: String = "ctrl-a",
        scrollbackLines: Int = 10_000,
        cursorStyle: String = "bar",
        cursorBlink: Bool = true,
        copyOnSelect: Bool = true,
        selectionBackgroundHex: String? = nil,
        selectionForegroundHex: String? = nil,
        boldColorHex: String? = nil,
        cursorTextHex: String? = nil,
        paletteHex: [String?] = Array(repeating: nil, count: 16),
        agentColorOverrides: [String: String] = [:],
        // nil = derive from theme (dark themes resolve to a quiet #1E1E1E hairline; see
        // MainSplitViewController.resolvedDividerColor). A pinned value would override that
        // on every theme, so leave it unset.
        dividerHex: String? = nil,
        statusLineHex: String? = nil,
        systemNotificationsEnabled: Bool = true,
        notificationSoundEnabled: Bool = true,
        notchVisibilityMode: NotchVisibilityMode = .automatic,
        notchOpenOnHover: Bool = true,
        colorRendering: TerminalColorRenderingMode? = nil,
        colorGamut: TerminalColorGamut = .auto,
        textRendering: TerminalTextRenderingMode? = nil,
        vividColors: Bool = false,
        linearBlending: Bool = false,
        applyThemeToTerminalOutput: Bool = false,
        ligatures: Bool = true,
        offMainParserFramePipeline: Bool = true,
        showPromptGutter: Bool = false,
        showStatusLine: Bool = true,
        // Fresh installs default to the simplest experience — a fast native terminal.
        // Existing installs migrate to `.full` in `init(from:)` so no
        // current user loses the prefix/status they already have.
        experienceMode: ExperienceMode = .plain,
        harnessControlsEnabled: Bool? = nil,
        resizeOverlay: ResizeOverlayMode = .afterFirst,
        resizeOverlayPosition: ResizeOverlayPosition = .center,
        windowPaddingBalance: Bool = true,
        minimumContrast: Double = 1,
        lightThemeName: String? = nil,
        darkThemeName: String? = nil,
        pasteProtection: Bool = true,
        commandFinishedNotifications: Bool = false,
        commandFinishedThresholdSeconds: Int = 10
    ) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.defaultShell = defaultShell
        self.defaultCWD = defaultCWD
        self.transparentTitlebar = transparentTitlebar
        self.sidebarVisible = sidebarVisible
        self.restoreWindowSize = restoreWindowSize
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.windowPaddingX = windowPaddingX
        self.windowPaddingY = windowPaddingY
        self.customBackgroundHex = customBackgroundHex
        self.customForegroundHex = customForegroundHex
        self.customCursorHex = customCursorHex
        self.importedConfigSignature = importedConfigSignature
        self.prefixKey = prefixKey
        self.scrollbackLines = scrollbackLines
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.copyOnSelect = copyOnSelect
        self.selectionBackgroundHex = selectionBackgroundHex
        self.selectionForegroundHex = selectionForegroundHex
        self.boldColorHex = boldColorHex
        self.cursorTextHex = cursorTextHex
        self.paletteHex = HarnessSettings.normalizedPalette(paletteHex)
        self.agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(agentColorOverrides)
        self.dividerHex = dividerHex
        self.statusLineHex = statusLineHex
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.notificationSoundEnabled = notificationSoundEnabled
        self.notchVisibilityMode = notchVisibilityMode
        self.notchOpenOnHover = notchOpenOnHover
        let resolvedColorRendering = colorRendering ?? (vividColors ? .vivid : .accurate)
        let resolvedTextRendering = textRendering ?? (linearBlending ? .crisp : .native)
        self.colorRendering = resolvedColorRendering
        self.colorGamut = colorGamut
        self.textRendering = resolvedTextRendering
        self.vividColors = resolvedColorRendering == .vivid
        self.linearBlending = resolvedTextRendering == .crisp
        self.applyThemeToTerminalOutput = applyThemeToTerminalOutput
        self.ligatures = ligatures
        self.offMainParserFramePipeline = offMainParserFramePipeline
        self.showPromptGutter = showPromptGutter
        self.showStatusLine = showStatusLine
        self.experienceMode = experienceMode
        self.harnessControlsEnabled = harnessControlsEnabled
        self.resizeOverlay = resizeOverlay
        self.resizeOverlayPosition = resizeOverlayPosition
        self.windowPaddingBalance = windowPaddingBalance
        self.minimumContrast = HarnessSettings.clampedContrast(minimumContrast)
        self.lightThemeName = lightThemeName
        self.darkThemeName = darkThemeName
        self.pasteProtection = pasteProtection
        self.commandFinishedNotifications = commandFinishedNotifications
        self.commandFinishedThresholdSeconds = max(0, commandFinishedThresholdSeconds)
    }

    /// Ensure the palette always has exactly 16 slots so index access is safe even if a
    /// hand-edited or older settings file carries a different count.
    public static func normalizedPalette(_ raw: [String?]) -> [String?] {
        if raw.count == 16 { return raw }
        if raw.count < 16 { return raw + Array(repeating: nil, count: 16 - raw.count) }
        return Array(raw.prefix(16))
    }

    public static func normalizedAgentColorOverrides(_ raw: [String: String]) -> [String: String] {
        raw.reduce(into: [:]) { result, item in
            guard AgentKind(rawValue: item.key) != nil,
                  let normalized = normalizedHex(item.value)
            else { return }
            result[item.key] = normalized
        }
    }

    public static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard cleaned.count == 6, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(cleaned.uppercased())"
    }

    public func agentColorHex(for kind: AgentKind) -> String {
        agentColorOverrides[kind.rawValue] ?? "#\(kind.dotHex.uppercased())"
    }

    /// Reset visual fields to either the user's imported terminal config or the source terminal's
    /// stock baseline. Preserves shell, cwd, sidebar/titlebar chrome, prefix key, and
    /// agent color overrides so selecting "Default" changes appearance, not behavior.
    public mutating func resetToImportedConfig(imported: ImportedTerminalConfig? = nil) {
        // Fall back to the first-run defaults (the memberwise init) so "Reset to defaults"
        // always lands on the same out-of-the-box look — no separate set of magic numbers.
        let defaults = HarnessSettings()
        backgroundOpacity = imported?.backgroundOpacity ?? defaults.backgroundOpacity
        backgroundBlur = imported?.backgroundBlur ?? defaults.backgroundBlur
        customBackgroundHex = imported?.backgroundHex
        customForegroundHex = imported?.foregroundHex
        customCursorHex = imported?.cursorColorHex
        selectionBackgroundHex = imported?.selectionBackgroundHex
        selectionForegroundHex = imported?.selectionForegroundHex
        boldColorHex = imported?.boldColorHex
        cursorTextHex = imported?.cursorTextHex
        dividerHex = nil
        statusLineHex = nil
        paletteHex = HarnessSettings.normalizedPalette(imported?.paletteHex ?? Array(repeating: nil, count: 16))
        fontFamily = imported?.fontFamily ?? defaults.fontFamily
        fontSize = defaults.fontSize // Harness-owned (import the face, not the size).
        windowPaddingX = imported?.windowPaddingX ?? defaults.windowPaddingX
        windowPaddingY = imported?.windowPaddingY ?? defaults.windowPaddingY
        cursorStyle = imported?.cursorStyle ?? defaults.cursorStyle
        cursorBlink = imported?.cursorBlink ?? defaults.cursorBlink
        copyOnSelect = imported?.copyOnSelect ?? defaults.copyOnSelect
        minimumContrast = HarnessSettings.clampedContrast(imported?.minimumContrast ?? defaults.minimumContrast)
        importedConfigSignature = imported?.signature
    }

    /// Decoder that gracefully accepts older settings files missing the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyHarnessSettingsCodingKeys.self)
        let imported = TerminalConfigImporter.load()
        let fallback = HarnessSettings.makeDefaults(imported: imported)

        fontSize = try container.decodeIfPresent(Float.self, forKey: .fontSize) ?? fallback.fontSize
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? fallback.fontFamily
        defaultShell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? fallback.defaultShell
        defaultCWD = try container.decodeIfPresent(String.self, forKey: .defaultCWD) ?? fallback.defaultCWD
        transparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .transparentTitlebar) ?? fallback.transparentTitlebar
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? fallback.sidebarVisible
        restoreWindowSize = try container.decodeIfPresent(Bool.self, forKey: .restoreWindowSize) ?? fallback.restoreWindowSize
        backgroundOpacity = try container.decodeIfPresent(Float.self, forKey: .backgroundOpacity) ?? fallback.backgroundOpacity
        backgroundBlur = try container.decodeIfPresent(Int.self, forKey: .backgroundBlur) ?? fallback.backgroundBlur
        windowPaddingX = try container.decodeIfPresent(Float.self, forKey: .windowPaddingX) ?? fallback.windowPaddingX
        windowPaddingY = try container.decodeIfPresent(Float.self, forKey: .windowPaddingY) ?? fallback.windowPaddingY
        customBackgroundHex = try container.decodeIfPresent(String.self, forKey: .customBackgroundHex) ?? fallback.customBackgroundHex
        customForegroundHex = try container.decodeIfPresent(String.self, forKey: .customForegroundHex) ?? fallback.customForegroundHex
        customCursorHex = try container.decodeIfPresent(String.self, forKey: .customCursorHex) ?? fallback.customCursorHex
        importedConfigSignature = try container.decodeIfPresent(String.self, forKey: .importedConfigSignature)
        prefixKey = try container.decodeIfPresent(String.self, forKey: .prefixKey) ?? fallback.prefixKey
        scrollbackLines = try container.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? fallback.scrollbackLines
        cursorStyle = try container.decodeIfPresent(String.self, forKey: .cursorStyle) ?? fallback.cursorStyle
        cursorBlink = try container.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? fallback.cursorBlink
        copyOnSelect = try container.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? fallback.copyOnSelect
        selectionBackgroundHex = try container.decodeIfPresent(String.self, forKey: .selectionBackgroundHex) ?? fallback.selectionBackgroundHex
        selectionForegroundHex = try container.decodeIfPresent(String.self, forKey: .selectionForegroundHex) ?? fallback.selectionForegroundHex
        boldColorHex = try container.decodeIfPresent(String.self, forKey: .boldColorHex) ?? fallback.boldColorHex
        cursorTextHex = try container.decodeIfPresent(String.self, forKey: .cursorTextHex) ?? fallback.cursorTextHex
        paletteHex = HarnessSettings.normalizedPalette(try container.decodeIfPresent([String?].self, forKey: .paletteHex) ?? fallback.paletteHex)
        let agentColors = try container.decodeIfPresent([String: String].self, forKey: .agentColorOverrides) ?? fallback.agentColorOverrides
        agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(agentColors)
        dividerHex = try container.decodeIfPresent(String.self, forKey: .dividerHex)
        statusLineHex = try container.decodeIfPresent(String.self, forKey: .statusLineHex)
        systemNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        notificationSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) ?? true
        notchVisibilityMode = try container.decodeIfPresent(NotchVisibilityMode.self, forKey: .notchVisibilityMode) ?? .automatic
        notchOpenOnHover = try container.decodeIfPresent(Bool.self, forKey: .notchOpenOnHover) ?? true
        let legacyVivid = try container.decodeIfPresent(Bool.self, forKey: .vividColors)
        let decodedColorRendering = try container.decodeIfPresent(TerminalColorRenderingMode.self, forKey: .colorRendering)
        let resolvedColorRendering = decodedColorRendering
            ?? ((legacyVivid ?? fallback.vividColors) ? .vivid : fallback.colorRendering)
        colorRendering = resolvedColorRendering
        colorGamut = try container.decodeIfPresent(TerminalColorGamut.self, forKey: .colorGamut) ?? fallback.colorGamut

        let legacyLinear = try container.decodeIfPresent(Bool.self, forKey: .linearBlending)
        let decodedTextRendering = try container.decodeIfPresent(TerminalTextRenderingMode.self, forKey: .textRendering)
        let resolvedTextRendering = decodedTextRendering
            ?? ((legacyLinear ?? fallback.linearBlending) ? .crisp : fallback.textRendering)
        textRendering = resolvedTextRendering
        vividColors = resolvedColorRendering == .vivid
        linearBlending = resolvedTextRendering == .crisp
        applyThemeToTerminalOutput = try container.decodeIfPresent(Bool.self, forKey: .applyThemeToTerminalOutput) ?? fallback.applyThemeToTerminalOutput
        ligatures = try container.decodeIfPresent(Bool.self, forKey: .ligatures) ?? fallback.ligatures
        // Default on when the key is absent (existing installs get the fast path); an explicitly
        // stored `false` is honored as an opt-out.
        offMainParserFramePipeline = try container.decodeIfPresent(Bool.self, forKey: .offMainParserFramePipeline) ?? true
        showPromptGutter = try container.decodeIfPresent(Bool.self, forKey: .showPromptGutter) ?? fallback.showPromptGutter
        showStatusLine = try container.decodeIfPresent(Bool.self, forKey: .showStatusLine) ?? fallback.showStatusLine
        // Behavior-preserving migration: a settings file that predates modes was written by a
        // user who already had the prefix + status line, i.e. the full Harness experience.
        // Default the absent key to `.full` (NOT the fresh-install `.plain`) so upgrading never
        // silently strips features. New installs get `.plain` via `makeDefaults`.
        experienceMode = try container.decodeIfPresent(ExperienceMode.self, forKey: .experienceMode) ?? .full
        harnessControlsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .harnessControlsEnabled)
            ?? legacyContainer.decodeIfPresent(Bool.self, forKey: .tmuxControlsEnabled)
        resizeOverlay = try container.decodeIfPresent(ResizeOverlayMode.self, forKey: .resizeOverlay) ?? fallback.resizeOverlay
        resizeOverlayPosition = try container.decodeIfPresent(ResizeOverlayPosition.self, forKey: .resizeOverlayPosition) ?? fallback.resizeOverlayPosition
        windowPaddingBalance = try container.decodeIfPresent(Bool.self, forKey: .windowPaddingBalance) ?? fallback.windowPaddingBalance
        minimumContrast = HarnessSettings.clampedContrast(
            try container.decodeIfPresent(Double.self, forKey: .minimumContrast) ?? fallback.minimumContrast)
        lightThemeName = try container.decodeIfPresent(String.self, forKey: .lightThemeName)
        darkThemeName = try container.decodeIfPresent(String.self, forKey: .darkThemeName)
        pasteProtection = try container.decodeIfPresent(Bool.self, forKey: .pasteProtection) ?? fallback.pasteProtection
        commandFinishedNotifications =
            try container.decodeIfPresent(Bool.self, forKey: .commandFinishedNotifications) ?? fallback.commandFinishedNotifications
        commandFinishedThresholdSeconds =
            try container.decodeIfPresent(Int.self, forKey: .commandFinishedThresholdSeconds) ?? fallback.commandFinishedThresholdSeconds
    }

    public static func load() -> HarnessSettings {
        let imported = TerminalConfigImporter.load()
        let url = HarnessPaths.settingsURL
        if FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) {
            guard var settings = try? JSONDecoder().decode(HarnessSettings.self, from: data) else {
                // Present but unreadable: preserve it as `.corrupt` for recovery rather than
                // silently overwriting it with defaults (which would discard the user's settings).
                // Mirrors SessionStore/OptionStore — return defaults WITHOUT rewriting the file.
                HarnessPaths.backupCorruptFile(at: url, label: "Harness")
                return HarnessSettings.makeDefaults(imported: imported)
            }
            let hasStoredColorChoice = settingsDataContainsColorChoice(data)
            // Track whether any migration below actually changed something, so a no-op launch never
            // rewrites settings.json (a needless write — and a corruption window — on every start).
            var didMutate = false
            // Schema migration: when the saved file predates a feature (e.g. it was written before
            // customBackgroundHex existed, or before the user installed a source terminal), backfill
            // from the live terminal config — but ONLY when the user hasn't set their own visuals.
            // Once colors/font are populated (a Harness edit, or a prior import), silently
            // overwriting them on a source-config change is data loss; the user re-pulls explicitly
            // via Settings / `source-config` / prefix `r` (the consented path). Either way we record
            // the new signature so we don't re-evaluate this every launch.
            if let imported, settings.importedConfigSignature != imported.signature {
                if settings.hasUserVisualCustomizations {
                    settings.importedConfigSignature = imported.signature
                } else {
                    settings.applyImportedDefaults(imported)
                }
                didMutate = true
            }
            // Recover from accidental "background-opacity = 0.05" footgun states.
            // The slider could go all the way down; older code didn't guard it.
            // Anything below 30% makes the window effectively invisible.
            let clampedOpacity = HarnessSettings.clampedOpacity(settings.backgroundOpacity)
            if clampedOpacity != settings.backgroundOpacity { settings.backgroundOpacity = clampedOpacity; didMutate = true }
            let clampedBlur = HarnessSettings.clampedBlur(settings.backgroundBlur)
            if clampedBlur != settings.backgroundBlur { settings.backgroundBlur = clampedBlur; didMutate = true }
            // One-shot color-fidelity migration: explicit vividColors/colorRendering keys
            // are the user's gamut choice. Older files that lack both never made one, so
            // land them on accurate sRGB.
            let migrationKey = "HarnessColorFidelityMigrationV1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if !hasStoredColorChoice, settings.colorRendering != .accurate {
                    settings.colorRendering = .accurate
                    didMutate = true
                }
            }
            // Persist only a migration that actually changed something — and surface a write failure
            // (a read-only disk / full volume) instead of silently dropping the migrated state.
            if didMutate {
                do { try settings.save() }
                catch { fputs("Harness: failed to persist migrated settings.json — \(error)\n", harnessStderr) }
            }
            return settings
        }
        // First-run / user nuked the file: seed from the imported config and persist
        // immediately so subsequent launches are stable.
        let seeded = HarnessSettings.makeDefaults(imported: imported)
        do { try seeded.save() }
        catch { fputs("Harness: failed to seed settings.json — \(error)\n", harnessStderr) }
        return seeded
    }

    /// Whether the user (or a prior import) has populated any editable visual field. Gates the
    /// auto-backfill in `load()`: a changed source-terminal config must never silently overwrite
    /// colors/font the user is relying on (they re-import explicitly to opt in).
    private var hasUserVisualCustomizations: Bool {
        customBackgroundHex != nil || customForegroundHex != nil || customCursorHex != nil
            || selectionBackgroundHex != nil || selectionForegroundHex != nil
            || boldColorHex != nil || cursorTextHex != nil
            || paletteHex.contains { $0 != nil }
    }

    private static func settingsDataContainsColorChoice(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object[CodingKeys.vividColors.stringValue] != nil
            || object[CodingKeys.colorRendering.stringValue] != nil
    }

    /// Opacity bounds. The user can pick any value from fully transparent to
    /// solid — that's an intentional product choice for power users who want
    /// extreme translucency. The 0.05 floor stays just to make sure dragging
    /// the slider to the far left doesn't strand the window completely
    /// invisible with no way to find it on screen.
    public static func clampedOpacity(_ value: Float) -> Float {
        max(0.05, min(1.0, value))
    }

    /// Background blur (pixels). 0 = no blur, 100 = aggressive heavy frost.
    /// The window blur caps the effective radius internally; we expose the full
    /// useful range so settings doesn't feel artificially constrained.
    public static func clampedBlur(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    /// Minimum-contrast WCAG ratio bounds. 1 = off (no adjustment); 21 = maximum (black on white).
    public static func clampedContrast(_ value: Double) -> Double {
        max(1, min(21, value))
    }

    public func save() throws {
        try HarnessPaths.ensureDirectories()
        let data = try JSONEncoder().encode(self)
        try data.write(to: HarnessPaths.settingsURL, options: .atomic)
    }

    /// Builds a default settings instance, layering imported config values over hardcoded defaults.
    public static func makeDefaults(imported: ImportedTerminalConfig?) -> HarnessSettings {
        var settings = HarnessSettings()
        guard let imported else { return settings }
        if let value = imported.fontFamily { settings.fontFamily = value }
        // Font *size* is Harness-owned (default 16), not imported: a source terminal's size
        // preference doesn't carry over — only the font face does.
        if let value = imported.defaultShell { settings.defaultShell = value }
        if let value = imported.backgroundOpacity { settings.backgroundOpacity = value }
        if let value = imported.backgroundBlur { settings.backgroundBlur = value }
        if let value = imported.windowPaddingX { settings.windowPaddingX = value }
        if let value = imported.windowPaddingY { settings.windowPaddingY = value }
        if let value = imported.backgroundHex { settings.customBackgroundHex = value }
        if let value = imported.foregroundHex { settings.customForegroundHex = value }
        if let value = imported.cursorColorHex { settings.customCursorHex = value }
        if let value = imported.cursorStyle { settings.cursorStyle = value }
        if let value = imported.cursorBlink { settings.cursorBlink = value }
        if let value = imported.copyOnSelect { settings.copyOnSelect = value }
        if let value = imported.minimumContrast { settings.minimumContrast = HarnessSettings.clampedContrast(value) }
        settings.selectionBackgroundHex = imported.selectionBackgroundHex
        settings.selectionForegroundHex = imported.selectionForegroundHex
        settings.boldColorHex = imported.boldColorHex
        settings.cursorTextHex = imported.cursorTextHex
        settings.paletteHex = HarnessSettings.normalizedPalette(imported.paletteHex)
        settings.importedConfigSignature = imported.signature
        return settings
    }

    private mutating func applyImportedDefaults(_ imported: ImportedTerminalConfig) {
        if let value = imported.fontFamily { fontFamily = value }
        // Font size is Harness-owned (see makeDefaults) — import the face, not the size.
        if let value = imported.defaultShell { defaultShell = value }
        if let value = imported.backgroundOpacity { backgroundOpacity = value }
        if let value = imported.backgroundBlur { backgroundBlur = value }
        if let value = imported.windowPaddingX { windowPaddingX = value }
        if let value = imported.windowPaddingY { windowPaddingY = value }
        if let value = imported.backgroundHex { customBackgroundHex = value }
        if let value = imported.foregroundHex { customForegroundHex = value }
        if let value = imported.cursorColorHex { customCursorHex = value }
        if let value = imported.cursorStyle { cursorStyle = value }
        if let value = imported.cursorBlink { cursorBlink = value }
        if let value = imported.copyOnSelect { copyOnSelect = value }
        if let value = imported.minimumContrast { minimumContrast = HarnessSettings.clampedContrast(value) }
        selectionBackgroundHex = imported.selectionBackgroundHex
        selectionForegroundHex = imported.selectionForegroundHex
        boldColorHex = imported.boldColorHex
        cursorTextHex = imported.cursorTextHex
        paletteHex = HarnessSettings.normalizedPalette(imported.paletteHex)
        importedConfigSignature = imported.signature
    }
}
