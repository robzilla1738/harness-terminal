import Foundation

public struct SessionGroup: Codable, Sendable, Identifiable, Equatable {
    public var id: SessionID
    public var name: String
    public var tabs: [Tab]
    public var activeTabID: TabID?
    /// Previously-active tab, for `last-window` / `select-window -l`. Optional, so
    /// older snapshots (without the key) decode via synthesized Codable to nil.
    public var lastActiveTabID: TabID?
    public var sortOrder: Int

    public init(
        id: SessionID = UUID(),
        name: String = "",
        tabs: [Tab] = [Tab()],
        activeTabID: TabID? = nil,
        lastActiveTabID: TabID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs.isEmpty ? [Tab()] : tabs
        self.activeTabID = activeTabID ?? self.tabs.first?.id
        self.lastActiveTabID = lastActiveTabID
        self.sortOrder = sortOrder
    }

    public var activeTab: Tab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    public mutating func setActiveTab(_ tabID: TabID) {
        if let current = activeTabID, current != tabID { lastActiveTabID = current }
        activeTabID = tabID
    }
}
