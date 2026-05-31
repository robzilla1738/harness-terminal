import Foundation

/// A flattened, machine-readable view of one running agent and the
/// workspace/session/tab/pane it lives in. Built by `SessionEditor.listAgents()`
/// from the agent state the daemon already maintains (`Tab.agent`, kept fresh by
/// `AgentScanner`, and `Tab.status == .waiting`, set by the notification path).
///
/// This is the wire shape returned by the `list-agents` daemon request and
/// rendered (text + JSON) by `AgentListFormatter`. Keep the field names stable —
/// they are part of the `--json` contract.
public struct AgentSessionSummary: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity for the row: the backing surface id (one agent per tab,
    /// surfaced through the tab's active/representative pane).
    public var id: String { surfaceID }

    public var workspaceName: String
    public var sessionID: UUID
    public var sessionName: String
    public var tabID: UUID
    public var tabTitle: String
    /// The tab's active (or first) pane and its surface — the "surface id" a
    /// caller would `attach`/`send-keys`/`capture-pane` against.
    public var surfaceID: String
    public var paneID: String?

    public var kind: AgentKind
    /// Human-readable agent name (`kind.displayName`), stored so JSON consumers
    /// don't have to map the `kind` enum themselves.
    public var agentName: String
    public var activity: AgentActivity
    /// The agent is blocking on you: `Tab.status == .waiting` (set by the
    /// notification/hook path). Distinct from `activity` — an agent can be
    /// `working` and not yet waiting, or `idle` and waiting.
    public var waiting: Bool
    public var lastActivityAt: Date
    /// The most recent notification body, when the tab is waiting.
    public var notificationText: String?

    public init(
        workspaceName: String,
        sessionID: UUID,
        sessionName: String,
        tabID: UUID,
        tabTitle: String,
        surfaceID: String,
        paneID: String?,
        kind: AgentKind,
        activity: AgentActivity,
        waiting: Bool,
        lastActivityAt: Date,
        notificationText: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.kind = kind
        self.agentName = kind.displayName
        self.activity = activity
        self.waiting = waiting
        self.lastActivityAt = lastActivityAt
        self.notificationText = notificationText
    }
}
