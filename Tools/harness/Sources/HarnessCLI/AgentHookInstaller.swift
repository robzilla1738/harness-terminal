import Foundation
import HarnessCore

/// Writes per-agent hook config files so each known agent CLI can call back
/// into Harness via `harness-cli notify --surface "$HARNESS_SURFACE"`.
/// This is the user-facing side of Phase 6c — the agent-side guide lives in
/// `docs/agent-hooks/<agent>.md`.
enum AgentHookInstaller {
    static func install(agent: String) throws {
        let normalized = agent.lowercased()
        guard !normalized.isEmpty else {
            fputs("install-hooks: missing agent name (e.g. claude-code, codex, cursor, pi, hermes, openclaw)\n", stderr)
            exit(1)
        }
        switch normalized {
        case "claude-code", "claude":
            try installClaudeCode()
        case "codex":
            try installCodex()
        case "cursor", "cursor-agent":
            try installCursor()
        case "pi":
            try installPi()
        case "hermes":
            try installHermes()
        case "openclaw":
            try installOpenClaw()
        default:
            fputs("install-hooks: unknown agent \"\(agent)\"\n", stderr)
            exit(1)
        }
    }

    private static func installClaudeCode() throws {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: claudeCodeHook())
        print("Installed Claude Code hooks at \(path)")
        print("Add 'docs/agent-hooks/claude-code.md' instructions for any custom workflows.")
    }

    private static func installCodex() throws {
        let path = ("~/.codex/hooks.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: codexHook())
        print("Installed Codex hooks at \(path)")
    }

    private static func installCursor() throws {
        // Cursor agents read shell hooks via env vars; we write a one-shot
        // shim into ~/.cursor/agent-hooks.json so the running agent can call it.
        let path = ("~/.cursor/agent-hooks.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: cursorHook())
        print("Installed Cursor agent hooks at \(path)")
    }

    private static func installPi() throws {
        let path = ("~/.pi/hooks.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""])
        print("Installed Pi hooks at \(path)")
    }

    private static func installHermes() throws {
        let path = ("~/.hermes/hooks.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""])
        print("Installed Hermes hooks at \(path)")
    }

    private static func installOpenClaw() throws {
        let path = ("~/.openclaw/hooks.json" as NSString).expandingTildeInPath
        try installHookFile(at: path, hook: ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""])
        print("Installed OpenClaw hooks at \(path)")
    }

    private static func claudeCodeHook() -> [String: Any] {
        [
            "hooks": [
                "Notification": [[
                    "matcher": "*",
                    "hooks": [[
                        "type": "command",
                        "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Claude Code\" --body \"$HARNESS_NOTIFY_MESSAGE\"",
                    ]],
                ]],
                "Stop": [[
                    "matcher": "*",
                    "hooks": [[
                        "type": "command",
                        "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Claude Code\" --body \"Done\"",
                    ]],
                ]],
            ],
        ]
    }

    private static func codexHook() -> [String: Any] {
        [
            "hooks": [
                "on_pause": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Awaiting input\"",
                "on_done": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Done\"",
            ],
        ]
    }

    private static func cursorHook() -> [String: Any] {
        [
            "version": 1,
            "agent_notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"$1\"",
        ]
    }

    private static func installHookFile(at path: String, hook: [String: Any]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            let backup = url.appendingPathExtension("harness-bak-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: url, to: backup)
            print("(backed up existing config to \(backup.path))")
        }
        let data = try JSONSerialization.data(withJSONObject: hook, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }
}
