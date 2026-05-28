import Foundation

/// Built-in named layouts. Applied by `SessionEditor.applyLayout(tabID:layout:)`
/// to rebuild the pane tree while preserving surfaces. The `mainPaneID`
/// argument lets `main-horizontal` / `main-vertical` honor the user's choice
/// of which pane is the "main" — typically the currently active pane.
public enum LayoutTemplate: String, Codable, Sendable, Equatable, CaseIterable {
    case evenHorizontal = "even-horizontal"
    case evenVertical = "even-vertical"
    case mainHorizontal = "main-horizontal"
    case mainVertical = "main-vertical"
    case tiled

    /// Layout cycled to by `next-layout` / `previous-layout`.
    public func next() -> LayoutTemplate {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .evenHorizontal }
        return all[(idx + 1) % all.count]
    }

    public func previous() -> LayoutTemplate {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .evenHorizontal }
        return all[(idx + all.count - 1) % all.count]
    }
}
