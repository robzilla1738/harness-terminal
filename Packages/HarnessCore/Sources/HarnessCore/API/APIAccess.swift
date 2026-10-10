import Foundation

public enum APIExposure: String, Codable, Sendable, CaseIterable {
    case cli, lua, mobile, mcp
}
public enum APIEffect: String, Codable, Sendable { case read, write }

public struct APIAccess: Codable, Equatable, Sendable {
    public var effect: APIEffect
    public var exposures: Set<APIExposure>
    public var capabilities: Set<String>
    public init(effect: APIEffect, exposures: Set<APIExposure>, capabilities: Set<String> = []) {
        self.effect = effect; self.exposures = exposures; self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey { case effect, exposures, capabilities }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(effect, forKey: .effect)
        try values.encode(exposures.map(\.rawValue).sorted(), forKey: .exposures)
        try values.encode(capabilities.sorted(), forKey: .capabilities)
    }

    /// Existing methods are deliberately enumerated. New methods default to local CLI only.
    public static func existing(_ name: String) -> APIAccess {
        switch name {
        case "notification.status":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.notificationPolicy])
        case "notification.configure", "agent.mute":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.notificationPolicy])
        case "power.status":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.powerManagement])
        case "power.mode", "power.configure":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.powerManagement])
        case "pane.explain":
            return .init(effect: .write, exposures: [.cli, .lua], capabilities: [DaemonStats.commandOutput])
        case "pane.command_output":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.commandOutput])
        case "pane.resume_policy":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.automaticResume])
        case "pane.resume":
            return .init(effect: .write, exposures: [.cli, .lua], capabilities: [DaemonStats.paneResume])
        case "profile.list":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.activityProfiles])
        case "profile.configure":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.activityProfiles])
        case "history.recover":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.historyRecovery])
        case "pane.preview":
            return .init(effect: .write, exposures: [.cli, .lua], capabilities: [DaemonStats.paneContent])
        case "pane.resources":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.paneResources])
        case "pane.kill_tree":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.paneResources])
        case "digest.repositories":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.repositoryDigest])
        case "usage.summary", "digest.get":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.usageDigest])
        case "agent.list", "agent.session":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.activityHistory])
        case "daemon-replace":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.sessionHost])
        case "server.version", "session.list", "session.view", "client.list", "pane.capture",
             "pane.process", "pane.pwd", "pane.list_dir", "pane.title", "pane.size",
             "pane.program_status", "pane.wait", "pane.view":
            return .init(effect: .read, exposures: Set(APIExposure.allCases))
        case "pane.search_paths":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.pathSearch])
        case "policy.audit":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.hookPolicy])
        case "summary.status", "summary.catalog", "summary.record", "summary.history":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.aiSummaries])
        case "summary.configure", "summary.models", "summary.generate", "summary.cancel":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.aiSummaries])
        case "schedule.list", "schedule.occurrences":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.schedules])
        case "schedule.save", "schedule.delete", "schedule.cancel":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.schedules])
        case "fanout.list":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.fanout])
        case "fanout.start", "fanout.inspect", "fanout.cancel", "fanout.compare", "fanout.cleanup", "fanout.test":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.fanout])
        case "worktree.list", "worktree.compare", "worktree.difftool":
            return .init(effect: .read, exposures: [.cli], capabilities: [DaemonStats.managedWorktrees])
        case "worktree.create", "worktree.configure", "worktree.remove", "worktree.inspect":
            return .init(effect: .write, exposures: [.cli], capabilities: [DaemonStats.managedWorktrees])
        case "output.search_filtered":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.filteredOutputSearch])
        case "output.search":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.outputSearch])
        case "setup.list":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.sessionLibrary])
        case "attention.list":
            return .init(effect: .read, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.paneAttention])
        case "attention.read", "attention.snooze":
            return .init(effect: .write, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.paneAttention])
        case "setup.capture", "setup.save", "setup.open", "setup.delete", "closed.restore", "closed.delete":
            return .init(effect: .write, exposures: Set(APIExposure.allCases), capabilities: [DaemonStats.sessionLibrary])
        case "pane.split", "session.create", "client.disconnect", "pane.zoom", "pane.focus",
             "pane.label", "pane.close", "pane.write", "pane.send_key", "pane.reset", "pane.swap",
             "pane.move", "pane.detach", "pane.resize", "pane.focus_direction", "tab.create",
             "tab.label", "tab.close", "tab.move", "tab.focus", "session.label":
            return .init(effect: .write, exposures: Set(APIExposure.allCases))
        case "pane.theme":
            return .init(effect: .write, exposures: [.cli, .lua])
        default:
            return .init(effect: .write, exposures: [.cli])
        }
    }
}
