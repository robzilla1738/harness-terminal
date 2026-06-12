import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// #168: scrollback replay on (re)attach must restore state without re-firing world-facing
/// side effects. Replayed queries (DECRQM, kitty keyboard, DA, DSR) were answered onto the
/// PTY long after the program stopped waiting, echoing `2026;2$y…1u` at the shell prompt;
/// historical bells / notifications / OSC 52 clipboard writes / command-finished reports
/// re-fired on every reopen. `isReplaying` suppresses exactly those, and only those.
final class ReplaySideEffectSuppressionTests: XCTestCase {
    /// The p10k-style startup probe from the issue: DECRQM 2026/2027 + kitty keyboard query,
    /// plus DA and DSR for breadth. Live, these all answer; replayed, none may.
    private static let queryBytes =
        "\u{1b}[?2026$p" + "\u{1b}[?2027$p" + "\u{1b}[?u" + "\u{1b}[c" + "\u{1b}[6n"

    func testReplaySuppressesQueryReplies() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }

        term.isReplaying = true
        term.feed(Self.queryBytes)
        term.isReplaying = false
        XCTAssertTrue(replies.isEmpty, "replayed queries must not write to the PTY: \(replies)")

        term.feed(Self.queryBytes)
        XCTAssertFalse(replies.isEmpty, "live queries must still answer after a replay")
    }

    func testReplaySuppressesBellNotificationClipboardAndCommandFinished() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var bells = 0
        var notifications: [String] = []
        var clipboard: [String] = []
        var finished: [Int?] = []
        term.onBell = { bells += 1 }
        term.onNotification = { _, body in notifications.append(body) }
        term.onSetClipboard = { clipboard.append($0) }
        term.onCommandFinished = { _, exit in finished.append(exit) }

        let secret = Data("secret".utf8).base64EncodedString()
        let sideEffects = "\u{07}"                                  // BEL
            + "\u{1b}]9;build finished\u{07}"                       // OSC 9 notification
            + "\u{1b}]777;notify;Build;ok\u{1b}\\"                  // OSC 777 notification
            + "\u{1b}]52;c;\(secret)\u{07}"                         // OSC 52 clipboard set
            + "\u{1b}]133;C\u{07}" + "\u{1b}]133;D;0\u{07}"         // OSC 133 command finished

        term.isReplaying = true
        term.feed(sideEffects)
        term.isReplaying = false
        XCTAssertEqual(bells, 0, "historical bells must stay silent on replay")
        XCTAssertTrue(notifications.isEmpty, "historical notifications must not re-fire")
        XCTAssertTrue(clipboard.isEmpty, "replay must never write the clipboard")
        XCTAssertTrue(finished.isEmpty, "historical command-finished must not re-notify")

        term.feed(sideEffects)
        XCTAssertEqual(bells, 1)
        XCTAssertEqual(notifications, ["build finished", "ok"])
        XCTAssertEqual(clipboard, ["secret"])
        XCTAssertEqual(finished, [0])
    }

    func testReplayStillRestoresStateAndMarks() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var titles: [String] = []
        var pwds: [String] = []
        term.onTitleChange = { titles.append($0) }
        term.onWorkingDirectoryChange = { pwds.append($0) }

        term.isReplaying = true
        term.feed("\u{1b}]0;my title\u{07}")
        term.feed("\u{1b}]7;file://host/tmp\u{07}")
        term.feed("\u{1b}]133;A\u{07}ls\r\n")
        term.feed("\u{1b}[?1049h") // alt screen — mode state must restore too
        term.isReplaying = false

        XCTAssertEqual(titles, ["my title"], "title restoration must survive replay")
        XCTAssertEqual(pwds, ["/tmp"], "cwd restoration must survive replay")
        XCTAssertTrue(term.isAlternateScreenActive, "mode state must apply during replay")
    }

    /// A query split across the replay→live boundary belongs to a program that is actively
    /// waiting (the PTY stream was snapshotted mid-sequence) — it must still be answered.
    func testQuerySpanningReplayBoundaryStillAnswers() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }

        term.isReplaying = true
        term.feed("\u{1b}[?2026") // replay snapshot ends mid-DECRQM
        term.isReplaying = false
        XCTAssertTrue(replies.isEmpty)

        term.feed("$p") // live bytes complete the query
        XCTAssertEqual(replies.last, "\u{1b}[?2026;2$y", "boundary-spanning query answers live")
    }
}
