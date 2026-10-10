import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension HarnessCLI {
    /// Observation hooks always fail open and never emit text or OSC on stdout.
    /// Both stdin and IPC have deadlines; no daemon startup or network connection is attempted.
    static func captureAgentHook(_ args: [String]) {
        guard let raw = flagValue(args, flag: "--contract"), let contract = HookContract(rawValue: raw),
              let surface = ProcessInfo.processInfo.environment["HARNESS_SURFACE"], UUID(uuidString: surface) != nil,
              let data = boundedHookInput(), let observation = try? ProviderHookAdapter.parse(data, contract: contract) else { return }
        let environment = ProcessInfo.processInfo.environment
        let profile = environment["HARNESS_AGENT_PROFILE"] ?? "default"
        guard profile.utf8.count <= 256 else { return }
        let endpoint: Endpoint = environment["HARNESS_SERVER"].map { .unix(path: $0) } ?? .localControlSocket
        let sender = flagValue(args, flag: "--sender-pid").flatMap(Int32.init) ?? getppid()
        let report = HookReport(surfaceID: surface, senderPID: sender, profile: profile, observation: observation, launchEnvironment: environment.filter { AgentResume.environmentKeys.contains($0.key) })
        _ = try? DaemonClient(endpoint: endpoint).request(.activity(.hook(report)), timeout: 0.35)
    }
    static func boundedHookInput() -> Data? {
        let deadline = Date().addingTimeInterval(0.25)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            guard count > 0, result.count + count <= ProviderHookAdapter.maximumPayloadBytes else { return nil }
            result.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }
    static func handleAwake(_ args: [String], client: DaemonClient) throws {
        let verb = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "status"
        let operation: PowerOperation
        if verb == "status" { operation = .status }
        else if let mode = AwakeMode(rawValue: verb) { operation = .mode(mode) }
        else { throw activityArgumentError("Use awake [status|auto|on|off] [--json]") }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.powerManagement) else {
            throw activityArgumentError("Power controls require an updated application daemon; existing shells remain running during replacement.")
        }
        guard case let .text(json) = try checkedRequest(client, .activity(.power(operation))) else { throw DaemonClientError.unexpectedResponse }
        if args.contains("--json") { print(json); return }
        let status = try JSONDecoder().decode(AwakeStatus.self, from: Data(json.utf8))
        print("Mode: \(status.mode.rawValue); power: \(status.source.rawValue); idle-sleep assertion: \(status.assertionActive ? "active" : "released"); working agents: \(status.workingAgents)")
        if let grace = status.graceUntil { print("Release after grace: " + grace.formatted(.iso8601)) }
        if let duration = status.lastSleepSeconds { print("Last observed sleep: \(Int(duration)) seconds; local execution paused while asleep.") }
        if let reason = status.unavailable { print(reason) }
    }
    static func handleAgentResume(_ args: [String], client: DaemonClient) throws {
        if let mode = flagValue(args, flag: "--auto-restore") {
            guard ["on", "off"].contains(mode), let surface = flagValue(args, flag: "--surface"), UUID(uuidString: surface) != nil else { throw activityArgumentError("Use --auto-restore on|off --surface <pane UUID>; on also requires --run <execution UUID>") }
            let runID = flagValue(args, flag: "--run").flatMap(UUID.init(uuidString:))
            guard mode == "off" || runID != nil else { throw activityArgumentError("Enabling automatic restore requires --run <verified execution UUID>") }
            guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.automaticResume) else { throw activityArgumentError("Automatic restore requires a newer application daemon; shells are preserved during replacement.") }
            _ = try checkedRequest(client, .activity(.resumePolicy(surfaceID: surface, runID: runID, automatic: mode == "on")))
            print(mode == "on" ? "Automatic conversation execution enabled for this pane's next fresh-shell restore." : "Automatic conversation execution disabled for this pane.")
            return
        }
        guard let raw = flagValue(args, flag: "--run"), let runID = UUID(uuidString: raw),
              let surface = flagValue(args, flag: "--surface"), UUID(uuidString: surface) != nil else {
            throw activityArgumentError("resume-agent requires --run <execution UUID> and --surface <fresh shell UUID>")
        }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.paneResume) else {
            throw activityArgumentError("This daemon does not support exact conversation resume; replace the application daemon while preserving shells.")
        }
        guard case let .text(json) = try checkedRequest(client, .activity(.resume(runID: runID, surfaceID: surface, freshShellIdentity: nil))) else { throw DaemonClientError.unexpectedResponse }
        let prepared = try JSONDecoder().decode(PreparedAgentResume.self, from: Data(json.utf8))
        if args.contains("--prepare") { print(args.contains("--json") ? json : prepared.command); return }
        guard let identity = prepared.freshShellIdentity else { throw ResumeError.shellChanged }
        let result = try checkedRequest(client, .activity(.resume(runID: runID, surfaceID: surface, freshShellIdentity: identity)))
        if args.contains("--json"), case let .text(text) = result { print(text) }
        else { print("Exact conversation command inserted. Press Enter in the target shell to run it.") }
    }
    static func handleActivityProfile(_ args: [String], client: DaemonClient) throws {
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.activityProfiles) else { throw activityArgumentError("This daemon does not support local profile configuration; replace the application daemon while preserving shells.") }
        guard case let .text(json) = try checkedRequest(client, .activity(.configure(nil))) else { throw DaemonClientError.unexpectedResponse }
        var settings = try JSONDecoder().decode(ActivitySettings.self, from: Data(json.utf8))
        let verb = args.count > 1 ? args[1] : "list"
        if verb == "list" { print(json); return }
        guard let name = flagValue(args, flag: "--name"), let raw = flagValue(args, flag: "--provider"),
              let provider = AgentHookInstaller.resolveAgentName(raw) else { throw activityArgumentError("activity-profile set|remove requires --name and --provider") }
        let prior = settings.profiles.first { $0.name == name && $0.provider == provider }
        settings.profiles.removeAll { $0.name == name && $0.provider == provider }
        switch verb {
        case "set":
            var roots: [String] = []
            for index in args.indices where args[index] == "--root" {
                guard index + 1 < args.count else { throw activityArgumentError("--root requires an absolute directory") }
                let root = (args[index + 1] as NSString).expandingTildeInPath
                guard root.hasPrefix("/") else { throw activityArgumentError("--root requires an absolute directory") }
                roots.append(URL(fileURLWithPath: root).standardizedFileURL.path)
            }
            guard !roots.isEmpty else { throw activityArgumentError("Provide each approved transcript root with --root") }
            let pricing: [UsagePrice]?
            if let json = flagValue(args, flag: "--pricing-json") { pricing = try JSONDecoder().decode([UsagePrice].self, from: Data(json.utf8)) }
            else { pricing = prior?.pricing }
            settings.profiles.append(AgentProfile(id: prior?.id ?? (name == "default" ? ActivitySettings.defaultProfileID(provider) : UUID()), name: name, provider: provider, transcriptRoots: roots, pricing: pricing))
        case "remove": guard prior != nil else { throw activityArgumentError("No matching profile is configured") }
        default: throw activityArgumentError("Use activity-profile list, set, or remove")
        }
        try settings.validate()
        _ = try checkedRequest(client, .activity(.configure(settings)))
        print("Local transcript profiles saved with a backup when changed. Launch this provider with HARNESS_AGENT_PROFILE=" + ShellQuoting.quote(name) + " so its hooks identify the configured profile.")
    }
    static func handleActivityReport(verb: String, args: [String], client: DaemonClient) throws {
        if args.contains("--repositories"), verb != "digest" { throw activityArgumentError("--repositories is available on digest") }
        if args.contains("--repositories"), args.contains("--surface") { throw activityArgumentError("Choose --surface or --repositories for this report") }
        if args.contains("--offset"), !args.contains("--repositories") { throw activityArgumentError("--offset requires --repositories") }
        let days = try activityInteger(args, flag: "--days", fallback: 1)
        guard (1...90).contains(days) else { throw activityArgumentError("--days must be 1–90") }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.usageDigest) else {
            throw activityArgumentError("This daemon does not support usage and digests. Replace the daemon to adopt the update; shells remain running.")
        }
        let to = Date(timeIntervalSince1970: (floor(Date().timeIntervalSince1970 / 86400) + 1) * 86400)
        let from = to.addingTimeInterval(-Double(days) * 86400)
        if verb == "digest", args.contains("--repositories") {
            guard stats.supports(DaemonStats.repositoryDigest) else { throw activityArgumentError("Repository reports require the repository-digest capability. Replace the application daemon; shells remain running.") }
            let offset = try activityInteger(args, flag: "--offset", fallback: 0)
            guard offset >= 0 else { throw activityArgumentError("--offset must be nonnegative") }
            guard case let .text(json) = try checkedRequest(client, .activity(.repositoryDigest(requestID: UUID(), from: from, to: to, offset: offset, limit: 20)), timeout: 6) else { throw DaemonClientError.unexpectedResponse }
            if args.contains("--json") { print(json); return }
            let page = try JSONDecoder().decode(RepositoryDigestPage.self, from: Data(json.utf8))
            if let reason = page.historyUnavailable { fputs(reason + "\n", harnessStderr) }
            if page.reports.isEmpty { print("No retained execution or attributable usage observations in this range.") }
            for report in page.reports {
                print("Repository: " + (report.repository ?? "unknown repository identity"))
                for worktree in report.worktrees { print("  worktree: " + worktree) }
                let t = report.totals
                if let tests = report.tests { print("  " + tests.displayText) }
                print("  Retained activity: \(t.executions) executions, \(t.turnsCompleted) completed turns, \(t.turnsFailed) failed turns, \(t.toolsCompleted)/\(t.toolsStarted) tool completions/starts")
                if report.usage.isEmpty { print("  Attributable usage: unavailable") }
                for profile in report.usage { print("  \(profile.provider.rawValue)/\(profile.profile): input \(profile.counters.input.map(String.init) ?? "unknown"), output \(profile.counters.output.map(String.init) ?? "unknown"); observed \(profile.observedAt?.formatted(.iso8601) ?? "unavailable")") }
                for warning in report.coverageWarnings { print("  " + warning) }
            }
            if let next = page.nextOffset { print("More repository reports: digest --repositories --days \(days) --offset \(next)") }
            return
        }
        let operation: ActivityOperation = verb == "usage" ? .usage(from: from, to: to) : .digest(from: from, to: to, surfaceID: flagValue(args, flag: "--surface"), responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])
        guard case let .text(json) = try checkedRequest(client, .activity(operation)) else { throw DaemonClientError.unexpectedResponse }
        if args.contains("--json") { print(json); return }
        let decoder = JSONDecoder()
        if verb == "digest" {
            let digest = try decoder.decode(ActivityDigest.self, from: Data(json.utf8))
            if let tests = digest.tests { print(tests.displayText) }
            print("Recorded activity: \(digest.totals.executions) executions, \(digest.totals.turnsCompleted) completed turns, \(digest.totals.turnsFailed) failed turns, \(digest.totals.toolsCompleted)/\(digest.totals.toolsStarted) tool completions/starts")
            if let reason = digest.historyUnavailable { fputs(reason + "\n", harnessStderr) }
            for event in digest.timeline { print("\(event.at.formatted(.iso8601)) \(event.kind.rawValue) run=\(event.runID.uuidString) sequence=\(event.terminalSequence.map(String.init) ?? "unavailable")") }
            if digest.timelineTruncated { print("The timeline shows the latest 200 events; totals include all retained events in this range.") }
        } else {
            let summary = try decoder.decode(UsageSummary.self, from: Data(json.utf8))
            if let reason = summary.historyUnavailable { fputs(reason + "\n", harnessStderr) }
            if summary.profiles.isEmpty { print("Usage is unavailable until a supported provider transcript is observed through its hooks.") }
            for profile in summary.profiles {
                print("\(profile.provider.displayName) / \(profile.profile): input=\(profile.counters.input.map(String.init) ?? "unknown") output=\(profile.counters.output.map(String.init) ?? "unknown") observed=\(profile.observedAt?.formatted(.iso8601) ?? "unavailable")")
                for limit in profile.limits { print("  \(limit.window): \(limit.usedPercent)% used; predicted reset \(limit.predictedReset?.formatted(.iso8601) ?? "unknown"); observed \(limit.observedAt.formatted(.iso8601))") }
                if let costs = profile.costs {
                    if costs.isEmpty { print("  Cost unavailable: no observed model has an explicit configured price.") }
                    for cost in costs { print("  Observed cost estimate: " + NSDecimalNumber(decimal: cost.amount).stringValue + " " + cost.currency + (cost.incomplete ? " (incomplete priced coverage)" : "") + "; " + cost.units) }
                }
                for warning in profile.coverageWarnings ?? [] { print("  Coverage: " + warning) }
                for limit in profile.limits where limit.resetObservedAt != nil { print("  " + limit.window + " reset evidence observed " + limit.resetObservedAt!.formatted(.iso8601)) }
                if let reason = profile.unavailable { print("  " + reason) }
            }
        }
    }
    private static func activityArgumentError(_ message: String) -> NSError {
        NSError(domain: "HarnessCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func activityInteger(_ args: [String], flag: String, fallback: Int) throws -> Int {
        guard args.contains(flag) else { return fallback }
        guard let raw = flagValue(args, flag: flag), let value = Int(raw) else { throw activityArgumentError(flag + " requires an integer") }
        return value
    }
    static func handleAgents(_ args: [String], client: DaemonClient) throws {
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.activityHistory) else {
            throw NSError(domain: "HarnessCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Execution history requires an updated daemon. Existing shells remain running; use list-agents for legacy state."])
        }
        let offset = try activityInteger(args, flag: "--offset", fallback: 0)
        let limit = try activityInteger(args, flag: "--limit", fallback: 100)
        let operation: ActivityOperation
        if let run = flagValue(args, flag: "--run") {
            guard let id = UUID(uuidString: run) else { throw NSError(domain: "HarnessCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--run must be a Harness execution UUID."]) }
            operation = .session(hostID: nil, runID: id, offset: offset, limit: limit, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities])
        } else { operation = .list(hostID: nil, surfaceID: flagValue(args, flag: "--surface"), activeOnly: args.contains("--active"), offset: offset, limit: limit, responseCapabilities: [DaemonStats.activityState, DaemonStats.agentIdentities]) }
        guard case let .text(json) = try checkedRequest(client, .activity(operation)) else { throw DaemonClientError.unexpectedResponse }
        if args.contains("--json") || flagValue(args, flag: "--run") != nil { print(json); return }
        let page = try JSONDecoder().decode(RunPage.self, from: Data(json.utf8))
        if let reason = page.historyUnavailable { fputs(reason + "\n", harnessStderr) }
        for run in page.runs {
            print("\(run.id.uuidString)  \(run.provider.displayName)  \(run.process.rawValue)/\(run.turn.rawValue)  \(run.attention.rawValue)  surface=\(run.surfaceID) host=\(run.hostID.uuidString)")
        }
        if let next = page.nextOffset { print("More history: --offset \(next)") }
    }
}
