import Foundation
import HarnessCore

extension HarnessCLI {
    static func handleSchedule(_ args: [String], client: DaemonClient) throws {

        func id() throws -> UUID { guard let id = flagValue(args, flag: "--id").flatMap(UUID.init(uuidString:)) else { throw ScheduleError.invalid("Provide --id UUID.") }; return id }
        func number(_ flag: String, fallback: Int) throws -> Int {
            guard args.contains(flag) else { return fallback }; guard let value = flagValue(args, flag: flag).flatMap(Int.init) else { throw ScheduleError.invalid("Invalid " + flag) }; return value
        }
        let verb = args.count > 1 ? args[1] : "list", operation: ScheduleOperation
        switch verb {
        case "list": operation = .list(offset: try number("--offset", fallback: 0), limit: 100)
        case "occurrences": operation = .occurrences(id: try id(), offset: try number("--offset", fallback: 0), limit: 100)
        case "save", "preview":
            let data: Data
            if let path = flagValue(args, flag: "--input"), let bytes = try PrivateFile.read(URL(fileURLWithPath: path), maximumBytes: 128 << 10) { data = bytes }
            else if args.contains("--stdin") { var bytes = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, (128 << 10) + 1 - bytes.count)), !chunk.isEmpty {
                    bytes.append(chunk); guard bytes.count <= 128 << 10 else { throw ScheduleError.budget }
                }; data = bytes }
            else { throw ScheduleError.invalid("Provide --input definition.json or --stdin. Use preview before save --reviewed.") }
            let definition = try JSONDecoder().decode(ScheduleDefinition.self, from: data); try definition.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; print(String(decoding: try encoder.encode(definition), as: UTF8.self))
            if verb == "preview" || args.contains("--dry-run") { return }
            guard args.contains("--reviewed") else { throw ScheduleError.invalid("Preview the executable, arguments, directory, stdin, timezone and enabled flag, then save --reviewed. This enables automatic execution only when enabled is true.") }
            let expected = args.contains("--revision") ? try number("--revision", fallback: 0) : nil
            operation = .save(definition: definition, expectedRevision: expected)
        case "delete": operation = .delete(id: try id(), expectedRevision: try number("--revision", fallback: 0))
        case "cancel":
            guard args.contains("--confirm") else { throw ScheduleError.invalid("Inspect the exact occurrence before using cancel --id UUID --confirm.") }
            operation = .cancelOccurrence(id: try id())
        default: throw ScheduleError.invalid("Use schedule list|preview|save --input definition.json --reviewed [--revision n]|occurrences|delete --id UUID --revision n|cancel --id occurrence-UUID --confirm.")
        }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.schedules) else { throw ScheduleError.unavailable("Update the daemon when existing shells permit adoption; this daemon has no scheduling capability.") }
        guard case let .text(json) = try checkedRequest(client, .activity(.schedules(requestID: UUID(), operation: operation)), timeout: 10) else { throw DaemonClientError.unexpectedResponse }; print(json)
    }
}
