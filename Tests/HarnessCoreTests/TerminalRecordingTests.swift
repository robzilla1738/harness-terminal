import XCTest
@testable import HarnessCore

final class TerminalRecordingTests: XCTestCase {
    private let surfaceID = "11111111-1111-1111-1111-111111111111"
    private let createdAt = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    // MARK: Encoding

    func testEncodeMetadataEvent() throws {
        let line = try TerminalRecordingCodec.encodeLine(
            .metadata(version: 1, createdAt: createdAt, surfaceID: surfaceID)
        )
        XCTAssertFalse(line.contains("\n"), "an event must encode to a single line")
        XCTAssertTrue(line.contains("\"type\":\"metadata\""))
        XCTAssertTrue(line.contains("\"version\":1"))
        XCTAssertTrue(line.contains("\"surfaceID\":\"\(surfaceID)\""))
        XCTAssertTrue(line.contains("\"createdAt\":\"2023-11-14T22:13:20Z\""), "dates are ISO-8601: \(line)")
        // Sorted keys: createdAt < surfaceID < type < version.
        XCTAssertLessThan(line.range(of: "createdAt")!.lowerBound, line.range(of: "surfaceID")!.lowerBound)
        XCTAssertLessThan(line.range(of: "surfaceID")!.lowerBound, line.range(of: "\"type\"")!.lowerBound)
    }

    func testEncodeOutputEvent() throws {
        let bytes = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x00, 0xFF]) // ESC [ 3 1 m NUL 0xFF
        let line = try TerminalRecordingCodec.encodeLine(.output(timeMs: 12, data: bytes))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("\"type\":\"output\""))
        XCTAssertTrue(line.contains("\"timeMs\":12"))
        XCTAssertTrue(line.contains("\"dataBase64\":\"\(bytes.base64EncodedString())\""))
    }

    // MARK: Decoding

    func testDecodeAllEventTypes() throws {
        let outputBytes = Data([1, 2, 3, 250])
        let inputBytes = Data("ls\r".utf8)
        let text = """
        {"createdAt":"2023-11-14T22:13:20Z","surfaceID":"\(surfaceID)","type":"metadata","version":1}
        {"cols":80,"rows":24,"timeMs":0,"type":"resize"}
        {"dataBase64":"\(outputBytes.base64EncodedString())","timeMs":12,"type":"output"}
        {"dataBase64":"\(inputBytes.base64EncodedString())","timeMs":18,"type":"input"}
        """
        let (events, skipped) = TerminalRecordingCodec.decode(text)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .metadata(version: 1, createdAt: createdAt, surfaceID: surfaceID))
        XCTAssertEqual(events[1], .resize(timeMs: 0, rows: 24, cols: 80))
        XCTAssertEqual(events[2], .output(timeMs: 12, data: outputBytes))
        XCTAssertEqual(events[3], .input(timeMs: 18, data: inputBytes))
    }

    func testEncodeDecodeRoundTripIsStable() throws {
        let events: [RecordingEvent] = [
            .metadata(version: 1, createdAt: createdAt, surfaceID: surfaceID),
            .resize(timeMs: 0, rows: 40, cols: 120),
            .output(timeMs: 5, data: Data([0, 1, 2, 254, 255])),
            .input(timeMs: 9, data: Data("hi\u{1b}".utf8)),
        ]
        for event in events {
            let line = try TerminalRecordingCodec.encodeLine(event)
            let decoded = try XCTUnwrap(TerminalRecordingCodec.decodeLine(line))
            XCTAssertEqual(decoded, event)
            XCTAssertEqual(try TerminalRecordingCodec.encodeLine(decoded), line, "re-encode is byte-stable")
        }
    }

    func testDecodeSkipsBlankAndMalformedTrailingLines() {
        let good = Data([7, 8, 9])
        let text = """
        {"dataBase64":"\(good.base64EncodedString())","timeMs":1,"type":"output"}

        {"dataBase64":"\(good.base64EncodedString())","timeMs":2,"type":"output"}
        {"type":"output","timeMs":3,"dataBase
        """ // last line is a truncated (interrupted) write
        let (events, skipped) = TerminalRecordingCodec.decode(text)
        XCTAssertEqual(events.count, 2, "blank line skipped silently; valid lines kept")
        XCTAssertEqual(skipped, 1, "the truncated final line is reported, not fatal")
    }

    func testDecodeLineReturnsNilForBlank() throws {
        XCTAssertNil(try TerminalRecordingCodec.decodeLine("   "))
        XCTAssertNil(try TerminalRecordingCodec.decodeLine(""))
    }

    // MARK: Replay scheduling

    func testReplayOrdering() {
        let a = Data("A".utf8), b = Data("B".utf8), c = Data("C".utf8)
        let events: [RecordingEvent] = [
            .metadata(version: 1, createdAt: createdAt, surfaceID: surfaceID),
            .output(timeMs: 0, data: a),
            .resize(timeMs: 5, rows: 24, cols: 80),
            .output(timeMs: 10, data: b),
            .input(timeMs: 12, data: Data("x".utf8)),
            .output(timeMs: 20, data: c),
        ]
        let steps = TerminalReplay.steps(from: events, honorTiming: false)
        XCTAssertEqual(steps.map(\.data), [a, b, c], "only output events emit, in file order")
        let joined = steps.reduce(Data()) { $0 + $1.data }
        XCTAssertEqual(joined, Data("ABC".utf8))
    }
    func testReplayMalformedExtremeTimestampsDoNotOverflow() {
        let events: [RecordingEvent] = [.input(timeMs: Int.min, data: Data()), .resize(timeMs: Int.max, rows: 24, cols: 80), .output(timeMs: Int.max, data: Data("fixture".utf8))]
        XCTAssertEqual(TerminalReplay.steps(from: events).first?.delayMs, Int.max)
        XCTAssertEqual(TerminalReplay.steps(from: events, honorTiming: false).first?.delayMs, 0)
    }

    func testNoTimingZeroesAllDelays() {
        let events: [RecordingEvent] = [
            .output(timeMs: 0, data: Data([1])),
            .output(timeMs: 100, data: Data([2])),
            .output(timeMs: 350, data: Data([3])),
        ]
        let steps = TerminalReplay.steps(from: events, honorTiming: false)
        XCTAssertEqual(steps.map(\.delayMs), [0, 0, 0])
    }

    func testTimingUsesDeltasAndFoldsSkippedEvents() {
        let events: [RecordingEvent] = [
            .output(timeMs: 0, data: Data([1])),       // delay 0
            .resize(timeMs: 30, rows: 24, cols: 80),   // advances clock, emits nothing
            .output(timeMs: 50, data: Data([2])),      // delay 50 (folds the resize gap)
            .output(timeMs: 90, data: Data([3])),      // delay 40
        ]
        let steps = TerminalReplay.steps(from: events, honorTiming: true, speed: 1)
        XCTAssertEqual(steps.map(\.delayMs), [0, 50, 40])
    }

    func testSpeedScalesDelays() {
        let events: [RecordingEvent] = [
            .output(timeMs: 0, data: Data([1])),
            .output(timeMs: 100, data: Data([2])),
            .output(timeMs: 300, data: Data([3])),
        ]
        let double = TerminalReplay.steps(from: events, honorTiming: true, speed: 2)
        XCTAssertEqual(double.map(\.delayMs), [0, 50, 100], "speed 2 halves the delays")
        let half = TerminalReplay.steps(from: events, honorTiming: true, speed: 0.5)
        XCTAssertEqual(half.map(\.delayMs), [0, 200, 400], "speed 0.5 doubles the delays")
    }

    func testNonPositiveSpeedIsInstant() {
        let events: [RecordingEvent] = [
            .output(timeMs: 0, data: Data([1])),
            .output(timeMs: 100, data: Data([2])),
        ]
        XCTAssertEqual(TerminalReplay.steps(from: events, honorTiming: true, speed: 0).map(\.delayMs), [0, 0])
    }

    func testExtremeSpeedDoesNotCrashOnIntConversion() {
        let events: [RecordingEvent] = [
            .output(timeMs: 0, data: Data([1])),
            .output(timeMs: 1_000, data: Data([2])),
        ]
        // A near-zero positive speed would overflow `Int(Double/speed)` without the guard.
        let slow = TerminalReplay.steps(from: events, honorTiming: true, speed: 1e-300)
        XCTAssertEqual(slow.count, 2)
        XCTAssertEqual(slow[1].delayMs, Int.max, "overflowing delay clamps to Int.max, no trap")
        // A huge speed collapses to instant without underflow issues.
        let fast = TerminalReplay.steps(from: events, honorTiming: true, speed: 1e300)
        XCTAssertEqual(fast.map(\.delayMs), [0, 0])
    }
}
