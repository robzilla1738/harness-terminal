import Foundation
import HarnessCore

/// One bounded owner queue. Intent/cursors/occurrences commit before a launch;
/// an uncertain accepted launch is inspected, never retried. All automatic work
/// enters SurfaceRegistry's generation-scoped accepted-mutation group.
final class ScheduleService: @unchecked Sendable {
    typealias Launch = @Sendable (ScheduleRecord, ScheduleOccurrence) throws -> WorkloadOutcome?
    private let queue = DispatchQueue(label: "com.harness.schedules", qos: .utility)
    private let store: ActivityStore, host: SessionHostClient?
    private let launch: Launch
    private let observeOwned: @Sendable (@Sendable () -> Void) -> Void
    private let limits: @Sendable (Date) throws -> UsageSummary
    private var timer: DispatchSourceTimer?, unavailable: String?, observationOffset = 0
    private var active = false
    private var lastTick: Date?
    private var maintenanceAt = Date.distantPast
    init(store: ActivityStore, host: SessionHostClient? = .configured,
         observeOwned: @escaping @Sendable (@Sendable () -> Void) -> Void = { $0() },
         limits: @escaping @Sendable (Date) throws -> UsageSummary, launch: @escaping Launch) {
        self.store = store; self.host = host; self.observeOwned = observeOwned; self.limits = limits; self.launch = launch
    }
    deinit { timer?.cancel() }
    func activate() {
        queue.sync {
            guard !active else { return }; active = true
            let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.observeOwned { [weak self] in self?.tickOnQueue(now: .now) } }
            self.timer = timer; timer.resume()
        }
    }
    func suspend() { queue.sync { active = false; timer?.cancel(); timer = nil } }
    func handle(_ operation: ScheduleOperation) throws -> Data { try queue.sync { try handleOnQueue(operation) } }
    private func handleOnQueue(_ operation: ScheduleOperation) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            switch operation {
            case let .list(offset, limit):
                try pageBounds(offset, limit)
                let records = try store.objectPage(ScheduleRecord.self, kind: "schedule", offset: offset, limit: limit + 1, orderByIdentity: true)
                let latest = try records.prefix(limit).compactMap { record in try record.lastOccurrenceID.flatMap { try occurrence($0, schedule: record.id) } }
                return try encoder.encode(SchedulePage(schedules: Array(records.prefix(limit)), occurrences: latest, nextOffset: records.count > limit ? offset + limit : nil, unavailable: unavailable ?? store.availability))
            case let .save(definition, expected):
                try requireDurable(); try definition.validate()
                let existing = try store.object(ScheduleRecord.self, kind: "schedule", id: definition.id.uuidString)
                guard existing.map({ $0.revision == expected }) ?? (expected == nil) else { throw ScheduleError.changed }
                if existing == nil, try store.objectPage(ScheduleRecord.self, kind: "schedule", limit: 129).count >= 128 { throw ScheduleError.budget }
                var record = ScheduleRecord(definition: definition, revision: (existing?.revision ?? 0) + 1, eventCursor: try store.latestEventSequence(), nextAt: try next(definition, after: .now))
                record.lastOccurrenceID = existing?.lastOccurrenceID
                try store.saveObjects([LedgerObject(kind: "schedule", id: record.id.uuidString, value: record)])
                return try encoder.encode(record)
            case let .delete(id, expected):
                try requireDurable()
                guard let record = try store.object(ScheduleRecord.self, kind: "schedule", id: id.uuidString), record.revision == expected else { throw ScheduleError.changed }
                if let last = try record.lastOccurrenceID.flatMap({ try occurrence($0, schedule: id) }), last.blocksOverlap { throw ScheduleError.invalid("Cancel the active occurrence and wait for its process outcome before deleting this schedule.") }
                try store.removeObjects(kind: "schedule", ids: [id.uuidString]); return Data("{}".utf8)
            case let .occurrences(id, offset, limit):
                try pageBounds(offset, limit)
                let records = try store.objectPage(ScheduleOccurrence.self, kind: "schedule-occurrence", offset: offset, limit: limit + 1, idPrefix: id.uuidString + ":")
                return try encoder.encode(SchedulePage(schedules: [], occurrences: Array(records.prefix(limit)), nextOffset: records.count > limit ? offset + limit : nil, unavailable: unavailable ?? store.availability))
            case let .cancelOccurrence(id):
                try requireDurable()
                guard let value = try store.objects(ScheduleOccurrence.self, kind: "schedule-occurrence").first(where: { $0.id == id }), let host else { throw ScheduleError.unavailable("This workload or its stable session host is unavailable. No process was signaled.") }
                if value.blocksOverlap { _ = try host.request(.cancelWorkload(id), timeout: 2) }
                return try encoder.encode(value)
            }
    }
    private func pageBounds(_ offset: Int, _ limit: Int) throws { guard (0...1_000_000).contains(offset), (1...100).contains(limit) else { throw ScheduleError.invalid("Use a nonnegative page offset and limit 1–100.") } }
    private func requireDurable() throws {
        if let reason = store.availability { throw ScheduleError.unavailable(reason) }
        guard host != nil else { throw ScheduleError.unavailable("A stable session host is required. Existing monolithic sessions are preserved; scheduling remains off.") }
    }
    private func next(_ definition: ScheduleDefinition, after: Date) throws -> Date? {
        switch definition.trigger {
        case let .once(at): at
        case let .cron(expression): try CronExpression(expression).next(after: after, timezone: TimeZone(identifier: definition.timezone)!)
        default: nil
        }
    }
    private func occurrence(_ id: UUID, schedule: UUID) throws -> ScheduleOccurrence? { try store.object(ScheduleOccurrence.self, kind: "schedule-occurrence", id: schedule.uuidString + ":" + id.uuidString) }
    private func save(_ occurrence: ScheduleOccurrence) throws { try store.saveObjects([LedgerObject(kind: "schedule-occurrence", id: occurrence.scheduleID.uuidString + ":" + occurrence.id.uuidString, value: occurrence)]) }
    /// Focused fixtures drive this exact owner-queue reducer with a deterministic clock.
    func tick(now: Date) { queue.sync { tickOnQueue(now: now) } }
    private func tickOnQueue(now: Date) {
        do {
            try requireDurable()
            let records = try store.objectPage(ScheduleRecord.self, kind: "schedule", limit: 129)
            guard records.count <= 128 else { throw ScheduleError.budget }
            let deadline = ProcessInfo.processInfo.systemUptime + 4
            let page = Array(records.dropFirst(observationOffset).prefix(16))
            observationOffset = observationOffset + page.count >= records.count ? 0 : observationOffset + page.count
            for record in page {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if let lastID = record.lastOccurrenceID, var last = try occurrence(lastID, schedule: record.id), last.blocksOverlap,
                   let host, case let .workloadOutcome(outcome) = try host.request(.workloadOutcome(lastID), timeout: 0.5) {
                    if let outcome {
                        last.outcome = outcome; last.observedAt = outcome.observedAt
                        last.state = outcome.state == .exited ? .exited : outcome.state == .running ? .running : .unknown
                    } else { last.state = .unknown; last.reason = "The accepted workload receipt is unavailable. No retry or overlapping launch is permitted." }
                    try save(last)
                }
            }
            var limitSummary: UsageSummary?
            for var record in records where record.definition.enabled {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                switch record.definition.trigger {
                case .once, .cron:
                    guard let at = record.nextAt, at <= now else { continue }
                    let missed = lastTick == nil || at < now.addingTimeInterval(-30)
                    record.nextAt = try { if case .cron = record.definition.trigger { return try next(record.definition, after: now) }; return nil }()
                    try claim(&record, key: "time:" + String(at.timeIntervalSince1970), due: at, missed: missed, now: now)
                case let .agentEvent(kind, surface, provider, profile):
                    let events = try store.scheduledEvents(after: record.eventCursor)
                    for entry in events {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                        record.eventCursor = entry.sequence
                        let event = entry.event
                        guard event.kind == kind, let run = try store.run(event.runID), surface.map({ $0 == run.surfaceID }) ?? true,
                              provider.map({ $0 == run.provider }) ?? true, profile.map({ $0 == run.profile }) ?? true else { continue }
                        try claim(&record, key: "event:" + event.id.uuidString, due: event.at, missed: lastTick == nil || event.at < now.addingTimeInterval(-30), now: now)
                    }
                    if !events.isEmpty { try store.saveObjects([LedgerObject(kind: "schedule", id: record.id.uuidString, value: record)]) }
                case let .limitReset(profileID, window, accepted):
                    guard accepted else { continue }
                    if limitSummary == nil { limitSummary = try limits(now) }
                    guard let observation = limitSummary?.profiles.first(where: { $0.id == profileID })?.limits.first(where: { $0.window == window }),
                          observation.observedAt > now.addingTimeInterval(-7200), let predicted = observation.predictedReset, predicted <= now else { continue }
                    let key = "predicted:" + String(predicted.timeIntervalSince1970)
                    guard record.lastResetKey != key else { continue }; record.lastResetKey = key
                    try claim(&record, key: key, due: predicted, missed: lastTick == nil || predicted < now.addingTimeInterval(-30), now: now, predicted: true)
                }
            }
            if now.timeIntervalSince(maintenanceAt) > 3600 { try prune(now: now); maintenanceAt = now }
            lastTick = now; unavailable = nil
        } catch { unavailable = error.localizedDescription }
    }
    private func claim(_ record: inout ScheduleRecord, key: String, due: Date, missed: Bool, now: Date, predicted: Bool = false) throws {
        if try store.objectCount(kind: "schedule-occurrence") >= 1000 { try prune(now: now) }
        guard try store.objectCount(kind: "schedule-occurrence") < 1000 else { throw ScheduleError.budget }
        let prior = try record.lastOccurrenceID.flatMap { try occurrence($0, schedule: record.id) }
        let blocked = prior?.blocksOverlap == true
        let previous = prior?.id
        var value = ScheduleOccurrence(schedule: record, key: key, at: due, state: missed ? .missed : blocked ? .skippedOverlap : .launching, predictedReset: predicted)
        value.observedAt = now
        if missed { value.reason = "Missed while the service was inactive or more than 30 seconds late. No catch-up launch. For cron, the missed interval is coalesced through " + ISO8601DateFormatter().string(from: now) + "." }
        if blocked { value.reason = "A prior accepted workload has no confirmed exit. This occurrence was not launched." }
        // Do not replace the active ownership pointer with a skipped record.
        if !blocked { record.lastOccurrenceID = value.id } else { record.lastOccurrenceID = previous }
        record.updatedAt = now
        try store.saveObjects([LedgerObject(kind: "schedule", id: record.id.uuidString, value: record), LedgerObject(kind: "schedule-occurrence", id: record.id.uuidString + ":" + value.id.uuidString, value: value)])
        guard value.state == .launching else { return }
        do {
            guard let outcome = try launch(record, value) else { throw ScheduleError.unavailable("The accepted workload outcome could not be confirmed.") }
            value.outcome = outcome; value.observedAt = outcome.observedAt
            value.state = outcome.state == .exited ? .exited : outcome.state == .running ? .running : .unknown
        } catch let OwnedWorkloadLaunchError.notAccepted(reason) {
            value.state = .failed; value.reason = "No host launch was attempted: " + reason
        } catch {
            value.state = .unknown; value.reason = "Launch acceptance or completion is uncertain. Inspect this occurrence; it will not be retried. " + error.localizedDescription
        }
        try save(value)
    }
    private func prune(now: Date) throws {
        let closed = try store.objects(ScheduleOccurrence.self, kind: "schedule-occurrence").filter { !$0.blocksOverlap }.sorted { $0.observedAt > $1.observedAt }
        let expired = closed.enumerated().filter { $0.offset >= 500 || $0.element.observedAt < now.addingTimeInterval(-14 * 86400) }.map { $0.element.scheduleID.uuidString + ":" + $0.element.id.uuidString }
        if !expired.isEmpty { try store.removeObjects(kind: "schedule-occurrence", ids: Array(expired.prefix(1024))) }
    }
}
