import XCTest
@testable import HarnessCore

final class RecordingExportTests: XCTestCase {
    func testArchiveRecoveryAndExportKeepTimingUTF8AndRedactionsAcrossChunks() throws {
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 27, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("harness-recording-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.hrec")
        let writer = try RecordingArchiveWriter(url: url, protection: protection)
        let secret = "sk-proj-abcdefghijklmnopqrstuvwx"
        let emoji = Data("🎉".utf8)
        try writer.append(.metadata(version: 1, createdAt: .now, surfaceID: UUID().uuidString))
        try writer.append(.resize(timeMs: 0, rows: 24, cols: 80))
        try writer.append(.output(timeMs: 20, data: Data("\u{1b}[31mhello \(secret.prefix(14))".utf8)))
        try writer.append(.output(timeMs: 30, data: Data(secret.dropFirst(14).utf8) + emoji.prefix(2)))
        try writer.append(.resize(timeMs: 40, rows: 30, cols: 100))
        try writer.append(.output(timeMs: 50, data: Data(emoji.dropFirst(2)) + Data("\u{1b}]52;c;unsafe".utf8)))
        try writer.append(.output(timeMs: 60, data: Data("clipboard\u{7} manual-private\u{1b}[0m\n".utf8)))
        try writer.append(.input(timeMs: 70, data: Data("never share input".utf8)))
        try writer.finish()
        let bytes = try Data(contentsOf: url)
        #if os(macOS)
        XCTAssertNil(bytes.range(of: Data("manual-private".utf8))); XCTAssertNil(bytes.range(of: Data(secret.utf8)))
        var corrupt = bytes; corrupt[corrupt.count - 2] ^= 1
        XCTAssertThrowsError(try RecordingArchive.decode(corrupt, protection: protection))
        #endif
        let document = try RecordingArchive.decode(bytes, protection: protection)
        XCTAssertFalse(document.interrupted)
        let partial = try RecordingArchive.decode(Data(bytes.dropLast(8)), protection: protection)
        XCTAssertTrue(partial.interrupted); XCTAssertEqual(partial.events, document.events)
        let review = try AsciicastExport.review(document)
        XCTAssertEqual(review.candidates.count, 1)
        let exported = try AsciicastExport.render(review, additionalLiterals: ["manual-private"])
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains("unsafe")); XCTAssertFalse(text.contains("clipboard")); XCTAssertFalse(text.contains("manual-private")); XCTAssertFalse(text.contains("never share input"))
        XCTAssertTrue(text.contains("🎉")); XCTAssertFalse(text.contains("�"))
        let lines = text.split(separator: "\n")
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]); XCTAssertEqual(header["width"] as? Int, 80)
        let rows = try lines.dropFirst().map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any]) }
        XCTAssertTrue(rows.contains { ($0[0] as? Double) == 0.04 && ($0[1] as? String) == "r" && ($0[2] as? String) == "100x30" })
        XCTAssertTrue(rows.contains { ($0[0] as? Double) == 0.05 && ($0[2] as? String)?.contains("🎉") == true })
        let unavailable = directory.appendingPathComponent("unavailable.hrec")
        XCTAssertThrowsError(try RecordingArchiveWriter(url: unavailable, protection: .unavailable("fixture locked key")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailable.path))
        XCTAssertThrowsError(try RecordingArchiveWriter(url: url, protection: protection))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
