import Foundation

/// A saved split tree: each leaf is a program and the directory it starts in.
public enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(program: String, cwd: String)
    indirect case split(direction: SplitDirection, ratio: Double, first: LayoutNode, second: LayoutNode)

    public var programs: [(program: String, cwd: String)] {
        switch self {
        case let .leaf(program, cwd):
            [(program, cwd)]
        case let .split(_, _, first, second):
            first.programs + second.programs
        }
    }
}

public struct NamedLayout: Codable, Equatable, Sendable {
    public var name: String
    public var tree: LayoutNode

    public init(name: String, tree: LayoutNode) {
        self.name = name
        self.tree = tree
    }
}

public enum LayoutAction: Equatable, Sendable {
    /// The first pane: create the session in this directory, running this program.
    case session(name: String, cwd: String, program: String)
    /// Create the next pane by splitting `target`, the index of an earlier pane
    /// (0 is the session). The direction and ratio are the branch this split creates,
    /// not a direction inherited from a nested child.
    case split(target: Int, direction: SplitDirection, ratio: Double, cwd: String, program: String)
}

public enum LayoutApplyError: Error, Equatable {
    case noSession
    case noTab
    case splitFailed
    case noSurface
}

/// Turns a saved layout into the IPC the daemon already understands: a session,
/// a split per later pane (with that pane's directory), a command in that pane,
/// and the saved split ratio. The CLI calls this and performs each request.
public enum LayoutApplication {
    public static func apply(
        plan: [LayoutAction],
        workspaceID: UUID,
        perform: (IPCRequest) throws -> IPCResponse
    ) throws {
        guard case let .session(name, cwd, program) = plan.first else { return }
        guard case let .sessionID(sessionID) = try perform(
            .newSession(workspaceID: workspaceID, cwd: cwd, name: name, shell: nil)
        ) else { throw LayoutApplyError.noSession }
        guard case let .snapshot(snapshot) = try perform(.getSnapshot),
              let session = snapshot.workspaces.flatMap(\.sessions).first(where: { $0.id == sessionID }),
              let tab = session.tabs.first,
              let rootPane = tab.rootPane.paneID,
              let rootSurface = tab.rootPane.surfaceID?.uuidString
        else { throw LayoutApplyError.noTab }
        if program != "shell" {
            _ = try perform(.send(surfaceID: rootSurface, text: program + "\n"))
        }
        var paneIDs = [rootPane]
        for action in plan.dropFirst() {
            guard case let .split(target, direction, ratio, cwd, program) = action else { continue }
            guard paneIDs.indices.contains(target) else { throw LayoutApplyError.splitFailed }
            let targetPane = paneIDs[target]
            guard case let .paneID(newPane) = try perform(
                .newSplit(tabID: tab.id, paneID: targetPane, direction: direction, shell: nil, cwd: cwd)
            ) else { throw LayoutApplyError.splitFailed }
            guard case let .snapshot(after) = try perform(.getSnapshot),
                  let tabAfter = after.workspaces.flatMap(\.sessions).flatMap(\.tabs).first(where: { $0.id == tab.id }),
                  let surface = surfaceID(pane: newPane, in: tabAfter.rootPane)
            else { throw LayoutApplyError.noSurface }
            if program != "shell" {
                _ = try perform(.send(surfaceID: surface, text: program + "\n"))
            }
            _ = try perform(.resizePaneRatio(
                tabID: tab.id,
                firstPaneID: targetPane,
                secondPaneID: newPane,
                ratio: ratio
            ))
            paneIDs.append(newPane)
        }
    }

    private static func surfaceID(pane: UUID, in node: PaneNode) -> String? {
        switch node {
        case let .leaf(leaf) where leaf.id == pane:
            return leaf.surfaceID.uuidString
        case let .branch(_, _, first, second):
            return surfaceID(pane: pane, in: first) ?? surfaceID(pane: pane, in: second)
        default:
            return nil
        }
    }
}

public enum NamedLayoutStore {
    public static func capture(
        name: String,
        tab: Tab,
        programs: [String: String] = [:],
        cwds: [String: String] = [:]
    ) -> NamedLayout {
        NamedLayout(
            name: name,
            tree: node(tab.rootPane, cwd: tab.cwd, command: tab.currentCommand, programs: programs, cwds: cwds)
        )
    }

    public static func save(_ layout: NamedLayout, directory: URL) throws {
        let url = fileURL(name: layout.name, directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(layout)
        try data.write(to: url, options: .atomic)
    }

    public static func load(name: String, directory: URL) throws -> NamedLayout {
        let data = try Data(contentsOf: fileURL(name: name, directory: directory))
        return try JSONDecoder().decode(NamedLayout.self, from: data)
    }

    /// Steps the CLI and the app both run to recreate the layout. The first leaf
    /// opens the session. Each later split carries the direction and ratio of the
    /// branch it creates, and the index of the pane that branch splits.
    public static func restorePlan(_ layout: NamedLayout) -> [LayoutAction] {
        guard let root = firstLeaf(layout.tree) else { return [] }
        var actions = [LayoutAction.session(name: layout.name, cwd: root.cwd, program: root.program)]
        var nextIndex = 1
        func build(_ node: LayoutNode, at index: Int) {
            guard case let .split(direction, ratio, first, second) = node else { return }
            guard let marker = firstLeaf(second) else { return }
            let secondIndex = nextIndex
            nextIndex += 1
            actions.append(.split(
                target: index,
                direction: direction,
                ratio: ratio,
                cwd: marker.cwd,
                program: marker.program
            ))
            build(first, at: index)
            build(second, at: secondIndex)
        }
        build(layout.tree, at: 0)
        return actions
    }

    private static func firstLeaf(_ node: LayoutNode) -> (program: String, cwd: String)? {
        switch node {
        case let .leaf(program, cwd):
            (program, cwd)
        case let .split(_, _, first, _):
            firstLeaf(first)
        }
    }

    public static func fileURL(name: String, directory: URL) -> URL {
        let safe = name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let stem = String(safe).isEmpty ? "layout" : String(safe)
        return directory.appendingPathComponent("\(stem).json")
    }

    private static func node(
        _ pane: PaneNode,
        cwd: String,
        command: String?,
        programs: [String: String],
        cwds: [String: String]
    ) -> LayoutNode {
        switch pane {
        case let .leaf(leaf):
            let program = programs[leaf.surfaceID.uuidString]
                ?? programs[leaf.id.uuidString]
                ?? command
                ?? "shell"
            let directory = cwds[leaf.surfaceID.uuidString]
                ?? cwds[leaf.id.uuidString]
                ?? cwd
            return .leaf(program: program, cwd: directory)
        case let .branch(direction, ratio, first, second):
            return .split(
                direction: direction,
                ratio: ratio,
                first: node(first, cwd: cwd, command: command, programs: programs, cwds: cwds),
                second: node(second, cwd: cwd, command: command, programs: programs, cwds: cwds)
            )
        }
    }
}
