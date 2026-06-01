import XCTest
@testable import HarnessCore

final class FormatStringTests: XCTestCase {
    private func context() -> FormatContext {
        FormatContext(
            paneID: "pane-1",
            paneTitle: "fish",
            paneCwd: "/Users/dev/Code/harness",
            paneActive: true,
            paneIndex: 0,
            sessionName: "work",
            tabName: "editor",
            tabIndex: 2,
            workspaceName: "Default",
            agentKind: "claude-code",
            agentActivity: "working",
            gitBranch: "main",
            clientName: "Harness.app",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testSubstitutesSimpleTokens() {
        let result = FormatString.evaluate("[#{session_name}] #{cwd_basename}", context: context())
        XCTAssertEqual(result, "[work] harness")
    }

    func testConditionalEvaluatesTruthyAndFalsy() {
        XCTAssertEqual(FormatString.evaluate("#{?agent_activity,● #{agent_kind} #{agent_activity},idle}", context: context()),
                       "● claude-code working")
        var empty = context()
        empty.agentActivity = nil
        XCTAssertEqual(FormatString.evaluate("#{?agent_activity,● #{agent_kind} #{agent_activity},idle}", context: empty),
                       "idle")
    }

    func testTruncationCapsLength() {
        let result = FormatString.evaluate("#{=4:pane_cwd}", context: context())
        XCTAssertEqual(result, "/Use")
    }

    func testTruncationDegradesInsteadOfTrapping() {
        // A negative width must not trap `String.prefix(_:)`; it clamps to 0 (empty), and a
        // non-numeric width falls through to the unknown-token path (also empty). A status
        // format string is user-authored, so these must never crash the renderer.
        XCTAssertEqual(FormatString.evaluate("#{=-5:pane_cwd}", context: context()), "")
        XCTAssertEqual(FormatString.evaluate("#{=0:pane_cwd}", context: context()), "")
        XCTAssertEqual(FormatString.evaluate("#{=abc:pane_cwd}", context: context()), "")
        // A width at/above the body length returns the body untouched.
        XCTAssertEqual(FormatString.evaluate("#{=99:session_name}", context: context()), "work")
    }

    func testUnknownTokenIsEmpty() {
        XCTAssertEqual(FormatString.evaluate("[#{nothing_here}]", context: context()), "[]")
    }

    func testLiteralBracesPassThrough() {
        XCTAssertEqual(FormatString.evaluate("plain text", context: context()), "plain text")
    }

    func testTimeTokenFormatsStrftimeStyle() {
        // strftime → ICU translation: %H → HH, %M → mm. With a fixed `now`,
        // the formatter should emit the zero-padded clock time, not the
        // bare-ICU result `%H:%M` would yield (which prints `%hour:%month`).
        let ctx = context()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let expected = formatter.string(from: ctx.now)
        XCTAssertEqual(FormatString.evaluate("#{time:%H:%M}", context: ctx), expected)
    }

    func testTimeTokenEmitsLiteralCharactersUnchanged() {
        let ctx = context()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let expectedDate = formatter.string(from: ctx.now)
        XCTAssertEqual(FormatString.evaluate("#{time:%Y-%m-%d}", context: ctx), expectedDate)
    }

    func testStatusLeftDefaultOmitsSeparatorWhenSessionMissing() {
        var ctx = context()
        ctx.workspaceName = "Workspace 2"
        ctx.sessionName = nil
        guard case .string(let format) = OptionStore.builtinDefaults["status-left"]! else {
            return XCTFail("status-left default is not a string")
        }
        XCTAssertEqual(FormatString.evaluate(format, context: ctx), " Workspace 2 ")
    }

    func testStatusRightDefaultOmitsBranchSegmentWhenMissing() {
        var ctx = context()
        ctx.gitBranch = nil
        guard case .string(let format) = OptionStore.builtinDefaults["status-right"]! else {
            return XCTFail("status-right default is not a string")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let expected = " harness · \(formatter.string(from: ctx.now)) "
        XCTAssertEqual(FormatString.evaluate(format, context: ctx), expected)
    }
}

final class OptionStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("options-\(UUID().uuidString).json")
    }

    func testGlobalGetSetRoundTrip() {
        let store = OptionStore(url: tmpURL())
        store.set(.bool(false), key: "status", scope: .global)
        XCTAssertEqual(store.get("status", scope: .global)?.boolValue, false)
    }

    func testScopeInheritanceFallsBack() {
        let store = OptionStore(url: tmpURL())
        store.set(.string("custom"), key: "status-left", scope: .global)
        XCTAssertEqual(store.get("status-left", scope: .tab, target: "tab-1")?.stringValue, "custom")
    }

    func testMoreSpecificScopeWins() {
        let store = OptionStore(url: tmpURL())
        store.set(.string("global"), key: "status-left", scope: .global)
        store.set(.string("session"), key: "status-left", scope: .session, target: "sess-1")
        XCTAssertEqual(store.get("status-left", scope: .session, target: "sess-1")?.stringValue, "session")
    }

    func testValueParsingCoercesCommonForms() {
        XCTAssertEqual(OptionStore.Value(parsing: "on"), .bool(true))
        XCTAssertEqual(OptionStore.Value(parsing: "false"), .bool(false))
        XCTAssertEqual(OptionStore.Value(parsing: "10"), .int(10))
        XCTAssertEqual(OptionStore.Value(parsing: "hello"), .string("hello"))
    }

    func testSupersededDefaultsAreUpgradedOnLoad() throws {
        // Persist the old buggy defaults the way an earlier build would have.
        let url = tmpURL()
        let writer = OptionStore(url: url)
        writer.set(.string(" #{workspace_name} · #{session_name} "), key: "status-left", scope: .global)
        writer.set(.string(" #{cwd_basename}#{?git_branch, · #{git_branch},} · %H:%M "), key: "status-right", scope: .global)

        // A fresh instance over the same file should migrate them.
        let reader = OptionStore(url: url)
        XCTAssertEqual(reader.get("status-left", scope: .global), OptionStore.builtinDefaults["status-left"])
        XCTAssertEqual(reader.get("status-right", scope: .global), OptionStore.builtinDefaults["status-right"])
    }

    func testUserCustomizedStatusLineIsNotMigrated() {
        let url = tmpURL()
        let writer = OptionStore(url: url)
        let custom = " custom · #{session_name} "
        writer.set(.string(custom), key: "status-left", scope: .global)

        let reader = OptionStore(url: url)
        XCTAssertEqual(reader.get("status-left", scope: .global)?.stringValue, custom)
    }
}
