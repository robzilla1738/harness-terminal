import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Which side of the target a joined or dropped pane lands on: `.before` is left or above,
/// `.after` right or below.
public enum SplitPlacement: String, Codable, Sendable {
    case before
    case after
}
