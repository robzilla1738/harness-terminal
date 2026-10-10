import Foundation

/// Project response enums only; canonical observations and authority remain intact.
public enum ActivityResponseCompatibility {
    private static func modern(_ capabilities: [String]?) -> Bool { capabilities?.contains(DaemonStats.activityState) == true }
    public static func run(_ value: AgentRun, capabilities: [String]?) -> AgentRun {
        var result = value
        result.provider = value.provider.projected(for: capabilities ?? [])
        guard !modern(capabilities) else { return result }
        if result.source == .launch { result.source = .process }
        if result.profileSource == .launch { result.profileSource = .process }
        if result.directorySource == .launch { result.directorySource = .process }
        return result
    }
    public static func event(_ value: RunEvent, capabilities: [String]?) -> RunEvent {
        var result = value
        if !modern(capabilities), result.source == .launch { result.source = .process }
        return result
    }
    public static func page(_ value: RunPage, capabilities: [String]?) -> RunPage {
        var result = value; result.runs = value.runs.map { run($0, capabilities: capabilities) }; return result
    }
}
