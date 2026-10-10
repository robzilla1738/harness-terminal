import Foundation

/// A launched process outcome, independent of provider conversational turn events.
/// This record contains structural identity only; prompts and launch arguments live
/// in the encrypted activity ledger. A host interruption never implies success.
public struct WorkloadOutcome: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case reserved, running, exited, unknown }
    public var id: UUID
    public var surfaceID: String
    public var streamIdentity: String?
    public var processGeneration: UInt64?
    public var pid: Int32?
    public var kernelIdentity: String?
    public var state: State
    public var exitCode: Int32?
    public var cancellationRequested: Bool
    public var acceptedAt: Date
    public var observedAt: Date
    public var storageUnavailable: Bool?
    /// Kernel identity proves the recorded root is absent; its exit code remains unknown.
    /// This does not claim that every orphaned descendant has stopped.
    public var processAbsentObservedAt: Date?
    public var mayBeRunning: Bool { state != .exited && processAbsentObservedAt == nil }
    public init(id: UUID, surfaceID: String, at: Date = .now) {
        self.id = id; self.surfaceID = surfaceID; state = .reserved
        cancellationRequested = false; acceptedAt = at; observedAt = at
    }
}
