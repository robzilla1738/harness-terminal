import Foundation
import HarnessCore

extension HarnessCLI {
    static func evaluateHookPolicy(_ args: [String]) -> Int32 {
        guard let raw = flagValue(args, flag: "--contract"), let contract = HookContract(rawValue: raw),
              let event = flagValue(args, flag: "--event"), let id = flagValue(args, flag: "--policy").flatMap(UUID.init(uuidString:)) else { return 2 }
        var result = HookPolicyResult(decision: .deny, reason: "Harness policy evaluation was unavailable; this guarded action was denied."), failed = false, requiresAudit = true
        do {
            guard let record = try HookPolicyRegistry.load().first(where: { $0.id == id }), record.policy.contract == contract else { throw HookPolicyError.missing }
            requiresAudit = record.policy.enabled
            let data = boundedHookInput()
            if record.policy.enabled {
                guard let data else { throw HookPolicyError.missing }
                result = try HookPolicyEvaluator.evaluate(record.policy, data: data, expectedEvent: event)
            } else {
                // Explicit disablement restores normal provider processing even
                // if observation input is malformed or its audit sink is unavailable.
                result = HookPolicyResult(decision: .unchanged, reason: "Policy is disabled; normal provider processing applies.")
            }
        } catch { failed = true }
        let environment = ProcessInfo.processInfo.environment
        let surface = environment["HARNESS_SURFACE"].flatMap { UUID(uuidString: $0)?.uuidString }
        let audit = HookPolicyAudit(policyID: id, contract: contract, event: event, result: result, surfaceID: surface, failure: failed)
        let endpoint: Endpoint = environment["HARNESS_SERVER"].map { .unix(path: $0) } ?? .localControlSocket
        let response = try? DaemonClient(endpoint: endpoint).request(.activity(.hookPolicy(.record(audit))), timeout: 0.2)
        if requiresAudit, !(response.map { if case .ok = $0 { true } else { false } } ?? false) { result = HookPolicyResult(decision: .deny, reason: "Harness policy audit was unavailable; this guarded action was denied.") }
        do { let output = try HookPolicyEvaluator.response(result, contract: contract, event: event); print(String(decoding: output, as: UTF8.self)); return 0 }
        catch { fputs("Harness cannot enforce this provider/event decision.\n", harnessStderr); return 2 }
    }
    static func handleHookPolicy(_ args: [String]) throws {
        let verb = args.count > 1 ? args[1] : "list"
        if verb == "evaluate" { exit(evaluateHookPolicy(args)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func printJSON<T: Encodable>(_ value: T) throws { print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        if verb == "list" { try printJSON(HookPolicyRegistry.load()); return }
        if verb == "audit" {
            guard case let .text(json) = try checkedRequest(makeClient(args), .activity(.hookPolicy(.audit(offset: flagValue(args, flag: "--offset").flatMap(Int.init) ?? 0, limit: 100)))) else { throw DaemonClientError.unexpectedResponse }; print(json); return
        }
        func id() throws -> UUID { guard let value = flagValue(args, flag: "--id").flatMap(UUID.init(uuidString:)) else { throw HookPolicyError.missing }; return value }
        if verb == "disable" { try HookPolicyRegistry.disable(id()); print("Policy disabled. Installed helpers retain normal provider processing while it is disabled."); return }
        let policy: HookPolicy
        if let path = flagValue(args, flag: "--input"), let data = try PrivateFile.read(URL(fileURLWithPath: path), maximumBytes: 256 << 10) { policy = try JSONDecoder().decode(HookPolicy.self, from: data) }
        else if let record = try HookPolicyRegistry.load().first(where: { $0.id == (try? id()) }) { policy = record.policy }
        else { throw HookPolicyError.missing }
        try policy.validate(); try printJSON(policy)
        if verb == "review" { return }
        if verb == "trust" {
            guard args.contains("--approve") else { throw HookPolicyError.unsupported("Review the literal conditions and decisions, then use trust --input FILE --approve. Repository files never grant trust automatically.") }
            try HookPolicyRegistry.approve(policy); print("Trusted local policy " + policy.id.uuidString); return
        }
        guard verb == "install" || verb == "uninstall" else { throw HookPolicyError.invalid }
        guard try HookPolicyRegistry.load().contains(where: { $0.policy == policy }) else { throw HookPolicyError.missing }
        var version: String?
        if policy.contract == .claude202610, verb != "uninstall" {
            let executable = try flagValue(args, flag: "--provider-executable").map { URL(fileURLWithPath: $0) } ?? (FanoutProvider(provider: .claudeCode).specification(directory: FileManager.default.currentDirectoryPath, path: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")).executableURL
            let value = try ProcessCapture.run(executable, arguments: ["--version"], timeout: 2, maxOutputBytes: 1024)
            guard value.status == 0 else { throw HookPolicyError.unsupported("Could not verify the installed Claude hook version.") }; version = String(decoding: value.stdout, as: UTF8.self)
        }
        let proposal = try HookPolicyInstallation.prepare(policy: policy, executable: CLIInstallLocator.sourceBinary().resolvingSymlinksInPath(), providerVersion: version,
            configurationDirectory: flagValue(args, flag: "--configuration-directory").map { URL(fileURLWithPath: $0) }, remove: verb == "uninstall")
        print(proposal.diff); print(proposal.trustNotice)
        if args.contains("--write"), !args.contains("--dry-run") { let backup = try HookPolicyInstallation.apply(proposal); print("Changed " + proposal.url.path + (backup.map { "; backup: " + $0.path } ?? "")) }
    }
}
private extension AgentLaunchSpecification { var executableURL: URL { URL(fileURLWithPath: executable) } }
