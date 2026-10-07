import Foundation

/// Where a command runs from. Inside a pane on this daemon that is the caller's own pane
/// (`HARNESS_SURFACE`, else `HARNESS_TAB`, else `HARNESS_SESSION`); otherwise it is what the
/// window is showing. An omitted target defaults to it, and a 1-based position counts
/// through its workspace's sessions, its session's tabs, and its tab's panes.
public struct TargetContext: Equatable, Sendable {
    public var workspace: Workspace?
    public var session: SessionGroup?
    public var tab: Tab?
    public var pane: PaneLeaf?

    public init(workspace: Workspace? = nil, session: SessionGroup? = nil, tab: Tab? = nil, pane: PaneLeaf? = nil) {
        self.workspace = workspace
        self.session = session
        self.tab = tab
        self.pane = pane
    }

    /// `environment` is the caller's `HARNESS_*` variables, or nil when they don't describe
    /// this daemon (`--host` reaches another machine).
    public static func current(in snapshot: SessionSnapshot, environment: [String: String]?) -> TargetContext {
        let env = environment ?? [:]
        func matches(_ id: UUID, _ key: String) -> Bool {
            env[key].map { id.uuidString.caseInsensitiveCompare($0) == .orderedSame } ?? false
        }
        if let surface = env["HARNESS_SURFACE"], let here = of(surface: surface, in: snapshot) {
            return here
        }
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                if let tab = session.tabs.first(where: { matches($0.id, "HARNESS_TAB") }) {
                    return TargetContext(workspace: workspace, session: session, tab: tab, pane: tab.activeLeaf)
                }
                if matches(session.id, "HARNESS_SESSION") {
                    return within(workspace, session)
                }
            }
        }
        guard let workspace = snapshot.activeWorkspace ?? snapshot.workspaces.first else { return TargetContext() }
        guard let session = workspace.sessions.first(where: { $0.id == workspace.activeSessionID }) ?? workspace.sessions.first else {
            return TargetContext(workspace: workspace)
        }
        return within(workspace, session)
    }

    /// The context of the pane showing `surface` (a surface or pane id), if it exists.
    public static func of(surface: String, in snapshot: SessionSnapshot) -> TargetContext? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    let leaf = tab.rootPane.allLeaves().first { leaf in
                        [leaf.surfaceID, leaf.id].contains { $0.uuidString.caseInsensitiveCompare(surface) == .orderedSame }
                    }
                    if let leaf { return TargetContext(workspace: workspace, session: session, tab: tab, pane: leaf) }
                }
            }
        }
        return nil
    }

    private static func within(_ workspace: Workspace, _ session: SessionGroup) -> TargetContext {
        let tab = session.activeTab ?? session.tabs.first
        return TargetContext(workspace: workspace, session: session, tab: tab, pane: tab?.activeLeaf)
    }
}

extension Tab {
    /// The focused pane, else the first.
    var activeLeaf: PaneLeaf? {
        let leaves = rootPane.allLeaves()
        return leaves.first { $0.id == activePaneID } ?? leaves.first
    }
}

/// The argument rewriting `harness-cli` does before a command sees its flags.
public enum CLIArguments {
    /// Rex-style short target flags. A command whose own tmux flags use the same letter keeps
    /// them: `set-option -s` is a scope, `capture-pane -S` a start line, `wait-for -S` a signal.
    static let shortFlags: [String: String] = ["-s": "--session", "-w": "--tab", "-b": "--pane", "-S": "--host"]
    static let ownsShortFlags: [String: Set<String>] = [
        "set-option": ["-s", "-w"], "setw": ["-s", "-w"], "set-window-option": ["-s", "-w"],
        "show-options": ["-s", "-w"], "set-environment": ["-s", "-w"], "setenv": ["-s", "-w"],
        "show-environment": ["-s", "-w"], "showenv": ["-s", "-w"],
        "capture-pane": ["-S"], "wait-for": ["-S"], "wait": ["-S"],
    ]
    /// Flags whose value is free text, so a `-s` after them is data, not a flag.
    static let textFlags: Set<String> = ["--text", "--keys", "--args", "--title", "--body", "--message", "--name", "-e"]

    /// Short target flags become long ones, and `inspect <target>` becomes `inspect --surface
    /// <target>`, so target resolution only ever sees long flags.
    public static func normalize(_ args: [String], command: String) -> [String] {
        let owned = ownsShortFlags[command] ?? []
        let end = args.firstIndex(of: "--") ?? args.count
        var out = args
        for index in 1..<max(end, 1) {
            guard let long = shortFlags[args[index]], !owned.contains(args[index]), !textFlags.contains(args[index - 1]) else { continue }
            out[index] = long
        }
        if command == "inspect", !out.contains(where: { ["--surface", "--pane", "--session"].contains($0) }),
           let index = out.indices.dropFirst().first(where: { !out[$0].hasPrefix("-") && out[$0 - 1] != "--host" }) {
            out.insert("--surface", at: index)
        }
        return out
    }

    /// Commands that act on one surface, and ones that act on one pane. Either flag works for
    /// both (a pane and its surface name the same terminal); with neither, the context's pane.
    static let surfaceCommands: Set<String> = [
        "send", "send-keys", "capture-pane", "pipe-pane", "respawn-pane", "clear-history", "clearhist",
        "copy-mode", "process", "notify", "inspect",
    ]
    static let paneCommands: Set<String> = ["kill-pane", "zoom-pane", "break-pane", "select-pane", "resize-pane"]

    public static func needsDefaultTarget(_ command: String) -> Bool {
        surfaceCommands.contains(command) || paneCommands.contains(command)
    }

    /// Adds the `--surface` or `--pane` a command needs when the caller left it out. Expects
    /// target flags already resolved to full ids.
    public static func withDefaultTarget(_ args: [String], command: String, snapshot: SessionSnapshot, context: TargetContext) -> [String] {
        guard needsDefaultTarget(command) else { return args }
        let wantsSurface = surfaceCommands.contains(command)
        let end = args.firstIndex(of: "--") ?? args.count
        func value(_ flag: String) -> String? {
            guard let index = args[..<end].firstIndex(of: flag), index + 1 < end else { return nil }
            return args[index + 1]
        }
        let flag = wantsSurface ? "--surface" : "--pane"
        guard value(flag) == nil else { return args }
        // `inspect` names a session as readily as a pane.
        if command == "inspect", value("--session") != nil { return args }
        let named = value(wantsSurface ? "--pane" : "--surface")
        guard let leaf = named.map({ TargetContext.of(surface: $0, in: snapshot)?.pane }) ?? context.pane else { return args }
        var out = args
        out.insert(contentsOf: [flag, wantsSurface ? leaf.surfaceID.uuidString : leaf.id.uuidString], at: 1)
        return out
    }
}
