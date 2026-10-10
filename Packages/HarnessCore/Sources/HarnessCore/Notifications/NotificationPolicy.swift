import Foundation

public enum NotificationSinkKind: String, Codable, Sendable, CaseIterable { case ntfy, pushover, webhook }
public struct NotificationSink: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: NotificationSinkKind
    /// ntfy server or generic JSON receiver. Pushover uses its documented fixed endpoint.
    public var endpoint: String
    public var topic: String?
    public var credentialReference: UUID?
    public var enabled: Bool
    public var includeMessages: Bool
    public var includeRepository: Bool
    public var minimumInterval: Double
    public init(id: UUID = UUID(), name: String, kind: NotificationSinkKind, endpoint: String = "", topic: String? = nil,
                credentialReference: UUID? = nil, enabled: Bool = false, includeMessages: Bool = false,
                includeRepository: Bool = false, minimumInterval: Double = 15) {
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint; self.topic = topic
        self.credentialReference = credentialReference; self.enabled = enabled
        self.includeMessages = includeMessages; self.includeRepository = includeRepository; self.minimumInterval = minimumInterval
    }
    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 128, minimumInterval.isFinite, (1...3600).contains(minimumInterval) else { throw NotificationPolicyError.invalid }
        if kind == .ntfy {
            guard let url = URLComponents(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil,
                  url.password == nil, url.query == nil, url.fragment == nil, endpoint.utf8.count <= 4096 else { throw NotificationPolicyError.endpoint }
        } else if !endpoint.isEmpty { throw NotificationPolicyError.endpoint }
        if kind == .ntfy {
            guard let topic, !topic.isEmpty, topic.utf8.count <= 256,
                  topic.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.").contains($0) }) else { throw NotificationPolicyError.topic }
        }
        if kind != .ntfy, enabled, credentialReference == nil { throw NotificationPolicyError.credential }
    }
}
public struct NotificationQuietHours: Codable, Equatable, Sendable {
    public var timeZone: String
    public var startMinute: Int
    public var endMinute: Int
    public init(timeZone: String, startMinute: Int, endMinute: Int) { self.timeZone = timeZone; self.startMinute = startMinute; self.endMinute = endMinute }
    public func contains(_ date: Date) -> Bool {
        guard let zone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date), minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute == endMinute { return true }
        return startMinute < endMinute ? (startMinute..<endMinute).contains(minute) : minute >= startMinute || minute < endMinute
    }
    public func validate() throws {
        guard TimeZone(identifier: timeZone) != nil, (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else { throw NotificationPolicyError.quietHours }
    }
}
public struct NotificationPolicySettings: Codable, Equatable, Sendable {
    public var banners = true
    public var chimes = true
    public var speech = false
    public var events: [String: Bool] = [:]
    public var quietHours: NotificationQuietHours?
    public var burstSeconds: Double = 1
    public var deliveryExpirySeconds: Double = 120
    public var sinks: [NotificationSink] = []
    public init() {}
    public init(legacy: HarnessSettings) {
        self = legacy.notificationPolicy ?? NotificationPolicySettings()
        banners = legacy.systemNotificationsEnabled; chimes = legacy.notificationSoundEnabled; events = legacy.notificationEvents
    }
    public func validate() throws {
        guard burstSeconds.isFinite, (0...10).contains(burstSeconds), deliveryExpirySeconds.isFinite,
              (5...3600).contains(deliveryExpirySeconds), sinks.count <= 8, Set(sinks.map(\.id)).count == sinks.count,
              events.keys.allSatisfy({ NotificationEvent(rawValue: $0) != nil }) else { throw NotificationPolicyError.invalid }
        try quietHours?.validate(); for sink in sinks { try sink.validate() }
    }
    public func allows(_ event: NotificationEvent, at: Date, muted: Bool, snoozedUntil: Date?) -> Bool {
        !muted && !(snoozedUntil.map { $0 > at } ?? false) && !(quietHours?.contains(at) ?? false) && (events[event.rawValue] ?? event.defaultEnabled)
    }
    private enum CodingKeys: String, CodingKey { case banners, chimes, speech, events, quietHours, burstSeconds, deliveryExpirySeconds, sinks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        banners = try c.decodeIfPresent(Bool.self, forKey: .banners) ?? true
        chimes = try c.decodeIfPresent(Bool.self, forKey: .chimes) ?? true
        speech = try c.decodeIfPresent(Bool.self, forKey: .speech) ?? false
        events = try c.decodeIfPresent([String: Bool].self, forKey: .events) ?? [:]
        quietHours = try c.decodeIfPresent(NotificationQuietHours.self, forKey: .quietHours)
        burstSeconds = try c.decodeIfPresent(Double.self, forKey: .burstSeconds) ?? 1
        deliveryExpirySeconds = try c.decodeIfPresent(Double.self, forKey: .deliveryExpirySeconds) ?? 120
        sinks = try c.decodeIfPresent([NotificationSink].self, forKey: .sinks) ?? []
        try validate()
    }
}
public struct NotificationNotice: Codable, Equatable, Sendable {
    public var id = UUID()
    public var observationIdentity: String?
    public var surfaceID: String?
    public var runID: UUID?
    public var event: NotificationEvent
    public var provider: String?
    public var title: String
    public var message: String
    public var repository: String?
    public var at: Date = .now
    public init(surfaceID: String?, runID: UUID? = nil, event: NotificationEvent, provider: String? = nil, title: String, message: String = "", repository: String? = nil) {
        self.surfaceID = surfaceID; self.runID = runID; self.event = event; self.provider = provider
        self.title = String(title.prefix(256)); self.message = String(message.prefix(2048)); self.repository = repository.map { String($0.prefix(4096)) }
    }
    public var minimalMessage: String { (provider ?? "Harness") + ": " + event.title }
}
public struct DesktopNotificationDelivery: Codable, Equatable, Sendable {
    public var notice: NotificationNotice
    public var banners: Bool
    public var chimes: Bool
    public var speech: Bool
    public var expires: Date
    public init(notice: NotificationNotice, settings: NotificationPolicySettings) {
        self.notice = notice; banners = settings.banners; chimes = settings.chimes; speech = settings.speech
        expires = notice.at.addingTimeInterval(settings.deliveryExpirySeconds)
    }
}
public struct AgentNotificationControl: Codable, Sendable {
    public var surfaceID: String
    public var runID: UUID?
    public var muted: Bool
    public var snoozedUntil: Date?
    public init(surfaceID: String, runID: UUID? = nil, muted: Bool = false, snoozedUntil: Date? = nil) { self.surfaceID = surfaceID; self.runID = runID; self.muted = muted; self.snoozedUntil = snoozedUntil }
    public var scopeIdentifier: String { runID.map { "run:" + $0.uuidString } ?? surfaceID }
}
public struct NotificationDeliveryDiagnostic: Codable, Sendable {
    public var sinkID: UUID?
    public var noticeID: UUID
    public var at: Date
    public var outcome: String
    public init(sinkID: UUID?, noticeID: UUID, outcome: String) { self.sinkID = sinkID; self.noticeID = noticeID; self.at = .now; self.outcome = outcome }
}
public struct NotificationPolicyStatus: Codable, Sendable {
    public var settings: NotificationPolicySettings
    public var controls: [AgentNotificationControl]
    public var diagnostics: [NotificationDeliveryDiagnostic]
    public var unavailable: String?
    public init(settings: NotificationPolicySettings, controls: [AgentNotificationControl], diagnostics: [NotificationDeliveryDiagnostic], unavailable: String?) { self.settings = settings; self.controls = controls; self.diagnostics = diagnostics; self.unavailable = unavailable }
}
public enum NotificationOperation: Codable, Sendable {
    case status, configure(NotificationPolicySettings), control(AgentNotificationControl)
    case credentials(reference: UUID, values: [String: String]?), removeCredentials(UUID)
}
public enum NotificationPolicyError: Error, LocalizedError {
    case invalid, endpoint, topic, credential, quietHours
    public var errorDescription: String? {
        switch self {
        case .invalid: "Notification policy values are invalid or exceed their limits."
        case .endpoint: "External notification endpoints require HTTPS without embedded credentials, query parameters, or fragments. Pushover uses its fixed endpoint."
        case .topic: "An ntfy topic requires 1–256 letters, numbers, dashes, underscores, or periods."
        case .credential: "Configure this destination's credential reference before enabling it."
        case .quietHours: "Quiet hours require a valid timezone and minute-of-day values from 0 to 1439."
        }
    }
}
