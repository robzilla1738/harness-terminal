import Foundation

public enum HookPolicyInstallation {
    public struct Proposal: Sendable {
        public let url: URL
        public let before: Data?
        public let after: Data
        public let diff: String
        public let trustNotice: String
    }
    public static func prepare(policy: HookPolicy, executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               providerVersion: String? = nil, configurationDirectory: URL? = nil, remove: Bool = false) throws -> Proposal {
        try policy.validate()
        guard executable.isFileURL, executable.path.hasPrefix("/"), !executable.path.contains("\0") else { throw HookPolicyError.invalid }
        if !remove {
            if policy.contract == .codex202610 { throw HookPolicyError.unsupported("Codex enforcement is unsupported because documented callback failures can fail open. Observation hooks remain available.") }
            if policy.contract == .claude202610 {
                guard let providerVersion, versionAtLeast(providerVersion, [2, 1, 295]) else { throw HookPolicyError.unsupported("Fail-closed Claude hooks require verified Claude Code 2.1.295 or later (onFailure: block). Supply the installed provider executable for version discovery.") }
            }
        }
        let relative = policy.contract == .claude202610 ? ".claude/settings.json" : policy.contract == .codex202610 ? ".codex/hooks.json" : ".cursor/hooks.json"
        let url = configurationDirectory.map { $0.appendingPathComponent(policy.contract == .claude202610 ? "settings.json" : "hooks.json") } ?? home.appendingPathComponent(relative), before = try PrivateFile.read(url)
        var root: [String: Any] = [:]
        if let before { guard let value = try JSONSerialization.jsonObject(with: before) as? [String: Any] else { throw HookPolicyError.invalid }; root = value }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { throw HookPolicyError.invalid }
        let marker = "--harness-policy=" + policy.id.uuidString
        let events = policy.contract == .cursorV1 ? ["preToolUse", "beforeShellExecution", "beforeMCPExecution"] : ["PreToolUse"]
        for event in events {
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil { throw HookPolicyError.invalid }
            let entries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = entries.filter { entry in
                if let command = entry["command"] as? String { return !command.contains(marker) }
                guard let handlers = entry["hooks"] as? [[String: Any]] else { return true }
                // Mixed vendor/user groups retain their unrelated handlers.
                return !handlers.allSatisfy { ($0["command"] as? String)?.contains(marker) == true }
            }.map { entry in
                var entry = entry
                if let handlers = entry["hooks"] as? [[String: Any]] { entry["hooks"] = handlers.filter { ($0["command"] as? String)?.contains(marker) != true } }
                return entry
            }
        }
        var additions: [String: Any] = [:]
        if !remove {
            for event in Set(policy.rules.map(\.event)).sorted() {
                let command = ShellQuoting.quote(executable.path) + " hook-policy evaluate --policy " + policy.id.uuidString + " --contract " + policy.contract.rawValue + " --event " + event + " " + marker
                let handler: [String: Any]
                if policy.contract == .cursorV1 { handler = ["command": command, "timeout": 2, "failClosed": true] }
                else { handler = ["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 2, "onFailure": "block"]]] }
                var entries = hooks[event] as? [[String: Any]] ?? []; entries.append(handler); hooks[event] = entries; additions[event] = [handler]
            }
            if policy.contract == .cursorV1 {
                if let version = root["version"] as? Int, version != 1 { throw HookPolicyError.unsupported("Unsupported Cursor hook schema version.") }; root["version"] = 1
            }
        }
        root["hooks"] = hooks
        let after = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let notice = "Review this change through the provider's hook trust mechanism. Harness does not approve vendor trust or bypass managed policy. Hooks are guardrails, not a complete shell security boundary."
        let diff = (remove ? "Remove only Harness policy " + policy.id.uuidString : String(decoding: try JSONSerialization.data(withJSONObject: ["hooks": additions], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        return Proposal(url: url, before: before, after: after, diff: diff, trustNotice: notice)
    }
    @discardableResult
    public static func apply(_ proposal: Proposal) throws -> URL? { try PrivateFile.replace(proposal.url, data: proposal.after, expected: proposal.before, backup: true) }
    private static func versionAtLeast(_ raw: String, _ minimum: [Int]) -> Bool {
        guard raw.utf8.count <= 1024, let token = raw.split(whereSeparator: { !("0123456789.".contains($0)) }).first(where: { $0.split(separator: ".").count == 3 }) else { return false }
        let values = token.split(separator: ".").compactMap { Int($0) }; guard values.count == 3 else { return false }
        for (a, b) in zip(values, minimum) { if a != b { return a > b } }; return true
    }
}
