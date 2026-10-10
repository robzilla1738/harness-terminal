import Foundation
import XCTest
@testable import HarnessTheme

final class ITermColorImportTests: XCTestCase {
    func testVariantColorSpaceValidationAndAtomicInstallBackup() throws {
        func color(_ r: Double, _ g: Double, _ b: Double, _ space: String = "sRGB") -> [String: Any] { ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": space] }
        var preset: [String: Any] = ["Background Color": color(0, 0, 0), "Foreground Color": color(1, 1, 1), "Background Color (Light)": color(1, 1, 1), "Foreground Color (Light)": color(0, 0, 0)]
        for index in 0..<16 { preset["Ansi \(index) Color"] = color(Double(index) / 15, 0.25, 0.5) }
        preset["Cursor Color"] = color(1, 0, 0, "P3")
        let data = try PropertyListSerialization.data(fromPropertyList: preset, format: .binary, options: 0)
        let base = try ITermColorImport.parse(data, name: "Imported"), light = try ITermColorImport.parse(data, name: "Imported", variant: .light)
        XCTAssertEqual(base.document.colors.background.hexString, "#000000"); XCTAssertEqual(light.document.colors.background.hexString, "#ffffff")
        XCTAssertTrue(base.warnings.contains { $0.contains("clipped") }); XCTAssertEqual(light.document.colors.palette.count, 16)
        preset["Ansi 0 Color"] = color(.nan, 0, 0)
        XCTAssertThrowsError(try ITermColorImport.parse(PropertyListSerialization.data(fromPropertyList: preset, format: .binary, options: 0), name: "Invalid"))
        preset["Ansi 0 Color"] = color(0, 0, 0, "Calibrated")
        XCTAssertThrowsError(try ITermColorImport.parse(PropertyListSerialization.data(fromPropertyList: preset, format: .xml, options: 0), name: "Invalid"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("himport-theme-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ThemeFileService(), file = try service.install(base.document, into: root)
        _ = try service.install(light.document, into: root)
        XCTAssertEqual(try service.importTheme(from: file), light.document)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".harness-bak-") }
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try service.importTheme(from: XCTUnwrap(backups.first)), base.document)
    }
}
