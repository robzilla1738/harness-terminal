import Foundation

/// Live grid retention. After `threshold` seconds without a PTY read the live
/// rows are dropped. Parking does not reap the child: the process is still alive,
/// and `presentsProcessAsRunning` stays whatever the caller set.
public struct IdleGrid: Equatable, Sendable {
    public static let defaultThreshold: TimeInterval = 60

    public var live: [String]
    public var history: [String]
    public var parked: Bool
    public var presentsProcessAsRunning: Bool

    public init(
        live: [String] = [],
        history: [String] = [],
        parked: Bool = false,
        presentsProcessAsRunning: Bool = true
    ) {
        self.live = live
        self.history = history
        self.parked = parked
        self.presentsProcessAsRunning = presentsProcessAsRunning
    }

    public mutating func tick(secondsSincePTYRead: TimeInterval, threshold: TimeInterval = IdleGrid.defaultThreshold) {
        guard !parked, secondsSincePTYRead >= threshold else { return }
        history = live
        live = []
        parked = true
    }

    public mutating func restore() {
        guard parked else { return }
        live = history
        parked = false
    }
}
