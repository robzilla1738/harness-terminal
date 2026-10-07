import Foundation

public struct Tab: Codable, Sendable, Identifiable, Equatable {
    public var id: TabID
    public var title: String
    public var cwd: String
    public var gitBranch: String?
    public var listeningPorts: [Int]
    public var notificationText: String?
    public var status: TabStatus
    public var rootPane: PaneNode
    public var sortOrder: Int
    public var agent: AgentSnapshot?
    public var zoomedPaneID: PaneID?
    /// The focused pane in this tab. Server-authoritative (schema v3): target-less
    /// commands (`kill-pane`, `split-window`, …) act on it, and every client (GUI +
    /// attach-window compositor) reads it so focus stays consistent across clients.
    public var activePaneID: PaneID?
    /// Most-recently-active pane before `activePaneID`, for `select-pane -l` / `.last`.
    public var lastActivePaneID: PaneID?
    /// Monitoring alerts (Phase 5), set by the daemon when a watched pane produces output
    /// (`activity`), goes silent (`silence`), or rings the bell (`bell`); cleared when the tab
    /// is viewed. Surfaced as `#`/`~`/`!` in `#{window_flags}`.
    public var activity: Bool
    public var silence: Bool
    public var bell: Bool
    /// Non-nil once the pane's process exits while `remain-on-exit` keeps the dead pane.
    public var exitStatus: Int?
    /// Name of the foreground process in this tab's terminal (`#{pane_current_command}`),
    /// refreshed by the daemon's ~1.5s metadata scan — same per-tab simplification as `cwd`
    /// (a split tab reports its most recently probed pane). nil until first probed.
    public var currentCommand: String?
    /// Pin this individual tab to survive a clean GUI quit even when neither the global
    /// `keepSessionsOnQuit` nor its session's `persistent` flag is set. The finest-grained
    /// persistence control: a tab survives iff `keepSessionsOnQuit || session.persistent ||
    /// tab.persistent`. Defaults to unpinned; older snapshots decode to `false`.
    public var persistent: Bool
    /// OSC 7501 attention for this tab, published by the daemon when the presented mark
    /// changes. Nil when the pane is idle. Older snapshots decode this as nil.
    public var programMark: ProgramMark?

    /// The tmux activity/silence/bell portion of `#{window_flags}`.
    public var alertFlags: String {
        (activity ? "#" : "") + (silence ? "~" : "") + (bell ? "!" : "")
    }

    public init(
        id: TabID = UUID(),
        title: String = "Shell",
        cwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        gitBranch: String? = nil,
        listeningPorts: [Int] = [],
        notificationText: String? = nil,
        status: TabStatus = .idle,
        rootPane: PaneNode? = nil,
        sortOrder: Int = 0,
        agent: AgentSnapshot? = nil,
        zoomedPaneID: PaneID? = nil,
        activePaneID: PaneID? = nil,
        lastActivePaneID: PaneID? = nil,
        activity: Bool = false,
        silence: Bool = false,
        bell: Bool = false,
        exitStatus: Int? = nil,
        currentCommand: String? = nil,
        persistent: Bool = false,
        programMark: ProgramMark? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.listeningPorts = listeningPorts
        self.notificationText = notificationText
        self.status = status
        let resolvedRoot = rootPane ?? .leaf(PaneLeaf())
        self.rootPane = resolvedRoot
        self.sortOrder = sortOrder
        self.agent = agent
        self.zoomedPaneID = zoomedPaneID
        // Default focus to the first leaf so a freshly built tab always has a
        // resolvable active pane (target-less commands depend on it).
        self.activePaneID = activePaneID ?? resolvedRoot.allPaneIDs().first
        self.lastActivePaneID = lastActivePaneID
        self.activity = activity
        self.silence = silence
        self.bell = bell
        self.exitStatus = exitStatus
        self.currentCommand = currentCommand
        self.persistent = persistent
        self.programMark = programMark
    }

    public var displaySubtitle: String {
        if let branch = gitBranch, !branch.isEmpty {
            return branch
        }
        if cwd == "/" { return "/" }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        listeningPorts = try container.decodeIfPresent([Int].self, forKey: .listeningPorts) ?? []
        notificationText = try container.decodeIfPresent(String.self, forKey: .notificationText)
        status = try container.decodeIfPresent(TabStatus.self, forKey: .status) ?? .idle
        rootPane = try container.decode(PaneNode.self, forKey: .rootPane)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        agent = try container.decodeIfPresent(AgentSnapshot.self, forKey: .agent)
        zoomedPaneID = try container.decodeIfPresent(PaneID.self, forKey: .zoomedPaneID)
        // v3 fields — absent in v2 layout.json; backfilled to the first leaf so older
        // files load cleanly with a valid focus.
        activePaneID = try container.decodeIfPresent(PaneID.self, forKey: .activePaneID)
            ?? rootPane.allPaneIDs().first
        lastActivePaneID = try container.decodeIfPresent(PaneID.self, forKey: .lastActivePaneID)
        // Monitoring fields — absent in older layout.json; default to no alert.
        activity = try container.decodeIfPresent(Bool.self, forKey: .activity) ?? false
        silence = try container.decodeIfPresent(Bool.self, forKey: .silence) ?? false
        bell = try container.decodeIfPresent(Bool.self, forKey: .bell) ?? false
        exitStatus = try container.decodeIfPresent(Int.self, forKey: .exitStatus)
        // Foreground-command metadata — absent in older layout.json; re-probed within ~1.5s.
        currentCommand = try container.decodeIfPresent(String.self, forKey: .currentCommand)
        // Per-tab persistence pin — absent in older layout.json; default to unpinned.
        persistent = try container.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
        programMark = try container.decodeIfPresent(ProgramMark.self, forKey: .programMark)
    }
}

/// The presented program-status mark for a tab. The decision lives in the engine;
/// this is the value the snapshot carries to the tab, the session row, and the notch.
public struct ProgramMark: Codable, Equatable, Sendable {
    public enum Attention: String, Codable, Sendable {
        case working, blocked, done, error
    }

    public var attention: Attention
    public var kind: String?
    public var message: String?
    public var app: String?
    public var progress: Int?
    /// True when a real OSC 7501 report owns the mark. Detector and OSC 9;4 fills are false.
    public var fromRealReport: Bool

    public init(attention: Attention, kind: String?, message: String?, app: String?, progress: Int?, fromRealReport: Bool) {
        self.attention = attention
        self.kind = kind
        self.message = message
        self.app = app
        self.progress = progress
        self.fromRealReport = fromRealReport
    }
}

/// Tab-chip title. The agent tint is `HarnessSettings.agentColorHex`; the 7501 `app` is appended here.
public enum TabChip {
    public static func title(base: String, app: String?) -> String {
        guard let app, !app.isEmpty else { return base }
        return "\(base) · \(app)"
    }
}
