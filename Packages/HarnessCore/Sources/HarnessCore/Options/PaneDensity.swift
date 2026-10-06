import Foundation

/// Pane chrome density. Comfortable separates panes by a gap (islands).
/// Compact draws a single-pixel border.
public enum PaneDensity: String, Codable, Sendable, Equatable {
    case comfortable
    case compact

    public var borderPoints: Double {
        switch self {
        case .comfortable: 8
        case .compact: 1
        }
    }

    public var separatedIslands: Bool { self == .comfortable }

    /// Split-divider thickness. Comfortable panes already separate by the
    /// island inset, so the divider must not add a second gap. Compact is the
    /// 1pt border and has no island inset.
    public var splitDividerPoints: Double {
        separatedIslands ? 0 : borderPoints
    }
}
