import Foundation

/// @unchecked Sendable: the subscriber table is guarded by `lock`; posts hop to the main queue.
public final class NotificationBus: @unchecked Sendable {
    public static let shared = NotificationBus()

    public let notificationPosted = Notification.Name("HarnessNotificationPosted")
    public let tabStatusChanged = Notification.Name("HarnessTabStatusChanged")
    public let snapshotChanged = Notification.Name("HarnessSnapshotChanged")
    public let sendKeysRequested = Notification.Name("HarnessSendKeysRequested")
    public let copyModeRequested = Notification.Name("HarnessCopyModeRequested")
    public let captureRequested = Notification.Name("HarnessCaptureRequested")

    private var latest: AgentNotification?
    private let lock = NSLock()
    private var captureProvider: ((String, Bool) -> String?)?

    private init() {}

    public func post(_ notification: AgentNotification) {
        lock.lock()
        latest = notification
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: self.notificationPosted,
                object: nil,
                userInfo: ["notification": notification]
            )
        }
    }

    public func postSnapshotChanged(revision: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: self.snapshotChanged,
                object: nil,
                userInfo: ["revision": revision]
            )
        }
    }

    public func postSendKeys(surfaceID: String, data: Data) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: self.sendKeysRequested,
                object: nil,
                userInfo: [
                    "surfaceID": surfaceID,
                    "data": data,
                ]
            )
        }
    }

    public func postCopyMode(surfaceID: String, enabled: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: self.copyModeRequested,
                object: nil,
                userInfo: [
                    "surfaceID": surfaceID,
                    "enabled": enabled,
                ]
            )
        }
    }

    /// Register a synchronous capture provider for the renderer surfaces. The
    /// daemon calls `requestCapture` to read scrollback from the running app.
    public func registerCaptureProvider(_ provider: @escaping (String, Bool) -> String?) {
        lock.lock()
        captureProvider = provider
        lock.unlock()
    }

    public func requestCapture(surfaceID: String, includeScrollback: Bool) -> String? {
        lock.lock()
        let provider = captureProvider
        lock.unlock()
        return provider?(surfaceID, includeScrollback)
    }

    public func latestNotification() -> AgentNotification? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
