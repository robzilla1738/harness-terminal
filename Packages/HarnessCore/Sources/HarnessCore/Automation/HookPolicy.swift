import Foundation

public enum HookPolicyDecision: String, Codable, Sendable { case unchanged, deny, ask }
public enum HookPolicyField: String, Codable, Sendable { case tool, command, path, directory }
public enum HookPolicyMatch: String, Codable, Sendable { case equals, prefix, contains }
public struct HookPolicyCondition: Codable, Equatable, Sendable {
    public var field: HookPolicyField
    public var match: HookPolicyMatch
    public var value: String
    public init(field: HookPolicyField, match: HookPolicyMatch, value: String) { self.field = field; self.match = match; self.value = value }
}
public struct HookPolicyRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var event: String
    public var conditions: [HookPolicyCondition]
    public var decision: HookPolicyDecision
    public var reason: String
    public init(id: UUID = UUID(), event: String, conditions: [HookPolicyCondition], decision: HookPolicyDecision, reason: String) {
        self.id = id; self.event = event; self.conditions = conditions; self.decision = decision; self.reason = reason
    }
}
public struct HookPolicy: Codable, Equatable, Sendable, Identifiable {
    public var version = 1
    public var id: UUID
    public var name: String
    public var contract: HookContract
    public var enabled: Bool
    public var rules: [HookPolicyRule]
    public init(id: UUID = UUID(), name: String, contract: HookContract, enabled: Bool = false, rules: [HookPolicyRule]) { self.id = id; self.name = name; self.contract = contract; self.enabled = enabled; self.rules = rules }
    public func validate() throws {
        func label(_ value: String, limit: Int) -> Bool { !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        guard version == 1, label(name, limit: 256), (1...32).contains(rules.count), Set(rules.map(\.id)).count == rules.count else { throw HookPolicyError.invalid }
        for rule in rules {
            guard (1...4).contains(rule.conditions.count), rule.conditions.allSatisfy({ !$0.value.isEmpty && $0.value.utf8.count <= 1024 && !$0.value.contains("\0") }),
                  label(rule.reason, limit: 512), rule.decision != .unchanged else { throw HookPolicyError.invalid }
            switch contract {
            case .claude202610: guard rule.event == "PreToolUse" else { throw HookPolicyError.unsupported("Claude policy rules use PreToolUse.") }
            case .codex202610:
                guard rule.event == "PreToolUse", rule.decision == .deny else { throw HookPolicyError.unsupported("Codex's current hook contract does not enforce ask.") }
            case .cursorV1:
                guard ["preToolUse", "beforeShellExecution", "beforeMCPExecution"].contains(rule.event), rule.decision != .ask || rule.event != "preToolUse" else { throw HookPolicyError.unsupported("Cursor ask is supported only by beforeShellExecution/beforeMCPExecution, not generic preToolUse.") }
            }
        }
        if enabled, contract == .codex202610 { throw HookPolicyError.unsupported("Codex can honor a deny decision, but its documented callback errors/timeouts may fail open. Harness cannot enable fail-closed enforcement for this contract.") }
    }
}
public struct TrustedHookPolicy: Codable, Sendable, Identifiable {
    public var id: UUID { policy.id }
    public var policy: HookPolicy
    public var approvedAt: Date
    public init(policy: HookPolicy) { self.policy = policy; approvedAt = .now }
}
public enum HookPolicyRegistry {
    public static var url: URL { HarnessPaths.applicationSupport.appendingPathComponent("trusted-hook-policies.json") }
    public static func load(at url: URL = url) throws -> [TrustedHookPolicy] {
        guard let data = try PrivateFile.read(url) else { return [] }
        let records = try JSONDecoder().decode([TrustedHookPolicy].self, from: data)
        guard records.count <= 32, Set(records.map(\.id)).count == records.count else { throw HookPolicyError.invalid }
        for record in records { try record.policy.validate() }; return records.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public static func approve(_ policy: HookPolicy, at url: URL = url) throws {
        try policy.validate(); let prior = try PrivateFile.read(url)
        var records = try load(at: url); records.removeAll { $0.id == policy.id }; records.append(TrustedHookPolicy(policy: policy))
        guard records.count <= 32 else { throw HookPolicyError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        _ = try PrivateFile.replace(url, data: encoder.encode(records), expected: prior)
    }
    public static func disable(_ id: UUID, at url: URL = url) throws {
        guard var record = try load(at: url).first(where: { $0.id == id }) else { throw HookPolicyError.missing }; record.policy.enabled = false; try approve(record.policy, at: url)
    }
}
public struct HookPolicyResult: Codable, Sendable {
    public var decision: HookPolicyDecision
    public var matchedRules: [UUID]
    public var reason: String
    public init(decision: HookPolicyDecision, matchedRules: [UUID] = [], reason: String) { self.decision = decision; self.matchedRules = matchedRules; self.reason = reason }
}
public enum HookPolicyEvaluator {
    /// Literal comparisons have bounded input/work and cannot launch code or regex engines.
    public static func evaluate(_ policy: HookPolicy, data: Data, expectedEvent: String) throws -> HookPolicyResult {
        try policy.validate()
        guard data.count <= ProviderHookAdapter.maximumPayloadBytes, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any], input["hook_event_name"] as? String == expectedEvent else { throw HookPolicyError.invalid }
        guard policy.enabled else { return HookPolicyResult(decision: .unchanged, reason: "Policy disabled") }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        var fields: [HookPolicyField: String] = [:]
        fields[.tool] = input["tool_name"] as? String ?? (expectedEvent == "beforeShellExecution" ? "Shell" : nil)
        fields[.command] = toolInput["command"] as? String ?? (expectedEvent == "beforeShellExecution" ? input["command"] as? String : nil)
        fields[.path] = toolInput["file_path"] as? String ?? input["file_path"] as? String
        fields[.directory] = input["cwd"] as? String ?? toolInput["working_directory"] as? String
        guard fields.values.allSatisfy({ $0.utf8.count <= 32 << 10 && !$0.contains("\0") }) else { throw HookPolicyError.invalid }
        let matches = policy.rules.filter { rule in
            rule.event == expectedEvent && rule.conditions.allSatisfy { condition in
                guard let value = fields[condition.field] else { return false }
                switch condition.match { case .equals: return value == condition.value; case .prefix: return value.hasPrefix(condition.value); case .contains: return value.contains(condition.value) }
            }
        }
        let decision: HookPolicyDecision = matches.contains(where: { $0.decision == .deny }) ? .deny : matches.isEmpty ? .unchanged : .ask
        return HookPolicyResult(decision: decision, matchedRules: matches.map(\.id), reason: matches.first(where: { $0.decision == decision })?.reason ?? "No policy rule matched")
    }
    public static func response(_ result: HookPolicyResult, contract: HookContract, event: String) throws -> Data {
        let value: [String: Any]
        switch contract {
        case .claude202610, .codex202610:
            guard event == "PreToolUse", contract != .codex202610 || result.decision != .ask else { throw HookPolicyError.unsupported("This provider/event cannot enforce the requested decision.") }
            value = result.decision == .unchanged ? [:] : ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": result.decision.rawValue, "permissionDecisionReason": result.reason]]
        case .cursorV1:
            guard ["preToolUse", "beforeShellExecution", "beforeMCPExecution"].contains(event), result.decision != .ask || event != "preToolUse" else { throw HookPolicyError.unsupported("Cursor generic preToolUse does not enforce ask.") }
            value = result.decision == .unchanged ? ["permission": "allow"] : ["permission": result.decision.rawValue, "user_message": result.reason, "agent_message": result.reason]
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
public struct HookPolicyAudit: Codable, Sendable, Identifiable {
    public var id: UUID
    public var policyID: UUID
    public var contract: HookContract
    public var event: String
    public var decision: HookPolicyDecision
    public var ruleIDs: [UUID]
    public var surfaceID: String?
    public var at: Date
    public var failure: Bool
    public init(policyID: UUID, contract: HookContract, event: String, result: HookPolicyResult, surfaceID: String?, failure: Bool = false) {
        id = UUID(); self.policyID = policyID; self.contract = contract; self.event = event; decision = result.decision; ruleIDs = result.matchedRules; self.surfaceID = surfaceID; at = .now; self.failure = failure
    }
}
public struct HookPolicyAuditPage: Codable, Sendable {
    public var records: [HookPolicyAudit]
    public var nextOffset: Int?
    public var unavailable: String?
    public init(records: [HookPolicyAudit], nextOffset: Int?, unavailable: String?) { self.records = records; self.nextOffset = nextOffset; self.unavailable = unavailable }
}
public enum HookPolicyOperation: Codable, Sendable { case record(HookPolicyAudit), audit(offset: Int, limit: Int) }
public enum HookPolicyError: Error, LocalizedError {
    case invalid, missing, unsupported(String)
    public var errorDescription: String? {
        switch self { case .invalid: "Policy declarations or hook input are invalid or exceed their bounded budget."; case .missing: "This policy is not explicitly trusted. The guarded action is denied."; case let .unsupported(reason): reason }
    }
}
