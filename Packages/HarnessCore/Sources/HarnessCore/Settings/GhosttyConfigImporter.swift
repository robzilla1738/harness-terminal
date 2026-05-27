import Foundation

/// Snapshot of the bits of the user's Ghostty config we mirror as defaults.
public struct GhosttyImportedDefaults: Sendable, Equatable {
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

    public var signature: String {
        var parts: [String] = []
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
        cursorColorHex: String? = nil
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
    }
}

/// Reads `~/.config/ghostty/config` (or the macOS app-support fallback) and pulls
/// values that map cleanly to Harness — font, opacity, blur, padding, theme/colors.
public enum GhosttyConfigImporter {
    public static let candidatePaths: [String] = {
        let home = NSString(string: "~").expandingTildeInPath
        return [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
        ]
    }()

    /// Imported defaults for the current user. `nil` when no config was found.
    public static func load() -> GhosttyImportedDefaults? {
        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            return parse(data)
        }
        return nil
    }

    static func parse(_ text: String) -> GhosttyImportedDefaults {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // NOTE: do NOT strip `#…` as a trailing comment — Ghostty config
            // values like `background = #000000` legitimately start with `#`.
            // Real Ghostty only treats `#` as a comment when it's the first
            // non-whitespace character on the line, which we already handle
            // above.
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = String(value)
        }

        var defaults = GhosttyImportedDefaults()
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
        return defaults
    }

    private static func normalizeHex(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return trimmed }
        return "#" + trimmed
    }
}
