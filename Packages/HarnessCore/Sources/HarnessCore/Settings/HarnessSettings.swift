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
    /// Custom hex (`#rrggbb`) overrides imported from Ghostty config when present.
    /// `nil` means "use the active theme color".
    public var customBackgroundHex: String?
    public var customForegroundHex: String?
    public var customCursorHex: String?
    /// When false, custom*Hex and the extended color fields are preserved on disk
    /// but ignored so selecting a named theme visibly changes the whole app.
    public var useCustomColors: Bool
    /// Signature of the Ghostty config last imported into these defaults.
    /// Used to migrate stale early settings without overwriting later manual edits.
    public var ghosttyConfigSignature: String?
    /// tmux-style prefix key (default `ctrl-a`). Format: `mod1-mod2-key`,
    /// where mod is `ctrl|cmd|opt|shift`. Set empty string to disable.
    public var prefixKey: String
    /// Number of lines kept in scrollback per pane (passed to libghostty + RealPty).
    public var scrollbackLines: Int
    /// Cursor shape: `block`, `bar`, or `underline` (Ghostty `cursor-style`).
    public var cursorStyle: String
    /// Whether the text cursor blinks (Ghostty `cursor-style-blink`).
    public var cursorBlink: Bool
    /// Copy a mouse selection to the clipboard automatically (Ghostty `copy-on-select`).
    public var copyOnSelect: Bool
    /// Selection (highlight) colors as `#rrggbb`. nil → use the theme's selection color.
    public var selectionBackgroundHex: String?
    public var selectionForegroundHex: String?
    /// Color of bold text. nil → derive from the foreground/theme.
    public var boldColorHex: String?
    /// Color of the text drawn under a block cursor. nil → use the theme.
    public var cursorTextHex: String?
    /// Minimum contrast ratio between text and its background (1 = off … 21 = max).
    public var minimumContrast: Double
    /// 16 ANSI palette overrides (`#rrggbb`); a nil slot uses the theme's color.
    /// Always normalized to exactly 16 entries (see `normalizedPalette`).
    public var paletteHex: [String?]
    /// Per-agent brand color overrides keyed by `AgentKind.rawValue`.
    /// Missing keys use the built-in agent default.
    public var agentColorOverrides: [String: String]

    public init(
        fontSize: Float = 14,
        fontFamily: String = "JetBrains Mono",
        defaultShell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        defaultCWD: String = FileManager.default.homeDirectoryForCurrentUser.path,
        transparentTitlebar: Bool = true,
        sidebarVisible: Bool = true,
        backgroundOpacity: Float = 1,
        backgroundBlur: Int = 0,
        windowPaddingX: Float = 12,
        windowPaddingY: Float = 12,
        customBackgroundHex: String? = nil,
        customForegroundHex: String? = nil,
        customCursorHex: String? = nil,
        useCustomColors: Bool = false,
        ghosttyConfigSignature: String? = nil,
        prefixKey: String = "ctrl-a",
        scrollbackLines: Int = 10_000,
        cursorStyle: String = "block",
        cursorBlink: Bool = true,
        copyOnSelect: Bool = false,
        selectionBackgroundHex: String? = nil,
        selectionForegroundHex: String? = nil,
        boldColorHex: String? = nil,
        cursorTextHex: String? = nil,
        minimumContrast: Double = 1,
        paletteHex: [String?] = Array(repeating: nil, count: 16),
        agentColorOverrides: [String: String] = [:]
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
        self.useCustomColors = useCustomColors
        self.ghosttyConfigSignature = ghosttyConfigSignature
        self.prefixKey = prefixKey
        self.scrollbackLines = scrollbackLines
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.copyOnSelect = copyOnSelect
        self.selectionBackgroundHex = selectionBackgroundHex
        self.selectionForegroundHex = selectionForegroundHex
        self.boldColorHex = boldColorHex
        self.cursorTextHex = cursorTextHex
        self.minimumContrast = minimumContrast
        self.paletteHex = HarnessSettings.normalizedPalette(paletteHex)
        self.agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(agentColorOverrides)
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

    /// Decoder that gracefully accepts older settings files missing the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let imported = GhosttyConfigImporter.load()
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
        useCustomColors = try container.decodeIfPresent(Bool.self, forKey: .useCustomColors) ?? false
        ghosttyConfigSignature = try container.decodeIfPresent(String.self, forKey: .ghosttyConfigSignature)
        prefixKey = try container.decodeIfPresent(String.self, forKey: .prefixKey) ?? fallback.prefixKey
        scrollbackLines = try container.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? fallback.scrollbackLines
        cursorStyle = try container.decodeIfPresent(String.self, forKey: .cursorStyle) ?? fallback.cursorStyle
        cursorBlink = try container.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? fallback.cursorBlink
        copyOnSelect = try container.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? fallback.copyOnSelect
        selectionBackgroundHex = try container.decodeIfPresent(String.self, forKey: .selectionBackgroundHex) ?? fallback.selectionBackgroundHex
        selectionForegroundHex = try container.decodeIfPresent(String.self, forKey: .selectionForegroundHex) ?? fallback.selectionForegroundHex
        boldColorHex = try container.decodeIfPresent(String.self, forKey: .boldColorHex) ?? fallback.boldColorHex
        cursorTextHex = try container.decodeIfPresent(String.self, forKey: .cursorTextHex) ?? fallback.cursorTextHex
        minimumContrast = try container.decodeIfPresent(Double.self, forKey: .minimumContrast) ?? fallback.minimumContrast
        let palette = try container.decodeIfPresent([String?].self, forKey: .paletteHex) ?? fallback.paletteHex
        paletteHex = HarnessSettings.normalizedPalette(palette)
        let agentColors = try container.decodeIfPresent([String: String].self, forKey: .agentColorOverrides) ?? fallback.agentColorOverrides
        agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(agentColors)
    }

    public static func load() -> HarnessSettings {
        let imported = GhosttyConfigImporter.load()
        if FileManager.default.fileExists(atPath: HarnessPaths.settingsURL.path),
           let data = try? Data(contentsOf: HarnessPaths.settingsURL),
           var settings = try? JSONDecoder().decode(HarnessSettings.self, from: data)
        {
            // Schema migration: when the saved file predates a feature (e.g. it
            // was written before customBackgroundHex existed, or before the
            // user installed Ghostty), backfill from the live Ghostty config so
            // visuals stay in sync without forcing a manual re-import.
            if let imported, settings.ghosttyConfigSignature != imported.signature {
                settings.applyImportedDefaults(imported)
            }
            // Recover from accidental "background-opacity = 0.05" footgun states.
            // The slider could go all the way down; older code didn't guard it.
            // Anything below 30% makes the window effectively invisible.
            settings.backgroundOpacity = HarnessSettings.clampedOpacity(settings.backgroundOpacity)
            settings.backgroundBlur = HarnessSettings.clampedBlur(settings.backgroundBlur)
            // Persist the migration so on next save we don't lose it.
            try? settings.save()
            return settings
        }
        // First-run / user nuked the file: seed from Ghostty and persist
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
    /// libghostty caps the effective blur internally; we expose the full
    /// useful range so settings doesn't feel artificially constrained.
    public static func clampedBlur(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    public func save() throws {
        try HarnessPaths.ensureDirectories()
        let data = try JSONEncoder().encode(self)
        try data.write(to: HarnessPaths.settingsURL, options: .atomic)
    }

    /// Builds a default settings instance, layering imported Ghostty values over hardcoded defaults.
    public static func makeDefaults(imported: GhosttyImportedDefaults?) -> HarnessSettings {
        var settings = HarnessSettings()
        guard let imported else { return settings }
        if let value = imported.fontFamily { settings.fontFamily = value }
        if let value = imported.fontSize { settings.fontSize = value }
        if let value = imported.defaultShell { settings.defaultShell = value }
        if let value = imported.backgroundOpacity { settings.backgroundOpacity = value }
        if let value = imported.backgroundBlur { settings.backgroundBlur = value }
        if let value = imported.windowPaddingX { settings.windowPaddingX = value }
        if let value = imported.windowPaddingY { settings.windowPaddingY = value }
        if let value = imported.backgroundHex { settings.customBackgroundHex = value }
        if let value = imported.foregroundHex { settings.customForegroundHex = value }
        if let value = imported.cursorColorHex { settings.customCursorHex = value }
        settings.useCustomColors = imported.backgroundHex != nil || imported.foregroundHex != nil || imported.cursorColorHex != nil
        settings.ghosttyConfigSignature = imported.signature
        return settings
    }

    private mutating func applyImportedDefaults(_ imported: GhosttyImportedDefaults) {
        if let value = imported.fontFamily { fontFamily = value }
        if let value = imported.fontSize { fontSize = value }
        if let value = imported.defaultShell { defaultShell = value }
        if let value = imported.backgroundOpacity { backgroundOpacity = value }
        if let value = imported.backgroundBlur { backgroundBlur = value }
        if let value = imported.windowPaddingX { windowPaddingX = value }
        if let value = imported.windowPaddingY { windowPaddingY = value }
        if let value = imported.backgroundHex { customBackgroundHex = value }
        if let value = imported.foregroundHex { customForegroundHex = value }
        if let value = imported.cursorColorHex { customCursorHex = value }
        // Honor the imported colors. Without this, a stale settings file with
        // `useCustomColors=false` would silently swallow the user's Ghostty
        // bg/fg overrides and force the named theme instead.
        if imported.backgroundHex != nil || imported.foregroundHex != nil || imported.cursorColorHex != nil {
            useCustomColors = true
        }
        ghosttyConfigSignature = imported.signature
    }
}
