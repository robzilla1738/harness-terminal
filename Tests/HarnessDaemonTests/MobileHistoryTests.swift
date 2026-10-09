import Foundation
import XCTest
import HarnessCore
import HarnessTerminalEngine
import HarnessRemoteProtocol
@testable import HarnessDaemonCore

final class MobileHistoryTests: XCTestCase {
    func testSilentPaneCheckpointCanAttachBeforeFirstOutputAndAfterParking() throws {
        let pty = try RealPty(id: UUID().uuidString, cwd: NSTemporaryDirectory(), shell: "/bin/cat", rows: 24, cols: 80, scrollbackBytes: 64 * 1024)
        defer { pty.close() }
        for parked in [false, true] {
            if parked { pty.parkIfIdle(now: Date().addingTimeInterval(120)) }
            let history = pty.attachHistory(history: false, fromSequence: nil, screenOnResync: true, includeCheckpoint: true)
            let frame = try XCTUnwrap(history.screen)
            XCTAssertEqual(history.endSequence, 1)
            XCTAssertEqual(frame.sequence, history.endSequence)
            let checkpoint = try PropertyListDecoder().decode(TerminalCheckpoint.self, from: XCTUnwrap(frame.checkpoint))
            let terminal = TerminalEmulator(cols: 80, rows: 24)
            try terminal.restore(checkpoint)
            terminal.feed("first output")
            XCTAssertTrue(terminal.captureLines(joinWrapped: false).joined().contains("first output"))
        }
    }

    func testOpenedSearchMatchUsesValidatedImmutableRowsAndRejectsRolledOutput() throws {
        let terminal = TerminalEmulator(cols: 20, rows: 3)
        terminal.feed("MATCH\r\nnext")
        func capture() -> MobileHistorySnapshot {
            let text = terminal.textSnapshot()
            return MobileHistorySnapshot(text: text, hyperlinks: [:], cellCount: text.lineCount * 20)
        }
        let match = OutputSearchMatch(workspaceID: UUID(), sessionID: UUID(), sessionName: "session",
            tabID: UUID(), tabTitle: "tab", paneID: UUID(), surfaceID: UUID(), line: 0, text: "MATCH")
        let store = MobileHistoryStore()
        let immutable = capture()
        guard case let .text(json) = store.matchedPage(match, epoch: "epoch", load: { immutable }) else { return XCTFail("Expected matched page") }
        let page = try JSONDecoder().decode(RemoteHistoryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.targetRow, 0)
        XCTAssertTrue(page.rows[0].cells.map(\.text).joined().contains("MATCH"))
        // Clear the retained history and replace this row, like a bounded scrollback roll.
        terminal.feed("\u{1b}[3J\u{1b}[2J\u{1b}[HREPLACED\r\n")
        if case .error = store.matchedPage(match, epoch: "epoch", load: { capture() }) { } else { XCTFail("Stale match accepted") }
        guard case let .text(oldJSON) = store.page(surfaceID: match.surfaceID.uuidString, token: page.token,
            before: nil, count: 3, epoch: "epoch", load: { capture() }) else { return XCTFail("Expected retained validated rows") }
        let old = try JSONDecoder().decode(RemoteHistoryPage.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(page.rows, old.rows)
    }

    func testCheckpointBoundaryAndParserContinuationSurvivePark() throws {
        let pty = try RealPty(id: UUID().uuidString, cwd: NSTemporaryDirectory(), shell: "/bin/cat", rows: 24, cols: 80, scrollbackBytes: 64 * 1024)
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("before\r\n\u{1b}[31".utf8))
        let expectedEnd = UInt64(1 + Data("before\r\n\u{1b}[31".utf8).count)
        let deadline = Date().addingTimeInterval(2)
        while pty.ringEnd < expectedEnd, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        pty.parkIfIdle(now: Date().addingTimeInterval(120))
        let history = pty.attachHistory(history: false, fromSequence: nil, screenOnResync: true, includeCheckpoint: true)
        let frame = try XCTUnwrap(history.screen)
        XCTAssertEqual(frame.sequence, history.endSequence)
        let checkpoint = try PropertyListDecoder().decode(TerminalCheckpoint.self, from: XCTUnwrap(frame.checkpoint))
        let terminal = TerminalEmulator(cols: 80, rows: 24)
        try terminal.restore(checkpoint)
        terminal.feed("mAFTER")
        let grid = terminal.readGrid()
        let colored = try XCTUnwrap(grid.cells.first { $0.codepoint == UInt32(UnicodeScalar("A").value) })
        XCTAssertEqual(colored.foreground, .palette(1))
        XCTAssertTrue(terminal.captureLines(joinWrapped: false).joined().contains("AFTER"))
        XCTAssertTrue(history.chunks.isEmpty)
    }

    func testHistoryTokenKeepsOldRowsAsOutputContinuesAndRejectsWrongSurface() throws {
        let pty = try RealPty(id: UUID().uuidString, cwd: NSTemporaryDirectory(), shell: "/bin/cat", rows: 24, cols: 80, scrollbackBytes: 64 * 1024)
        defer { pty.close() }
        pty.injectSyntheticOutput(Data("OLD\r\n".utf8))
        let deadline = Date().addingTimeInterval(2)
        while pty.ringEnd < 6, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let store = MobileHistoryStore()
        guard case let .text(body) = store.page(surfaceID: pty.id, token: nil, before: nil, count: 24, epoch: "epoch", load: pty.mobileHistorySnapshot) else { return XCTFail("Expected history") }
        let first = try JSONDecoder().decode(RemoteHistoryPage.self, from: Data(body.utf8))
        pty.injectSyntheticOutput(Data("NEW\r\n".utf8))
        guard case let .text(next) = store.page(surfaceID: pty.id, token: first.token, before: nil, count: 24, epoch: "epoch", load: pty.mobileHistorySnapshot) else { return XCTFail("Expected same snapshot") }
        let second = try JSONDecoder().decode(RemoteHistoryPage.self, from: Data(next.utf8))
        XCTAssertEqual(first.rows, second.rows)
        if case .error = store.page(surfaceID: "other", token: first.token, before: nil, count: 24, epoch: "epoch", load: pty.mobileHistorySnapshot) { } else { XCTFail("Cross-pane token accepted") }
        if case .error = store.page(surfaceID: pty.id, token: first.token, before: nil, count: 257, epoch: "epoch", load: pty.mobileHistorySnapshot) { } else { XCTFail("Oversized page accepted") }
        if case .error = store.page(surfaceID: pty.id, token: first.token, before: nil, count: 24, epoch: "new-epoch", load: pty.mobileHistorySnapshot) { } else { XCTFail("Old daemon token accepted") }
    }
}
