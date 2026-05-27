import Foundation

public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public var id: WorkspaceID
    public var name: String
    public var sessions: [SessionGroup]
    public var activeSessionID: SessionID?
    public var sortOrder: Int

    public init(
        id: WorkspaceID = UUID(),
        name: String = "Default",
        sessions: [SessionGroup] = [SessionGroup()],
        activeSessionID: SessionID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sessions = sessions.isEmpty ? [SessionGroup()] : sessions
        self.activeSessionID = activeSessionID ?? self.sessions.first?.id
        self.sortOrder = sortOrder
    }

    public var activeSession: SessionGroup? {
        guard let activeSessionID else { return sessions.first }
        return sessions.first { $0.id == activeSessionID } ?? sessions.first
    }

    public var tabs: [Tab] {
        activeSession?.tabs ?? []
    }

    public var activeTabID: TabID? {
        activeSession?.activeTabID
    }

    public var activeTab: Tab? {
        activeSession?.activeTab
    }

    public mutating func setActiveSession(_ sessionID: SessionID) {
        activeSessionID = sessionID
    }

    public mutating func setActiveTab(_ tabID: TabID) {
        for index in sessions.indices {
            guard sessions[index].tabs.contains(where: { $0.id == tabID }) else { continue }
            sessions[index].activeTabID = tabID
            activeSessionID = sessions[index].id
            return
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sessions
        case activeSessionID
        case tabs
        case activeTabID
        case sortOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(WorkspaceID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0

        if let decodedSessions = try container.decodeIfPresent([SessionGroup].self, forKey: .sessions) {
            sessions = decodedSessions.isEmpty ? [SessionGroup()] : decodedSessions
            activeSessionID = try container.decodeIfPresent(SessionID.self, forKey: .activeSessionID) ?? sessions.first?.id
            return
        }

        let legacyTabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) ?? [Tab()]
        let activeTabID = try container.decodeIfPresent(TabID.self, forKey: .activeTabID)
        sessions = legacyTabs.enumerated().map { index, tab in
            SessionGroup(
                name: "",
                tabs: [tab],
                activeTabID: tab.id,
                sortOrder: index
            )
        }
        if sessions.isEmpty {
            sessions = [SessionGroup()]
        }
        if let activeTabID,
           let match = sessions.first(where: { session in session.tabs.contains(where: { $0.id == activeTabID }) })
        {
            activeSessionID = match.id
        } else {
            activeSessionID = sessions.first?.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(activeSessionID, forKey: .activeSessionID)
        try container.encode(sortOrder, forKey: .sortOrder)
    }

}
