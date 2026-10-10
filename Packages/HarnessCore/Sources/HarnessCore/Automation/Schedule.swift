import Foundation

public enum ScheduleTrigger: Codable, Equatable, Sendable {
    case once(at: Date)
    case cron(expression: String)
    case agentEvent(kind: RunEventKind, surfaceID: String?, provider: AgentKind?, profile: String?)
    case limitReset(profileID: UUID, window: String, acceptPredictedTime: Bool)
    private enum Keys: String, CodingKey { case once, cron, agentEvent, limitReset, at, expression, kind, surfaceID, provider, profile, profileID, window, acceptPredictedTime }
    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        guard root.allKeys.count == 1, let key = root.allKeys.first else { throw ScheduleError.invalid("Choose exactly one schedule trigger.") }
        let value = try root.nestedContainer(keyedBy: Keys.self, forKey: key)
        switch key {
        case .once:
            let at: Date
            if let legacy = try? value.decode(Date.self, forKey: .at) { at = legacy }
            else { let text = try value.decode(String.self, forKey: .at); guard text.count <= 40, let date = ISO8601DateFormatter().date(from: text) else { throw ScheduleError.invalid("Use an ISO 8601 one-shot timestamp with a UTC offset.") }; at = date }
            self = .once(at: at)
        case .cron: self = .cron(expression: try value.decode(String.self, forKey: .expression))
        case .agentEvent: self = try .agentEvent(kind: value.decode(RunEventKind.self, forKey: .kind), surfaceID: value.decodeIfPresent(String.self, forKey: .surfaceID), provider: value.decodeIfPresent(AgentKind.self, forKey: .provider), profile: value.decodeIfPresent(String.self, forKey: .profile))
        case .limitReset: self = try .limitReset(profileID: value.decode(UUID.self, forKey: .profileID), window: value.decode(String.self, forKey: .window), acceptPredictedTime: value.decode(Bool.self, forKey: .acceptPredictedTime))
        default: throw ScheduleError.invalid("Unsupported schedule trigger.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .once(at): var value = root.nestedContainer(keyedBy: Keys.self, forKey: .once); try value.encode(ISO8601DateFormatter().string(from: at), forKey: .at)
        case let .cron(expression): var value = root.nestedContainer(keyedBy: Keys.self, forKey: .cron); try value.encode(expression, forKey: .expression)
        case let .agentEvent(kind, surface, provider, profile): var value = root.nestedContainer(keyedBy: Keys.self, forKey: .agentEvent); try value.encode(kind, forKey: .kind); try value.encodeIfPresent(surface, forKey: .surfaceID); try value.encodeIfPresent(provider, forKey: .provider); try value.encodeIfPresent(profile, forKey: .profile)
        case let .limitReset(profile, window, accepted): var value = root.nestedContainer(keyedBy: Keys.self, forKey: .limitReset); try value.encode(profile, forKey: .profileID); try value.encode(window, forKey: .window); try value.encode(accepted, forKey: .acceptPredictedTime)
        }
    }

}
public struct ScheduleDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var timezone: String
    public var trigger: ScheduleTrigger
    public var workspaceID: UUID
    public var provider: AgentKind
    public var launch: AgentLaunchSpecification
    public var input: String?
    public init(id: UUID = UUID(), name: String, enabled: Bool = false, timezone: String, trigger: ScheduleTrigger,
                workspaceID: UUID, provider: AgentKind = .generic, launch: AgentLaunchSpecification, input: String? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.timezone = timezone; self.trigger = trigger
        self.workspaceID = workspaceID; self.provider = provider; self.launch = launch; self.input = input
    }
    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 256, !name.contains("\0"), TimeZone(identifier: timezone) != nil,
              launch.executable.hasPrefix("/"), launch.executable.utf8.count <= 4096, !launch.executable.contains("\0"),
              launch.directory.hasPrefix("/"), launch.directory.utf8.count <= 8192, !launch.directory.contains("\0"),
              launch.arguments.count <= 256, launch.arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }),
              launch.arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 << 10,
              launch.profile.utf8.count <= 256, !launch.profile.isEmpty, !launch.profile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              input.map({ $0.utf8.count <= 32 << 10 && !$0.contains("\0") }) ?? true else { throw ScheduleError.invalid("Check name, IANA timezone, absolute executable/directory and bounded arguments/input.") }
        let environment = launch.environment ?? [:]
        guard environment.count <= 8, environment.allSatisfy({ ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "LANG", "LC_ALL"].contains($0.key) && $0.value.utf8.count <= 4096 && !$0.value.contains("\0") }) else { throw ScheduleError.invalid("Only profile and locale environment overrides are supported; credentials belong in the credential store.") }
        switch trigger {
        case let .once(at): guard at.timeIntervalSince1970.isFinite else { throw ScheduleError.invalid("Invalid scheduled date.") }
        case let .cron(expression): _ = try CronExpression(expression).next(after: .now, timezone: TimeZone(identifier: timezone)!)
        case let .agentEvent(_, surface, _, profile): guard surface.map({ UUID(uuidString: $0) != nil }) ?? true, profile.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw ScheduleError.invalid("Invalid event surface/profile filter.") }
        case let .limitReset(_, window, accepted): guard !window.isEmpty, window.utf8.count <= 128, !enabled || accepted else { throw ScheduleError.invalid("Limit-reset execution requires explicit consent to its predicted, unconfirmed reset time.") }
        }
    }
}
public struct ScheduleRecord: Codable, Sendable, Identifiable {
    public var id: UUID { definition.id }
    public var definition: ScheduleDefinition
    public var revision: Int
    public var generation: UUID
    public var nextAt: Date?
    public var eventCursor: Int64
    public var lastOccurrenceID: UUID?
    public var lastResetKey: String?
    public var updatedAt: Date
    public init(definition: ScheduleDefinition, revision: Int = 1, eventCursor: Int64 = 0, nextAt: Date? = nil) {
        self.definition = definition; self.revision = revision; generation = UUID(); self.eventCursor = eventCursor; self.nextAt = nextAt; updatedAt = .now
    }
}
public enum ScheduleOccurrenceState: String, Codable, Sendable {
    case launching, running, exited, missed, skippedOverlap, failed, unknown
    public var blocksOverlap: Bool { [.launching, .running, .unknown].contains(self) }
}
public struct ScheduleOccurrence: Codable, Sendable, Identifiable {
    public var id: UUID
    public var scheduleID: UUID
    public var generation: UUID
    public var key: String
    public var dueAt: Date
    public var observedAt: Date
    public var state: ScheduleOccurrenceState
    public var surfaceID: String
    public var outcome: WorkloadOutcome?
    public var reason: String?
    public var predictedReset: Bool
    public var blocksOverlap: Bool { state.blocksOverlap && outcome?.processAbsentObservedAt == nil }
    public init(schedule: ScheduleRecord, key: String, at: Date, state: ScheduleOccurrenceState, predictedReset: Bool = false) {
        id = UUID(); scheduleID = schedule.id; generation = schedule.generation; self.key = key; dueAt = at; observedAt = .now; self.state = state; surfaceID = UUID().uuidString; self.predictedReset = predictedReset
    }
}
public struct SchedulePage: Codable, Sendable {
    public var schedules: [ScheduleRecord]
    public var occurrences: [ScheduleOccurrence]
    public var nextOffset: Int?
    public var unavailable: String?
    public init(schedules: [ScheduleRecord], occurrences: [ScheduleOccurrence], nextOffset: Int?, unavailable: String?) {
        self.schedules = schedules; self.occurrences = occurrences; self.nextOffset = nextOffset; self.unavailable = unavailable
    }
}
public enum ScheduleOperation: Codable, Sendable {
    case list(offset: Int, limit: Int)
    case save(definition: ScheduleDefinition, expectedRevision: Int?)
    case delete(id: UUID, expectedRevision: Int)
    case occurrences(id: UUID, offset: Int, limit: Int)
    case cancelOccurrence(id: UUID)
}
public enum ScheduleError: Error, LocalizedError {
    case invalid(String), unavailable(String), changed, budget
    public var errorDescription: String? {
        switch self {
        case let .invalid(value): value
        case let .unavailable(value): "Scheduling is unavailable: " + value
        case .changed: "The schedule changed since you reviewed it. Refresh before saving."
        case .budget: "The bounded schedule or occurrence budget is full. Existing work is preserved."
        }
    }
}
