import Foundation

public enum AwakeMode: String, Codable, Sendable { case auto, on, off }
public enum PowerSource: String, Codable, Sendable { case ac, battery, unknown, unsupported }
public struct PowerSettings: Codable, Equatable, Sendable {
    public var keepWorkingAgentsAwake = true
    public var allowOnBattery = false
    public var graceSeconds: Double = 30
    public init() {}
    private enum CodingKeys: String, CodingKey { case keepWorkingAgentsAwake, allowOnBattery, graceSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepWorkingAgentsAwake = try c.decodeIfPresent(Bool.self, forKey: .keepWorkingAgentsAwake) ?? true
        allowOnBattery = try c.decodeIfPresent(Bool.self, forKey: .allowOnBattery) ?? false
        graceSeconds = try c.decodeIfPresent(Double.self, forKey: .graceSeconds) ?? 30
        try validate()
    }
    public func validate() throws {
        guard graceSeconds.isFinite, (0...3600).contains(graceSeconds) else {
            throw ConfigurationError.grace
        }
    }
    public enum ConfigurationError: Error, LocalizedError {
        case grace
        public var errorDescription: String? { "Idle-sleep grace must be between zero and 3600 seconds." }
    }
}
public struct AwakeStatus: Codable, Sendable {
    public var mode: AwakeMode
    public var settings: PowerSettings
    public var source: PowerSource
    public var assertionActive: Bool
    public var workingAgents: Int
    public var graceUntil: Date?
    public var sleeping: Bool
    public var lastWakeAt: Date?
    public var lastSleepSeconds: Double?
    public var unavailable: String?
    public init(mode: AwakeMode, settings: PowerSettings, source: PowerSource, assertionActive: Bool,
                workingAgents: Int, graceUntil: Date?, sleeping: Bool, lastWakeAt: Date?, lastSleepSeconds: Double?, unavailable: String?) {
        self.mode = mode; self.settings = settings; self.source = source; self.assertionActive = assertionActive
        self.workingAgents = workingAgents; self.graceUntil = graceUntil; self.sleeping = sleeping
        self.lastWakeAt = lastWakeAt; self.lastSleepSeconds = lastSleepSeconds; self.unavailable = unavailable
    }

}
public enum PowerOperation: Codable, Sendable { case status, mode(AwakeMode), configure(PowerSettings) }
public struct PowerPolicy: Sendable {
    private var lastWorkingAt: Date?
    public init() {}
    public mutating func evaluate(settings: PowerSettings, mode: AwakeMode, source: PowerSource,
                                  workingAgents: Int, at: Date) -> (hold: Bool, graceUntil: Date?) {
        if workingAgents > 0 { lastWorkingAt = at }
        guard source == .ac || (source == .battery && settings.allowOnBattery), mode != .off else { return (false, nil) }
        if mode == .on { return (true, nil) }
        guard settings.keepWorkingAgentsAwake else { return (false, nil) }
        if workingAgents > 0 { return (true, nil) }
        if let end = lastWorkingAt?.addingTimeInterval(settings.graceSeconds), end > at { return (true, end) }
        return (false, nil)
    }
}
