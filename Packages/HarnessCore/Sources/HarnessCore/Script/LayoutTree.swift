import Foundation

/// One node of a `session.create` / `pane.split` layout tree.
public struct APILayoutNode: Equatable, Sendable {
    public var direction: String?
    public var ratio: Double?
    public var command: String?
    public var cwd: String?
    public var shell: String?
    public var input: String?
    public var keepOpen: Bool
    public var children: [APILayoutNode]

    public init(
        direction: String? = nil,
        ratio: Double? = nil,
        command: String? = nil,
        cwd: String? = nil,
        shell: String? = nil,
        input: String? = nil,
        keepOpen: Bool = false,
        children: [APILayoutNode] = []
    ) {
        self.direction = direction
        self.ratio = ratio
        self.command = command
        self.cwd = cwd
        self.shell = shell
        self.input = input
        self.keepOpen = keepOpen
        self.children = children
    }
}

public struct APILayoutSplit: Equatable, Sendable {
    public var direction: String
    public var ratio: Double

    public init(direction: String, ratio: Double) {
        self.direction = direction
        self.ratio = ratio
    }
}

public struct APILayoutLeaf: Equatable, Sendable {
    public var command: String?
    public var cwd: String?
    public var shell: String?
    public var input: String?
    public var keepOpen: Bool
    /// Splits applied to reach this leaf. The first leaf has none; it is the pane that already exists.
    public var splits: [APILayoutSplit]

    public init(command: String?, cwd: String?, shell: String?, input: String?, keepOpen: Bool, splits: [APILayoutSplit]) {
        self.command = command
        self.cwd = cwd
        self.shell = shell
        self.input = input
        self.keepOpen = keepOpen
        self.splits = splits
    }
}

public struct LayoutParseError: Error, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public enum LayoutTree {
    public static func parse(_ argument: APIArgument) -> Result<APILayoutNode, LayoutParseError> {
        parseNode(argument, path: "layout")
    }

    public static func leaves(_ node: APILayoutNode) -> [APILayoutLeaf] {
        var out: [APILayoutLeaf] = []
        walk(node, splits: [], into: &out)
        return out
    }

    private static func walk(_ node: APILayoutNode, splits: [APILayoutSplit], into out: inout [APILayoutLeaf]) {
        if node.children.isEmpty {
            out.append(APILayoutLeaf(
                command: node.command, cwd: node.cwd, shell: node.shell,
                input: node.input, keepOpen: node.keepOpen, splits: splits
            ))
            return
        }
        let direction = node.direction ?? "vertical"
        let ratio = node.ratio ?? 0.5
        for (index, child) in node.children.enumerated() {
            let next = index == 0 ? splits : splits + [APILayoutSplit(direction: direction, ratio: ratio)]
            walk(child, splits: next, into: &out)
        }
    }

    private static func parseNode(_ argument: APIArgument, path: String) -> Result<APILayoutNode, LayoutParseError> {
        guard case let .object(fields) = argument else { return .failure(LayoutParseError("\(path) must be an object")) }
        var direction = fields["direction"]?.string ?? fields["split"]?.string
        if let direction, direction != "horizontal", direction != "vertical" {
            return .failure(LayoutParseError("\(path) direction must be horizontal or vertical"))
        }
        var ratio: Double?
        if let value = fields["ratio"]?.double {
            guard value >= 0, value <= 1 else { return .failure(LayoutParseError("\(path) ratio must be from 0 to 1")) }
            ratio = value
        }
        if fields["children"] != nil, direction == nil { direction = "vertical" }
        var children: [APILayoutNode] = []
        if let raw = fields["children"] {
            guard case let .array(items) = raw else { return .failure(LayoutParseError("\(path) children must be an array")) }
            for (index, item) in items.enumerated() {
                switch parseNode(item, path: "\(path).children[\(index)]") {
                case let .success(child): children.append(child)
                case let .failure(message): return .failure(message)
                }
            }
        }
        let keep = fields["keep-open"]?.bool ?? fields["keepOpen"]?.bool ?? false
        return .success(APILayoutNode(
            direction: direction,
            ratio: ratio,
            command: fields["command"]?.string,
            cwd: fields["cwd"]?.string,
            shell: fields["shell"]?.string,
            input: fields["input"]?.string ?? fields["initial"]?.string,
            keepOpen: keep,
            children: children
        ))
    }
}

/// Turns a parsed layout into the session and split requests the daemon already runs.
public enum APILayoutApply {
    public static func createSession(
        name: String?,
        layout: APILayoutNode?,
        workspaceID: UUID,
        perform: (IPCRequest) throws -> IPCResponse
    ) throws -> String {
        let leaves = layout.map(LayoutTree.leaves) ?? []
        let first = leaves.first
        guard case let .sessionID(sessionID) = try perform(.newSession(
            workspaceID: workspaceID,
            cwd: first?.cwd,
            name: name,
            shell: executable(first?.shell ?? first?.command)
        )) else { throw LayoutApplyError.noSession }
        guard case let .snapshot(snapshot) = try perform(.getSnapshot),
              let session = snapshot.workspaces.flatMap(\.sessions).first(where: { $0.id == sessionID }),
              let tab = session.tabs.first,
              let rootPane = tab.rootPane.paneID,
              let rootSurface = tab.rootPane.surfaceID?.uuidString
        else { throw LayoutApplyError.noTab }
        try send(first?.input, surface: rootSurface, perform: perform)
        try grow(leaves: Array(leaves.dropFirst()), tabID: tab.id, root: rootPane, rootSplits: [], perform: perform)
        return sessionID.uuidString
    }

    /// The first leaf is the pane that already exists. Later leaves are splits off it.
    public static func split(
        tabID: UUID,
        paneID: UUID,
        layout: APILayoutNode,
        perform: (IPCRequest) throws -> IPCResponse
    ) throws -> String {
        let leaves = LayoutTree.leaves(layout)
        let created = try grow(leaves: Array(leaves.dropFirst()), tabID: tabID, root: paneID, rootSplits: [], perform: perform)
        return created ?? paneID.uuidString
    }

    @discardableResult
    private static func grow(
        leaves: [APILayoutLeaf],
        tabID: UUID,
        root: UUID,
        rootSplits: [APILayoutSplit],
        perform: (IPCRequest) throws -> IPCResponse
    ) throws -> String? {
        var created: [(id: UUID, splits: [APILayoutSplit])] = [(root, rootSplits)]
        var last: String?
        for leaf in leaves {
            let parentSplits = Array(leaf.splits.dropLast())
            guard let parent = created.last(where: { $0.splits == parentSplits }),
                  let split = leaf.splits.last,
                  let direction = SplitDirection(rawValue: split.direction)
            else { throw LayoutApplyError.splitFailed }
            guard case let .paneID(newPane) = try perform(.newSplit(
                tabID: tabID,
                paneID: parent.id,
                direction: direction,
                shell: executable(leaf.shell ?? leaf.command),
                cwd: leaf.cwd
            )) else { throw LayoutApplyError.splitFailed }
            guard case let .snapshot(after) = try perform(.getSnapshot),
                  let tab = after.workspaces.flatMap(\.sessions).flatMap(\.tabs).first(where: { $0.id == tabID }),
                  let surface = surfaceID(pane: newPane, in: tab.rootPane)
            else { throw LayoutApplyError.noSurface }
            _ = try perform(.resizePaneRatio(
                tabID: tabID, firstPaneID: parent.id, secondPaneID: newPane, ratio: split.ratio
            ))
            try send(leaf.input, surface: surface, perform: perform)
            created.append((newPane, leaf.splits))
            last = newPane.uuidString
        }
        return last
    }

    private static func send(_ text: String?, surface: String, perform: (IPCRequest) throws -> IPCResponse) throws {
        guard let text, !text.isEmpty else { return }
        _ = try perform(.send(surfaceID: surface, text: text))
    }

    private static func executable(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw == "false" ? "/usr/bin/false" : raw
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
