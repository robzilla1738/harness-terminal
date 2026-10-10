import Foundation

extension IPCRequest {
    /// Administrative/configuration controls are local even when forwarded by
    /// the stable owner. This is independent of API tool exposure metadata.
    public var requiresLocalOwner: Bool {
        switch self {
        case .handoverDaemon, .replaceDaemon, .shutdownDaemon, .retryHistory,
             .activity(.hook), .activity(.resumePolicy), .activity(.resume), .activity(.explain),
             .activity(.power), .activity(.notifications), .activity(.terminateTree), .activity(.configure),
             .activity(.aiSummaries), .activity(.hookPolicy), .activity(.schedules), .activity(.fanout), .activity(.worktrees): true
        default: false
        }
    }
}
