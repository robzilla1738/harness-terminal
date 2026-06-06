import XCTest
@testable import HarnessCLI

/// Coverage for the CLI's pure argument-parsing helpers. `harness-cli` previously had no test
/// target at all, so a refactor could silently break flag parsing. `flagValue` is the shared
/// extractor behind ~40 subcommands; its "flag present but no value follows" case (returns nil,
/// which callers treat as "not supplied") is the one the audit flagged as untested.
final class HarnessCLITests: XCTestCase {
    func testFlagValueReturnsTheFollowingToken() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "abc"], flag: "--tab"), "abc")
        XCTAssertEqual(HarnessCLI.flagValue(["--cwd", "~", "--tab", "id"], flag: "--tab"), "id")
    }

    func testFlagValueIsNilWhenFlagHasNoValue() {
        // Flag is the final token, so no value follows. Regression guard: this must stay nil (not
        // crash or read past the end), and callers fall back to their usage error.
        XCTAssertNil(HarnessCLI.flagValue(["close-tab", "--tab"], flag: "--tab"))
    }

    func testFlagValueIsNilWhenFlagAbsent() {
        XCTAssertNil(HarnessCLI.flagValue(["--workspace", "Default"], flag: "--tab"))
        XCTAssertNil(HarnessCLI.flagValue([], flag: "--tab"))
    }

    func testFlagValueTakesFirstOccurrence() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "first", "--tab", "second"], flag: "--tab"), "first")
    }

    func testFlagValueTakesNextTokenVerbatimEvenIfFlagLike() {
        // Documents current behavior: the token immediately after the flag is taken verbatim, even
        // if it itself looks like a flag — callers validate the value, not flagValue.
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "--oops"], flag: "--tab"), "--oops")
    }

    // MARK: - bind-hook (`--if` trap)

    func testBindHookRejectsLeadingIfFlagWithoutTrapping() {
        // Regression: ["--if", "cond"] passed the count>=2 guard with ifIndex==0, then
        // `rest[1..<0]` trapped ("Range requires lowerBound <= upperBound", exit 133) before any
        // IPC. Must now parse to nil (caller prints usage + exit 1), not crash.
        XCTAssertNil(HarnessCLI.parseBindHook(["--if", "cond"]))
    }

    func testBindHookRejectsIfFlagImmediatelyAfterEvent() {
        // ifIndex==1 means an empty command (event but no source). Reject rather than send a blank
        // command to the daemon.
        XCTAssertNil(HarnessCLI.parseBindHook(["ev", "--if", "fmt"]))
    }

    func testBindHookRejectsDanglingIfFlag() {
        // `--if` with no format token following it is malformed.
        XCTAssertNil(HarnessCLI.parseBindHook(["ev", "cmd", "--if"]))
    }

    func testBindHookRejectsTooFewTokens() {
        XCTAssertNil(HarnessCLI.parseBindHook([]))
        XCTAssertNil(HarnessCLI.parseBindHook(["ev"]))
    }

    func testBindHookParsesWellFormedWithCondition() {
        let parsed = HarnessCLI.parseBindHook(["ev", "cmd", "--if", "fmt"])
        XCTAssertEqual(parsed?.event, "ev")
        XCTAssertEqual(parsed?.source, "cmd")
        XCTAssertEqual(parsed?.condition, "fmt")
    }

    func testBindHookParsesMultiTokenCommandWithCondition() {
        let parsed = HarnessCLI.parseBindHook(["ev", "new-window", "-h", "--if", "fmt"])
        XCTAssertEqual(parsed?.event, "ev")
        XCTAssertEqual(parsed?.source, "new-window -h")
        XCTAssertEqual(parsed?.condition, "fmt")
    }

    func testBindHookParsesWithoutCondition() {
        let parsed = HarnessCLI.parseBindHook(["ev", "new-window", "-h"])
        XCTAssertEqual(parsed?.event, "ev")
        XCTAssertEqual(parsed?.source, "new-window -h")
        XCTAssertNil(parsed?.condition)
    }

    // MARK: - parseDetachSequence + resolveDetachSequence

    func testParseDetachSequenceRejectsPlausibleBadInputs() {
        // These all look reasonable to a user but are not in any accepted format; each previously
        // parsed to nil and was silently swallowed, leaving the configured keys ignored.
        XCTAssertNil(HarnessCLI.parseDetachSequence("ctrl-d"))
        XCTAssertNil(HarnessCLI.parseDetachSequence("^A,d"))
        XCTAssertNil(HarnessCLI.parseDetachSequence("300"))   // out of UInt8 range
        XCTAssertNil(HarnessCLI.parseDetachSequence(""))
    }

    func testParseDetachSequenceAcceptsValidFormats() {
        XCTAssertEqual(HarnessCLI.parseDetachSequence("C-a d"), [0x01, 0x64])
        XCTAssertEqual(HarnessCLI.parseDetachSequence("0x01 0x64"), [0x01, 0x64])
        XCTAssertEqual(HarnessCLI.parseDetachSequence("1,100"), [1, 100])
    }

    func testResolveDetachSequenceAbsentFlagKeepsDefault() {
        // Flag absent → .absent: the caller keeps its built-in default, never errors.
        XCTAssertEqual(HarnessCLI.resolveDetachSequence(["attach", "--surface", "x"]), .absent)
    }

    func testResolveDetachSequenceValidFlagParses() {
        XCTAssertEqual(
            HarnessCLI.resolveDetachSequence(["--detach-keys", "C-a d"]),
            .parsed([0x01, 0x64]))
    }

    func testResolveDetachSequenceInvalidFlagFailsLoudly() {
        // Flag provided but unparseable → .invalid with a message naming the bad value and the
        // accepted formats. The attach handlers turn this into exit 64 WITHOUT attaching, so
        // AttachClient.run is never reached.
        guard case .invalid(let message) =
            HarnessCLI.resolveDetachSequence(["--detach-keys", "ctrl-d"]) else {
            return XCTFail("expected .invalid")
        }
        XCTAssertTrue(message.contains("ctrl-d"), "message should name the bad value")
        XCTAssertTrue(message.contains("C-a d"), "message should list an accepted format")
    }

    // MARK: - optionalUUIDFlag (new-split --pane / select-layout --main)

    func testOptionalUUIDFlagAbsentIsAbsent() {
        // Absent flag must stay .absent so the daemon applies its default (active pane) — not an error.
        XCTAssertEqual(
            HarnessCLI.optionalUUIDFlag(["new-split", "--tab", "t"], flag: "--pane"),
            .absent)
    }

    func testOptionalUUIDFlagValidRoundTrips() {
        let uuid = UUID()
        XCTAssertEqual(
            HarnessCLI.optionalUUIDFlag(["--pane", uuid.uuidString], flag: "--pane"),
            .valid(uuid))
    }

    func testOptionalUUIDFlagInvalidFailsWithRawValue() {
        // Bogus UUID → .invalid(raw): the caller errors loudly instead of silently splitting the
        // active pane (the #68 silent-fallback class, missed here for --pane / --main).
        XCTAssertEqual(
            HarnessCLI.optionalUUIDFlag(["--pane", "not-a-uuid"], flag: "--pane"),
            .invalid("not-a-uuid"))
    }
}
