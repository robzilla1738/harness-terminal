import Foundation

/// One settings control in the command palette. `apply` writes through `SettingsEditor`,
/// the same writer the settings window uses.
public struct SettingsPaletteRow {
    public var id: String
    public var title: String
    public var apply: (inout HarnessSettings) -> Void
    public var detail: (HarnessSettings) -> String

    public init(
        id: String,
        title: String,
        apply: @escaping (inout HarnessSettings) -> Void,
        detail: @escaping (HarnessSettings) -> String
    ) {
        self.id = id
        self.title = title
        self.apply = apply
        self.detail = detail
    }
}

public enum SettingsPalette {
    public static func rows(appearanceIsLight: Bool) -> [SettingsPaletteRow] {
        var rows: [SettingsPaletteRow] = []
        func add(
            _ id: String,
            _ title: String,
            detail: @escaping (HarnessSettings) -> String,
            _ apply: @escaping (inout HarnessSettings) -> Void
        ) {
            rows.append(SettingsPaletteRow(id: id, title: title, apply: apply, detail: detail))
        }
        func toggle(_ id: String, _ title: String, _ key: WritableKeyPath<HarnessSettings, Bool>) {
            add(id, title, detail: { $0[keyPath: key] ? "On" : "Off" }) { settings in
                SettingsEditor.applyFromPalette(key, !settings[keyPath: key], on: &settings)
            }
        }
        func cycle<T: Equatable & RawRepresentable>(
            _ id: String, _ title: String, _ cases: [T], _ key: WritableKeyPath<HarnessSettings, T>
        ) where T.RawValue == String {
            add(id, title, detail: { $0[keyPath: key].rawValue }) { settings in
                SettingsEditor.applyFromPalette(key, Self.next(cases, settings[keyPath: key]), on: &settings)
            }
        }

        add("backgroundOpacity", "Background opacity", detail: { String($0.backgroundOpacity) }) { settings in
            let stepped = HarnessSettings.clampedOpacity(settings.backgroundOpacity + 0.05)
            let next = stepped == settings.backgroundOpacity ? HarnessSettings.clampedOpacity(0.05) : stepped
            SettingsEditor.applyFromPalette(\.backgroundOpacity, next, on: &settings)
        }
        add("backgroundBlur", "Background blur", detail: { String($0.backgroundBlur) }) { settings in
            let stepped = HarnessSettings.clampedBlur(settings.backgroundBlur + 5)
            let next = stepped == settings.backgroundBlur ? 0 : stepped
            SettingsEditor.applyFromPalette(\.backgroundBlur, next, on: &settings)
        }
        add("windowBorderOpacity", "Window border opacity", detail: { String($0.windowBorderOpacity) }) { settings in
            let stepped = min(Float(1), settings.windowBorderOpacity + 0.1)
            let next = stepped == settings.windowBorderOpacity ? Float(0) : stepped
            SettingsEditor.applyFromPalette(\.windowBorderOpacity, next, on: &settings)
        }
        for spec in colorSpecs() {
            add(spec.id, spec.title, detail: { $0[keyPath: spec.key] ?? "Theme" }) { settings in
                SettingsEditor.applyFromPalette(spec.key, settings[keyPath: spec.key], on: &settings)
            }
        }
        add("paletteHex", "ANSI palette", detail: { _ in "16 slots" }) { settings in
            SettingsEditor.applyFromPalette(\.paletteHex, settings.paletteHex, on: &settings)
        }
        toggle("transparentTitlebar", "Transparent titlebar", \.transparentTitlebar)
        toggle("showStatusLine", "Status line", \.showStatusLine)
        toggle("sidebarVisible", "Sidebar", \.sidebarVisible)
        toggle("restoreWindowSize", "Remember window size", \.restoreWindowSize)
        add("windowPaddingX", "Horizontal padding", detail: { String($0.windowPaddingX) }) { settings in
            SettingsEditor.applyFromPalette(\.windowPaddingX, HarnessSettings.clampedPadding(settings.windowPaddingX + 1), on: &settings)
        }
        add("windowPaddingY", "Vertical padding", detail: { String($0.windowPaddingY) }) { settings in
            SettingsEditor.applyFromPalette(\.windowPaddingY, HarnessSettings.clampedPadding(settings.windowPaddingY + 1), on: &settings)
        }
        cycle("appearanceMode", "Appearance", HarnessAppearanceMode.allCases, \.appearanceMode)
        add("fontSize", "Font size", detail: { String($0.fontSize) }) { settings in
            let stepped = HarnessSettings.clampedFontSize(settings.fontSize + 1)
            let next = stepped == settings.fontSize ? HarnessSettings.clampedFontSize(8) : stepped
            SettingsEditor.applyFromPalette(\.fontSize, next, on: &settings)
        }
        add("fontFamily", "Font", detail: { $0.fontFamily }) { settings in
            SettingsEditor.applyFromPalette(\.fontFamily, settings.fontFamily, on: &settings)
        }
        add("defaultShell", "Shell", detail: { $0.defaultShell }) { settings in
            SettingsEditor.applyFromPalette(\.defaultShell, settings.defaultShell, on: &settings)
        }
        add("defaultCWD", "Working directory", detail: { $0.defaultCWD }) { settings in
            SettingsEditor.applyFromPalette(\.defaultCWD, settings.defaultCWD, on: &settings)
        }
        add("scrollbackLines", "Scrollback lines", detail: { $0.scrollbackLines == 0 ? "Unlimited" : String($0.scrollbackLines) }) { settings in
            let next: Int
            if settings.scrollbackLines == 0 { next = 10_000 }
            else if settings.scrollbackLines >= 100_000 { next = 0 }
            else { next = settings.scrollbackLines + 1_000 }
            SettingsEditor.applyFromPalette(\.scrollbackLines, next, on: &settings)
        }
        add("cursorStyle", "Cursor style", detail: { $0.cursorStyle }) { settings in
            let styles = ["block", "bar", "underline"]
            SettingsEditor.applyFromPalette(\.cursorStyle, next(styles, settings.cursorStyle), on: &settings)
        }
        toggle("cursorBlink", "Cursor blink", \.cursorBlink)
        toggle("copyOnSelect", "Copy on select", \.copyOnSelect)
        toggle("systemNotificationsEnabled", "System notifications", \.systemNotificationsEnabled)
        toggle("notificationSoundEnabled", "Notification sound", \.notificationSoundEnabled)
        add("colorRendering", "Color rendering", detail: { $0.colorRendering.rawValue }) { settings in
            let next: TerminalColorRenderingMode = settings.colorRendering == .accurate ? .vivid : .accurate
            SettingsEditor.applyFromPalette(\.colorRendering, next, on: &settings)
        }
        add("textRendering", "Text rendering", detail: { $0.textRendering.rawValue }) { settings in
            let order: [TerminalTextRenderingMode] = [.native, .crisp, .soft]
            SettingsEditor.applyFromPalette(\.textRendering, next(order, settings.textRendering), on: &settings)
        }
        toggle("applyThemeToTerminalOutput", "Theme terminal output", \.applyThemeToTerminalOutput)
        toggle("ligatures", "Ligatures", \.ligatures)
        toggle("showPromptGutter", "Prompt gutter", \.showPromptGutter)
        toggle("offMainParserFramePipeline", "Off-main parser", \.offMainParserFramePipeline)
        toggle("liveResizeReflow", "Live resize reflow", \.liveResizeReflow)
        cycle("resizeOverlay", "Resize overlay", ResizeOverlayMode.allCases, \.resizeOverlay)
        cycle("resizeOverlayPosition", "Resize overlay position", ResizeOverlayPosition.allCases, \.resizeOverlayPosition)
        cycle("bellMode", "Bell", BellMode.allCases, \.bellMode)
        add("scrollMultiplier", "Scroll speed", detail: { String($0.scrollMultiplier) }) { settings in
            let stepped = HarnessSettings.clampedScrollMultiplier(settings.scrollMultiplier + 0.25)
            let next = stepped == settings.scrollMultiplier ? HarnessSettings.clampedScrollMultiplier(0.1) : stepped
            SettingsEditor.applyFromPalette(\.scrollMultiplier, next, on: &settings)
        }
        toggle("mouseHideWhileTyping", "Hide mouse while typing", \.mouseHideWhileTyping)
        cycle("optionAsMeta", "Option key", OptionAsMetaMode.allCases, \.optionAsMeta)
        toggle("quickTerminalEnabled", "Quick terminal", \.quickTerminalEnabled)
        add("quickTerminalHotkey", "Quick terminal hotkey", detail: { $0.quickTerminalHotkey }) { settings in
            SettingsEditor.applyFromPalette(\.quickTerminalHotkey, settings.quickTerminalHotkey, on: &settings)
        }
        toggle("windowPaddingBalance", "Balance padding", \.windowPaddingBalance)
        add("minimumContrast", "Minimum contrast", detail: { String($0.minimumContrast) }) { settings in
            let stepped = HarnessSettings.clampedContrast(settings.minimumContrast + 0.5)
            let next = stepped == settings.minimumContrast ? 1 : stepped
            SettingsEditor.applyFromPalette(\.minimumContrast, next, on: &settings)
        }
        toggle("pasteProtection", "Paste protection", \.pasteProtection)
        toggle("remoteControl", "Remote control", \.remoteControl)
        toggle("boldIsBright", "Bold is bright", \.boldIsBright)
        add("themeFit", "Theme fit", detail: { settings in
            settings.effectiveThemeFit(appearanceIsLight: appearanceIsLight) ? "On" : "Off"
        }) { settings in
            let on = !settings.effectiveThemeFit(appearanceIsLight: appearanceIsLight)
            let stored = ThemeFitPolicy.stored(toggleOn: on, appearanceIsLight: appearanceIsLight)
            SettingsEditor.applyFromPalette(\.themeFit, stored, on: &settings)
        }
        add("paneDensity", "Pane density", detail: { $0.paneDensity.rawValue }) { settings in
            let next: PaneDensity = settings.paneDensity == .comfortable ? .compact : .comfortable
            SettingsEditor.applyFromPalette(\.paneDensity, next, on: &settings)
        }
        add("paneHeaders", "Pane headers", detail: { $0.paneHeaders ? "On" : "Off" }) { settings in
            SettingsEditor.applyFromPalette(\.paneHeaders, !settings.paneHeaders, on: &settings)
        }
        for event in NotificationEvent.allCases {
            add("notify.\(event.rawValue)", "Notify: \(event.title)", detail: { $0.isEventEnabled(event) ? "On" : "Off" }) { settings in
                SettingsEditor.setEvent(event, !settings.isEventEnabled(event), on: &settings)
            }
        }
        add("commandFinishedThresholdSeconds", "Command finished threshold", detail: { String($0.commandFinishedThresholdSeconds) }) { settings in
            let next = settings.commandFinishedThresholdSeconds >= 120 ? 1 : settings.commandFinishedThresholdSeconds + 1
            SettingsEditor.applyFromPalette(\.commandFinishedThresholdSeconds, next, on: &settings)
        }
        cycle("experienceMode", "Experience", ExperienceMode.allCases, \.experienceMode)
        add("prefixKeyEnabled", "Prefix key enabled", detail: { optionalBool($0.prefixKeyEnabled) }) { settings in
            SettingsEditor.applyFromPalette(\.prefixKeyEnabled, nextOptional(settings.prefixKeyEnabled), on: &settings)
        }
        add("statusLineEnabled", "Status line enabled", detail: { optionalBool($0.statusLineEnabled) }) { settings in
            SettingsEditor.applyFromPalette(\.statusLineEnabled, nextOptional(settings.statusLineEnabled), on: &settings)
        }
        add("prefixKey", "Prefix key", detail: { $0.prefixKey }) { settings in
            SettingsEditor.applyFromPalette(\.prefixKey, settings.prefixKey, on: &settings)
        }
        for kind in AgentKind.allCases {
            add("agentColor.\(kind.rawValue)", "\(kind.rawValue) color", detail: { $0.agentColorHex(for: kind) }) { settings in
                var overrides = settings.agentColorOverrides
                overrides[kind.rawValue] = settings.agentColorHex(for: kind)
                SettingsEditor.applyFromPalette(
                    \.agentColorOverrides,
                    HarnessSettings.normalizedAgentColorOverrides(overrides),
                    on: &settings
                )
            }
        }
        return rows
    }

    /// The next value in `cases`, wrapping. An unknown current value starts at the first.
    public static func next<T: Equatable>(_ cases: [T], _ current: T) -> T {
        guard let index = cases.firstIndex(of: current) else { return cases[0] }
        return cases[(index + 1) % cases.count]
    }

    private static func nextOptional(_ value: Bool?) -> Bool? {
        switch value {
        case .none: return true
        case .some(true): return false
        case .some(false): return nil
        }
    }

    private static func optionalBool(_ value: Bool?) -> String {
        switch value {
        case .none: return "Automatic"
        case .some(true): return "On"
        case .some(false): return "Off"
        }
    }

    private static func colorSpecs() -> [(id: String, title: String, key: WritableKeyPath<HarnessSettings, String?>)] {
        [
        ("customBackgroundHex", "Background color", \.customBackgroundHex),
        ("customForegroundHex", "Foreground color", \.customForegroundHex),
        ("customCursorHex", "Cursor color", \.customCursorHex),
        ("cursorTextHex", "Cursor text color", \.cursorTextHex),
        ("selectionBackgroundHex", "Selection background", \.selectionBackgroundHex),
        ("selectionForegroundHex", "Selection foreground", \.selectionForegroundHex),
        ("boldColorHex", "Bold color", \.boldColorHex),
        ("dividerHex", "Divider color", \.dividerHex),
        ("statusLineHex", "Status line color", \.statusLineHex),
        ("windowBorderHex", "Window border color", \.windowBorderHex),
        ]
    }
}
