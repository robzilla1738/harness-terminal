import Foundation
import HarnessCore

extension HarnessCLI {
    static func handleFanout(_ args: [String], client: DaemonClient) throws {
        for flag in ["--id", "--repository", "--base", "--workspace", "--providers-file", "--prompt-file", "--offset", "--participant", "--operation", "--executable", "--arguments-file"] where args.contains(flag) {
            guard let value = flagValue(args, flag: flag), !value.hasPrefix("--") else { throw FanoutError.invalid }
        }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.fanout) else { throw FanoutError.host }
        func id(_ flag: String) throws -> UUID {
            guard let value = flagValue(args, flag: flag).flatMap(UUID.init(uuidString:)) else { throw FanoutError.missing }; return value
        }
        func file(_ path: String, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)); defer { try? handle.close() }
            return try boundedInput(handle, limit: limit)
        }
        let verb = args.count > 1 ? args[1] : "list", operation: FanoutOperation
        switch verb {
        case "list":
            let offset = flagValue(args, flag: "--offset").flatMap(Int.init) ?? 0
            if args.contains("--offset"), flagValue(args, flag: "--offset").flatMap(Int.init) == nil { throw FanoutError.invalid }
            operation = .list(offset: offset, limit: 100)
        case "start":
            guard let directory = flagValue(args, flag: "--repository"), let configuration = flagValue(args, flag: "--providers-file") else { throw FanoutError.invalid }
            let providers = try JSONDecoder().decode([FanoutProvider].self, from: file(configuration, limit: 64 << 10))
            let promptBytes = try flagValue(args, flag: "--prompt-file").map { try file($0, limit: 32 << 10) } ?? boundedInput(.standardInput, limit: 32 << 10)
            guard let prompt = String(data: promptBytes, encoding: .utf8) else { throw FanoutError.invalid }
            let operationID = args.contains("--id") ? try id("--id") : UUID()
            let workspace = args.contains("--workspace") ? try id("--workspace") : nil
            fputs("Fan-out operation ID: " + operationID.uuidString + "; inspect this ID after an uncertain outcome. No launch is automatically repeated.\n", harnessStderr)
            operation = .start(id: operationID, directory: (directory as NSString).expandingTildeInPath, base: flagValue(args, flag: "--base"), workspaceID: workspace,
                prompt: prompt, providers: providers, managedWorktrees: !args.contains("--shared-checkout"))
        case "inspect": operation = .inspect(id: try id("--id"))
        case "compare": operation = .compare(id: try id("--id"))
        case "cancel", "cleanup":
            guard args.contains("--confirm") else { throw NSError(domain: "HarnessFanout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Inspect the group, then use " + verb + " --id UUID --confirm. Cancellation signals only recorded workloads; cleanup protects dirty, active and unpushed work."]) }
            operation = verb == "cancel" ? .cancel(id: try id("--id")) : .cleanup(id: try id("--id"))
        case "test":
            guard let executable = flagValue(args, flag: "--executable"), let argumentsFile = flagValue(args, flag: "--arguments-file") else { throw FanoutError.invalid }
            let arguments = try JSONDecoder().decode([String].self, from: file(argumentsFile, limit: 64 << 10))
            let testID = args.contains("--operation") ? try id("--operation") : UUID()
            fputs("Explicit test operation ID: " + testID.uuidString + "\n", harnessStderr)
            operation = .test(id: try id("--id"), participantID: try id("--participant"), operationID: testID, executable: executable, arguments: arguments)
        default:
            throw NSError(domain: "HarnessFanout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use fanout list|start --repository path --providers-file providers.json [--prompt-file prompt.txt] [--base committed-ref]|inspect|compare|cancel|cleanup --id UUID --confirm|test --id UUID --participant UUID --executable /path --arguments-file args.json. Start reads the prompt from stdin when no prompt file is supplied."])
        }
        let response = try checkedRequest(client, .activity(.fanout(requestID: UUID(), operation: operation)), timeout: operation.requestTimeout)
        guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }; print(json)
    }
    private static func boundedInput(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(8192, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk); guard data.count <= limit else { throw FanoutError.budget }
        }
        return data
    }
}
