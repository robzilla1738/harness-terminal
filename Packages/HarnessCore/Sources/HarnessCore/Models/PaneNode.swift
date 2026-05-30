import Foundation

public enum PaneNode: Codable, Sendable, Equatable {
    case leaf(PaneLeaf)
    indirect case branch(direction: SplitDirection, ratio: Double, first: PaneNode, second: PaneNode)

    public var paneID: PaneID? {
        if case let .leaf(leaf) = self { return leaf.id }
        return nil
    }

    public var surfaceID: SurfaceID? {
        if case let .leaf(leaf) = self { return leaf.surfaceID }
        return nil
    }

    public mutating func replaceSurface(_ surfaceID: SurfaceID, in paneID: PaneID) {
        switch self {
        case var .leaf(leaf) where leaf.id == paneID:
            leaf.surfaceID = surfaceID
            self = .leaf(leaf)
        case .branch(let direction, let ratio, var first, var second):
            first.replaceSurface(surfaceID, in: paneID)
            second.replaceSurface(surfaceID, in: paneID)
            self = .branch(direction: direction, ratio: ratio, first: first, second: second)
        default:
            break
        }
    }

    public func allSurfaceIDs() -> [SurfaceID] {
        switch self {
        case let .leaf(leaf):
            [leaf.surfaceID]
        case let .branch(_, _, first, second):
            first.allSurfaceIDs() + second.allSurfaceIDs()
        }
    }

    public func allPaneIDs() -> [PaneID] {
        switch self {
        case let .leaf(leaf):
            [leaf.id]
        case let .branch(_, _, first, second):
            first.allPaneIDs() + second.allPaneIDs()
        }
    }

    /// All leaves in the same first-then-second order as `allPaneIDs()`/`allSurfaceIDs()` and
    /// `display-panes`/`select-pane` numbering — pairs each pane id with its surface atomically.
    public func allLeaves() -> [PaneLeaf] {
        switch self {
        case let .leaf(leaf):
            [leaf]
        case let .branch(_, _, first, second):
            first.allLeaves() + second.allLeaves()
        }
    }
}

public struct PaneLeaf: Codable, Sendable, Equatable {
    public var id: PaneID
    public var surfaceID: SurfaceID
    public var daemonSurfaceID: DaemonSurfaceID?

    public init(
        id: PaneID = UUID(),
        surfaceID: SurfaceID = UUID(),
        daemonSurfaceID: DaemonSurfaceID? = nil
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.daemonSurfaceID = daemonSurfaceID
    }
}
