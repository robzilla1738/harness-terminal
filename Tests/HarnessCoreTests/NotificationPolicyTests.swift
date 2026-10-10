import XCTest
@testable import HarnessCore

final class NotificationPolicyTests: XCTestCase {
    func testConsentQuietHoursAndSinkSpecificPayloads() throws {
        var policy = try JSONDecoder().decode(NotificationPolicySettings.self, from: Data("{}".utf8))
        XCTAssertFalse(policy.speech); XCTAssertTrue(policy.sinks.isEmpty)
        XCTAssertFalse(policy.allows(.systemSleep, at: .now, muted: false, snoozedUntil: nil))
        policy.quietHours = NotificationQuietHours(timeZone: "America/Chicago", startMinute: 22 * 60, endMinute: 7 * 60)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T07:30:00Z"))
        XCTAssertFalse(policy.allows(.agentFinished, at: date, muted: false, snoozedUntil: nil))
        policy.quietHours = nil
        XCTAssertFalse(policy.allows(.agentFinished, at: date, muted: true, snoozedUntil: nil))
        XCTAssertFalse(policy.allows(.agentFinished, at: date, muted: false, snoozedUntil: date.addingTimeInterval(1)))
        let notice = NotificationNotice(surfaceID: UUID().uuidString, event: .agentFinished, provider: "Claude", title: "private title", message: "private message", repository: "/private/repo")
        var sink = NotificationSink(name: "Private", kind: .ntfy, endpoint: "https://ntfy.example", topic: "topic")
        let minimal = try NotificationPayload.request(notice: notice, sink: sink, credentials: ["token": "safe"])
        let body = try XCTUnwrap(minimal.httpBody)
        XCTAssertNil(body.range(of: Data("private".utf8))); XCTAssertEqual(minimal.value(forHTTPHeaderField: "Authorization"), "Bearer safe")
        sink.includeMessages = true; sink.includeRepository = true
        let included = try XCTUnwrap(NotificationPayload.request(notice: notice, sink: sink, credentials: [:]).httpBody)
        XCTAssertNotNil(included.range(of: Data("private message".utf8))); XCTAssertTrue((try JSONSerialization.jsonObject(with: included) as? [String: Any])?["message"] as? String == "private message\nRepository: /private/repo")
        let pushover = NotificationSink(name: "Phone", kind: .pushover)
        let request = try NotificationPayload.request(notice: notice, sink: pushover, credentials: ["token": "a&b", "user": "u+x"])
        XCTAssertEqual(request.url?.absoluteString, "https://api.pushover.net/1/messages.json")
        let form = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(form.contains("token=a%26b")); XCTAssertTrue(form.contains("user=u%2Bx"))
        let webhook = NotificationSink(name: "Receiver", kind: .webhook)
        let receiver = try NotificationPayload.request(notice: notice, sink: webhook, credentials: ["endpoint": "https://receiver.example/private-key?token=secret"])
        XCTAssertEqual(receiver.url?.query, "token=secret")
        XCTAssertNil(try JSONEncoder().encode(webhook).range(of: Data("private-key".utf8)))
        XCTAssertThrowsError(try NotificationPayload.request(notice: notice, sink: sink, credentials: ["token": "bad\r\nheader"]))
    }
    func testSettingsEditsKeepOwnedSectionsAndClearOptionalValues() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hsettings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("settings.json")
        let initial = Data(##"{"future":{"key":true},"customBackgroundHex":"#123456","power":{"keepWorkingAgentsAwake":false},"notificationPolicy":{"speech":true}}"##.utf8)
        try PrivateFile.replace(url, data: initial, expected: nil)
        var settings = HarnessSettings(); settings.fontSize = 19; settings.customBackgroundHex = nil
        try settings.save(to: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(PrivateFile.read(url))) as? [String: Any])
        XCTAssertNil(root["customBackgroundHex"]); XCTAssertEqual(root["fontSize"] as? Int, 19)
        XCTAssertEqual((root["power"] as? [String: Any])?["keepWorkingAgentsAwake"] as? Bool, false)
        XCTAssertEqual((root["future"] as? [String: Any])?["key"] as? Bool, true)
        var policy = NotificationPolicySettings(); policy.banners = false; policy.chimes = false; policy.events["agentFinished"] = false
        try SettingsSectionStorage.save(policy, key: "notificationPolicy", url: url, rootValues: ["systemNotificationsEnabled": false, "notificationSoundEnabled": false], events: policy.events)
        let decoded = try HarnessSettings.reload(data: XCTUnwrap(PrivateFile.read(url)))
        let effective = NotificationPolicySettings(legacy: decoded)
        XCTAssertFalse(effective.banners); XCTAssertFalse(effective.chimes); XCTAssertFalse(effective.events["agentFinished"] ?? true)
    }
}
