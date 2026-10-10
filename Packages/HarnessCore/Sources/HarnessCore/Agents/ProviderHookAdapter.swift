import Foundation

public enum HookContract: String, Codable, Sendable {
    case claude202610 = "claude-hooks-2026-10"
    case codex202610 = "codex-hooks-2026-10"
    case cursorV1 = "cursor-hooks-v1"
    public var provider: AgentKind {
        switch self { case .claude202610: .claudeCode; case .codex202610: .codex; case .cursorV1: .cursor }
    }
}
/// Allowlisted hook fields only. Credential/account identity and raw transcripts
/// never enter the hook observation model.
public struct HookObservation: Codable, Sendable {
    public var contract: HookContract
    public var eventName: String
    public var kind: RunEventKind
    public var conversationID: String?
    public var turnID: String?
    public var toolID: String?
    public var toolName: String?
    public var eventID: String?
    public var subagentID: String?
    public var directory: String?
    public var transcriptPath: String?
    public var message: String?
    public var command: String?
    public var reportedAt: Date
}
public struct HookReport: Codable, Sendable {
    public var surfaceID: String
    public var senderPID: Int32
    public var profile: String
    public var launchEnvironment: [String: String]?
    public var observation: HookObservation
    public init(surfaceID: String, senderPID: Int32, profile: String = "default", observation: HookObservation, launchEnvironment: [String: String]? = nil) {
        self.surfaceID = surfaceID; self.senderPID = senderPID; self.profile = profile; self.observation = observation; self.launchEnvironment = launchEnvironment
    }
}
public enum ProviderHookAdapter {
    public static let maximumPayloadBytes = 128 * 1024
    public static func parse(_ data: Data, contract: HookContract, at: Date = .now) throws -> HookObservation {
        guard !data.isEmpty, data.count <= maximumPayloadBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookAdapterError.invalidPayload }
        func text(_ key: String, limit: Int = 4096) -> String? {
            guard let value = object[key] as? String, !value.isEmpty, value.utf8.count <= limit, !value.contains("\0") else { return nil }
            return value
        }
        guard let name = text("hook_event_name", limit: 128) else { throw HookAdapterError.invalidPayload }
        let kind: RunEventKind
        switch (contract, name) {
        case (.claude202610, "SessionStart"), (.codex202610, "SessionStart"), (.cursorV1, "sessionStart"): kind = .sessionStarted
        case (.claude202610, "SessionEnd"), (.codex202610, "SessionEnd"), (.cursorV1, "sessionEnd"): kind = .sessionEnded
        case (.claude202610, "UserPromptSubmit"), (.codex202610, "UserPromptSubmit"), (.cursorV1, "beforeSubmitPrompt"): kind = .turnStarted
        case (.claude202610, "Stop"), (.codex202610, "Stop"), (.cursorV1, "stop"): kind = .turnCompleted
        case (.claude202610, "StopFailure"): kind = .turnFailed
        case (.claude202610, "Notification"), (.codex202610, "Notification"): kind = .attention
        case (.claude202610, "PermissionRequest"), (.codex202610, "PermissionRequest"): kind = .permissionRequested
        case (.claude202610, "PreToolUse"), (.codex202610, "PreToolUse"), (.cursorV1, "preToolUse"): kind = .toolStarted
        case (.claude202610, "PostToolUse"), (.claude202610, "PostToolUseFailure"), (.codex202610, "PostToolUse"), (.cursorV1, "postToolUse"): kind = .toolCompleted
        case (.claude202610, "SubagentStart"), (.codex202610, "SubagentStart"), (.cursorV1, "subagentStart"): kind = .subagentStarted
        case (.claude202610, "SubagentStop"), (.codex202610, "SubagentStop"), (.cursorV1, "subagentStop"): kind = .subagentCompleted
        default: throw HookAdapterError.unsupportedEvent(name)
        }
        var directory = text("cwd")
        if directory == nil, contract == .cursorV1 { directory = (object["workspace_roots"] as? [String])?.first.map { String($0.prefix(4096)) } }
        var command: String?
        if let input = object["tool_input"] as? [String: Any], let value = input["command"] as? String, value.utf8.count <= 16 * 1024 { command = value }
        return HookObservation(contract: contract, eventName: name, kind: kind,
            conversationID: contract == .cursorV1 ? text("conversation_id") ?? text("session_id") : text("session_id"),
            turnID: contract == .cursorV1 ? text("generation_id") : (contract == .codex202610 ? text("turn_id") : text("prompt_id")),
            toolID: text("tool_use_id"), toolName: text("tool_name", limit: 512), eventID: nil,
            subagentID: text("agent_id"), directory: directory, transcriptPath: text("transcript_path"),
            message: text("message") ?? text("error_message"), command: command, reportedAt: at)
    }
}
public enum HookAdapterError: Error, LocalizedError {
    case invalidPayload, unsupportedEvent(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "Hook payload is invalid or exceeds its bounded input limit."
        case let .unsupportedEvent(event): "This hook adapter does not support event \(event)."
        }
    }
}
