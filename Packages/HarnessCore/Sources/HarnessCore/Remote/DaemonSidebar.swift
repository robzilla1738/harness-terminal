import Foundation

/// One session row in the multi-daemon sidebar. `owner` is `DaemonSidebar.localID`
/// or the remote host name. Sessions sit under the machine that owns them.
public struct DaemonSidebarSession: Equatable, Sendable {
    public var id: String
    public var name: String
    public var owner: String

    public init(id: String, name: String, owner: String) {
        self.id = id
        self.name = name
        self.owner = owner
    }
}

public struct DaemonSidebarGroup: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var local: Bool
    public var sessions: [DaemonSidebarSession]

    public init(id: String, title: String, detail: String, local: Bool, sessions: [DaemonSidebarSession]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.local = local
        self.sessions = sessions
    }
}

/// Groups sessions by the daemon that owns them. Local is always one group.
/// A split of a session runs on that session's daemon (`splitDaemon`).
public enum DaemonSidebar {
    public static let localID = "local"

    public static func groups(
        localTitle: String,
        sessions: [DaemonSidebarSession],
        remoteHosts: [String],
        remoteDetail: String
    ) -> [DaemonSidebarGroup] {
        let rows = sessions.map { session -> DaemonSidebarSession in
            guard session.owner.isEmpty else { return session }
            return DaemonSidebarSession(id: session.id, name: session.name, owner: localID)
        }
        var owners = [localID]
        for host in remoteHosts where host != localID && !owners.contains(host) {
            owners.append(host)
        }
        for row in rows where !owners.contains(row.owner) {
            owners.append(row.owner)
        }
        return owners.map { owner in
            let local = owner == localID
            return DaemonSidebarGroup(
                id: owner,
                title: local ? localTitle : owner,
                detail: local ? "" : remoteDetail,
                local: local,
                sessions: rows.filter { $0.owner == owner }
            )
        }
    }

    /// The daemon a split of this session must run on. The attach is still the
    /// existing SSH-tunneled framed socket; this only picks which one.
    public static func splitDaemon(owner: String) -> String {
        owner.isEmpty ? localID : owner
    }
}
