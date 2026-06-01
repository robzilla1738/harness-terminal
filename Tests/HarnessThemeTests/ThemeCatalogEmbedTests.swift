import Foundation
import XCTest
@testable import HarnessTheme

/// Keeps the compiled-in community theme catalog (`BundledThemesData.base64JSON`) in lockstep
/// with its editable source of truth, `Resources/themes.json`.
///
/// The themes used to ship as a SwiftPM resource bundle loaded via `Bundle.module`, whose
/// trap-on-missing accessor crashed the app at launch whenever the bundle was misplaced. The
/// catalog is now embedded directly in the binary, so there is no resource to strand. This test
/// is both the regenerator (gated) and the drift guard (ungated) that keeps the embed honest.
final class ThemeCatalogEmbedTests: XCTestCase {
    /// `#filePath` is `<repo>/Tests/HarnessThemeTests/ThemeCatalogEmbedTests.swift`; three
    /// parent hops reach the repo root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HarnessThemeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private static var sourceJSON: URL {
        repoRoot.appendingPathComponent("Packages/HarnessTheme/Sources/HarnessTheme/Resources/themes.json")
    }

    private static var embedSwift: URL {
        repoRoot.appendingPathComponent("Packages/HarnessTheme/Sources/HarnessTheme/BundledThemesData.swift")
    }

    /// Builds the exact `BundledThemesData.swift` contents for a given base64 payload. Kept here
    /// so the regenerator and any byte-level expectations share one definition of the format.
    private static func embedFileContents(base64: String) -> String {
        "// Generated from Resources/themes.json by `EXPORT_THEMES=1 swift test --filter ThemeCatalogEmbedTests`.\n"
            + "// Do NOT edit by hand. Base64-encoded JSON of [HarnessThemeDefinition] (the community theme catalog).\n"
            + "enum BundledThemesData {\n"
            + "    static let base64JSON = \"\(base64)\"\n"
            + "}\n"
    }

    /// Regenerator — gated. Reads the canonical `themes.json`, validates it decodes, and rewrites
    /// `BundledThemesData.swift`. Run after editing themes:
    ///   `EXPORT_THEMES=1 swift test --filter ThemeCatalogEmbedTests`
    func testRegenerateEmbeddedThemes() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["EXPORT_THEMES"] == "1",
            "Set EXPORT_THEMES=1 to regenerate BundledThemesData.swift from themes.json."
        )
        let json = try Data(contentsOf: Self.sourceJSON)
        // Fail loudly rather than embed a payload that won't decode at runtime.
        _ = try JSONDecoder().decode([HarnessThemeDefinition].self, from: json)
        let contents = Self.embedFileContents(base64: json.base64EncodedString())
        try Data(contents.utf8).write(to: Self.embedSwift, options: .atomic)
    }

    /// Drift guard — ungated, always runs. Fails the moment the committed embed diverges from
    /// the source `themes.json`, so a theme edit can't silently ship stale.
    func testEmbeddedThemesMatchSource() throws {
        let sourceData = try Data(contentsOf: Self.sourceJSON)
        let embeddedData = try XCTUnwrap(
            Data(base64Encoded: BundledThemesData.base64JSON),
            "BundledThemesData.base64JSON is not valid base64."
        )
        let fromSource = try JSONDecoder().decode([HarnessThemeDefinition].self, from: sourceData)
        let fromEmbedded = try JSONDecoder().decode([HarnessThemeDefinition].self, from: embeddedData)
        XCTAssertEqual(
            fromSource, fromEmbedded,
            "BundledThemesData.swift is stale. Run `EXPORT_THEMES=1 swift test --filter ThemeCatalogEmbedTests` and commit the result."
        )
    }
}
