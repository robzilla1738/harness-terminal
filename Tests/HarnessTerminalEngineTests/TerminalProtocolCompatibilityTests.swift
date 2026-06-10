import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Harness protocol coverage: OSC 9/777 notifications, OSC 22 cursor shape, programmable tab
/// stops (HTS/TBC/CHT/CBT), and DEC special-graphics charset designation. All headless.
final class TerminalProtocolCompatibilityTests: XCTestCase {
    // MARK: OSC 9 / 777 notifications

    func testOSC9NotificationBodyOnly() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var got: (String?, String)?
        term.onNotification = { got = ($0, $1) }
        term.feed("\u{1b}]9;build finished\u{07}")
        XCTAssertNil(got?.0)
        XCTAssertEqual(got?.1, "build finished")
    }

    func testOSC777NotifyTitleAndBody() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var got: (String?, String)?
        term.onNotification = { got = ($0, $1) }
        term.feed("\u{1b}]777;notify;Build;succeeded\u{1b}\\")
        XCTAssertEqual(got?.0, "Build")
        XCTAssertEqual(got?.1, "succeeded")
    }

    // MARK: DECSET 1007 alternate scroll

    func testAlternateScrollModeDefaultsOnAndToggles() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertTrue(term.modes.alternateScroll, "1007 defaults on (iTerm2/Ghostty convention)")
        term.feed("\u{1b}[?1007$p") // DECRQM
        XCTAssertEqual(replies.last, "\u{1b}[?1007;1$y")
        term.feed("\u{1b}[?1007l")
        XCTAssertFalse(term.modes.alternateScroll)
        term.feed("\u{1b}[?1007$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1007;2$y")
        term.feed("\u{1b}[?1007h")
        XCTAssertTrue(term.modes.alternateScroll)
    }

    func testAlternateScreenActiveFlagTracksSwitches() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        XCTAssertFalse(term.isAlternateScreenActive)
        term.feed("\u{1b}[?1049h")
        XCTAssertTrue(term.isAlternateScreenActive)
        term.feed("\u{1b}[?1049l")
        XCTAssertFalse(term.isAlternateScreenActive)
    }

    // MARK: DECSET 1004 focus reporting mode (the kit layer emits CSI I/O on focus changes)

    func testFocusReportingModeTogglesAndReports() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertFalse(term.modes.focusReporting)
        term.feed("\u{1b}[?1004h")
        XCTAssertTrue(term.modes.focusReporting)
        term.feed("\u{1b}[?1004$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1004;1$y")
        term.feed("\u{1b}[?1004l")
        XCTAssertFalse(term.modes.focusReporting)
    }

    // MARK: XTVERSION formatting

    func testXTVERSIONReplyOmitsTrailingSpaceWhenVersionEmpty() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[>q") // XTVERSION with the default (empty) version string
        let last = replies.last ?? ""
        XCTAssertTrue(last.hasPrefix("\u{1b}P>|"), "XTVERSION reply shape: \(last.debugDescription)")
        XCTAssertFalse(last.contains(" \u{1b}\\"), "no trailing space before ST: \(last.debugDescription)")
    }

    // MARK: OSC 9;4 progress reports (ConEmu)

    func testOSC94IndeterminateProgress() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var notified = false
        term.onProgress = { reports.append($0) }
        term.onNotification = { _, _ in notified = true }
        term.feed("\u{1b}]9;4;3;0\u{07}")        // BEL terminator, Claude Code style
        term.feed("\u{1b}]9;4;3\u{1b}\\")        // ST terminator, no value
        XCTAssertEqual(reports, [
            TerminalProgressReport(state: .indeterminate, value: 0),
            TerminalProgressReport(state: .indeterminate, value: nil),
        ])
        XCTAssertFalse(notified, "9;4 must never surface as a notification (Ghostty parity)")
    }

    func testOSC94BareFourIsConsumedSilently() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var notified = false
        term.onProgress = { reports.append($0) }
        term.onNotification = { _, _ in notified = true }
        term.feed("\u{1b}]9;4\u{07}") // progress-shaped but stateless: dropped entirely
        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(notified, "bare 9;4 must not surface as a notification either")
    }

    func testOSC94SetRemoveAndClamp() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        term.onProgress = { reports.append($0) }
        term.feed("\u{1b}]9;4;1;50\u{07}")
        term.feed("\u{1b}]9;4;1;250\u{07}")      // out-of-range value clamps to 100
        term.feed("\u{1b}]9;4;2\u{07}")          // error, no value
        term.feed("\u{1b}]9;4;4;30\u{07}")       // paused at 30
        term.feed("\u{1b}]9;4;0;0\u{07}")        // remove
        XCTAssertEqual(reports, [
            TerminalProgressReport(state: .set, value: 50),
            TerminalProgressReport(state: .set, value: 100),
            TerminalProgressReport(state: .error, value: nil),
            TerminalProgressReport(state: .paused, value: 30),
            TerminalProgressReport(state: .remove, value: 0),
        ])
    }

    func testOSC94UnknownStateIsIgnoredNotNotified() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var notified = false
        term.onProgress = { reports.append($0) }
        term.onNotification = { _, _ in notified = true }
        term.feed("\u{1b}]9;4;9;0\u{07}")        // state 9 doesn't exist
        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(notified)
    }

    func testOSC9BodyStartingWithFourStillNotifiesUnlessSubCodeFour() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var bodies: [String] = []
        term.onProgress = { reports.append($0) }
        term.onNotification = { bodies.append($1) }
        term.feed("\u{1b}]9;42 tests passed\u{07}") // "42…" is a body, not sub-code 4
        term.feed("\u{1b}]9;hello\u{07}")
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(bodies, ["42 tests passed", "hello"])
    }

    // MARK: OSC 22 pointer shape

    func testOSC22SetsPointerShape() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var changes: [String?] = []
        term.onPointerShapeChange = { changes.append($0) }
        term.feed("\u{1b}]22;pointer\u{07}")
        XCTAssertEqual(term.pointerShape, "pointer")
        XCTAssertEqual(changes, ["pointer"])
        // Re-setting the same shape doesn't re-fire.
        term.feed("\u{1b}]22;pointer\u{07}")
        XCTAssertEqual(changes, ["pointer"])
    }

    // MARK: Programmable tab stops

    private func cursorCol(_ term: TerminalEmulator) -> Int { term.readGrid().cursor.col }

    func testHTSSetsStopAndTabLandsThere() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\u{1b}[3g")     // TBC clear all stops
        term.feed("\u{1b}[4G")     // CHA → column 4 (1-based) = col 3
        term.feed("\u{1b}H")       // HTS — set a stop here (col 3)
        term.feed("\r\t")          // CR home, then HT
        XCTAssertEqual(cursorCol(term), 3)
    }

    func testTBCClearAllSendsTabToLastColumn() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\u{1b}[3g\r\t") // no stops → tab goes to the last column
        XCTAssertEqual(cursorCol(term), 39)
    }

    func testDefaultTabIsEveryEight() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\r\t")
        XCTAssertEqual(cursorCol(term), 8)
        term.feed("\t")
        XCTAssertEqual(cursorCol(term), 16)
    }

    func testForwardAndBackwardTabs() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\r\u{1b}[3I")   // CHT 3 → cols 8,16,24
        XCTAssertEqual(cursorCol(term), 24)
        term.feed("\u{1b}[2Z")     // CBT 2 → back to col 8
        XCTAssertEqual(cursorCol(term), 8)
    }

    // MARK: DEC special-graphics charset

    private func codepoint(_ term: TerminalEmulator, row: Int, col: Int) -> UInt32? {
        term.readGrid().cell(row: row, col: col)?.codepoint
    }

    func testDECSpecialGraphicsLineDrawing() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}(0lqk")   // designate G0 = special graphics, print l q k
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x250C) // ┌
        XCTAssertEqual(codepoint(term, row: 0, col: 1), 0x2500) // ─
        XCTAssertEqual(codepoint(term, row: 0, col: 2), 0x2510) // ┐
    }

    func testCharsetRestoreToASCII() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}(0q")     // ─
        term.feed("\u{1b}(Bq")     // back to ASCII → literal 'q'
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x2500)
        XCTAssertEqual(codepoint(term, row: 0, col: 1), UInt32(UnicodeScalar("q").value))
    }

    func testSOSIInvokeG1AndG0() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b})0")      // designate G1 = special graphics
        term.feed("\u{0e}q")       // SO → invoke G1, print q → ─
        term.feed("\u{0f}q")       // SI → invoke G0 (ascii), print q → 'q'
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x2500)
        XCTAssertEqual(codepoint(term, row: 0, col: 1), UInt32(UnicodeScalar("q").value))
    }

    // MARK: Device attributes (DA1 / DA3)

    func testPrimaryDAReportsVT220ClassWithSixelAndColor() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[c")
        XCTAssertEqual(replies.last, "\u{1b}[?62;4;22c",
                       "VT220 class (62) + Sixel (4) + ANSI color (22)")
    }

    func testTertiaryDAReportsUnitID() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[=c")
        XCTAssertEqual(replies.last, "\u{1b}P!|00000000\u{1b}\\", "DECRPTUI with the xterm all-zero unit id")
    }

    // MARK: DECRQM — ANSI (non-private) form

    func testANSIDECRQMReportsIRMAndUnrecognizedModes() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[4$p")
        XCTAssertEqual(replies.last, "\u{1b}[4;2$y", "IRM defaults reset")
        term.feed("\u{1b}[4h\u{1b}[4$p")
        XCTAssertEqual(replies.last, "\u{1b}[4;1$y", "IRM set")
        term.feed("\u{1b}[4l\u{1b}[4$p")
        XCTAssertEqual(replies.last, "\u{1b}[4;2$y")
        // Unrecognized ANSI mode → state 0, the conformance-correct feature-detect answer.
        term.feed("\u{1b}[999$p")
        XCTAssertEqual(replies.last, "\u{1b}[999;0$y")
    }

    // MARK: DECSET 1048 — save/restore cursor

    func testMode1048SavesAndRestoresCursor() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[3;5H\u{1b}[?1048h") // park at (3,5), save
        term.feed("\u{1b}[?1048$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1048;1$y")
        term.feed("\u{1b}[1;1H\u{1b}[?1048l") // move away, restore
        term.feed("\u{1b}[6n")                // DSR-CPR: where is the cursor now?
        XCTAssertEqual(replies.last, "\u{1b}[3;5R", "1048l must restore the saved position")
        term.feed("\u{1b}[?1048$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1048;2$y")
    }

    func testSoftResetClearsMode1048SavedBit() {
        let term = TerminalEmulator(cols: 20, rows: 6)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[?1048h\u{1b}[?1048$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1048;1$y")
        // DECSTR discards the saved cursor; the mode bit must follow it.
        term.feed("\u{1b}[!p\u{1b}[?1048$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1048;2$y", "DECSTR must clear the 1048 save bit")
    }

    // MARK: DECSET 12 — att610 cursor blink

    func testAtt610CursorBlinkModeTogglesAndReports() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertNil(term.readGrid().cursor.blinking, "default: user setting decides")
        term.feed("\u{1b}[?12h")
        XCTAssertEqual(term.readGrid().cursor.blinking, true)
        term.feed("\u{1b}[?12$p")
        XCTAssertEqual(replies.last, "\u{1b}[?12;1$y")
        term.feed("\u{1b}[?12l")
        XCTAssertEqual(term.readGrid().cursor.blinking, false)
        term.feed("\u{1b}[?12$p")
        XCTAssertEqual(replies.last, "\u{1b}[?12;2$y")
    }

    // MARK: DECSET 5 — DECSCNM reverse video

    func testDECSCNMTracksReportsAndDirtiesTheScreen() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertFalse(term.modes.reverseVideo)
        term.feed("hello")
        _ = term.consumeDamage() // drain print damage so the toggle's damage is isolated
        term.feed("\u{1b}[?5h")
        XCTAssertTrue(term.modes.reverseVideo)
        XCTAssertTrue(term.consumeDamage().full, "a whole-screen video swap must repaint everything")
        term.feed("\u{1b}[?5$p")
        XCTAssertEqual(replies.last, "\u{1b}[?5;1$y")
        term.feed("\u{1b}[?5l")
        XCTAssertFalse(term.modes.reverseVideo)
        term.feed("\u{1b}[?5$p")
        XCTAssertEqual(replies.last, "\u{1b}[?5;2$y")
        // Setting the already-current state must not re-dirty the screen.
        _ = term.consumeDamage()
        term.feed("\u{1b}[?5l")
        XCTAssertFalse(term.consumeDamage().full, "a no-op DECSCNM must not force a repaint")
    }

    // MARK: DECSET 1016 — SGR-pixel mouse mode flag

    func testMode1016TracksAndReports() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertFalse(term.modes.mouseSGRPixel)
        term.feed("\u{1b}[?1016h")
        XCTAssertTrue(term.modes.mouseSGRPixel)
        term.feed("\u{1b}[?1016$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1016;1$y")
        term.feed("\u{1b}[?1016l")
        XCTAssertFalse(term.modes.mouseSGRPixel)
        term.feed("\u{1b}[?1016$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1016;2$y")
    }

    // MARK: DECRQM — alternate-screen modes

    func testDECRQMReportsAlternateScreenModes() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[?1049$p")
        XCTAssertEqual(replies.last, "\u{1b}[?1049;2$y")
        term.feed("\u{1b}[?1049h")
        for mode in [47, 1047, 1049] {
            term.feed("\u{1b}[?\(mode)$p")
            XCTAssertEqual(replies.last, "\u{1b}[?\(mode);1$y", "mode \(mode) reflects the alt screen")
        }
        term.feed("\u{1b}[?1049l\u{1b}[?47$p")
        XCTAssertEqual(replies.last, "\u{1b}[?47;2$y")
    }

    // MARK: XTWINOPS (CSI t) — size reports + title stack

    func testWindowOpsSizeReports() {
        let term = TerminalEmulator(cols: 80, rows: 24)
        var replies: [String] = []
        term.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        term.feed("\u{1b}[18t")
        XCTAssertEqual(replies.last, "\u{1b}[8;24;80t", "text area size in characters")
        // Pixel report derives from the host-supplied cell pixel size (the inline-image
        // plumb); headless, the screen's synthetic 8×16 default answers — never silence.
        term.feed("\u{1b}[14t")
        XCTAssertEqual(replies.last, "\u{1b}[4;\(24 * 16);\(80 * 8)t")
        term.setCellPixelSize(width: 10, height: 20)
        term.feed("\u{1b}[14t")
        XCTAssertEqual(replies.last, "\u{1b}[4;480;800t", "CSI 4 ; height ; width t at real cell metrics")
    }

    func testWindowOpsTitleStackPushPop() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var titles: [String] = []
        term.onTitleChange = { titles.append($0) }
        term.feed("\u{1b}]2;first\u{07}")
        term.feed("\u{1b}[22;0t")             // push "first"
        term.feed("\u{1b}]2;second\u{07}")
        XCTAssertEqual(term.currentTitle, "second")
        term.feed("\u{1b}[23;0t")             // pop → restore + announce "first"
        XCTAssertEqual(term.currentTitle, "first")
        XCTAssertEqual(titles, ["first", "second", "first"])

        // Pop on an empty stack is silent (no spurious title change).
        term.feed("\u{1b}[23;0t")
        XCTAssertEqual(titles.count, 3)
    }

    func testWindowOpsTitleStackIsDepthCapped() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var titles: [String] = []
        term.onTitleChange = { titles.append($0) }
        for i in 0 ..< 15 { // push 15 — only the first 10 are retained
            term.feed("\u{1b}]2;t\(i)\u{07}\u{1b}[22;0t")
        }
        titles.removeAll()
        for _ in 0 ..< 15 { term.feed("\u{1b}[23;0t") }
        XCTAssertEqual(titles.count, 10, "pushes beyond the cap dropped; pops beyond the stack silent")
        XCTAssertEqual(titles.first, "t9", "the newest retained push pops first")
        XCTAssertEqual(titles.last, "t0")
    }

    func testFullResetClearsTitleStack() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var titles: [String] = []
        term.onTitleChange = { titles.append($0) }
        term.feed("\u{1b}]2;kept\u{07}\u{1b}[22;0t")
        term.feed("\u{1b}c") // RIS
        titles.removeAll()
        term.feed("\u{1b}[23;0t") // stack emptied by RIS → silent
        XCTAssertTrue(titles.isEmpty)
    }

    // MARK: OSC 1337 — CurrentDir= / SetUserVar= (F20)

    func testOSC1337CurrentDirReportsAbsolutePathsOnly() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var paths: [String] = []
        term.onWorkingDirectoryChange = { paths.append($0) }
        term.feed("\u{1b}]1337;CurrentDir=/Users/me/project\u{07}")
        XCTAssertEqual(paths, ["/Users/me/project"])
        // Same trust policy as OSC 7: hostile output must not steer the inherited cwd.
        term.feed("\u{1b}]1337;CurrentDir=relative/path\u{07}")
        term.feed("\u{1b}]1337;CurrentDir=\u{07}")
        XCTAssertEqual(paths, ["/Users/me/project"], "non-absolute paths are ignored")
    }

    func testOSC1337SetUserVarDecodesValidatesAndCaps() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var seen: [(String, String)] = []
        term.onUserVariableChange = { seen.append(($0, $1)) }

        // "hello" base64 = aGVsbG8=
        term.feed("\u{1b}]1337;SetUserVar=status=aGVsbG8=\u{07}")
        XCTAssertEqual(term.userVariables["status"], "hello")
        XCTAssertEqual(seen.count, 1)

        // Updates overwrite; names are shape-validated; junk base64 is ignored.
        term.feed("\u{1b}]1337;SetUserVar=status=d29ybGQ=\u{07}") // "world"
        XCTAssertEqual(term.userVariables["status"], "world")
        term.feed("\u{1b}]1337;SetUserVar=bad name=aGVsbG8=\u{07}")
        term.feed("\u{1b}]1337;SetUserVar=ok=!!!not-base64!!!\u{07}")
        term.feed("\u{1b}]1337;SetUserVar=noequals\u{07}")
        XCTAssertEqual(term.userVariables.count, 1, "invalid sets are dropped")

        // Population cap: new names rejected past 64; existing stay updatable.
        for i in 0 ..< 100 {
            let value = Data("v\(i)".utf8).base64EncodedString()
            term.feed("\u{1b}]1337;SetUserVar=var\(i)=\(value)\u{07}")
        }
        XCTAssertLessThanOrEqual(term.userVariables.count, 64)
        term.feed("\u{1b}]1337;SetUserVar=status=YWdhaW4=\u{07}") // "again"
        XCTAssertEqual(term.userVariables["status"], "again", "existing names stay updatable at the cap")
    }

    /// Same-name-same-value rewrites must not re-fire the host callback — each fire
    /// becomes a GUI→daemon push, so an output loop re-asserting one variable would
    /// otherwise amplify into an IPC flood.
    func testOSC1337SetUserVarSameValueRewriteDoesNotRefire() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var fired = 0
        term.onUserVariableChange = { _, _ in fired += 1 }
        for _ in 0 ..< 5 {
            term.feed("\u{1b}]1337;SetUserVar=status=aGVsbG8=\u{07}") // "hello", unchanged
        }
        XCTAssertEqual(fired, 1, "rewrites of an unchanged value are deduped")
        term.feed("\u{1b}]1337;SetUserVar=status=d29ybGQ=\u{07}") // "world" — a real change
        XCTAssertEqual(fired, 2)
    }

    /// Name validation is ASCII-tight: Unicode letters/digits (`café`, `½`) must not
    /// slip through `isLetter`/`isNumber`.
    func testOSC1337SetUserVarRejectsNonASCIINames() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}]1337;SetUserVar=caf\u{e9}=aGVsbG8=\u{07}")
        term.feed("\u{1b}]1337;SetUserVar=\u{bd}=aGVsbG8=\u{07}")
        XCTAssertTrue(term.userVariables.isEmpty)
    }

    /// The base64 TEXT is bounded before decoding (4096 bytes ≈ 5464 chars with padding):
    /// a hostile multi-MiB payload is rejected without ever reaching the decoder, while
    /// the 4096-byte boundary value still lands.
    func testOSC1337SetUserVarBoundsBase64TextBeforeDecoding() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        let maxValue = String(repeating: "a", count: 4096) // encodes to exactly 5464 chars
        term.feed("\u{1b}]1337;SetUserVar=max=\(Data(maxValue.utf8).base64EncodedString())\u{07}")
        XCTAssertEqual(term.userVariables["max"], maxValue)
        let oversized = Data(repeating: 0x61, count: 65536).base64EncodedString()
        XCTAssertGreaterThan(oversized.count, 5464)
        term.feed("\u{1b}]1337;SetUserVar=big=\(oversized)\u{07}")
        XCTAssertNil(term.userVariables["big"])
    }

    /// Decoded values carrying C0 controls, DEL, or C1 are rejected outright — they get
    /// format-expanded into status lines and other clients' TTYs later, where a raw ESC
    /// is escape injection.
    func testOSC1337SetUserVarRejectsControlCharacterValues() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        func feedValue(_ name: String, _ raw: String) {
            term.feed("\u{1b}]1337;SetUserVar=\(name)=\(Data(raw.utf8).base64EncodedString())\u{07}")
        }
        feedValue("esc", "evil\u{1b}[31m") // C0 (ESC)
        feedValue("nul", "a\u{0}b")        // C0 (NUL)
        feedValue("del", "a\u{7f}b")       // DEL
        feedValue("nel", "a\u{85}b")       // C1 (NEL)
        XCTAssertTrue(term.userVariables.isEmpty)
        feedValue("ok", "plain text, punctuation: 100%")
        XCTAssertEqual(term.userVariables["ok"], "plain text, punctuation: 100%")
    }

    func testOSC1337FileStillRoutesToImageHandler() {
        // The new demux must not break inline images: junk File= payloads are ignored
        // exactly as before (no crash, no user-var side effects).
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}]1337;File=inline=1:notreallyanimage\u{07}")
        XCTAssertTrue(term.userVariables.isEmpty)
    }

    func testFullResetClearsUserVariables() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}]1337;SetUserVar=keep=aGVsbG8=\u{07}")
        XCTAssertFalse(term.userVariables.isEmpty)
        term.feed("\u{1b}c") // RIS
        XCTAssertTrue(term.userVariables.isEmpty)
    }

    /// RIS reports the clear so hosts can drop their mirrored copies (the pane-scoped
    /// `@` options) — silently clearing engine state left `#{@name}` serving stale
    /// pre-reset values forever. No-clear resets stay silent.
    func testFullResetFiresUserVariablesClearedCallback() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var cleared = 0
        term.onUserVariablesCleared = { cleared += 1 }
        term.feed("\u{1b}c") // nothing to clear → no callback
        XCTAssertEqual(cleared, 0)
        term.feed("\u{1b}]1337;SetUserVar=keep=aGVsbG8=\u{07}")
        term.feed("\u{1b}c")
        XCTAssertEqual(cleared, 1)
        XCTAssertTrue(term.userVariables.isEmpty)
    }
}
