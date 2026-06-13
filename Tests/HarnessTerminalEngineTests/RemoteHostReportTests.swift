import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// OSC 7's hostname component: emitted on CHANGE only (the shell re-reports every prompt),
/// nil for authority-less reports, dropped (with a nil emission) by a full reset.
final class RemoteHostReportTests: XCTestCase {
    private func emulator(_ collect: @escaping (String?) -> Void) -> TerminalEmulator {
        let term = TerminalEmulator(cols: 40, rows: 6)
        term.onRemoteHostChange = collect
        return term
    }

    func testHostEmitsOnChangeOnlyAndLowercases() {
        var hosts: [String?] = []
        let term = emulator { hosts.append($0) }
        term.feed("\u{1b}]7;file://MacBook.local/Users/me\u{07}")
        term.feed("\u{1b}]7;file://MacBook.local/Users/me/code\u{07}") // same host: no re-emit
        term.feed("\u{1b}]7;file://db1.PROD.example.com/root\u{07}")   // ssh'd: emit
        XCTAssertEqual(hosts, ["macbook.local", "db1.prod.example.com"])
    }

    func testAuthoritylessReportEmitsNilOnce() {
        var hosts: [String?] = []
        let term = emulator { hosts.append($0) }
        term.feed("\u{1b}]7;file:///tmp\u{07}")
        term.feed("\u{1b}]7;file:///var\u{07}")
        XCTAssertEqual(hosts, [nil], "the first report is emitted even when hostless — once")
    }

    func testFullResetClearsTheHostWithANilEmission() {
        var hosts: [String?] = []
        let term = emulator { hosts.append($0) }
        term.feed("\u{1b}]7;file://remote.box/home\u{07}")
        term.feed("\u{1b}c") // RIS
        XCTAssertEqual(hosts, ["remote.box", nil])
        // The respawned shell re-reports — and re-emits, since the reset dropped the state.
        term.feed("\u{1b}]7;file://remote.box/home\u{07}")
        XCTAssertEqual(hosts, ["remote.box", nil, "remote.box"])
    }

    func testRejectedPayloadsEmitNothing() {
        var hosts: [String?] = []
        let term = emulator { hosts.append($0) }
        term.feed("\u{1b}]7;https://evil.example.com/path\u{07}") // non-file scheme: rejected
        term.feed("\u{1b}]7;file://host-without-path\u{07}")      // no absolute path: rejected
        XCTAssertTrue(hosts.isEmpty)
    }

    /// Host (like cwd) is pane STATE, so OSC 7 fires onRemoteHostChange even during replay —
    /// the opposite of bells/notifications/queries, which `isReplaying` suppresses. This is
    /// what restores a reopened pane's per-host profile; gating it would regress that. Locks
    /// the intentional asymmetry (see `handleWorkingDirectoryOSC`).
    func testHostFiresDuringReplay() {
        var hosts: [String?] = []
        let term = emulator { hosts.append($0) }
        term.isReplaying = true
        term.feed("\u{1b}]7;file://remote.box/home\u{07}")
        term.isReplaying = false
        XCTAssertEqual(hosts, ["remote.box"], "replayed OSC 7 must restore the host")
    }
}
