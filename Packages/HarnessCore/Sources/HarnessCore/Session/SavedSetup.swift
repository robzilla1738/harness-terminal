import Foundation

public struct SetupPane: Codable, Sendable, Equatable {
    public var directory: String
    public var shell: String?
    public var startupCommand: String?
}

public indirect enum SetupLayout: Codable, Sendable, Equatable {
    case pane(SetupPane)
    case split(direction: SplitDirection, ratio: Double, first: SetupLayout, second: SetupLayout)

    public init(_ node: PaneNode, defaultDirectory: String) {
        switch node {
        case let .leaf(leaf):
            self = .pane(SetupPane(directory: leaf.cwd ?? defaultDirectory, shell: leaf.shell))
        case let .branch(direction, ratio, first, second):
            self = .split(direction: direction, ratio: ratio,
                          first: SetupLayout(first, defaultDirectory: defaultDirectory),
                          second: SetupLayout(second, defaultDirectory: defaultDirectory))
        }
    }

    public var panes: [SetupPane] {
        switch self {
        case let .pane(pane): [pane]
        case let .split(_, _, first, second): first.panes + second.panes
        }
    }

    public func makePaneTree() -> PaneNode {
        switch self {
        case let .pane(pane):
            var leaf = PaneLeaf(cwd: pane.directory)
            leaf.shell = pane.shell
            return .leaf(leaf)
        case let .split(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio, first: first.makePaneTree(), second: second.makePaneTree())
        }
    }

    public func validate(depth: Int = 0) throws {
        guard depth < 16 else { throw SetupError.invalid("The layout is too deeply nested.") }
        switch self {
        case let .pane(pane):
            guard pane.directory.hasPrefix("/"), !pane.directory.contains("\0") else {
                throw SetupError.invalid("Each pane needs an absolute directory path on its host.")
            }
            if let shell = pane.shell, !shell.hasPrefix("/") || shell.contains("\0") {
                throw SetupError.invalid("Shells must be absolute executable paths.")
            }
            if let command = pane.startupCommand, command.utf8.count > 16_384 || command.contains("\0") {
                throw SetupError.invalid("A startup command is invalid or too long.")
            }
        case let .split(_, ratio, first, second):
            guard ratio.isFinite, (0.1...0.9).contains(ratio) else { throw SetupError.invalid("Split proportions must be between 10% and 90%.") }
            try first.validate(depth: depth + 1)
            try second.validate(depth: depth + 1)
        }
    }
}

public struct SetupTab: Codable, Sendable, Equatable {
    public var title: String
    public var layout: SetupLayout

    public init(_ tab: Tab) {
        title = tab.title
        layout = SetupLayout(tab.rootPane, defaultDirectory: tab.cwd)
    }
}

public struct SavedSetup: Codable, Sendable, Equatable, Identifiable {
    public var version = 1
    public var id = UUID()
    public var name: String
    public var tabs: [SetupTab]

    public init(name: String, tabs: [SetupTab]) {
        self.name = name
        self.tabs = tabs
    }

    public func validate() throws {
        guard version == 1 else { throw SetupError.invalid("This setup requires a different Harness version.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else {
            throw SetupError.invalid("Choose a setup name of 1–200 characters.")
        }
        guard !tabs.isEmpty, tabs.count <= 32 else { throw SetupError.invalid("A setup must contain 1–32 tabs.") }
        for tab in tabs { try tab.layout.validate() }
        guard tabs.reduce(0, { $0 + $1.layout.panes.count }) <= 64 else { throw SetupError.invalid("A setup can contain up to 64 panes.") }
    }
}

public enum SetupError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { message } else { nil } }
}

public struct ClosedLayout: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case pane, tab, session }
    public var id = UUID()
    public var closedAt = Date()
    public var kind: Kind
    public var sessionID: SessionID
    public var setup: SavedSetup

    public init(kind: Kind, sessionID: SessionID, setup: SavedSetup) {
        self.kind = kind
        self.sessionID = sessionID
        self.setup = setup
    }
}

public struct SessionLibrary: Codable, Sendable, Equatable {
    public var setups: [SavedSetup] = []
    public var recentlyClosed: [ClosedLayout] = []
    public init() {}
}

public enum SetupOpenMode: String, Codable, Sendable { case existing, newCopy }

public enum LibraryOperation: Codable, Sendable {
    case list
    case capture(sessionID: SessionID, name: String)
    case save(SavedSetup, sourceSessionID: SessionID? = nil)
    case deleteSetup(UUID)
    case open(UUID, mode: SetupOpenMode)
    case restoreClosed(UUID)
    case deleteClosed(UUID?)
}
