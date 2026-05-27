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
        zoomedPaneID: PaneID? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.listeningPorts = listeningPorts
        self.notificationText = notificationText
        self.status = status
        self.rootPane = rootPane ?? .leaf(PaneLeaf())
        self.sortOrder = sortOrder
        self.agent = agent
        self.zoomedPaneID = zoomedPaneID
    }

    public var displaySubtitle: String {
        if let branch = gitBranch, !branch.isEmpty {
            return branch
        }
        return (cwd as NSString).lastPathComponent
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
    }
}
