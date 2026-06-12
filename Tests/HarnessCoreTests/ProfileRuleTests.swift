import XCTest
@testable import HarnessCore

/// Per-host/per-command profile matching: glob semantics, criteria conjunction, and the
/// tolerant decode shared with `TriggerRule`.
final class ProfileRuleTests: XCTestCase {
    func testHostGlobMatchesCaseInsensitively() {
        let rule = ProfileRule(host: "*.prod.example.com", theme: "Red Alert")
        XCTAssertTrue(rule.matches(host: "db1.prod.example.com", command: nil))
        XCTAssertTrue(rule.matches(host: "DB1.PROD.EXAMPLE.COM", command: nil))
        XCTAssertFalse(rule.matches(host: "db1.staging.example.com", command: nil))
        XCTAssertFalse(rule.matches(host: nil, command: "zsh"), "host rule needs a known host")
    }

    func testCommandGlobMatches() {
        let rule = ProfileRule(command: "ssh", theme: "Dracula")
        XCTAssertTrue(rule.matches(host: nil, command: "ssh"))
        XCTAssertFalse(rule.matches(host: nil, command: "zsh"))
        XCTAssertFalse(rule.matches(host: "anywhere", command: nil))
    }

    func testBothCriteriaMustHold() {
        let rule = ProfileRule(host: "*.prod*", command: "psql", theme: "Red Alert")
        XCTAssertTrue(rule.matches(host: "db.prod.io", command: "psql"))
        XCTAssertFalse(rule.matches(host: "db.prod.io", command: "zsh"))
        XCTAssertFalse(rule.matches(host: "db.dev.io", command: "psql"))
    }

    func testGuardsNeverMatch() {
        XCTAssertFalse(ProfileRule(theme: "X").matches(host: "h", command: "c"),
                       "a rule with no criteria must never re-theme everything")
        XCTAssertFalse(ProfileRule(host: "*", theme: "X", enabled: false).matches(host: "h", command: nil))
        XCTAssertFalse(ProfileRule(host: "*", theme: "").matches(host: "h", command: nil),
                       "an empty theme has nothing to apply")
    }

    func testDecodingIsTolerant() throws {
        let json = #"[{"host":"*.prod","theme":"Red"},{"theme":42},{"command":"ssh","theme":"Dracula","enabled":false}]"#
        let rules = try JSONDecoder().decode([ProfileRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].host, "*.prod")
        XCTAssertEqual(rules[1].theme, "", "a non-string theme decodes empty (rule is inert)")
        XCTAssertFalse(rules[2].enabled)
    }

    func testSettingsRoundTripCarriesProfiles() throws {
        var settings = HarnessSettings.makeDefaults(imported: nil)
        settings.profiles = [ProfileRule(host: "*.prod", theme: "Red Alert")]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.profiles, settings.profiles)
    }
}
