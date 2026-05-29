import Foundation
import XCTest
@testable import HarnessTheme

final class ThemeFileServiceTests: XCTestCase {
    private var tempDir: URL!
    private let service = ThemeFileService()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-theme-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleDocument(name: String = "Dracula") -> ThemeDocument {
        ThemeDocument(definition: HarnessThemeCatalog.theme(named: name)!)
    }

    func testExportThenImportRoundTrips() throws {
        let doc = sampleDocument()
        let url = tempDir.appendingPathComponent("dracula.harnesstheme")
        try service.export(doc, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let restored = try service.importTheme(from: url)
        XCTAssertEqual(restored, doc)
    }

    func testInstallUsesSanitizedName() throws {
        let doc = sampleDocument(name: "Tokyo Night")
        let url = try service.install(doc, into: tempDir)
        XCTAssertEqual(url.lastPathComponent, "Tokyo Night.harnesstheme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testInstalledThemesListsValidFilesOnly() throws {
        try service.install(sampleDocument(name: "Nord"), into: tempDir)
        try service.install(sampleDocument(name: "Monokai"), into: tempDir)
        // A bogus file with the right extension must be skipped, not crash the scan.
        try Data("not a theme".utf8)
            .write(to: tempDir.appendingPathComponent("broken.harnesstheme"))
        // A non-theme file must be ignored entirely.
        try Data("noise".utf8).write(to: tempDir.appendingPathComponent("readme.txt"))

        let themes = try service.installedThemes(in: tempDir)
        XCTAssertEqual(themes.count, 2)
        XCTAssertEqual(Set(themes.map(\.name)), ["Nord", "Monokai"])
    }

    func testInstalledThemesMissingDirectoryReturnsEmpty() throws {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertEqual(try service.installedThemes(in: missing).count, 0)
    }

    func testFileNameSanitization() {
        XCTAssertEqual(ThemeFileService.fileName(for: "Solarized Dark"), "Solarized Dark.harnesstheme")
        XCTAssertEqual(ThemeFileService.fileName(for: "a/b:c"), "a-b-c.harnesstheme")
        XCTAssertEqual(ThemeFileService.fileName(for: "   "), "theme.harnesstheme")
    }

    func testImportMalformedThrows() throws {
        let url = tempDir.appendingPathComponent("bad.harnesstheme")
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try service.importTheme(from: url))
    }
}
