import Foundation
import Testing
@testable import HarnessTerminalEngine

struct PortableImageDecoderTests {
    // Generated in-house: two RGBA pixels and a uniform 8×8 JPEG, no fixture licensing.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR4nGP4z8DQwMDw/z8ADX4DfuoeFyEAAAAASUVORK5CYII=")!
    private let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAASABIAAD/4QBARXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAACKADAAQAAAABAAAACAAAAAD/wAARCAAIAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9sAQwACAgICAgIDAgIDBQMDAwUGBQUFBQYIBgYGBgYICggICAgICAoKCgoKCgoKDAwMDAwMDg4ODg4PDw8PDw8PDw8P/9sAQwECAgIEBAQHBAQHEAsJCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/90ABAAB/9oADAMBAAIRAxEAPwD9IKKKKAP/2Q==")!

    @Test func pngAndJPEGDecodeWithBoundedPremultipliedPixels() throws {
        let image = try #require(ImageDecoder.decode(png))
        #expect(image.pixelWidth == 2 && image.pixelHeight == 1)
        #expect(image.rgba == [128, 0, 0, 128, 0, 0, 255, 255])
        let photo = try #require(ImageDecoder.decode(jpeg))
        #expect(photo.pixelWidth == 8 && photo.pixelHeight == 8)
        #expect(abs(Int(photo.rgba[0]) - 200) <= 2)
        #expect(photo.rgba[3] == 255)
    }

    @Test func malformedAndOversizedImagesAreRejected() {
        #expect(ImageDecoder.decode(Data(png.prefix(20))) == nil)
        #expect(ImageDecoder.decode(Data(jpeg.prefix(20))) == nil)
        #expect(ImageDecoder.decode(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgABhqAAAYagCAYAAACoUgvIAAAACUlEQVR4nGMAAAABAAFe/335AAAAAElFTkSuQmCC")!) == nil)
    }

    @Test func encodedKittyImageSurvivesCheckpoint() throws {
        let original = TerminalEmulator(cols: 80, rows: 24)
        original.feed(Data("\u{1B}_Ga=T,f=100,i=7;\(png.base64EncodedString())\u{1B}\\".utf8))
        let placement = try #require(original.readGrid().images.first)
        let image = try #require(original.image(for: placement.id))
        let restored = TerminalEmulator(cols: 80, rows: 24)
        try restored.restore(original.checkpoint())
        let restoredPlacement = try #require(restored.readGrid().images.first)
        #expect(restored.image(for: restoredPlacement.id) == image)
    }
}
