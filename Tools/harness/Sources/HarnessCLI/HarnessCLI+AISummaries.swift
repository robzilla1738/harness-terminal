import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension HarnessCLI {
    static func handleSummary(_ args: [String], client: DaemonClient) throws {
        func uuid(_ flag: String) throws -> UUID { guard let id = flagValue(args, flag: flag).flatMap(UUID.init(uuidString:)) else { throw AISummaryError.configuration("Provide " + flag + " UUID.") }; return id }
        func stdinBytes(limit: Int) throws -> Data {
            guard args.contains("--stdin"), isatty(STDIN_FILENO) == 0 else { throw AISummaryError.configuration("Use redirected --stdin; credentials are never accepted in arguments or echoed at a terminal.") }
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, limit + 1 - data.count)), !chunk.isEmpty { data.append(chunk); guard data.count <= limit else { throw AISummaryError.responseLimit } }; return data
        }
        let verb = args.count > 1 ? args[1] : "status", operation: AISummaryOperation
        switch verb {
        case "credential-set":
            let reference = try uuid("--reference"), bytes = try stdinBytes(limit: 8193)
            guard let key = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines), !key.isEmpty, key.utf8.count <= 8192, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AISummaryError.authentication }
            try CredentialStore.save(["key": key], reference: reference); print("Saved credential reference " + reference.uuidString); return
        case "credential-remove": try CredentialStore.remove(uuid("--reference")); print("Removed credential reference."); return
        case "preview", "configure":
            let data: Data
            if let path = flagValue(args, flag: "--input"), let bytes = try PrivateFile.read(URL(fileURLWithPath: path), maximumBytes: 128 << 10) { data = bytes }
            else { data = try stdinBytes(limit: 128 << 10) }
            let settings = try JSONDecoder().decode(AISettings.self, from: data); try settings.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; print(String(decoding: try encoder.encode(settings), as: UTF8.self))
            if verb == "preview" || args.contains("--dry-run") { return }
            guard args.contains("--reviewed") else { throw AISummaryError.configuration("Review every exact destination, model, selected content category and automatic workspace, then configure --reviewed. Enabling a provider performs model discovery.") }; operation = .configure(settings)
        case "status": operation = .status
        case "models": operation = .refreshModels(providerID: try uuid("--provider"))
        case "catalog":
            guard !args.contains("--offset") || flagValue(args, flag: "--offset").flatMap(Int.init) != nil else { throw AISummaryError.configuration("Invalid --offset.") }
            operation = .catalog(providerID: try uuid("--provider"), offset: flagValue(args, flag: "--offset").flatMap(Int.init) ?? 0, limit: 500)
        case "generate":
            guard args.contains("--reviewed") else { throw AISummaryError.configuration("Inspect summary status and its destination/content consent before generate --reviewed.") }
            guard let from = flagValue(args, flag: "--from").flatMap(Double.init), let to = flagValue(args, flag: "--to").flatMap(Double.init) else { throw AISummaryError.configuration("Provide exact --from and --to Unix seconds so a request can be inspected and deduplicated.") }
            operation = .generate(id: try uuid("--id"), providerID: try uuid("--provider"), workspaceID: args.contains("--workspace") ? try uuid("--workspace") : nil, from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to))
        case "record": operation = .record(id: try uuid("--id"))
        case "cancel": operation = .cancel(id: try uuid("--id"))
        case "history":
            let offset: Int
            if args.contains("--offset") { guard let value = flagValue(args, flag: "--offset").flatMap(Int.init) else { throw AISummaryError.configuration("Invalid --offset.") }; offset = value } else { offset = 0 }
            operation = .history(offset: offset, limit: 100)
        default: throw AISummaryError.configuration("Use summary status|preview|configure --input settings.json --reviewed|models --provider UUID|generate --id UUID --provider UUID --from seconds --to seconds --reviewed [--workspace UUID]|record|cancel --id UUID|history [--offset n]|credential-set --reference UUID --stdin|credential-remove --reference UUID.")
        }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.aiSummaries) else { throw AISummaryError.unavailable("This daemon has no AI summary capability. Adopt the pending update when existing shells permit it.") }
        guard case let .text(json) = try checkedRequest(client, .activity(.aiSummaries(operation)), timeout: 10) else { throw DaemonClientError.unexpectedResponse }; print(json)
    }
}
