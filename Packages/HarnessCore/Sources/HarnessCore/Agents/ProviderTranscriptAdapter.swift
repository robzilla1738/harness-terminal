import Foundation
import CoreFoundation

public enum TranscriptContract: String, Codable, Sendable {
    case claudeJSONL2026 = "claude-jsonl-2026-10"
    case codexRollout2026 = "codex-rollout-2026-10"
}
public struct TranscriptUsageObservation: Sendable {
    public var watermarkID: String
    public var counters: UsageCounters
    public var at: Date?
    public var limits: [ObservedLimit]
    public var model: String? = nil
}
/// Transcript shapes are not a stable public protocol. Keep version-specific parsing
/// here; unknown records supply no usage instead of guessed zero values.
public enum ProviderTranscriptAdapter {
    public static let maximumLineBytes = 256 * 1024
    public static func usage(_ line: Data, contract: TranscriptContract, observedAt: Date = .now) throws -> TranscriptUsageObservation? {
        guard line.count <= maximumLineBytes else { throw UsageAccountingError.invalid }
        guard let root = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw UsageAccountingError.invalid }
        let timestamp = (root["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) ?? fractionalDate($0) }
        switch contract {
        case .claudeJSONL2026:
            guard root["type"] as? String == "assistant", let message = root["message"] as? [String: Any],
                  let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 512,
                  let usage = message["usage"] as? [String: Any] else { return nil }
            return try .init(watermarkID: "message:" + id, counters: counters(usage, claude: true), at: timestamp, limits: [], model: modelName(message["model"]))
        case .codexRollout2026:
            guard root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any], payload["type"] as? String == "token_count" else { return nil }
            let info = payload["info"] as? [String: Any], total = info?["total_token_usage"] as? [String: Any]
            let rateLimits = payload["rate_limits"] as? [String: Any]
            var limits: [ObservedLimit] = []
            for name in ["primary", "secondary"] {
                guard let window = rateLimits?[name] as? [String: Any], let used = window["used_percent"] as? NSNumber,
                      CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite, (0...100).contains(used.doubleValue) else { continue }
                let minutes = try integer(window, "window_minutes").flatMap(Int.init(exactly:))
                let reset = try integer(window, "resets_at").map { Date(timeIntervalSince1970: Double($0)) }
                limits.append(.init(window: name, usedPercent: used.doubleValue, windowMinutes: minutes, predictedReset: reset, observedAt: timestamp ?? observedAt))
            }
            // last_token_usage is repeated for limit-only updates. Only the cumulative
            // watermark participates in accounting.
            return try .init(watermarkID: "conversation-total", counters: total.map { try counters($0, claude: false) } ?? UsageCounters(), at: timestamp, limits: limits)
        }
    }
    /// Model context is an adapter detail, never a guessed model or account identity.
    public static func modelContext(_ line: Data, contract: TranscriptContract) throws -> String? {
        guard line.count <= maximumLineBytes else { throw UsageAccountingError.invalid }
        guard contract == .codexRollout2026, let root = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "turn_context", let payload = root["payload"] as? [String: Any] else { return nil }
        return modelName(payload["model"])
    }
    private static func modelName(_ value: Any?) -> String? {
        guard let name = value as? String, !name.isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
    private static func counters(_ dictionary: [String: Any], claude: Bool) throws -> UsageCounters {
        try UsageCounters(input: integer(dictionary, "input_tokens"), output: integer(dictionary, "output_tokens"),
                          cachedInput: integer(dictionary, claude ? "cache_read_input_tokens" : "cached_input_tokens"),
                          reasoning: integer(dictionary, "reasoning_output_tokens"), cacheCreation: integer(dictionary, claude ? "cache_creation_input_tokens" : "cache_write_input_tokens"))
    }
    private static func integer(_ dictionary: [String: Any], _ key: String) throws -> Int64? {
        guard let raw = dictionary[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw UsageAccountingError.invalid }
        return number.int64Value
    }
    private static func fractionalDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
