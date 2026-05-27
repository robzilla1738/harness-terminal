import Foundation

public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public var id: WorkspaceID
    public var name: String
    public var tabs: [Tab]
    public var activeTabID: TabID?
    public var sortOrder: Int

    public init(
        id: WorkspaceID = UUID(),
        name: String = "Default",
        tabs: [Tab] = [Tab()],
        activeTabID: TabID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
        self.sortOrder = sortOrder
    }

    public var activeTab: Tab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    public mutating func setActiveTab(_ tabID: TabID) {
        activeTabID = tabID
    }
}
