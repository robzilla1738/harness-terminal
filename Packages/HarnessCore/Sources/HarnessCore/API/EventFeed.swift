import Foundation

/// The daemon's event stream, buffered for a reader that polls (Lua `harness.wait` and
/// `harness.on`). Subscribes on a background thread as soon as it's created, so events
/// that happen while a script is still starting are not lost.
public final class EventFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FollowEvent] = []
    private var ended = false

    public init(client: DaemonClient, sessionID: String? = nil, includeServer: Bool = true) {
        let thread = Thread { [weak self] in
            try? client.followEvents(sessionID: sessionID, includeServer: includeServer) { event in
                self?.append(event)
            }
            self?.finish()
        }
        thread.name = "harness.event-feed"
        thread.start()
    }

    /// The oldest undelivered event, or nil when none is waiting.
    public func poll() -> FollowEvent? {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// The daemon closed the stream (or was never reachable) and the buffer is empty.
    public var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended && queue.isEmpty
    }

    private func append(_ event: FollowEvent) {
        lock.lock(); queue.append(event); lock.unlock()
    }

    private func finish() {
        lock.lock(); ended = true; lock.unlock()
    }
}
