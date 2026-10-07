import Foundation

/// Edge peek, then overview, for the other tabs. `rows` and `columns` are the live
/// pane's grid size captured when the peek opens. Nothing in this type writes them.
public struct TabPeek: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case closed, peeking, overview
    }

    public struct Tab: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var preview: String
        public var mark: ProgramMark?

        public init(id: String, title: String, preview: String, mark: ProgramMark?) {
            self.id = id
            self.title = title
            self.preview = preview
            self.mark = mark
        }
    }

    public private(set) var phase: Phase
    public private(set) var selection: Int
    public private(set) var rows: Int
    public private(set) var columns: Int
    public private(set) var tabs: [Tab]

    public init(rows: Int, columns: Int, tabs: [Tab] = []) {
        phase = .closed
        selection = 0
        self.rows = rows
        self.columns = columns
        self.tabs = tabs
    }

    /// Closed plus Reduce Motion opens the overview. Otherwise the first step peeks from the edge.
    public mutating func toggle(reduceMotion: Bool) {
        switch phase {
        case .closed:
            phase = reduceMotion ? .overview : .peeking
        case .peeking:
            phase = .overview
        case .overview:
            phase = .closed
        }
    }

    public mutating func move(delta: Int) {
        guard phase != .closed, !tabs.isEmpty else { return }
        let count = tabs.count
        selection = ((selection + delta) % count + count) % count
    }

    public mutating func replaceTabs(_ tabs: [Tab]) {
        self.tabs = tabs
        if tabs.isEmpty {
            selection = 0
        } else {
            selection = min(selection, tabs.count - 1)
        }
    }

    public static func badge(_ mark: ProgramMark?) -> String {
        guard let mark else { return "" }
        switch mark.attention {
        case .working: return "working"
        case .blocked: return mark.kind ?? "blocked"
        case .done: return "done"
        case .error: return "error"
        }
    }
}
