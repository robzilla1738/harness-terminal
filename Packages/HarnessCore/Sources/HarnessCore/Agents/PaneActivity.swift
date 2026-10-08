import Foundation

public struct PaneActivity: Codable, Sendable, Equatable {
    public var agent: AgentSnapshot?
    public var mark: ProgramMark?
    public var notification: String?
    public var unread = false
    public var snoozedUntil: Date?
    public var updatedAt = Date()

    public init() {}

    public var rank: AttentionRank {
        AttentionRank.of(
            waiting: notification != nil,
            activity: mark?.fromRealReport == true || agent?.activity == .awaiting ? nil : agent?.activity,
            mark: mark?.attention
        )
    }

    public var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } ?? false }
    public var message: String? { mark?.message ?? notification }
}

public struct PaneAttention: Codable, Sendable, Equatable, Identifiable {
    public var id: SurfaceID { surfaceID }
    public var workspaceID: WorkspaceID
    public var sessionID: SessionID
    public var sessionName: String
    public var tabID: TabID
    public var tabTitle: String
    public var paneID: PaneID
    public var surfaceID: SurfaceID
    public var activity: PaneActivity
}

public extension SessionEditor {
    func listAttention() -> [PaneAttention] {
        var entries: [PaneAttention] = []
        var seen: Set<SurfaceID> = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    for leaf in tab.rootPane.allLeaves() {
                        guard let activity = leaf.activity,
                              activity.agent != nil || activity.mark != nil || activity.notification != nil,
                              seen.insert(leaf.surfaceID).inserted else { continue }
                        entries.append(PaneAttention(
                            workspaceID: workspace.id, sessionID: session.id, sessionName: SessionDisplayName.title(of: session, in: workspace),
                            tabID: tab.id, tabTitle: tab.title, paneID: leaf.id,
                            surfaceID: leaf.surfaceID, activity: activity
                        ))
                    }
                }
            }
        }
        return AttentionRank.sorted(entries, rank: { $0.activity.rank }, lastActivity: { $0.activity.updatedAt })
    }

    @discardableResult
    mutating func updatePaneActivity(surfaceID: SurfaceID, _ update: (inout PaneActivity) -> Void) -> Bool {
        var changed = false
        for wi in snapshot.workspaces.indices {
            for si in snapshot.workspaces[wi].sessions.indices {
                for ti in snapshot.workspaces[wi].sessions[si].tabs.indices {
                    var tab = snapshot.workspaces[wi].sessions[si].tabs[ti]
                    var leafChanged = false
                    tab.rootPane.updateLeaf(surfaceKey: surfaceID.uuidString) { leaf in
                        var activity = leaf.activity ?? PaneActivity()
                        let before = activity
                        update(&activity)
                        guard before != activity else { return }
                        if before.agent != activity.agent || before.mark != activity.mark || before.notification != activity.notification {
                            activity.updatedAt = Date()
                        }
                        leaf.activity = activity
                        leafChanged = true
                    }
                    guard leafChanged else { continue }
                    let activities = tab.rootPane.allLeaves().compactMap(\.activity)
                        .sorted { $0.rank > $1.rank }
                    tab.agent = activities.compactMap(\.agent).first
                    tab.programMark = activities.compactMap(\.mark).first
                    tab.notificationText = activities.compactMap(\.notification).first
                    tab.status = tab.notificationText != nil ? .waiting :
                        (activities.contains { $0.rank == .error } ? .error : .idle)
                    snapshot.workspaces[wi].sessions[si].tabs[ti] = tab
                    changed = true
                }
            }
        }
        if changed {
            snapshot.revision += 1
            snapshot.savedAt = Date()
        }
        return changed
    }
}
