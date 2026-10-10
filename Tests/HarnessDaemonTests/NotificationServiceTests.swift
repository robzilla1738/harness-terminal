import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class NotificationServiceTests: XCTestCase {
    private struct PendingProjection: Decodable { var coalesced: Int }
    func testDurableReceiptCoalescingPaneSnoozeAndLeaseRecovery() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hnotifications-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 95, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let url = home.appendingPathComponent("activity.sqlite"), settingsURL = home.appendingPathComponent("settings.json")
        let store = ActivityStore(url: url, protection: protection)
        var settings = HarnessSettings(); var policy = NotificationPolicySettings(); policy.burstSeconds = 10
        settings.notificationPolicy = policy
        let service = NotificationService(store: store, settings: settings, settingsURL: settingsURL)
        try service.activate(); defer { service.suspend() }
        let surface = UUID().uuidString, run = UUID()
        var notice = NotificationNotice(surfaceID: surface, runID: run, event: .agentWaiting, title: "private title", message: "private message")
        notice.observationIdentity = "stream:1"; service.submit(notice); _ = service.status()
        let first = try store.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129)
        XCTAssertEqual(first.count, 1)
        service.submit(notice); _ = service.status()
        XCTAssertEqual(try store.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).count, 1)
        notice.observationIdentity = "stream:2"; service.submit(notice); _ = service.status()
        let combined = try store.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129)
        XCTAssertEqual(combined.count, 1); XCTAssertEqual(combined.first?.coalesced, 2)
        try service.control(AgentNotificationControl(surfaceID: surface, snoozedUntil: Date().addingTimeInterval(60)))
        try service.control(AgentNotificationControl(surfaceID: surface, runID: run, muted: false))
        notice.observationIdentity = "stream:3"; service.submit(notice); _ = service.status()
        XCTAssertTrue(try store.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).isEmpty)
        service.suspend(); try store.suspend()
        let nextStore = ActivityStore(url: url, protection: protection, writable: false)
        try nextStore.activate()
        let replacement = NotificationService(store: nextStore, settings: settings, settingsURL: settingsURL)
        try replacement.activate(); defer { replacement.suspend() }
        XCTAssertEqual(replacement.status().controls.count, 2)
        replacement.submit(notice); _ = replacement.status()
        XCTAssertTrue(try nextStore.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).isEmpty)
        XCTAssertTrue(try nextStore.object(Bool.self, kind: "notification-observed", id: "stream:3") ?? false)
        replacement.submit(NotificationNotice(surfaceID: UUID().uuidString, event: .agentWaiting, title: "queued before consent change"))
        _ = replacement.status()
        XCTAssertEqual(try nextStore.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).count, 1)
        policy.events[NotificationEvent.agentWaiting.rawValue] = false
        try replacement.configure(policy)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, try !nextStore.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).isEmpty {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(try nextStore.objectPage(PendingProjection.self, kind: "notification-pending", limit: 129).isEmpty, "Revoked policy retires queued delivery before its original burst deadline")
    }
}
