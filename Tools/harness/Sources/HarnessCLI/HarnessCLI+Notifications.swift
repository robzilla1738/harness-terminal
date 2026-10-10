import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension HarnessCLI {
    static func handleNotifications(_ args: [String], client: DaemonClient) throws {
        let verb = args.count > 1 ? args[1] : "status"
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.notificationPolicy) else {
            throw notificationArgumentError("Notification policy requires an updated application daemon. Existing shells remain running during replacement.")
        }
        let operation: NotificationOperation
        switch verb {
        case "status": operation = .status
        case "configure":
            let settings = try JSONDecoder().decode(NotificationPolicySettings.self, from: notificationInput(args))
            try settings.validate(); operation = .configure(settings)
        case "credential-set", "credential-remove":
            guard let raw = flagValue(args, flag: "--reference"), let reference = UUID(uuidString: raw) else { throw notificationArgumentError("Provide --reference <credential UUID>") }
            if verb == "credential-set" {
                let input = try notificationInput(args)
                let values = try JSONDecoder().decode([String: String].self, from: input)
                operation = .credentials(reference: reference, values: values)
            } else { operation = .removeCredentials(reference) }
        case "mute", "snooze":
            guard let surface = flagValue(args, flag: "--surface"), UUID(uuidString: surface) != nil else { throw notificationArgumentError("Provide --surface <surface UUID>") }
            let runID: UUID?
            if let value = flagValue(args, flag: "--run") {
                guard let id = UUID(uuidString: value) else { throw notificationArgumentError("--run requires an execution UUID") }; runID = id
            } else { runID = nil }
            guard case let .text(json) = try checkedRequest(client, .activity(.notifications(.status))) else { throw DaemonClientError.unexpectedResponse }
            let status = try JSONDecoder().decode(NotificationPolicyStatus.self, from: Data(json.utf8))
            var control = status.controls.first { $0.surfaceID == surface && $0.runID == runID } ?? AgentNotificationControl(surfaceID: surface, runID: runID)
            if verb == "mute" { control.muted = !args.contains("--off") }
            else {
                guard let raw = flagValue(args, flag: "--minutes"), let minutes = Int(raw), (0...43200).contains(minutes) else { throw notificationArgumentError("--minutes must be 0–43200; zero removes snooze") }
                control.snoozedUntil = minutes == 0 ? nil : Date().addingTimeInterval(Double(minutes * 60))
            }
            operation = .control(control)
        default: throw notificationArgumentError("Use notifications status, configure, mute, snooze, credential-set, or credential-remove")
        }
        let response = try checkedRequest(client, .activity(.notifications(operation)))
        if case let .text(json) = response { print(json) }
        else { print("Credential reference updated. Secret values are never returned.") }
    }
    private static func notificationArgumentError(_ message: String) -> NSError {
        NSError(domain: "HarnessCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func notificationInput(_ args: [String]) throws -> Data {
        guard args.contains("--stdin"), isatty(STDIN_FILENO) == 0 else {
            throw notificationArgumentError("Supply a bounded JSON object through redirected --stdin. Credentials are not accepted in arguments or echoed at a terminal prompt.")
        }
        let deadline = Date().addingTimeInterval(5)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, max(1, Int32(deadline.timeIntervalSinceNow * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw notificationArgumentError("Input did not complete before its five-second deadline") }
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= 65536 else { throw notificationArgumentError("Input failed or exceeded 65536 bytes") }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw notificationArgumentError("Input did not complete before its five-second deadline")
    }
}
