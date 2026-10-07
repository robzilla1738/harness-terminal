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

    /// Applies `change` to the leaf showing `surfaceKey`. Returns whether a leaf matched.
    @discardableResult
    public mutating func updateLeaf(surfaceKey: String, _ change: (inout PaneLeaf) -> Void) -> Bool {
        switch self {
        case var .leaf(leaf) where leaf.surfaceID.uuidString == surfaceKey:
            change(&leaf)
            self = .leaf(leaf)
            return true
        case .branch(let direction, let ratio, var first, var second):
            let found = first.updateLeaf(surfaceKey: surfaceKey, change)
                || second.updateLeaf(surfaceKey: surfaceKey, change)
            if found { self = .branch(direction: direction, ratio: ratio, first: first, second: second) }
            return found
        default:
            return false
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
    /// This pane's own working directory. The tab's `cwd` follows whichever pane reported
    /// last, so a split needs its own copy for the pane header. Nil until first reported.
    public var cwd: String?
    /// This pane's foreground command (`#{pane_current_command}`), nil until first probed.
    public var command: String?

    public init(
        id: PaneID = UUID(),
        surfaceID: SurfaceID = UUID(),
        daemonSurfaceID: DaemonSurfaceID? = nil,
        cwd: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.daemonSurfaceID = daemonSurfaceID
        self.cwd = cwd
        self.command = command
    }
}
