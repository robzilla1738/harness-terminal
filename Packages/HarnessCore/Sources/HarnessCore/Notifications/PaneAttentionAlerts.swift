import Foundation

public struct PaneAttentionAlerts {
    public struct Alert: Sendable {
        public let entry: PaneAttention
        public let event: NotificationEvent
        public let message: String
    }

    private struct Signature: Equatable {
        let rank: AttentionRank
        let message: String?
    }
    private var previous: [SurfaceID: Signature] = [:]
    private var delivered: [SurfaceID: (event: NotificationEvent, date: Date)] = [:]
    private var primed = false

    public init() {}

    public mutating func alerts(for entries: [PaneAttention], now: Date = Date()) -> [Alert] {
        var current: [SurfaceID: Signature] = [:]
        var alerts: [Alert] = []
        for entry in entries {
            let activity = entry.activity
            let signature = Signature(rank: activity.rank, message: activity.message)
            current[entry.surfaceID] = signature
            guard primed, signature != previous[entry.surfaceID], !activity.isSnoozed else { continue }
            let event: NotificationEvent
            let fallback: String
            switch activity.rank {
            case .waiting, .blocked:
                // Only a report or hook can assert that a person is needed.
                guard activity.notification != nil || activity.mark?.fromRealReport == true else { continue }
                event = .agentWaiting; fallback = "Needs your input"
            case .error: event = .failed; fallback = "Failed"
            case .done: event = .agentFinished; fallback = "Finished"
            case .idle:
                guard previous[entry.surfaceID]?.rank == .working else { continue }
                event = .agentFinished; fallback = "Stopped producing output"
            case .working: continue
            }
            if let last = delivered[entry.surfaceID], last.event == event, now.timeIntervalSince(last.date) < 15 { continue }
            delivered[entry.surfaceID] = (event, now)
            alerts.append(Alert(entry: entry, event: event, message: activity.message ?? fallback))
        }
        previous = current
        delivered = delivered.filter { current[$0.key] != nil }
        primed = true
        return alerts
    }
}
