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
    /// Pin this session to survive a clean GUI quit even when the global
    /// `keepSessionsOnQuit` is off (Plain mode). A session survives iff
    /// `keepSessionsOnQuit || persistent` — so when keep-on-quit is on (Persistent/Full/Agent,
    /// and every pre-modes install) this flag is moot and everything survives. Defaults to
    /// unpinned; promoting a session sets it. Older snapshots decode to `false`.
    public var persistent: Bool

    public init(
        id: SessionID = UUID(),
        name: String = "",
        tabs: [Tab] = [Tab()],
        activeTabID: TabID? = nil,
        lastActiveTabID: TabID? = nil,
        sortOrder: Int = 0,
        persistent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tabs = tabs.isEmpty ? [Tab()] : tabs
        self.activeTabID = activeTabID ?? self.tabs.first?.id
        self.lastActiveTabID = lastActiveTabID
        self.sortOrder = sortOrder
        self.persistent = persistent
    }

    // Custom decoder so older snapshots (written before `persistent` existed) decode it as
    // `false` instead of failing. Everything else uses the synthesized keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SessionID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let decodedTabs = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        tabs = decodedTabs.isEmpty ? [Tab()] : decodedTabs
        activeTabID = try c.decodeIfPresent(TabID.self, forKey: .activeTabID) ?? tabs.first?.id
        lastActiveTabID = try c.decodeIfPresent(TabID.self, forKey: .lastActiveTabID)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        persistent = try c.decodeIfPresent(Bool.self, forKey: .persistent) ?? false
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
