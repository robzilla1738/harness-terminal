import AppKit
import XCTest
import HarnessTerminalEngine
@testable import HarnessTerminalKit

final class HarnessTerminalSurfaceDragDropTests: XCTestCase {
    @MainActor
    func testDroppedFileURLsAcceptFoldersAndImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessTerminalSurfaceDragDropTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Folder With Spaces", isDirectory: true)
        let image = root.appendingPathComponent("image file.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HarnessDragDrop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([folder as NSURL, image as NSURL]))

        let urls = HarnessTerminalSurfaceView.droppedFileURLs(from: pasteboard)

        XCTAssertEqual(urls.map(\.path), [folder.path, image.path])
    }

    @MainActor
    func testDroppedFileURLsAcceptLegacyFinderFilenames() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HarnessDragDropLegacy-\(UUID().uuidString)"))
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.clearContents()
        pasteboard.declareTypes([filenamesType], owner: nil)
        pasteboard.setPropertyList(["/tmp/Harness Folder", "/tmp/Harness Folder"], forType: filenamesType)

        let urls = HarnessTerminalSurfaceView.droppedFileURLs(from: pasteboard)

        XCTAssertEqual(urls.map(\.path), ["/tmp/Harness Folder"])
    }

    @MainActor
    func testDroppedPathTextQuotesShellUnsafePaths() {
        let urls = [
            URL(fileURLWithPath: "/tmp/plain-file.png"),
            URL(fileURLWithPath: "/tmp/My Folder/it's final.png"),
        ]

        XCTAssertEqual(
            HarnessTerminalSurfaceView.droppedPathText(for: urls),
            "/tmp/plain-file.png '/tmp/My Folder/it'\\''s final.png'"
        )
    }

    // MARK: - Image paste (screenshot on the clipboard)

    @MainActor
    func testPasteImageWritesDecodablePNGAndReturnsPath() throws {
        // A real, decodable PNG on the clipboard — exactly what a screenshot (⌘⇧4) produces.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HarnessPasteImage-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        let path = try XCTUnwrap(HarnessTerminalSurfaceView.writePastedImage(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(path.hasSuffix(".png"))
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNotNil(ImageDecoder.decode(written), "the written file should be a decodable image")
    }

    @MainActor
    func testPasteImageReturnsNilForNonImageClipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HarnessPasteNoImage-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertNil(HarnessTerminalSurfaceView.writePastedImage(from: pasteboard))
    }
}
