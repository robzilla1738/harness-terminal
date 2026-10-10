import XCTest
@testable import HarnessTerminalEngine

final class ProgramStatusTests: XCTestCase {
    func testPublishedInteroperabilityVectorsAndRepresentativeTUIReplays() throws {
        struct Fixture: Decodable { struct Vector: Decodable { var name: String; var wire_base64: String; var expected_states: [String: String] }; var vectors: [Vector] }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/interop")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("osc-7501-vectors.json")))
        func check(_ data: Data, expected: [String: String], name: String) {
            let complete = scanBook(data)
            var scanner = PtyStreamScanner(), split = ProgramStatusBook()
            let terminal = TerminalEmulator(cols: 80, rows: 24); terminal.isReplaying = true
            for byte in data { let chunk = Data([byte]); for event in scanner.scan(chunk) { _ = split.apply(scan: event) }; terminal.feed(chunk) }
            XCTAssertEqual(complete, split, name); XCTAssertEqual(complete, terminal.programStatus, name)
            XCTAssertEqual(complete.records.mapValues { $0.state.rawValue }, expected, name)
        }
        for vector in fixture.vectors { check(try XCTUnwrap(Data(base64Encoded: vector.wire_base64)), expected: vector.expected_states, name: vector.name) }
        for (name, provider) in [("claude", "claude-code"), ("codex", "codex"), ("cursor", "cursor")] {
            let lines = try String(contentsOf: directory.appendingPathComponent(name + "-tui.cast"), encoding: .utf8).split(separator: "\n")
            var bytes = Data()
            for line in lines.dropFirst() { let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any]); XCTAssertEqual(event[1] as? String, "o"); bytes.append(contentsOf: try XCTUnwrap(event[2] as? String).utf8) }
            check(bytes, expected: ["": "done"], name: name)
            XCTAssertEqual(scanBook(bytes).records[""]?.app, provider)
        }
    }
    private func osc(_ body: String, bel: Bool = false) -> Data {
        var data = Data([0x1B, 0x5D])
        data.append(contentsOf: body.utf8)
        if bel { data.append(0x07) } else { data.append(contentsOf: [0x1B, 0x5C]) }
        return data
    }

    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func scanBook(_ data: Data) -> ProgramStatusBook {
        var scanner = PtyStreamScanner()
        var book = ProgramStatusBook()
        for event in scanner.scan(data) {
            _ = book.apply(scan: event)
        }
        return book
    }

    func testBlockedThenDoneAndLifetimes() {
        let blocked = "7501;state=blocked:kind=permission:app=terraform:msg=\(b64("Apply?"))"
        let done = "7501;state=done:app=terraform:msg=\(b64("Applied"))"
        let working = "7501;state=working:app=brew:msg=\(b64("Installing"))"
        var book = ProgramStatusBook()
        XCTAssertEqual(book.apply(body: String(blocked.dropFirst("7501;".count)), sequenceLength: osc(blocked).count), .applied)
        XCTAssertEqual(book.records[""]?.state, .blocked)
        XCTAssertEqual(book.records[""]?.kind, .permission)
        XCTAssertEqual(book.records[""]?.message, "Apply?")
        book.acknowledgeVisible()
        XCTAssertEqual(book.records[""]?.state, .blocked, "a key does not clear blocked")
        XCTAssertEqual(book.apply(body: String(done.dropFirst("7501;".count)), sequenceLength: osc(done).count), .applied)
        book.acknowledgeVisible()
        XCTAssertNil(book.records[""], "focus plus a key clears done")

        var running = ProgramStatusBook()
        _ = running.apply(body: String(working.dropFirst("7501;".count)), sequenceLength: osc(working).count)
        _ = running.apply(body: String(done.dropFirst("7501;".count)), sequenceLength: osc(done).count)
        running.dropEphemeral()
        XCTAssertEqual(running.records[""]?.state, .done, "done survives process exit and the next prompt")
        _ = running.apply(body: String(working.dropFirst("7501;".count)), sequenceLength: osc(working).count)
        running.dropEphemeral()
        XCTAssertNil(running.records[""], "OSC 133 A and process exit drop working")
    }

    func testLimitsLeaveRecordsUnchanged() {
        var book = ProgramStatusBook()
        _ = book.apply(body: "state=idle:app=brew", sequenceLength: 32)
        let before = book

        XCTAssertEqual(book.apply(body: "state=working", sequenceLength: 4097), .discarded)
        XCTAssertEqual(book.apply(body: "state=nope", sequenceLength: 24), .ignored)
        XCTAssertEqual(book.apply(body: "state=working:title=\(b64("\u{1}bad"))", sequenceLength: 80), .discarded)
        let longKey = String(repeating: "k", count: 17)
        XCTAssertEqual(book.apply(body: "state=working:\(longKey)=1", sequenceLength: 40), .discarded)
        XCTAssertEqual(book, before)

        let term = TerminalEmulator(cols: 40, rows: 8)
        term.feed(osc("7501;state=idle:app=brew"))
        let kept = term.programStatus
        var huge = Data([0x1B, 0x5D])
        huge.append(contentsOf: "7501;state=working:x=".utf8)
        huge.append(contentsOf: String(repeating: "a", count: 4097).utf8)
        huge.append(contentsOf: [0x1B, 0x5C])
        term.feed(huge)
        term.feed(osc("7501;state=pondering"))
        XCTAssertEqual(term.programStatus, kept)
    }

    func testRISClearsAndDECSTRDoesNot() {
        let term = TerminalEmulator(cols: 40, rows: 8)
        term.feed(osc("7501;state=done:app=brew:msg=\(b64("Upgraded"))"))
        term.feed("\u{1b}[?1049h")
        XCTAssertEqual(term.programStatus.records[""]?.state, .done, "the alternate screen keeps records")
        term.feed("\u{1b}[!p")
        XCTAssertEqual(term.programStatus.records[""]?.state, .done, "DECSTR keeps records")
        term.feed("\u{1b}c")
        XCTAssertTrue(term.programStatus.records.isEmpty)
        XCTAssertFalse(term.programStatus.acceptedRealReport)
    }

    func testQueryRepliesWithQuestionMarkOnly() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed(osc("7501;?"))
        XCTAssertEqual(replies, [ProgramStatusRevision.queryReply])
        XCTAssertTrue(term.programStatus.records.isEmpty)
        term.isReplaying = true
        term.feed(osc("7501;?"))
        XCTAssertEqual(replies.count, 1, "replay must not answer the query")
    }

    func testScannerAndEmulatorAgreeOnOneFixture() {
        let fixture = osc("7501;state=blocked:kind=question:app=claude-code:msg=\(b64("Needs you"))")
            + osc("9;4;1;40", bel: true)
            + osc("7501;state=done:app=claude-code:id=task:msg=\(b64("Done"))")
            + osc("133;A", bel: true)
            + osc("9;4;3", bel: true)
        let scanned = scanBook(fixture)
        let term = TerminalEmulator(cols: 80, rows: 24)
        term.feed(fixture)
        XCTAssertEqual(scanned, term.programStatus)
        XCTAssertEqual(term.programStatus.records["task"]?.state, .done)
        XCTAssertNil(term.programStatus.records[""], "133 A dropped the root working/blocked record")
        XCTAssertEqual(term.programStatus.inheritedApp(for: "task"), "claude-code")
        term.feed(osc("9;4;1;5", bel: true))
        XCTAssertEqual(term.programStatus.records["task"]?.state, .done, "9;4 stops mapping after a real report")
    }

    /// `id=build/test` stays one pair. `/` is parent/child for clear and app inheritance.
    /// The scanner, the emulator, and the presenter all read that one fixture.
    func testSlashPathFixtureAgreesAcrossScannerEmulatorAndPresenter() {
        let message = b64("Approve the plan?")
        let fixture = osc("7501;state=idle:app=deploy")
            + osc("7501;state=working:id=build")
            + osc("7501;state=blocked:kind=permission:id=build/test:msg=\(message)")
            + osc("7501;state=done:id=build/other")
        let scanned = scanBook(fixture)
        let term = TerminalEmulator(cols: 80, rows: 24)
        term.feed(fixture)
        XCTAssertEqual(scanned, term.programStatus)
        XCTAssertEqual(scanned.records[""]?.state, .idle)
        XCTAssertEqual(scanned.records[""]?.app, "deploy")
        XCTAssertEqual(scanned.records["build"]?.state, .working)
        XCTAssertNil(scanned.records["build"]?.app)
        XCTAssertEqual(scanned.records["build/test"]?.state, .blocked)
        XCTAssertEqual(scanned.records["build/test"]?.kind, .permission)
        XCTAssertEqual(scanned.records["build/test"]?.message, "Approve the plan?")
        XCTAssertNil(scanned.records["build/test"]?.app)
        XCTAssertEqual(scanned.records["build/other"]?.state, .done)
        XCTAssertEqual(scanned.inheritedApp(for: "build/test"), "deploy")

        let detector = ProgramStatusDetectorFill(app: "codex", silent: true)
        let scannedDecision = present(scanned, detector: detector)
        let emulatorDecision = present(term.programStatus, detector: detector)
        XCTAssertEqual(scannedDecision, emulatorDecision)
        XCTAssertEqual(scannedDecision.mark, .blocked)
        XCTAssertEqual(scannedDecision.kind, .permission)
        XCTAssertEqual(scannedDecision.app, "deploy", "the child inherits the root app, not the detector")
        XCTAssertEqual(scannedDecision.message, "Approve the plan?")
        XCTAssertTrue(scannedDecision.fromRealReport)
        XCTAssertTrue(scannedDecision.joinsWaitingQueue)
        XCTAssertFalse(scannedDecision.showsWorkingDot)
        XCTAssertEqual(scannedDecision.notifications.count, 1)
        XCTAssertEqual(ProgramStatusPresenter.sessionMark([scannedDecision.mark, .working, .done]), .blocked)

        let withParentApp = fixture + osc("7501;state=working:id=build:app=make")
        let parented = scanBook(withParentApp)
        term.feed(osc("7501;state=working:id=build:app=make"))
        XCTAssertEqual(parented, term.programStatus)
        XCTAssertEqual(parented.inheritedApp(for: "build/test"), "make")
        XCTAssertEqual(parented.records[""]?.app, "deploy")
        XCTAssertEqual(present(parented, detector: detector).app, "make")

        let childCleared = withParentApp + osc("7501;state=clear:id=build/test")
        let afterChild = scanBook(childCleared)
        term.feed(osc("7501;state=clear:id=build/test"))
        XCTAssertEqual(afterChild, term.programStatus)
        XCTAssertNil(afterChild.records["build/test"])
        XCTAssertEqual(afterChild.records["build/other"]?.state, .done)
        XCTAssertEqual(afterChild.records["build"]?.app, "make")
        XCTAssertEqual(afterChild.records[""]?.state, .idle)

        let parentCleared = childCleared + osc("7501;state=clear:id=build")
        let afterParent = scanBook(parentCleared)
        term.feed(osc("7501;state=clear:id=build"))
        XCTAssertEqual(afterParent, term.programStatus)
        XCTAssertNil(afterParent.records["build"])
        XCTAssertNil(afterParent.records["build/other"])
        XCTAssertEqual(afterParent.records[""]?.state, .idle)
        XCTAssertEqual(afterParent.records[""]?.app, "deploy")
        XCTAssertEqual(present(afterParent, detector: detector).mark, .none)
        XCTAssertTrue(present(afterParent, detector: detector).fromRealReport)
    }

    private func present(_ book: ProgramStatusBook, detector: ProgramStatusDetectorFill) -> ProgramStatusPresentation {
        ProgramStatusPresenter.decide(
            book: book,
            detector: detector,
            paneName: "build",
            previous: nil,
            now: 10,
            lastNotifiedAt: nil
        )
    }

    func testOSC94MapsUntilTheFirstRealReportThenRISRestoresIt() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed(osc("9;4;1;40", bel: true))
        XCTAssertEqual(term.programStatus.records[""]?.state, .working)
        XCTAssertEqual(term.programStatus.records[""]?.progress, 40)
        XCTAssertFalse(term.programStatus.acceptedRealReport)
        term.feed(osc("7501;state=blocked:kind=auth:app=brew"))
        term.feed(osc("9;4;1;1", bel: true))
        XCTAssertEqual(term.programStatus.records[""]?.state, .blocked)
        XCTAssertNil(term.programStatus.records[""]?.progress)
        term.feed("\u{1b}c")
        term.feed(osc("9;4;3", bel: true))
        XCTAssertEqual(term.programStatus.records[""]?.state, .working)
    }

    func testClearInheritanceAndUnknownKeys() {
        var book = ProgramStatusBook()
        _ = book.apply(body: "state=working:app=deploy:msg=\(b64("Deploying"))", sequenceLength: 80)
        _ = book.apply(body: "state=blocked:kind=permission:id=eu-west:msg=\(b64("Approve?"))", sequenceLength: 80)
        XCTAssertEqual(book.inheritedApp(for: "eu-west"), "deploy")
        _ = book.apply(body: "state=working:ignoredkey=xyz:app=deploy", sequenceLength: 48)
        XCTAssertEqual(book.records[""]?.app, "deploy")
        XCTAssertNil(book.records[""]?.message, "a report replaces its record completely")
        _ = book.apply(body: "state=clear:id=eu-west", sequenceLength: 32)
        XCTAssertNil(book.records["eu-west"])
        XCTAssertNotNil(book.records[""])
        _ = book.apply(body: "state=clear", sequenceLength: 20)
        XCTAssertTrue(book.records.isEmpty)
        XCTAssertTrue(book.acceptedRealReport, "clear is a real report, so 9;4 stays unmapped")
    }

    func testAtLeast64RecordsAndLRUEviction() {
        var book = ProgramStatusBook()
        for index in 0 ..< 70 {
            let result = book.apply(body: "state=idle:id=job\(index)", sequenceLength: 32)
            XCTAssertEqual(result, .applied)
        }
        XCTAssertGreaterThanOrEqual(book.records.count, 64)
        XCTAssertEqual(book.records.count, 70)
        for index in 70 ..< 300 {
            _ = book.apply(body: "state=idle:id=job\(index)", sequenceLength: 32)
        }
        XCTAssertEqual(book.records.count, 256)
        XCTAssertNotNil(book.records["job299"])
        XCTAssertNil(book.records["job0"])
    }

    func testPresenterNotifiesOnceWhenProgressDetectorAndReportAllFire() {
        var book = ProgramStatusBook()
        book.applyOSC94(TerminalProgressReport(state: .indeterminate, value: nil))
        _ = book.apply(body: "state=blocked:kind=permission:app=claude-code:msg=\(b64("Allow the command\u{202E}?"))", sequenceLength: 120)
        let decision = ProgramStatusPresenter.decide(
            book: book,
            detector: ProgramStatusDetectorFill(app: "claude-code", silent: true),
            paneName: "shell",
            previous: nil,
            now: 10,
            lastNotifiedAt: nil
        )
        XCTAssertEqual(decision.notifications.count, 1)
        XCTAssertEqual(decision.mark, .blocked)
        XCTAssertEqual(decision.kind, .permission)
        XCTAssertFalse(decision.message?.contains("\u{202E}") ?? true, "bidi overrides are stripped outside the grid")
        XCTAssertTrue(decision.joinsWaitingQueue)
        XCTAssertFalse(decision.showsWorkingDot)
        XCTAssertTrue(decision.fromRealReport)
        XCTAssertTrue(decision.accessibilityLabel.contains("shell"))
        XCTAssertTrue(decision.accessibilityLabel.contains("blocked"))

        let again = ProgramStatusPresenter.decide(
            book: book,
            detector: ProgramStatusDetectorFill(app: "claude-code", silent: true),
            paneName: "shell",
            previous: decision,
            now: 11,
            lastNotifiedAt: 10
        )
        XCTAssertTrue(again.notifications.isEmpty, "the same pane is not notified twice")
        XCTAssertEqual(ProgramStatusPresenter.sessionMark([.working, .done, .blocked]), .blocked)
    }

    func testModeMirrorTracksCursorKittyAndKeypad() {
        var scanner = PtyStreamScanner()
        var mirror = KeyboardModeMirror()
        let bytes = Data([0x1B, 0x5B, 0x3F, 0x31, 0x68]) // CSI ? 1 h
            + Data([0x1B, 0x3D]) // DECKPAM
            + Data([0x1B, 0x5B, 0x3E, 0x35, 0x75]) // CSI > 5 u
        for event in scanner.scan(bytes) { mirror.apply(event) }
        XCTAssertTrue(mirror.cursorKeysApplication)
        XCTAssertTrue(mirror.keypadApplication)
        XCTAssertEqual(mirror.kittyFlags, 5)
        var off = PtyStreamScanner()
        for event in off.scan(Data([0x1B, 0x5B, 0x3F, 0x31, 0x6C, 0x1B, 0x3E])) {
            mirror.apply(event)
        }
        XCTAssertFalse(mirror.cursorKeysApplication)
        XCTAssertFalse(mirror.keypadApplication)
        let modes = mirror.terminalModes
        XCTAssertEqual(modes.kittyKeyboardFlags, 5)
        XCTAssertFalse(modes.cursorKeysApplication)
    }

    func testTerminfoDefinesPst() throws {
        XCTAssertEqual(ProgramStatusRevision.terminfoSource, "Pst=\\E]7501;%p1%s\\E\\\\")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("term/harness.ti"), encoding: .utf8)
        XCTAssertTrue(source.contains(ProgramStatusRevision.terminfoSource))

        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        let name = "Pst".utf8.map { String(format: "%02x", $0) }.joined()
        term.feed("\u{1b}P+q\(name)\u{1b}\\")
        let value = ProgramStatusRevision.terminfoValue.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(replies, ["\u{1b}P1+r\(name)=\(value)\u{1b}\\"])
    }

    func testEmulatorDropsWorkingOnPromptAndDoneOnKey() {
        let term = TerminalEmulator(cols: 40, rows: 8)
        term.feed(osc("7501;state=working:app=brew"))
        term.feed(osc("133;A", bel: true))
        XCTAssertNil(term.programStatus.records[""])
        term.feed(osc("7501;state=error:app=brew:msg=\(b64("failed"))"))
        term.noteUserKey()
        XCTAssertNil(term.programStatus.records[""])
    }
}
