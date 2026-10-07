import Foundation

/// What one client's resize does to the PTY and to that client's own grid.
public enum ClientResize: Equatable, Sendable {
    /// This client owns the size. The daemon applies `TIOCSWINSZ`.
    case pty(SurfaceSize)
    /// Non-owner, primary screen. Reflow the local grid. Do not ioctl.
    case localReflow(SurfaceSize)
    /// Non-owner on the alternate screen. Leave the grid and the PTY alone.
    case unchanged
}

public enum ClientResizePolicy {
    public static func decide(owner: Bool, alternateScreen: Bool, rows: Int, cols: Int) -> ClientResize {
        let size = SurfaceSize(rows: cells(rows), cols: cells(cols))
        if owner { return .pty(size) }
        if alternateScreen { return .unchanged }
        return .localReflow(size)
    }

    private static func cells(_ value: Int) -> UInt16 {
        UInt16(min(max(value, 1), Int(UInt16.max)))
    }
}

public struct ResizeEffect: Equatable, Sendable {
    public var pty: SurfaceSize?
    public var localReflow: SurfaceSize?

    public init(pty: SurfaceSize?, localReflow: SurfaceSize?) {
        self.pty = pty
        self.localReflow = localReflow
    }
}

/// One resize through the size arbiter. A non-owner vote does not change the
/// owner's PTY size. The alternate screen does not take the local-reflow path.
public enum OwnerResize {
    public static func effect(
        arbiter: inout SurfaceSizeArbiter,
        client: Int32,
        surface: String,
        rows: UInt16,
        cols: UInt16,
        alternateScreen: Bool
    ) -> ResizeEffect {
        let owns = arbiter.claimsPTY(client: client, surface: surface)
        let voted = arbiter.vote(client: client, surface: surface, rows: rows, cols: cols)
        switch ClientResizePolicy.decide(
            owner: owns,
            alternateScreen: alternateScreen,
            rows: Int(rows),
            cols: Int(cols)
        ) {
        case .pty:
            return ResizeEffect(pty: voted, localReflow: nil)
        case let .localReflow(size):
            return ResizeEffect(pty: nil, localReflow: size)
        case .unchanged:
            return ResizeEffect(pty: nil, localReflow: nil)
        }
    }
}
