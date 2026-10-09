import XCTest
@testable import HarnessTerminalEngine

final class TerminalCheckpointTests: XCTestCase {
    func testContinuationAtEveryByteBoundary() throws {
        let text = "A界e\u{301}👩🏽‍💻\u{1b}[38:2::12:34:56mZ\u{1b}[0m\u{1b}]8;id=link;https://example.com\u{1b}\\URL\u{1b}]8;;\u{1b}\\\u{1b})0\u{e}qx\u{f}\u{1b}[?1h\u{1b}[?2004h\u{1b}[>3u\u{1b}7\u{1b}[2;3H\u{1b}[?1049hALT\u{1b}[?1049l\u{1b}8!"
        let bytes = Array(text.utf8)
        let reference = TerminalEmulator(cols: 40, rows: 6)
        reference.feed(Data(bytes))
        for boundary in 0...bytes.count {
            let source = TerminalEmulator(cols: 40, rows: 6)
            source.feed(Data(bytes.prefix(boundary)))
            let checkpoint = try source.checkpoint()
            let restored = TerminalEmulator(cols: 1, rows: 1)
            try restored.restore(checkpoint)
            restored.feed(Data(bytes.dropFirst(boundary)))
            XCTAssertEqual(restored.readGrid(), reference.readGrid(), "Continuation boundary \(boundary)")
            XCTAssertEqual(restored.modes, reference.modes, "Mode boundary \(boundary)")
        }
    }

    func testRestoreIsSilentAndClientOwnsFilesystemAccess() throws {
        let source = TerminalEmulator(cols: 20, rows: 4)
        source.feed("\u{7}\u{1b}]52;c;aGVsbG8=\u{7}\u{1b}]9;hello\u{7}\u{1b}]2;title\u{7}")
        let restored = TerminalEmulator(cols: 20, rows: 4)
        restored.readsGraphicsFiles = false
        var effects = 0
        restored.onResponse = { _ in effects += 1 }
        restored.onSetClipboard = { _ in effects += 1 }
        restored.onBell = { effects += 1 }
        restored.onNotification = { _, _ in effects += 1 }
        restored.onTitleChange = { _ in effects += 1 }
        try restored.restore(source.checkpoint())
        XCTAssertEqual(effects, 0)
        XCTAssertFalse(restored.readsGraphicsFiles)
        XCTAssertEqual(restored.currentTitle, "title")
        restored.feed("\u{7}")
        XCTAssertEqual(effects, 1)
    }

    func testPartialClipboardSequenceCompletesExactlyOnceAfterRestore() throws {
        let source = TerminalEmulator(cols: 20, rows: 4)
        source.feed("\u{1b}]52;c;aGVs")
        let restored = TerminalEmulator(cols: 20, rows: 4)
        var clipboard: [String] = []
        restored.onSetClipboard = { clipboard.append($0) }
        try restored.restore(source.checkpoint())
        XCTAssertTrue(clipboard.isEmpty)
        restored.feed("bG8=\u{1b}\\")
        XCTAssertEqual(clipboard, ["hello"])
    }

    func testCustomTabsScrollMarginsAndPenSurvive() throws {
        let source = TerminalEmulator(cols: 20, rows: 5)
        source.feed("\u{1b}[3g\u{1b}[1;5H\u{1b}H\u{1b}[2;4r\u{1b}[?6h\u{1b}[4h\u{1b}[1;31m\u{1b}7")
        let restored = TerminalEmulator(cols: 20, rows: 5)
        try restored.restore(source.checkpoint())
        let continuation = "\u{1b}[2;2Habc\u{1b}8\tQ\r\nZ"
        source.feed(continuation); restored.feed(continuation)
        XCTAssertEqual(restored.readGrid(), source.readGrid())
    }

    func testBothScreensSurviveWithOldHistoryPagedSeparately() throws {
        let source = TerminalEmulator(cols: 20, rows: 3)
        source.feed("one\r\ntwo\r\nthree\r\nfour\u{1b}[?1049hEDITOR")
        XCTAssertEqual(source.historyCount, 0) // alternate buffer
        let restored = TerminalEmulator(cols: 20, rows: 3)
        try restored.restore(source.checkpoint())
        XCTAssertEqual(restored.readGrid(), source.readGrid())
        source.feed("\u{1b}[?1049l!"); restored.feed("\u{1b}[?1049l!")
        XCTAssertEqual(restored.readGrid(), source.readGrid())
        XCTAssertGreaterThan(source.historyCount, 0)
        XCTAssertEqual(restored.historyCount, 0)
    }

    func testImagesAndPendingKittyChunksSurviveAndIDsRemainUnique() throws {
        let source = TerminalEmulator(cols: 20, rows: 5)
        source.readsGraphicsFiles = false
        source.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=42,m=1;/w\u{1b}\\")
        let restored = TerminalEmulator(cols: 20, rows: 5)
        restored.readsGraphicsFiles = false
        try restored.restore(source.checkpoint())
        let suffix = "\u{1b}_Gm=0;AA/w==\u{1b}\\"
        source.feed(suffix); restored.feed(suffix)
        let original = source.readGrid().images
        let continued = restored.readGrid().images
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(source.image(for: original[0].id), restored.image(for: continued[0].id))
        let next = TerminalEmulator(cols: 20, rows: 5)
        try next.restore(restored.checkpoint())
        let before = next.readGrid().images
        XCTAssertEqual(before.count, 1)
        XCTAssertNotEqual(before[0].id, continued[0].id)
        XCTAssertEqual(next.image(for: before[0].id), restored.image(for: continued[0].id))
        next.feed("\u{1b}_Ga=T,f=32,s=1,v=1,i=43;AAD//w==\u{1b}\\")
        let after = next.readGrid().images
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(Set(after.map(\.id)).count, 2)
    }

    func testWireRoundTripAndInvalidCheckpointLeaveExistingStateIntact() throws {
        let source = HarnessGridTerminal(cols: 10, rows: 3)!
        source.feed("hello")
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let wire = try encoder.encode(source.checkpoint())
        let checkpoint = try PropertyListDecoder().decode(TerminalCheckpoint.self, from: wire)
        let restored = HarnessGridTerminal(cols: 10, rows: 3)!
        try restored.restore(checkpoint)
        XCTAssertEqual(restored.readGrid(), source.readGrid())
        let initial = restored.readGrid()
        let invalid = try TerminalCheckpoint(payload: Data("invalid".utf8))
        XCTAssertThrowsError(try restored.restore(invalid))
        XCTAssertEqual(restored.readGrid(), initial)
        XCTAssertThrowsError(try TerminalCheckpoint(version: 99, payload: Data()))
        XCTAssertThrowsError(try TerminalCheckpoint(payload: Data(count: TerminalCheckpoint.maxPayloadBytes + 1)))
    }

    func testPackedCellsRejectInvalidAttributeTags() throws {
        var data = CheckpointCells.encode([TerminalGridCell(codepoint: 65)])
        data[24] = 0xff; data[25] = 0xff
        XCTAssertThrowsError(try CheckpointCells.decode(data))
    }
}
