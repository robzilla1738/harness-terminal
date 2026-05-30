import XCTest
@testable import HarnessCore

/// The tmux migration contract: lines a user puts in a file and runs via `source-file` go
/// through `CommandParser`. These pin down which `.tmux.conf` constructs carry over verbatim
/// (the multiplexer verbs + bindings) and which do NOT (options — set via `harness-cli
/// set-option`/IPC, not as a `Command`). MIGRATION.md must stay consistent with this.
final class TmuxMigrationTests: XCTestCase {
    func testCommonTmuxConfCommandsParse() throws {
        XCTAssertEqual(try CommandParser.parse("split-window -h"), .splitWindow(direction: .vertical))
        XCTAssertEqual(try CommandParser.parse("split-window -v"), .splitWindow(direction: .horizontal))
        XCTAssertEqual(try CommandParser.parse("select-pane -L"), .selectPane(target: .left))
        XCTAssertEqual(try CommandParser.parse("resize-pane -R 5"), .resizePane(direction: .right, amount: 5))
    }

    func testBindKeyFromConfParses() throws {
        // A classic `.tmux.conf` rebind: `bind | split-window -h`.
        let cmd = try CommandParser.parse("bind | split-window -h")
        guard case let .bindKey(table, spec, inner, repeatable) = cmd else {
            return XCTFail("expected bindKey, got \(cmd)")
        }
        XCTAssertEqual(table, "prefix")
        XCTAssertEqual(spec, "|")
        XCTAssertEqual(inner, .splitWindow(direction: .vertical))
        XCTAssertFalse(repeatable)
    }

    func testRepeatableAndTableBindKeyParse() throws {
        let cmd = try CommandParser.parse("bind-key -r -T prefix H resize-pane -L 2")
        guard case let .bindKey(table, spec, inner, repeatable) = cmd else {
            return XCTFail("expected bindKey, got \(cmd)")
        }
        XCTAssertEqual(table, "prefix")
        XCTAssertEqual(spec, "H")
        XCTAssertEqual(inner, .resizePane(direction: .left, amount: 2))
        XCTAssertTrue(repeatable)
    }

    func testOptionLinesAreNotCommands() {
        // Options aren't `Command`s — a tmux user sets them with `harness-cli set-option`
        // (IPC), not by sourcing them. Asserting the boundary keeps MIGRATION.md honest.
        XCTAssertThrowsError(try CommandParser.parse("set -g status-left ' #S '"))
        XCTAssertThrowsError(try CommandParser.parse("set-option -g base-index 1"))
    }
}
