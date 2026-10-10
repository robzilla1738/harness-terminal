import Foundation

public struct PreparedAgentResume: Codable, Sendable {
    public var runID: UUID
    public var surfaceID: String
    public var command: String
    public var freshShellIdentity: String?
    public var inserted: Bool
    public init(runID: UUID, surfaceID: String, command: String, freshShellIdentity: String?, inserted: Bool = false) {
        self.runID = runID; self.surfaceID = surfaceID; self.command = command
        self.freshShellIdentity = freshShellIdentity; self.inserted = inserted
    }
}

public enum AgentResume {
    public static let environmentKeys: Set<String> = ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME"]
    private static func safe(_ value: String, maximum: Int = 4096) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    /// Keep only the actual launcher and documented profile selector. Arbitrary
    /// argv (including prompts, credentials and config overrides) is never saved.
    public static func launch(executable: String, arguments: [String], provider: AgentKind,
                              directory: String, profile: String, environment: [String: String]) -> AgentLaunchSpecification? {
        guard executable.hasPrefix("/"), directory.hasPrefix("/"), safe(executable), safe(directory), safe(profile, maximum: 256),
              !arguments.isEmpty, arguments.count <= 128,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 16 * 1024 else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let allowed: [AgentKind: Set<String>] = [.claudeCode: ["claude"], .codex: ["codex"], .cursor: ["cursor-agent", "agent"]]
        var kept: [String] = [], optionStart = 1
        if allowed[provider]?.contains(name) != true {
            guard ["node", "bun"].contains(name), arguments.count > 1, safe(arguments[1]), arguments[1].hasPrefix("/") else { return nil }
            let script = arguments[1]
            let known = (provider == .claudeCode && script.hasSuffix("/node_modules/@anthropic-ai/claude-code/cli.js"))
                || (provider == .codex && script.hasSuffix("/node_modules/@openai/codex/bin/codex.js"))
                || (provider == .cursor && ["cursor-agent", "agent"].contains(URL(fileURLWithPath: script).lastPathComponent))
            guard known else { return nil }
            kept = [script]; optionStart = 2
        }
        let options = Array(arguments.dropFirst(optionStart))
        // Remote execution or ad-hoc configuration cannot be recreated from a
        // local conversation ID. Present the recorded activity without a button.
        guard !options.contains(where: { ["--remote", "--config", "-c", "--settings", "--setting-sources", "--api-key", "-a"].contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "") }) else { return nil }
        if provider == .codex {
            for (index, value) in options.enumerated() {
                if value == "--profile" || value == "-p" {
                    guard index + 1 < options.count, safe(options[index + 1], maximum: 256), !options[index + 1].hasPrefix("-") else { return nil }
                    kept += ["--profile", options[index + 1]]
                } else if value.hasPrefix("--profile=") {
                    let selected = String(value.dropFirst(10))
                    guard safe(selected, maximum: 256), !selected.hasPrefix("-") else { return nil }
                    kept += ["--profile", selected]
                }
            }
        }
        let env = environment.filter { environmentKeys.contains($0.key) && $0.value.hasPrefix("/") && safe($0.value) }
        return AgentLaunchSpecification(executable: executable, arguments: kept, directory: directory, profile: profile, environment: env)
    }
    public static func validateFiles(for run: AgentRun) throws {
        guard let launch = run.launch, FileManager.default.isExecutableFile(atPath: launch.executable) else { throw ResumeError.unavailable }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.directory, isDirectory: &directory), directory.boolValue else { throw ResumeError.unavailable }
        if let script = launch.arguments.first, script.hasPrefix("/"), !FileManager.default.isReadableFile(atPath: script) { throw ResumeError.unavailable }
    }
    public static func command(for run: AgentRun) throws -> String {
        guard let launch = run.launch, let conversation = run.conversationID,
              safe(conversation, maximum: 256), !conversation.hasPrefix("-"),
              [.claudeCode, .codex, .cursor].contains(run.provider),
              (run.provider == .cursor || UUID(uuidString: conversation) != nil),
              launch.executable.hasPrefix("/"), launch.directory.hasPrefix("/"), safe(launch.executable), safe(launch.directory), safe(launch.profile, maximum: 256),
              launch.arguments.allSatisfy({ safe($0) }) else { throw ResumeError.unavailable }
        guard let verified = self.launch(executable: launch.executable, arguments: [launch.executable] + launch.arguments,
            provider: run.provider, directory: launch.directory, profile: launch.profile, environment: launch.environment ?? [:]),
            verified.arguments == launch.arguments, verified.environment == (launch.environment ?? [:]) else { throw ResumeError.unavailable }
        var environment = launch.environment ?? [:]
        guard environment.allSatisfy({ environmentKeys.contains($0.key) && $0.value.hasPrefix("/") && safe($0.value) }) else { throw ResumeError.unavailable }
        environment["HARNESS_AGENT_PROFILE"] = launch.profile
        let env = environment.keys.sorted().map { $0 + "=" + ShellQuoting.quote(environment[$0]!) }.joined(separator: " ")
        let suffix = run.provider == .codex ? ["resume", conversation, "--cd", launch.directory] : ["--resume", conversation]
        return "cd -- " + ShellQuoting.quote(launch.directory) + " && env " + env + " "
            + ([launch.executable] + launch.arguments + suffix).map(ShellQuoting.quote).joined(separator: " ")
    }
}
public enum ResumeError: Error, LocalizedError {
    case unavailable, shellChanged
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Was running an agent, but verified launch details and an exact supported conversation are unavailable."
        case .shellChanged: "The target shell is busy, has received input, or changed since preparation. The resume command was not inserted."
        }
    }
}
