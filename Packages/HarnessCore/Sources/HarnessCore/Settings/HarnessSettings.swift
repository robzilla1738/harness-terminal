import Foundation

public struct HarnessSettings: Codable, Sendable, Equatable {
    public var fontSize: Float
    public var fontFamily: String
    public var defaultShell: String
    public var defaultCWD: String
    public var transparentTitlebar: Bool
    public var sidebarVisible: Bool
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
    /// Extra-saturated full Display-P3 gamut when true; accurate sRGB (the source terminal
    /// parity, the default) when false. Maps to `window-colorspace`.
    public var vividColors: Bool
    /// Gamma-correct ("linear-corrected") alpha blending for text antialiasing when
    /// true, or macOS-native blending when false. Maps to `alpha-blending`.
    public var linearBlending: Bool
    /// When true, the active theme's 16 ANSI colors recolor terminal *output* too. Default
    /// false: the canvas (default bg/fg/cursor) always follows the
    /// theme so it matches the chrome, but program output keeps untouched/default ANSI
    /// colors — programs render their true colors over a themed, optionally translucent
    /// canvas.
    public var applyThemeToTerminalOutput: Bool
    /// Programming-font ligatures (e.g. `=>`, `!=`, `->`) via CoreText run shaping. On by
    /// default; turn off for the fastest one-glyph-per-cell path.
    public var ligatures: Bool
    /// Show the bottom status line (workspace · git · clock). When false the band is
    /// hidden and the terminal split extends to the window bottom. Read by
    /// `StatusLineView.refresh` (alongside the tmux `status` option).
    public var showStatusLine: Bool

    public init(
        // First-run "out of the box" look (a fresh install with no imported config):
        // translucent + blurred canvas, Nerd Font, roomy padding, copy-on-select on.
        fontSize: Float = 16,
        fontFamily: String = "JetBrainsMono Nerd Font",
        defaultShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        defaultCWD: String = FileManager.default.homeDirectoryForCurrentUser.path,
        transparentTitlebar: Bool = true,
        sidebarVisible: Bool = true,
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
        cursorStyle: String = "block",
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
        vividColors: Bool = true,
        linearBlending: Bool = false,
        applyThemeToTerminalOutput: Bool = false,
        ligatures: Bool = true,
        showStatusLine: Bool = true
    ) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.defaultShell = defaultShell
        self.defaultCWD = defaultCWD
        self.transparentTitlebar = transparentTitlebar
        self.sidebarVisible = sidebarVisible
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
        self.vividColors = vividColors
        self.linearBlending = linearBlending
        self.applyThemeToTerminalOutput = applyThemeToTerminalOutput
        self.ligatures = ligatures
        self.showStatusLine = showStatusLine
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
        importedConfigSignature = imported?.signature
    }

    /// Decoder that gracefully accepts older settings files missing the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let imported = TerminalConfigImporter.load()
        let fallback = HarnessSettings.makeDefaults(imported: imported)

        fontSize = try container.decodeIfPresent(Float.self, forKey: .fontSize) ?? fallback.fontSize
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? fallback.fontFamily
        defaultShell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? fallback.defaultShell
        defaultCWD = try container.decodeIfPresent(String.self, forKey: .defaultCWD) ?? fallback.defaultCWD
        transparentTitlebar = try container.decodeIfPresent(Bool.self, forKey: .transparentTitlebar) ?? fallback.transparentTitlebar
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? fallback.sidebarVisible
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
        vividColors = try container.decodeIfPresent(Bool.self, forKey: .vividColors) ?? fallback.vividColors
        linearBlending = try container.decodeIfPresent(Bool.self, forKey: .linearBlending) ?? fallback.linearBlending
        applyThemeToTerminalOutput = try container.decodeIfPresent(Bool.self, forKey: .applyThemeToTerminalOutput) ?? fallback.applyThemeToTerminalOutput
        ligatures = try container.decodeIfPresent(Bool.self, forKey: .ligatures) ?? fallback.ligatures
        showStatusLine = try container.decodeIfPresent(Bool.self, forKey: .showStatusLine) ?? fallback.showStatusLine
    }

    public static func load() -> HarnessSettings {
        let imported = TerminalConfigImporter.load()
        if FileManager.default.fileExists(atPath: HarnessPaths.settingsURL.path),
           let data = try? Data(contentsOf: HarnessPaths.settingsURL),
           var settings = try? JSONDecoder().decode(HarnessSettings.self, from: data)
        {
            // Schema migration: when the saved file predates a feature (e.g. it
            // was written before customBackgroundHex existed, or before the
            // user installed a source terminal), backfill from the live terminal config so
            // visuals stay in sync without forcing a manual re-import.
            if let imported, settings.importedConfigSignature != imported.signature {
                settings.applyImportedDefaults(imported)
            }
            // Recover from accidental "background-opacity = 0.05" footgun states.
            // The slider could go all the way down; older code didn't guard it.
            // Anything below 30% makes the window effectively invisible.
            settings.backgroundOpacity = HarnessSettings.clampedOpacity(settings.backgroundOpacity)
            settings.backgroundBlur = HarnessSettings.clampedBlur(settings.backgroundBlur)
            // One-shot color-fidelity migration: the previous default rendered in
            // sRGB, which clamped the renderer's wide gamut and washed out chromatic
            // colors. Flip existing installs to vivid Display-P3 once (users can
            // toggle back in Settings ▸ Appearance). Keyed in UserDefaults so it
            // runs exactly once and never overrides a later explicit choice.
            let migrationKey = "HarnessColorFidelityMigrationV1"
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                settings.vividColors = true
            }
            // Persist the migration so on next save we don't lose it.
            try? settings.save()
            return settings
        }
        // First-run / user nuked the file: seed from the imported config and persist
        // immediately so subsequent launches are stable.
        let seeded = HarnessSettings.makeDefaults(imported: imported)
        try? seeded.save()
        return seeded
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
        selectionBackgroundHex = imported.selectionBackgroundHex
        selectionForegroundHex = imported.selectionForegroundHex
        boldColorHex = imported.boldColorHex
        cursorTextHex = imported.cursorTextHex
        paletteHex = HarnessSettings.normalizedPalette(imported.paletteHex)
        importedConfigSignature = imported.signature
    }
}
