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

public enum HarnessAppearanceMode: String, Codable, Sendable, CaseIterable {
    case theme
    case macOSSystem = "macos-system"
}

public enum HarnessSystemAppearance: String, Codable, Sendable {
    case light
    case dark
}

public enum HarnessEffectiveAppearanceRefreshPolicy {
    public static func shouldRefreshOnEffectiveAppearanceChange(
        appearanceMode: HarnessAppearanceMode
    ) -> Bool {
        appearanceMode == .macOSSystem
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

/// Feedback for a terminal bell (`\a` / BEL) on the *focused* surface. The unfocused path always
/// posts the OS notification / tab bell-flag regardless of this. Default `.visual` — a brief,
/// non-jarring flash — gives feedback (today a focused bell is silent) without the annoyance of a
/// beep on every completion bell; users who want the classic beep choose `.audible` or `.both`.
public enum BellMode: String, Codable, Sendable, CaseIterable {
    case off
    case audible
    case visual
    case both
}

private enum LegacyHarnessSettingsCodingKeys: String, CodingKey {
    case tmuxControlsEnabled
    /// Removed in favor of the per-event `notificationEvents` map; still read here to migrate
    /// an existing on/off choice into `notificationEvents[.commandFinished]`.
    case commandFinishedNotifications
    case lightThemeName
    case darkThemeName
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
    /// Harness appearance policy. `.theme` uses the selected Harness theme; `.macOSSystem`
    /// resolves Harness-owned light/dark palettes from the current macOS appearance.
    public var appearanceMode: HarnessAppearanceMode
    /// Named themes used only by `.macOSSystem` resolution. `.theme` mode ignores these
    /// fields and continues to render `themeName` exactly as before.
    public var systemLightThemeName: String
    public var systemDarkThemeName: String
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
    /// Number of lines kept in scrollback per pane (passed to the renderer + RealPty). `0` means
    /// **unlimited**: the emulator's line history grows unbounded while the daemon's persisted
    /// scrollback stays bounded by a large on-disk safety ceiling.
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
    /// Hairline border around the entire window edge (Ghostty's faint perimeter line),
    /// helping the window stand out from same-tone backgrounds. nil → derive from the
    /// theme (light grey on dark themes, dark grey on light).
    public var windowBorderHex: String?
    /// Opacity of the window-edge hairline, 0–1. 0 hides it entirely.
    public var windowBorderOpacity: Float
    /// Delivery channel: show a macOS banner for an enabled notification event (which events
    /// notify is decided per-event by `notificationEvents` / `isEventEnabled(_:)`). When false,
    /// the in-window bell badge still updates but the OS banner is suppressed; an enabled event
    /// can still chime if `notificationSoundEnabled` is on.
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
    ///
    /// INVARIANT: `colorRendering` and the legacy `vividColors` bool are deliberately kept in lockstep
    /// by their mutual `didSet`s (vivid ⇔ true) so the new enum and the old on-disk bool always agree
    /// — old configs/callers keep working while new code reads the explicit mode. The `!=` guard in
    /// each setter is what stops the two `didSet`s from recursing forever; never drop it.
    public var colorRendering: TerminalColorRenderingMode {
        didSet {
            let legacyValue = colorRendering == .vivid
            if vividColors != legacyValue { vividColors = legacyValue }
        }
    }
    /// INVARIANT: stored and round-tripped through Codable for forward/migration compatibility, but
    /// NOT consulted by gamut resolution today — `TerminalColorGamut.resolved` derives the gamut
    /// purely from `colorRendering` (accurate → sRGB, vivid → Display-P3). Kept so a future policy
    /// can honor an explicit request without a schema break; don't remove it just because it's unread.
    public var colorGamut: TerminalColorGamut
    /// Text antialiasing coverage mode. This only maps to glyph coverage gamma; it never
    /// participates in RGB conversion.
    ///
    /// INVARIANT: paired with the legacy `linearBlending` bool the same way `colorRendering`/`vividColors`
    /// are — the mutual `didSet`s keep them in sync (crisp ⇔ true) for on-disk back-compat, and the
    /// `!=` guard breaks the otherwise-infinite write loop. `.native`/`.soft` both map to `false`.
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
    /// Real-time (Ghostty-style) live resize: while dragging the window edge, reflow the grid and
    /// signal the running program (`SIGWINCH`) at every cell boundary, so interactive programs
    /// (vim/htop/tmux) redraw continuously instead of waiting for the drag to end. **Default on.**
    /// An explicitly stored `false` reverts to the legacy defer-to-release behavior (the authoritative
    /// reflow + `SIGWINCH` fire once, when the drag ends).
    public var liveResizeReflow: Bool
    /// Draw the OSC 133 prompt gutter — a per-row stripe in the left margin marking shell
    /// prompts (green = success, red = failure). Off by default; the marks still power
    /// jump-to-prompt either way, so this only controls the stripe's visibility.
    public var showPromptGutter: Bool
    /// Show the bottom status line (workspace · git · clock). When false the band is
    /// hidden and the terminal split extends to the window bottom. Read by
    /// `StatusLineView.refresh` (alongside the `status` option and `effectiveStatusLineEnabled`).
    public var showStatusLine: Bool
    /// The user-facing experience (Plain / Persistent / Full / Agent). Drives which chrome
    /// is shown, the default session-persistence policy, and onboarding copy — all on top of
    /// the same daemon session core. See `ExperienceMode`.
    public var experienceMode: ExperienceMode
    /// Explicit override for Harness controls visibility (prefix key + status line) as a single
    /// umbrella. `nil` derives from `experienceMode`. Lets a Persistent/Agent user opt into both
    /// the prefix and status line without switching to Full Terminal, or a Full Terminal user turn
    /// them both off without changing modes. The finer-grained `prefixKeyEnabled` /
    /// `statusLineEnabled` below take precedence over this when set.
    public var harnessControlsEnabled: Bool?
    /// Per-component override for the command prefix, independent of the status line. `nil` falls
    /// back to `harnessControlsEnabled`, then the mode's `showsPrefixByDefault`. Lets any preset be
    /// tuned one piece at a time (e.g. Full Terminal with the status line but no prefix).
    public var prefixKeyEnabled: Bool?
    /// Per-component override for the bottom status line, independent of the prefix. `nil` falls
    /// back to `harnessControlsEnabled`, then the mode's `showsStatusLineByDefault`. Lets a Plain
    /// terminal show a status line without arming the prefix, and vice versa.
    public var statusLineEnabled: Bool?
    /// When the live resize dimensions overlay ("120 × 32") is shown while resizing the window.
    public var resizeOverlay: ResizeOverlayMode
    /// Where the resize overlay is positioned within the surface.
    public var resizeOverlayPosition: ResizeOverlayPosition
    /// Feedback for a bell on the focused surface (off/audible/visual/both). The tmux
    /// `visual-bell`/`bell-action` options bridge into this via `BellFeedback.resolve`.
    public var bellMode: BellMode
    /// Multiplier applied to mouse-wheel / trackpad scroll distance (Ghostty `mouse-scroll-
    /// multiplier`). 1 = native; >1 faster, <1 slower. Clamped to a sane range on read.
    public var scrollMultiplier: Double
    /// Hide the mouse cursor while typing until the mouse next moves (Ghostty
    /// `mouse-hide-while-typing`). Off by default (matching Ghostty).
    public var mouseHideWhileTyping: Bool
    /// Enable the quick terminal: a Quake-style dropdown surface summoned by a global hotkey from
    /// anywhere, even when Harness is in the background. Off by default.
    public var quickTerminalEnabled: Bool
    /// Global hotkey that toggles the quick terminal, in the `mod-mod-key` form used by `prefixKey`
    /// (default ⌘⌥`). Requires at least one modifier; only honored while `quickTerminalEnabled` is set.
    public var quickTerminalHotkey: String
    /// Distribute the leftover sub-cell space evenly so the grid is centered, instead of parking
    /// the remainder at the bottom-right edge (Ghostty's `window-padding-balance`).
    public var windowPaddingBalance: Bool
    /// Minimum WCAG contrast ratio (1…21) forced between a cell's foreground and its background.
    /// 1 = off (no adjustment). Imported from a terminal config's `minimum-contrast`.
    public var minimumContrast: Double
    /// Confirm before pasting text containing newlines / control characters when the program has
    /// not enabled bracketed paste — guards against blind multi-line command execution.
    public var pasteProtection: Bool
    /// Minimum runtime (seconds) for the `commandFinished` notification — only commands that
    /// ran at least this long fire it (uses OSC 133 timing).
    public var commandFinishedThresholdSeconds: Int
    /// Per-event desktop-banner gating, keyed by `NotificationEvent.rawValue`. A sparse map:
    /// an absent key falls back to the event's `defaultEnabled`, so older `settings.json` files
    /// decode to today's behavior. The two global channel toggles (`systemNotificationsEnabled`
    /// = show banner, `notificationSoundEnabled` = play chime) still decide *how* an enabled
    /// event is delivered; this map decides *which* events notify. Read via `isEventEnabled(_:)`.
    public var notificationEvents: [String: Bool]
    /// Map bold + palette colors 0–7 to their bright variants 8–15 (classic terminal
    /// behavior, Ghostty `bold-is-bright`). Off keeps the theme's exact colors for bold text.
    public var boldIsBright: Bool
    /// Hold process-global secure keyboard entry (`EnableSecureEventInput`) while Harness is the
    /// active app, so another local process can't keylog passphrases typed at sudo/ssh prompts.
    /// Off by default — opt-in, matching Terminal.app / iTerm2 shipping it off.
    public var secureKeyboardEntry: Bool
    /// New tabs/windows open in the focused pane's working directory (Ghostty
    /// `window-inherit-working-directory`, default on — the shipped Harness behavior).
    /// Off pins new tabs to `defaultCWD`.
    public var windowInheritCWD: Bool

    /// Whether the *umbrella* Harness controls are on (prefix or status line). Kept for onboarding
    /// copy and tests; the prefix and status line each resolve independently via the effective
    /// accessors below, so a preset can show one without the other.
    public var showsHarnessControls: Bool {
        effectivePrefixKeyEnabled || effectiveStatusLineEnabled
    }

    /// Whether the command prefix should be armed. Precedence: the per-component override wins,
    /// then the legacy umbrella `harnessControlsEnabled`, then the mode default. Consulted by
    /// `PrefixKeymap` (via `effectivePrefixKey`).
    public var effectivePrefixKeyEnabled: Bool {
        prefixKeyEnabled ?? harnessControlsEnabled ?? experienceMode.showsPrefixByDefault
    }

    /// Whether the bottom status line should show. Same precedence as the prefix, but resolved
    /// separately. Consulted by `StatusLineView` (alongside the explicit `showStatusLine` toggle).
    public var effectiveStatusLineEnabled: Bool {
        statusLineEnabled ?? harnessControlsEnabled ?? experienceMode.showsStatusLineByDefault
    }

    /// The prefix shortcut string to actually arm, or `nil` to disable the prefix entirely.
    /// `nil` when the prefix is disabled (by mode/override) or when the user blanked the prefix in
    /// Settings — fixes the old bug where an empty `prefixKey` silently fell back to Ctrl-A.
    public var effectivePrefixKey: String? {
        guard effectivePrefixKeyEnabled else { return nil }
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
        appearanceMode: HarnessAppearanceMode = .theme,
        systemLightThemeName: String = "Zenwritten Light",
        systemDarkThemeName: String = "Harness Default",
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
        windowBorderHex: String? = nil,
        windowBorderOpacity: Float = 0.25,
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
        liveResizeReflow: Bool = true,
        showPromptGutter: Bool = false,
        showStatusLine: Bool = true,
        // Fresh installs default to the simplest experience — a fast native terminal.
        // Existing installs migrate to `.full` in `init(from:)` so no
        // current user loses the prefix/status they already have.
        experienceMode: ExperienceMode = .plain,
        harnessControlsEnabled: Bool? = nil,
        prefixKeyEnabled: Bool? = nil,
        statusLineEnabled: Bool? = nil,
        resizeOverlay: ResizeOverlayMode = .afterFirst,
        resizeOverlayPosition: ResizeOverlayPosition = .center,
        bellMode: BellMode = .visual,
        scrollMultiplier: Double = 1,
        mouseHideWhileTyping: Bool = false,
        quickTerminalEnabled: Bool = false,
        quickTerminalHotkey: String = "cmd-opt-`",
        windowPaddingBalance: Bool = true,
        minimumContrast: Double = 1,
        pasteProtection: Bool = true,
        commandFinishedThresholdSeconds: Int = 10,
        notificationEvents: [String: Bool] = [:],
        boldIsBright: Bool = true,
        secureKeyboardEntry: Bool = false,
        windowInheritCWD: Bool = true
    ) {
        self.fontSize = HarnessSettings.clampedFontSize(fontSize)
        self.fontFamily = fontFamily
        self.defaultShell = defaultShell
        self.defaultCWD = defaultCWD
        self.transparentTitlebar = transparentTitlebar
        self.sidebarVisible = sidebarVisible
        self.restoreWindowSize = restoreWindowSize
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.windowPaddingX = HarnessSettings.clampedPadding(windowPaddingX)
        self.windowPaddingY = HarnessSettings.clampedPadding(windowPaddingY)
        self.appearanceMode = appearanceMode
        self.systemLightThemeName = systemLightThemeName
        self.systemDarkThemeName = systemDarkThemeName
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
        self.windowBorderHex = windowBorderHex
        self.windowBorderOpacity = max(0, min(1, windowBorderOpacity))
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
        self.liveResizeReflow = liveResizeReflow
        self.showPromptGutter = showPromptGutter
        self.showStatusLine = showStatusLine
        self.experienceMode = experienceMode
        self.harnessControlsEnabled = harnessControlsEnabled
        self.prefixKeyEnabled = prefixKeyEnabled
        self.statusLineEnabled = statusLineEnabled
        self.resizeOverlay = resizeOverlay
        self.resizeOverlayPosition = resizeOverlayPosition
        self.bellMode = bellMode
        self.scrollMultiplier = scrollMultiplier
        self.mouseHideWhileTyping = mouseHideWhileTyping
        self.quickTerminalEnabled = quickTerminalEnabled
        self.quickTerminalHotkey = quickTerminalHotkey
        self.windowPaddingBalance = windowPaddingBalance
        self.minimumContrast = HarnessSettings.clampedContrast(minimumContrast)
        self.pasteProtection = pasteProtection
        self.commandFinishedThresholdSeconds = max(0, commandFinishedThresholdSeconds)
        self.notificationEvents = notificationEvents
        self.boldIsBright = boldIsBright
        self.secureKeyboardEntry = secureKeyboardEntry
        self.windowInheritCWD = windowInheritCWD
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

    /// Whether `event` is allowed to fire a notification. Falls back to the event's
    /// `defaultEnabled` when the user hasn't made an explicit choice, so the sparse
    /// `notificationEvents` map stays small and old configs behave as before.
    public func isEventEnabled(_ event: NotificationEvent) -> Bool {
        notificationEvents[event.rawValue] ?? event.defaultEnabled
    }

    /// Record an explicit per-event notification choice.
    public mutating func setEventEnabled(_ event: NotificationEvent, _ enabled: Bool) {
        notificationEvents[event.rawValue] = enabled
    }

    public mutating func clearThemeColorOverrides() {
        customBackgroundHex = nil
        customForegroundHex = nil
        customCursorHex = nil
        selectionBackgroundHex = nil
        selectionForegroundHex = nil
        boldColorHex = nil
        cursorTextHex = nil
        paletteHex = Array(repeating: nil, count: 16)
        dividerHex = nil
        statusLineHex = nil
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
        if let light = imported?.systemLightThemeName, let dark = imported?.systemDarkThemeName {
            appearanceMode = .macOSSystem
            systemLightThemeName = light
            systemDarkThemeName = dark
        } else {
            appearanceMode = defaults.appearanceMode
            systemLightThemeName = defaults.systemLightThemeName
            systemDarkThemeName = defaults.systemDarkThemeName
        }
        customBackgroundHex = imported?.backgroundHex
        customForegroundHex = imported?.foregroundHex
        customCursorHex = imported?.cursorColorHex
        selectionBackgroundHex = imported?.selectionBackgroundHex
        selectionForegroundHex = imported?.selectionForegroundHex
        boldColorHex = imported?.boldColorHex
        cursorTextHex = imported?.cursorTextHex
        dividerHex = nil
        statusLineHex = nil
        windowBorderHex = nil
        windowBorderOpacity = defaults.windowBorderOpacity
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

    /// Forward-compat field decode driven by the default instance: `decode(.key, \\.field)`
    /// reads the key when present and otherwise returns `fallback[keyPath:]` — one place
    /// owns every fallback (`makeDefaults`), and the typo class where a line decodes one
    /// key but falls back to a DIFFERENT field's default can no longer be written. Fields
    /// with non-default semantics (legacy migrations, deliberate `?? true` upgrades,
    /// clamps with their own comments) stay hand-written below, on purpose.
    /// (Generic over the key type because the compiler-synthesized `CodingKeys` cannot be
    /// named in a nested type's signature; inference binds it at the use site in `init(from:)`.)
    private struct FieldDecoder<Keys: CodingKey> {
        let container: KeyedDecodingContainer<Keys>
        let fallback: HarnessSettings

        func decode<T: Decodable>(_ key: Keys, _ field: KeyPath<HarnessSettings, T>) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback[keyPath: field]
        }
    }

    /// Decoder that gracefully accepts older settings files missing the newer fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyHarnessSettingsCodingKeys.self)
        // Consume the cached import result when decode is called from load() — that caller
        // already ran TerminalConfigImporter.load() and stashed the result here so we don't
        // invoke the importer twice on every first-run or migration path.
        let imported = HarnessSettings.pendingImportedConfig ?? TerminalConfigImporter.load()
        let fallback = HarnessSettings.makeDefaults(imported: imported)
        let fields = FieldDecoder(container: container, fallback: fallback)

        fontSize = HarnessSettings.clampedFontSize(try fields.decode(.fontSize, \.fontSize))
        fontFamily = try fields.decode(.fontFamily, \.fontFamily)
        defaultShell = try fields.decode(.defaultShell, \.defaultShell)
        defaultCWD = try fields.decode(.defaultCWD, \.defaultCWD)
        transparentTitlebar = try fields.decode(.transparentTitlebar, \.transparentTitlebar)
        sidebarVisible = try fields.decode(.sidebarVisible, \.sidebarVisible)
        restoreWindowSize = try fields.decode(.restoreWindowSize, \.restoreWindowSize)
        backgroundOpacity = try fields.decode(.backgroundOpacity, \.backgroundOpacity)
        backgroundBlur = try fields.decode(.backgroundBlur, \.backgroundBlur)
        windowPaddingX = HarnessSettings.clampedPadding(try fields.decode(.windowPaddingX, \.windowPaddingX))
        windowPaddingY = HarnessSettings.clampedPadding(try fields.decode(.windowPaddingY, \.windowPaddingY))
        // Hand-written (migration semantics, deliberately NOT FieldDecoder): a settings file
        // written before `appearanceMode` existed may carry the legacy auto light/dark pair
        // (`lightThemeName`/`darkThemeName`, shipped since v1.1.x). Those users opted into
        // following the macOS appearance — migrate them to `.macOSSystem` and seed the system
        // theme names from their legacy choice so the feature survives the update. The
        // fallback for the appearance fields is the plain memberwise default (`.theme`), not
        // the import-influenced `fallback`: an existing settings.json must never flip modes
        // because the *source terminal's* config changed — imports only land via the consented
        // backfill in `load()`.
        let decodedAppearanceMode = try container.decodeIfPresent(HarnessAppearanceMode.self, forKey: .appearanceMode)
        let legacyLightThemeName = try legacyContainer.decodeIfPresent(String.self, forKey: .lightThemeName)
        let legacyDarkThemeName = try legacyContainer.decodeIfPresent(String.self, forKey: .darkThemeName)
        let defaultSettings = HarnessSettings()
        if decodedAppearanceMode == nil,
           let legacyLightThemeName,
           let legacyDarkThemeName,
           !legacyLightThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !legacyDarkThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            appearanceMode = .macOSSystem
            systemLightThemeName = legacyLightThemeName
            systemDarkThemeName = legacyDarkThemeName
        } else {
            appearanceMode = decodedAppearanceMode ?? defaultSettings.appearanceMode
            systemLightThemeName = try container.decodeIfPresent(String.self, forKey: .systemLightThemeName) ?? defaultSettings.systemLightThemeName
            systemDarkThemeName = try container.decodeIfPresent(String.self, forKey: .systemDarkThemeName) ?? defaultSettings.systemDarkThemeName
        }
        customBackgroundHex = try fields.decode(.customBackgroundHex, \.customBackgroundHex)
        customForegroundHex = try fields.decode(.customForegroundHex, \.customForegroundHex)
        customCursorHex = try fields.decode(.customCursorHex, \.customCursorHex)
        importedConfigSignature = try container.decodeIfPresent(String.self, forKey: .importedConfigSignature)
        prefixKey = try fields.decode(.prefixKey, \.prefixKey)
        scrollbackLines = try fields.decode(.scrollbackLines, \.scrollbackLines)
        cursorStyle = try fields.decode(.cursorStyle, \.cursorStyle)
        cursorBlink = try fields.decode(.cursorBlink, \.cursorBlink)
        copyOnSelect = try fields.decode(.copyOnSelect, \.copyOnSelect)
        selectionBackgroundHex = try fields.decode(.selectionBackgroundHex, \.selectionBackgroundHex)
        selectionForegroundHex = try fields.decode(.selectionForegroundHex, \.selectionForegroundHex)
        boldColorHex = try fields.decode(.boldColorHex, \.boldColorHex)
        cursorTextHex = try fields.decode(.cursorTextHex, \.cursorTextHex)
        paletteHex = HarnessSettings.normalizedPalette(try fields.decode(.paletteHex, \.paletteHex))
        let agentColors = try container.decodeIfPresent([String: String].self, forKey: .agentColorOverrides) ?? fallback.agentColorOverrides
        agentColorOverrides = HarnessSettings.normalizedAgentColorOverrides(agentColors)
        dividerHex = try container.decodeIfPresent(String.self, forKey: .dividerHex)
        statusLineHex = try container.decodeIfPresent(String.self, forKey: .statusLineHex)
        windowBorderHex = try container.decodeIfPresent(String.self, forKey: .windowBorderHex)
        windowBorderOpacity = max(0, min(1, try fields.decode(.windowBorderOpacity, \.windowBorderOpacity)))
        systemNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        notificationSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) ?? true
        notchVisibilityMode = try container.decodeIfPresent(NotchVisibilityMode.self, forKey: .notchVisibilityMode) ?? .automatic
        notchOpenOnHover = try container.decodeIfPresent(Bool.self, forKey: .notchOpenOnHover) ?? true
        let legacyVivid = try container.decodeIfPresent(Bool.self, forKey: .vividColors)
        let decodedColorRendering = try container.decodeIfPresent(TerminalColorRenderingMode.self, forKey: .colorRendering)
        let resolvedColorRendering = decodedColorRendering
            ?? ((legacyVivid ?? fallback.vividColors) ? .vivid : fallback.colorRendering)
        colorRendering = resolvedColorRendering
        colorGamut = try fields.decode(.colorGamut, \.colorGamut)

        let legacyLinear = try container.decodeIfPresent(Bool.self, forKey: .linearBlending)
        let decodedTextRendering = try container.decodeIfPresent(TerminalTextRenderingMode.self, forKey: .textRendering)
        let resolvedTextRendering = decodedTextRendering
            ?? ((legacyLinear ?? fallback.linearBlending) ? .crisp : fallback.textRendering)
        textRendering = resolvedTextRendering
        vividColors = resolvedColorRendering == .vivid
        linearBlending = resolvedTextRendering == .crisp
        applyThemeToTerminalOutput = try fields.decode(.applyThemeToTerminalOutput, \.applyThemeToTerminalOutput)
        ligatures = try fields.decode(.ligatures, \.ligatures)
        // Default on when the key is absent (existing installs get the fast path); an explicitly
        // stored `false` is honored as an opt-out.
        offMainParserFramePipeline = try container.decodeIfPresent(Bool.self, forKey: .offMainParserFramePipeline) ?? true
        // Default on when the key is absent (existing installs get real-time resize); an explicitly
        // stored `false` is honored as an opt-out to the legacy defer-to-release behavior.
        liveResizeReflow = try container.decodeIfPresent(Bool.self, forKey: .liveResizeReflow) ?? true
        showPromptGutter = try fields.decode(.showPromptGutter, \.showPromptGutter)
        showStatusLine = try fields.decode(.showStatusLine, \.showStatusLine)
        // Behavior-preserving migration: a settings file that predates modes was written by a
        // user who already had the prefix + status line, i.e. the full Harness experience.
        // Default the absent key to `.full` (NOT the fresh-install `.plain`) so upgrading never
        // silently strips features. New installs get `.plain` via `makeDefaults`.
        experienceMode = try container.decodeIfPresent(ExperienceMode.self, forKey: .experienceMode) ?? .full
        harnessControlsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .harnessControlsEnabled)
            ?? legacyContainer.decodeIfPresent(Bool.self, forKey: .tmuxControlsEnabled)
        // Per-component overrides — absent in older files, so they decode to nil and fall back to
        // the legacy umbrella `harnessControlsEnabled` (then the mode) via the effective accessors.
        // No data migration needed: an existing file with `harnessControlsEnabled` keeps behaving
        // exactly as before until the user touches a finer toggle.
        prefixKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .prefixKeyEnabled)
        statusLineEnabled = try container.decodeIfPresent(Bool.self, forKey: .statusLineEnabled)
        resizeOverlay = try fields.decode(.resizeOverlay, \.resizeOverlay)
        resizeOverlayPosition = try fields.decode(.resizeOverlayPosition, \.resizeOverlayPosition)
        bellMode = try fields.decode(.bellMode, \.bellMode)
        scrollMultiplier = HarnessSettings.clampedScrollMultiplier(try fields.decode(.scrollMultiplier, \.scrollMultiplier))
        mouseHideWhileTyping = try fields.decode(.mouseHideWhileTyping, \.mouseHideWhileTyping)
        quickTerminalEnabled = try fields.decode(.quickTerminalEnabled, \.quickTerminalEnabled)
        quickTerminalHotkey = try fields.decode(.quickTerminalHotkey, \.quickTerminalHotkey)
        windowPaddingBalance = try fields.decode(.windowPaddingBalance, \.windowPaddingBalance)
        minimumContrast = HarnessSettings.clampedContrast(try fields.decode(.minimumContrast, \.minimumContrast))
        // `lightThemeName`/`darkThemeName` are no longer stored fields — the legacy pair is
        // consumed by the `appearanceMode` migration above (via LegacyHarnessSettingsCodingKeys).
        pasteProtection = try fields.decode(.pasteProtection, \.pasteProtection)
        commandFinishedThresholdSeconds =
            try fields.decode(.commandFinishedThresholdSeconds, \.commandFinishedThresholdSeconds)
        var decodedEvents = try container.decodeIfPresent([String: Bool].self, forKey: .notificationEvents) ?? [:]
        // One-time migration: fold the legacy standalone `commandFinishedNotifications` bool into the
        // per-event map, unless the map already carries an explicit choice for it.
        if decodedEvents[NotificationEvent.commandFinished.rawValue] == nil,
           let legacyCommandFinished = try legacyContainer.decodeIfPresent(Bool.self, forKey: .commandFinishedNotifications) {
            decodedEvents[NotificationEvent.commandFinished.rawValue] = legacyCommandFinished
        }
        notificationEvents = decodedEvents
        boldIsBright = try fields.decode(.boldIsBright, \.boldIsBright)
        secureKeyboardEntry = try fields.decode(.secureKeyboardEntry, \.secureKeyboardEntry)
        windowInheritCWD = try fields.decode(.windowInheritCWD, \.windowInheritCWD)
    }

    /// Thread-unsafe scratch slot used exclusively within `load()` to pass the already-computed
    /// import result into `init(from decoder:)` without running `TerminalConfigImporter.load()`
    /// a second time. Set immediately before `JSONDecoder().decode(…)`, cleared immediately after.
    /// Only valid on the calling thread; `load()` is always called from a single context
    /// (app start / settings save+reload), never concurrently.
    nonisolated(unsafe) private static var pendingImportedConfig: ImportedTerminalConfig??

    /// `imported` defaults to the live terminal-config import; tests inject a fixture so
    /// migration behavior doesn't depend on the machine's source-terminal config.
    public static func load(imported: ImportedTerminalConfig? = TerminalConfigImporter.load()) -> HarnessSettings {
        let url = HarnessPaths.settingsURL
        if FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) {
            // Stash the already-loaded import result so init(from:) can reuse it rather than
            // calling TerminalConfigImporter.load() a second time.
            pendingImportedConfig = imported
            defer { pendingImportedConfig = nil }
            guard var settings = try? JSONDecoder().decode(HarnessSettings.self, from: data) else {
                // Present but unreadable: preserve it as `.corrupt` for recovery rather than
                // silently overwriting it with defaults (which would discard the user's settings).
                // Mirrors SessionStore/OptionStore — return defaults WITHOUT rewriting the file.
                HarnessPaths.backupCorruptFile(at: url, label: "Harness")
                return HarnessSettings.makeDefaults(imported: imported)
            }
            let hasStoredColorChoice = settingsDataContainsColorChoice(data)
            let hasStoredImportOwnedVisualChoice = settingsDataContainsImportOwnedVisualChoice(data)
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
                if settings.hasUserVisualCustomizations || hasStoredImportOwnedVisualChoice {
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
            // Recover hand-edited or runaway font sizes that would overflow the glyph atlas (huge)
            // or balloon the grid allocation (tiny). 8–32 matches the Cmd+/- zoom policy.
            let clampedFontSize = HarnessSettings.clampedFontSize(settings.fontSize)
            if clampedFontSize != settings.fontSize { settings.fontSize = clampedFontSize; didMutate = true }
            let clampedPaddingX = HarnessSettings.clampedPadding(settings.windowPaddingX)
            if clampedPaddingX != settings.windowPaddingX { settings.windowPaddingX = clampedPaddingX; didMutate = true }
            let clampedPaddingY = HarnessSettings.clampedPadding(settings.windowPaddingY)
            if clampedPaddingY != settings.windowPaddingY { settings.windowPaddingY = clampedPaddingY; didMutate = true }
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

    private static func settingsDataContainsImportOwnedVisualChoice(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object[CodingKeys.backgroundOpacity.stringValue] != nil
            || object[CodingKeys.backgroundBlur.stringValue] != nil
            || object[CodingKeys.windowPaddingX.stringValue] != nil
            || object[CodingKeys.windowPaddingY.stringValue] != nil
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

    /// Scroll-speed multiplier bounds. 0 (or negative) would freeze or invert scrolling; a huge
    /// value would jump pages per notch. Keep it usefully adjustable but sane.
    public static func clampedScrollMultiplier(_ value: Double) -> Double {
        max(0.1, min(10, value))
    }

    /// Font-size bounds (points), matching the Cmd+/- zoom policy in `SessionCoordinator.applyFontSize`.
    /// Out-of-range values are a footgun: ≥~500 overflows the glyph atlas page (invisible text),
    /// ≤~1 forces a multi-hundred-megabyte grid allocation. Clamp at every persistence boundary.
    public static func clampedFontSize(_ value: Float) -> Float {
        max(8, min(32, value))
    }

    /// Window padding (points) is never negative. The renderer already neutralizes negatives, so
    /// this is belt-and-braces — it keeps the persisted value sane regardless of the read site.
    public static func clampedPadding(_ value: Float) -> Float {
        max(0, value)
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
        if let light = imported.systemLightThemeName, let dark = imported.systemDarkThemeName {
            settings.appearanceMode = .macOSSystem
            settings.systemLightThemeName = light
            settings.systemDarkThemeName = dark
        }
        if let value = imported.backgroundHex { settings.customBackgroundHex = value }
        if let value = imported.foregroundHex { settings.customForegroundHex = value }
        if let value = imported.cursorColorHex { settings.customCursorHex = value }
        if let value = imported.cursorStyle { settings.cursorStyle = value }
        if let value = imported.cursorBlink { settings.cursorBlink = value }
        if let value = imported.copyOnSelect { settings.copyOnSelect = value }
        if let value = imported.minimumContrast { settings.minimumContrast = HarnessSettings.clampedContrast(value) }
        if let value = imported.boldIsBright { settings.boldIsBright = value }
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
        if let light = imported.systemLightThemeName, let dark = imported.systemDarkThemeName {
            appearanceMode = .macOSSystem
            systemLightThemeName = light
            systemDarkThemeName = dark
        }
        if let value = imported.backgroundHex { customBackgroundHex = value }
        if let value = imported.foregroundHex { customForegroundHex = value }
        if let value = imported.cursorColorHex { customCursorHex = value }
        if let value = imported.cursorStyle { cursorStyle = value }
        if let value = imported.cursorBlink { cursorBlink = value }
        if let value = imported.copyOnSelect { copyOnSelect = value }
        if let value = imported.minimumContrast { minimumContrast = HarnessSettings.clampedContrast(value) }
        if let value = imported.boldIsBright { boldIsBright = value }
        selectionBackgroundHex = imported.selectionBackgroundHex
        selectionForegroundHex = imported.selectionForegroundHex
        boldColorHex = imported.boldColorHex
        cursorTextHex = imported.cursorTextHex
        paletteHex = HarnessSettings.normalizedPalette(imported.paletteHex)
        importedConfigSignature = imported.signature
    }
}
