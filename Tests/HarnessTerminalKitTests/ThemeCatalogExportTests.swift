import Foundation
import GhosttyTheme
import HarnessTheme
import XCTest

/// One-off porter: extracts the libghostty fork's full theme catalog into our native
/// `themes.json` resource, in `HarnessThemeDefinition` JSON form. This is how we take
/// ownership of the ~400 community theme *values* (colors only — no Ghostty code) so the
/// fork can be deleted in Phase 8 without losing the catalog.
///
/// It is skipped during normal test runs and only writes when explicitly requested:
///
///     EXPORT_THEMES=1 swift test --filter ThemeCatalogExportTests
///
/// After running, rebuild and commit the regenerated
/// `Packages/HarnessTheme/Sources/HarnessTheme/Resources/themes.json`.
final class ThemeCatalogExportTests: XCTestCase {
    func testExportGhosttyCatalogToThemesJSON() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["EXPORT_THEMES"] == "1",
            "Set EXPORT_THEMES=1 to regenerate themes.json from the libghostty catalog."
        )

        var exported: [HarnessThemeDefinition] = []
        var skipped: [String] = []

        for theme in GhosttyThemeCatalog.search("") {
            guard
                let background = RGBColor(hex: theme.background),
                let foreground = RGBColor(hex: theme.foreground)
            else {
                skipped.append(theme.name)
                continue
            }
            // Require a complete 16-color palette; skip otherwise so every exported theme
            // satisfies HarnessThemeDefinition's invariant.
            var palette: [RGBColor] = []
            for i in 0 ..< 16 {
                guard
                    i < theme.palette.count,
                    let hex = theme.palette[i],
                    let color = RGBColor(hex: hex)
                else { break }
                palette.append(color)
            }
            guard palette.count == 16 else {
                skipped.append(theme.name)
                continue
            }

            exported.append(HarnessThemeDefinition(
                name: theme.name,
                background: background,
                foreground: foreground,
                cursor: theme.cursorColor.flatMap { RGBColor(hex: $0) },
                cursorText: theme.cursorText.flatMap { RGBColor(hex: $0) },
                selectionBackground: theme.selectionBackground.flatMap { RGBColor(hex: $0) },
                selectionForeground: theme.selectionForeground.flatMap { RGBColor(hex: $0) },
                bold: nil,
                palette: palette
            ))
        }

        exported.sort { $0.name.lowercased() < $1.name.lowercased() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(exported)

        // #filePath = …/Tests/HarnessTerminalKitTests/ThemeCatalogExportTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HarnessTerminalKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let destination = repoRoot.appendingPathComponent(
            "Packages/HarnessTheme/Sources/HarnessTheme/Resources/themes.json"
        )
        try data.write(to: destination, options: .atomic)

        print("Exported \(exported.count) themes to \(destination.path)")
        if !skipped.isEmpty {
            print("Skipped \(skipped.count) themes lacking bg/fg or a full 16-color palette: \(skipped.joined(separator: ", "))")
        }
        XCTAssertGreaterThan(exported.count, 100, "expected the fork's full catalog")
    }
}
