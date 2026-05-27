import Foundation

public struct AgentNotification: Sendable, Equatable {
    public var surfaceID: SurfaceID?
    public var daemonSurfaceID: DaemonSurfaceID?
    public var title: String
    public var body: String
    public var receivedAt: Date

    public init(
        surfaceID: SurfaceID? = nil,
        daemonSurfaceID: DaemonSurfaceID? = nil,
        title: String,
        body: String,
        receivedAt: Date = .now
    ) {
        self.surfaceID = surfaceID
        self.daemonSurfaceID = daemonSurfaceID
        self.title = title
        self.body = body
        self.receivedAt = receivedAt
    }
}

public enum OSCNotificationParser {
    /// Parses OSC 9 (desktop notification), 99, and 777 style sequences.
    public static func parse(from data: Data) -> AgentNotification? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(from: text)
    }

    public static func parse(from text: String) -> AgentNotification? {
        // OSC 9 ; <title> ; <body>
        if text.contains("9;") || text.contains("\u{9}") {
            let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 {
                return AgentNotification(title: parts[1], body: parts[2])
            }
        }
        // OSC 777 ; notify ; title ; body
        if text.contains("777") {
            let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 4, parts[1].lowercased() == "notify" {
                return AgentNotification(title: parts[2], body: parts[3])
            }
        }
        // Bell / attention heuristic
        if text.contains("\u{07}") {
            return AgentNotification(title: "Terminal", body: "Attention required")
        }
        return nil
    }
}
