import Foundation
import HarnessCore

struct HostedAttention: Identifiable, Equatable {
    let owner: String
    let entry: PaneAttention
    let connected: Bool
    var id: String { "\(owner):\(entry.surfaceID)" }
    var hostName: String { owner == DaemonSidebar.localID ? "This Mac" : owner }
}
