import Foundation

/// Turns program-status marks a program reported itself (OSC 7501 `blocked`, `done`, `error`)
/// into notification events. Detector guesses are not here: the app's agent-activity path owns
/// those, and it already skips a tab that a real report owns.
///
/// A tab alerts when its mark changes into one of the three (or its message changes while it
/// stays there). The first snapshot after launch only records what is already showing, so
/// opening the app doesn't replay every old mark, and one tab can't repeat the same kind of
/// alert inside `cooldown`.
public struct ProgramStatusAlerts {
    public struct Alert: Equatable, Sendable {
        public let event: NotificationEvent
        public let tabID: TabID
        public let message: String?
    }

    public var cooldown: TimeInterval
    private var marks: [TabID: ProgramMark] = [:]
    private var lastAlerted: [TabID: (attention: ProgramMark.Attention, at: Date)] = [:]
    private var primed = false

    public init(cooldown: TimeInterval = 15) {
        self.cooldown = cooldown
    }

    public static func event(for attention: ProgramMark.Attention) -> NotificationEvent? {
        switch attention {
        case .blocked: return .agentWaiting
        case .done: return .agentFinished
        case .error: return .failed
        case .working: return nil
        }
    }

    public mutating func alerts(for tabs: [Tab], now: Date = Date()) -> [Alert] {
        var next: [TabID: ProgramMark] = [:]
        var out: [Alert] = []
        for tab in tabs {
            guard let mark = tab.programMark, mark.fromRealReport else { continue }
            next[tab.id] = mark
            guard primed, let event = Self.event(for: mark.attention) else { continue }
            let previous = marks[tab.id]
            guard previous?.attention != mark.attention || previous?.message != mark.message else { continue }
            if let last = lastAlerted[tab.id], last.attention == mark.attention,
               now.timeIntervalSince(last.at) < cooldown { continue }
            lastAlerted[tab.id] = (mark.attention, now)
            out.append(Alert(event: event, tabID: tab.id, message: mark.message))
        }
        marks = next
        lastAlerted = lastAlerted.filter { next[$0.key] != nil }
        primed = true
        return out
    }

    /// One line for several alerts that land together ("2 need you · 1 failed"), most urgent
    /// first, so a burst becomes a single banner instead of a stack.
    public static func summary(of alerts: [Alert]) -> String {
        let order: [(NotificationEvent, String)] = [
            (.agentWaiting, "need you"), (.failed, "failed"), (.agentFinished, "finished"),
        ]
        return order.compactMap { event, verb in
            let count = alerts.filter { $0.event == event }.count
            guard count > 0 else { return nil }
            return event == .agentWaiting && count == 1 ? "1 needs you" : "\(count) \(verb)"
        }.joined(separator: " · ")
    }
}
