import Foundation

/// Snapshot of the bits of an existing terminal config we mirror as defaults.
public struct ImportedTerminalConfig: Sendable, Equatable {
    // v4: selection/bold/cursor-text/minimum-contrast/palette are now honored
    // (previously imported then discarded), so bump to force a one-time re-import.
    private static let signatureVersion = "v4"

    public var fontFamily: String?
    public var fontSize: Float?
    public var defaultShell: String?
    public var backgroundOpacity: Float?
    public var backgroundBlur: Int?
    public var windowPaddingX: Float?
    public var windowPaddingY: Float?
    public var themeName: String?
    public var backgroundHex: String?
    public var foregroundHex: String?
    public var cursorColorHex: String?
    public var selectionBackgroundHex: String?
    public var selectionForegroundHex: String?
    public var boldColorHex: String?
    public var cursorTextHex: String?
    /// Parsed for the config fingerprint only — Harness no longer surfaces a
    /// minimum-contrast setting, so this value is not applied to `HarnessSettings`.
    public var minimumContrast: Double?
    public var paletteHex: [String?]
    public var cursorStyle: String?
    public var cursorBlink: Bool?
    public var copyOnSelect: Bool?

    public var signature: String {
        var parts: [String] = []
        parts.append(Self.signatureVersion)
        parts.append(fontFamily ?? "")
        parts.append(fontSize.map { String($0) } ?? "")
        parts.append(defaultShell ?? "")
        parts.append(backgroundOpacity.map { String($0) } ?? "")
        parts.append(backgroundBlur.map { String($0) } ?? "")
        parts.append(windowPaddingX.map { String($0) } ?? "")
        parts.append(windowPaddingY.map { String($0) } ?? "")
        parts.append(themeName ?? "")
        parts.append(backgroundHex ?? "")
        parts.append(foregroundHex ?? "")
        parts.append(cursorColorHex ?? "")
        parts.append(selectionBackgroundHex ?? "")
        parts.append(selectionForegroundHex ?? "")
        parts.append(boldColorHex ?? "")
        parts.append(cursorTextHex ?? "")
        parts.append(minimumContrast.map { String($0) } ?? "")
        parts.append(HarnessSettings.normalizedPalette(paletteHex).map { $0 ?? "" }.joined(separator: ","))
        parts.append(cursorStyle ?? "")
        parts.append(cursorBlink.map { String($0) } ?? "")
        parts.append(copyOnSelect.map { String($0) } ?? "")
        return parts.joined(separator: "|")
    }

    public init(
        fontFamily: String? = nil,
        fontSize: Float? = nil,
        defaultShell: String? = nil,
        backgroundOpacity: Float? = nil,
        backgroundBlur: Int? = nil,
        windowPaddingX: Float? = nil,
        windowPaddingY: Float? = nil,
        themeName: String? = nil,
        backgroundHex: String? = nil,
        foregroundHex: String? = nil,
        cursorColorHex: String? = nil,
        selectionBackgroundHex: String? = nil,
        selectionForegroundHex: String? = nil,
        boldColorHex: String? = nil,
        cursorTextHex: String? = nil,
        minimumContrast: Double? = nil,
        paletteHex: [String?] = Array(repeating: nil, count: 16),
        cursorStyle: String? = nil,
        cursorBlink: Bool? = nil,
        copyOnSelect: Bool? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.defaultShell = defaultShell
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.windowPaddingX = windowPaddingX
        self.windowPaddingY = windowPaddingY
        self.themeName = themeName
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.cursorColorHex = cursorColorHex
        self.selectionBackgroundHex = selectionBackgroundHex
        self.selectionForegroundHex = selectionForegroundHex
        self.boldColorHex = boldColorHex
        self.cursorTextHex = cursorTextHex
        self.minimumContrast = minimumContrast
        self.paletteHex = HarnessSettings.normalizedPalette(paletteHex)
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.copyOnSelect = copyOnSelect
    }

    public var hasTerminalColorOverrides: Bool {
        backgroundHex != nil
            || foregroundHex != nil
            || cursorColorHex != nil
            || selectionBackgroundHex != nil
            || selectionForegroundHex != nil
            || boldColorHex != nil
            || cursorTextHex != nil
            || paletteHex.contains { $0 != nil }
    }
}

/// Reads an existing terminal config from disk and pulls values that map cleanly to Harness —
/// font, opacity, blur, padding, theme/colors.
public enum TerminalConfigImporter {
    public static let candidatePaths: [String] = {
        let home = NSString(string: "~").expandingTildeInPath
        return [
            "\(home)/.config/ghostty/config.ghostty",
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
        ]
    }()

    /// Existing config files in merge order. Later files override earlier
    /// files for duplicated keys, matching how Harness has historically treated
    /// XDG config plus the macOS app-support fallback on this machine.
    public static func existingConfigPaths(from paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Existing config files in default discovery order.
    public static func existingConfigPaths() -> [String] {
        existingConfigPaths(from: candidatePaths)
    }

    /// First existing config file from the given paths, if any.
    public static func existingConfigPath(from paths: [String]) -> String? {
        existingConfigPaths(from: paths).first
    }

    /// First existing config file on disk, if any.
    public static func existingConfigPath() -> String? {
        existingConfigPath(from: candidatePaths)
    }

    /// Imported defaults for the current user. `nil` when no config was found.
    public static func load() -> ImportedTerminalConfig? {
        load(from: candidatePaths)
    }

    static func load(from paths: [String]) -> ImportedTerminalConfig? {
        var merged: ImportedTerminalConfig?
        for path in paths {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            if let existing = merged {
                merged = existing.merging(parse(data))
            } else {
                merged = parse(data)
            }
        }
        return merged
    }

    static func parse(_ text: String) -> ImportedTerminalConfig {
        var values: [String: String] = [:]
        var paletteHex: [String?] = Array(repeating: nil, count: 16)
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // NOTE: do NOT strip `#…` as a trailing comment — config
            // values like `background = #000000` legitimately start with `#`.
            // The config format only treats `#` as a comment when it's the first
            // non-whitespace character on the line, which we already handle
            // above.
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if key == "palette", let entry = parsePaletteEntry(String(value)) {
                paletteHex[entry.index] = entry.hex
            }
            values[key] = String(value)
        }

        var defaults = ImportedTerminalConfig()
        defaults.paletteHex = paletteHex
        if let value = values["font-family"], !value.isEmpty {
            defaults.fontFamily = value
        }
        if let raw = values["font-size"], let value = Float(raw) {
            defaults.fontSize = value
        }
        if let value = values["command"]?.split(separator: " ").first.map(String.init) {
            defaults.defaultShell = value
        }
        if let raw = values["background-opacity"], let value = Float(raw) {
            defaults.backgroundOpacity = max(0, min(1, value))
        }
        if let raw = values["background-blur"] ?? values["background-blur-radius"] {
            if let value = Int(raw) {
                defaults.backgroundBlur = max(0, value)
            } else if raw.lowercased() == "true" {
                defaults.backgroundBlur = 20
            }
        }
        if let raw = values["window-padding-x"], let value = Float(raw) {
            defaults.windowPaddingX = max(0, value)
        }
        if let raw = values["window-padding-y"], let value = Float(raw) {
            defaults.windowPaddingY = max(0, value)
        }
        if let value = values["theme"], !value.isEmpty {
            defaults.themeName = value
        }
        if let value = values["background"], !value.isEmpty {
            defaults.backgroundHex = normalizeHex(value)
        }
        if let value = values["foreground"], !value.isEmpty {
            defaults.foregroundHex = normalizeHex(value)
        }
        if let value = values["cursor-color"], !value.isEmpty {
            defaults.cursorColorHex = normalizeHex(value)
        }
        if let value = values["selection-background"], !value.isEmpty {
            defaults.selectionBackgroundHex = normalizeHex(value)
        }
        if let value = values["selection-foreground"], !value.isEmpty {
            defaults.selectionForegroundHex = normalizeHex(value)
        }
        if let value = values["bold-color"], !value.isEmpty {
            defaults.boldColorHex = normalizeHex(value)
        }
        if let value = values["cursor-text"], !value.isEmpty {
            defaults.cursorTextHex = normalizeHex(value)
        }
        if let raw = values["minimum-contrast"], let value = Double(raw) {
            defaults.minimumContrast = min(21, max(1, value))
        }
        if let value = values["cursor-style"], ["block", "bar", "underline"].contains(value) {
            defaults.cursorStyle = value
        }
        if let value = values["cursor-style-blink"].flatMap(parseBool) {
            defaults.cursorBlink = value
        }
        if let value = values["copy-on-select"].flatMap(parseBool) {
            defaults.copyOnSelect = value
        }
        return defaults
    }

    private static func normalizeHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return HarnessSettings.normalizedHex(trimmed)
    }

    private static func parsePaletteEntry(_ raw: String) -> (index: Int, hex: String?)? {
        let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let index = Int(parts[0]),
              (0 ..< 16).contains(index)
        else { return nil }
        return (index, normalizeHex(parts[1]))
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }
}

private extension ImportedTerminalConfig {
    func merging(_ newer: ImportedTerminalConfig) -> ImportedTerminalConfig {
        ImportedTerminalConfig(
            fontFamily: newer.fontFamily ?? fontFamily,
            fontSize: newer.fontSize ?? fontSize,
            defaultShell: newer.defaultShell ?? defaultShell,
            backgroundOpacity: newer.backgroundOpacity ?? backgroundOpacity,
            backgroundBlur: newer.backgroundBlur ?? backgroundBlur,
            windowPaddingX: newer.windowPaddingX ?? windowPaddingX,
            windowPaddingY: newer.windowPaddingY ?? windowPaddingY,
            themeName: newer.themeName ?? themeName,
            backgroundHex: newer.backgroundHex ?? backgroundHex,
            foregroundHex: newer.foregroundHex ?? foregroundHex,
            cursorColorHex: newer.cursorColorHex ?? cursorColorHex,
            selectionBackgroundHex: newer.selectionBackgroundHex ?? selectionBackgroundHex,
            selectionForegroundHex: newer.selectionForegroundHex ?? selectionForegroundHex,
            boldColorHex: newer.boldColorHex ?? boldColorHex,
            cursorTextHex: newer.cursorTextHex ?? cursorTextHex,
            minimumContrast: newer.minimumContrast ?? minimumContrast,
            paletteHex: mergePalette(newer.paletteHex, over: paletteHex),
            cursorStyle: newer.cursorStyle ?? cursorStyle,
            cursorBlink: newer.cursorBlink ?? cursorBlink,
            copyOnSelect: newer.copyOnSelect ?? copyOnSelect
        )
    }

    private func mergePalette(_ newer: [String?], over older: [String?]) -> [String?] {
        let normalizedNewer = HarnessSettings.normalizedPalette(newer)
        let normalizedOlder = HarnessSettings.normalizedPalette(older)
        return (0 ..< 16).map { normalizedNewer[$0] ?? normalizedOlder[$0] }
    }
}
