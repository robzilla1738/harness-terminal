import Foundation

/// How attached clients agree on a surface's PTY size.
///
/// `smallest` is the tmux compatibility rule: every attached client votes and the
/// PTY uses the minimum rows and columns. `owner` lets one client set the size.
/// Other clients record an advisory vote that does not resize the PTY. `take`
/// moves ownership. When the owner disconnects, ownership passes to the client
/// that most recently submitted a vote.
public enum SurfaceSizeMode: String, Codable, Sendable, Equatable {
    case smallest
    case owner
}

public struct SurfaceSize: Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }
}

public struct SurfaceTake: Equatable, Sendable {
    public var ownershipChanged: Bool
    public var size: SurfaceSize?

    public init(ownershipChanged: Bool, size: SurfaceSize?) {
        self.ownershipChanged = ownershipChanged
        self.size = size
    }
}

/// Pure multi-client size rule. The daemon calls this for every resize, take,
/// and disconnect; it does not read the PTY itself.
public struct SurfaceSizeArbiter: Equatable, Sendable {
    public private(set) var mode: SurfaceSizeMode
    private var votes: [String: [Int32: Vote]] = [:]
    private var owners: [String: Int32] = [:]
    private var nextSequence: UInt64 = 1

    private struct Vote: Equatable {
        var size: SurfaceSize
        var sequence: UInt64
    }

    public init(mode: SurfaceSizeMode = .smallest) {
        self.mode = mode
    }

    /// Record `client`'s requested size. Returns the size to apply to the PTY,
    /// or nil when this vote must not change the current size (a non-owner in
    /// `owner` mode, or a vote that does not move the smallest-client minimum).
    public mutating func vote(client: Int32, surface: String, rows: UInt16, cols: UInt16) -> SurfaceSize? {
        let before = effectiveSize(surface)
        let sequence = nextSequence
        nextSequence += 1
        votes[surface, default: [:]][client] = Vote(size: SurfaceSize(rows: rows, cols: cols), sequence: sequence)
        if mode == .owner, owners[surface] == nil {
            owners[surface] = client
        }
        return changed(from: before, surface: surface)
    }

    /// Make `client` the owner of `surface`. Ownership does not change in
    /// `smallest` mode, when `client` has not voted, or when `client` already
    /// owns the surface. `size` is set only when the PTY dimensions change.
    public mutating func take(client: Int32, surface: String) -> SurfaceTake {
        guard mode == .owner, votes[surface]?[client] != nil else {
            return SurfaceTake(ownershipChanged: false, size: nil)
        }
        let previous = owners[surface]
        let before = effectiveSize(surface)
        owners[surface] = client
        let after = effectiveSize(surface)
        return SurfaceTake(ownershipChanged: previous != client, size: after != before ? after : nil)
    }

    /// Drop every vote from `client`. In `owner` mode, a disconnected owner is
    /// replaced by the remaining client with the highest vote sequence.
    public mutating func disconnect(client: Int32) -> [String: SurfaceSize] {
        var changedSizes: [String: SurfaceSize] = [:]
        for surface in Array(votes.keys) {
            if let size = disconnect(client: client, surface: surface) {
                changedSizes[surface] = size
            }
        }
        return changedSizes
    }

    /// Drop one surface vote. Returns the new PTY size when it changed.
    public mutating func disconnect(client: Int32, surface: String) -> SurfaceSize? {
        let before = effectiveSize(surface)
        let wasOwner = owners[surface] == client
        votes[surface]?.removeValue(forKey: client)
        if votes[surface]?.isEmpty != false {
            votes[surface] = nil
            owners[surface] = nil
        } else if wasOwner {
            owners[surface] = mostRecentClient(surface)
        }
        return changed(from: before, surface: surface)
    }

    /// Switch modes and return every surface whose effective size changed.
    public mutating func setMode(_ mode: SurfaceSizeMode) -> [String: SurfaceSize] {
        let before = allEffective()
        self.mode = mode
        if mode == .owner {
            for surface in votes.keys where owners[surface] == nil {
                owners[surface] = mostRecentClient(surface)
            }
        }
        var changedSizes: [String: SurfaceSize] = [:]
        for (surface, size) in allEffective() where before[surface] != size {
            changedSizes[surface] = size
        }
        return changedSizes
    }

    public func effectiveSize(_ surface: String) -> SurfaceSize? {
        guard let table = votes[surface], !table.isEmpty else { return nil }
        switch mode {
        case .smallest:
            let rows = table.values.map(\.size.rows).min() ?? 0
            let cols = table.values.map(\.size.cols).min() ?? 0
            guard rows > 0, cols > 0 else { return nil }
            return SurfaceSize(rows: rows, cols: cols)
        case .owner:
            let owner = owners[surface] ?? mostRecentClient(surface)
            guard let owner, let vote = table[owner], vote.size.rows > 0, vote.size.cols > 0 else { return nil }
            return vote.size
        }
    }

    public func owner(of surface: String) -> Int32? { owners[surface] }

    /// Whether `client`'s resize may change the PTY. `smallest` lets every voter
    /// contribute. In `owner` mode an existing owner is the only claim; the first
    /// voter claims when nobody owns the surface yet.
    public func claimsPTY(client: Int32, surface: String) -> Bool {
        if mode != .owner { return true }
        guard let owner = owners[surface] else { return true }
        return owner == client
    }

    private func mostRecentClient(_ surface: String) -> Int32? {
        votes[surface]?.max { $0.value.sequence < $1.value.sequence }?.key
    }

    private func changed(from before: SurfaceSize?, surface: String) -> SurfaceSize? {
        guard let after = effectiveSize(surface), after != before else { return nil }
        return after
    }

    private func allEffective() -> [String: SurfaceSize] {
        var out: [String: SurfaceSize] = [:]
        for surface in votes.keys {
            if let size = effectiveSize(surface) { out[surface] = size }
        }
        return out
    }
}
