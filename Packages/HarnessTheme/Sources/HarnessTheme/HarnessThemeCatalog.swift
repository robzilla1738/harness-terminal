import Foundation

/// The native theme catalog.
///
/// Phase 3 ships the hand-curated featured themes with full, accurate 16-color palettes.
/// Community themes live in the bundled `themes.json` resource and merge in here without
/// API changes — `theme(named:)`, `search(_:)`, and `allThemes` are the stable surface.
public enum HarnessThemeCatalog {
    /// The default theme used when none is selected. This muted ANSI-16 baseline keeps
    /// fresh installs from starting with over-saturated primaries.
    public static let defaultThemeName = "Harness Default"

    /// Curated, surfaced-first themes.
    public static let featuredNames = [
        "Harness Default",
        "Catppuccin Mocha",
        "Dracula",
        "Tokyo Night",
        "Nord",
        "One Dark",
        "Gruvbox Dark",
        "Solarized Dark",
        "Monokai",
        "GitHub Dark",
    ]

    /// Look up a theme by exact name (case-insensitive).
    ///
    /// Resolve builtins (the default + every featured theme) first so the common
    /// path — applying the active/default theme at startup — does NOT force the
    /// 256 KB community `themes.json` parse. Builtins already win name conflicts in
    /// `all`, so the result is identical; this only makes the bundle load lazy:
    /// it happens when a non-builtin theme is actually requested (or the full list
    /// is shown in Settings/the palette), never on the launch chrome path.
    public static func theme(named name: String) -> HarnessThemeDefinition? {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lookupName = legacyThemeAliases[lowered] ?? lowered
        if let builtin = builtins.first(where: { $0.name.lowercased() == lookupName }) { return builtin }
        return all.first { $0.name.lowercased() == lookupName }
    }

    /// Fuzzy-ish search: empty query returns all (featured first); otherwise themes whose
    /// name contains the query, case-insensitive.
    public static func search(_ query: String) -> [HarnessThemeDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    /// Every known theme, featured ones first (in `featuredNames` order), then the rest
    /// alphabetically.
    public static var allThemes: [HarnessThemeDefinition] { all }

    // MARK: - Storage

    /// Featured builtins first (in `featuredNames` order), then every bundled theme not
    /// already covered by a builtin, alphabetically. Builtins win on name conflicts so
    /// our curated palettes are authoritative.
    private static let all: [HarnessThemeDefinition] = {
        var seen = Set(builtins.map { $0.name.lowercased() })
        let extras = loadBundledThemes()
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return builtins + extras
    }()

    private static let legacyThemeAliases = [
        "ghostty default": defaultThemeName.lowercased(),
    ]

    /// Load the ported community catalog, embedded as base64-encoded JSON in
    /// `BundledThemesData` (an array of `HarnessThemeDefinition`). The data is compiled
    /// into the binary — there is no SwiftPM resource bundle and no `Bundle.module`, so a
    /// packaging slip can never strand it (a missing `Bundle.module` bundle used to crash
    /// the app at launch). Returns empty if the payload is somehow unreadable — the catalog
    /// then runs on the curated builtins alone, never crashing. Regenerate the payload from
    /// `Resources/themes.json` with `EXPORT_THEMES=1 swift test --filter ThemeCatalogEmbedTests`.
    private static func loadBundledThemes() -> [HarnessThemeDefinition] {
        guard
            let data = Data(base64Encoded: BundledThemesData.base64JSON),
            let themes = try? JSONDecoder().decode([HarnessThemeDefinition].self, from: data)
        else { return [] }
        return themes
    }

    private static let builtins: [HarnessThemeDefinition] = [
        .make(
            "Harness Default",
            bg: "#000000", fg: "#ffffff", cursor: "#ffffff",
            selectionBackground: "#333333",
            palette: [
                "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                "#666666", "#d54e53", "#b9ca4a", "#e7c547",
                "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
            ]
        ),
        .make(
            "Catppuccin Mocha",
            bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc",
            selectionBackground: "#585b70",
            palette: [
                "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
                "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
                "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
            ]
        ),
        .make(
            "Dracula",
            bg: "#282a36", fg: "#f8f8f2", cursor: "#f8f8f2",
            selectionBackground: "#44475a",
            palette: [
                "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
            ]
        ),
        .make(
            "Tokyo Night",
            bg: "#1a1b26", fg: "#c0caf5", cursor: "#c0caf5",
            selectionBackground: "#283457",
            palette: [
                "#15161e", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                "#414868", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
            ]
        ),
        .make(
            "Nord",
            bg: "#2e3440", fg: "#d8dee9", cursor: "#d8dee9",
            selectionBackground: "#434c5e",
            palette: [
                "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
            ]
        ),
        .make(
            "One Dark",
            bg: "#282c34", fg: "#abb2bf", cursor: "#528bff",
            selectionBackground: "#3e4451",
            palette: [
                "#282c34", "#e06c75", "#98c379", "#e5c07b",
                "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                "#5c6370", "#e06c75", "#98c379", "#e5c07b",
                "#61afef", "#c678dd", "#56b6c2", "#ffffff",
            ]
        ),
        .make(
            "Gruvbox Dark",
            bg: "#282828", fg: "#ebdbb2", cursor: "#ebdbb2",
            selectionBackground: "#3c3836",
            palette: [
                "#282828", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#a89984",
                "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
            ]
        ),
        .make(
            "Solarized Dark",
            bg: "#002b36", fg: "#839496", cursor: "#93a1a1",
            selectionBackground: "#073642",
            palette: [
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
            ]
        ),
        .make(
            "Monokai",
            bg: "#272822", fg: "#f8f8f2", cursor: "#f8f8f0",
            selectionBackground: "#49483e",
            palette: [
                "#272822", "#f92672", "#a6e22e", "#f4bf75",
                "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
                "#75715e", "#f92672", "#a6e22e", "#f4bf75",
                "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
            ]
        ),
        .make(
            "GitHub Dark",
            bg: "#0d1117", fg: "#c9d1d9", cursor: "#c9d1d9",
            selectionBackground: "#163356",
            palette: [
                "#484f58", "#ff7b72", "#3fb950", "#d29922",
                "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                "#6e7681", "#ffa198", "#56d364", "#e3b341",
                "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc",
            ]
        ),
    ]
}
