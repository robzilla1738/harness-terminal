#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation // CGPoint and CGRect on Linux
#endif

/// Where a dragged pane lands on another pane: an edge splits that pane and puts the dragged
/// one on that side; the middle swaps the two. The edge bands are a quarter of the pane, so the
/// middle stays a generous target.
public enum PaneDropZone: Equatable, Sendable {
    case left, right, top, bottom, center

    /// `point` in the target's bounds, y-up (AppKit's default).
    public static func at(_ point: CGPoint, in bounds: CGRect) -> PaneDropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        let edges: [(PaneDropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.bottom, y), (.top, 1 - y)]
        guard let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return .center }
        return nearest.0
    }

    /// The split an edge drop makes: side by side for left and right.
    public var direction: SplitDirection? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }

    public var placement: SplitPlacement {
        self == .left || self == .top ? .before : .after
    }

    /// The part of `bounds` the dropped pane would take, for the highlight (y-up).
    public func highlight(in bounds: CGRect) -> CGRect {
        switch self {
        case .left: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right: return CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .bottom: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        case .top: return CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .center: return bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        }
    }
}
