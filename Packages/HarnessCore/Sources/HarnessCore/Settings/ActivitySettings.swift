import Foundation

/// Approved transcript roots identify a provider profile, never an account recovered
/// from a credential file. Custom roots are an explicit local configuration choice.
public struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: AgentKind
    public var transcriptRoots: [String]
    public var pricing: [UsagePrice]?
    public init(id: UUID = UUID(), name: String, provider: AgentKind, transcriptRoots: [String], pricing: [UsagePrice]? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.transcriptRoots = transcriptRoots; self.pricing = pricing
    }
}
public struct ActivitySettings: Codable, Equatable, Sendable {
    public var profiles: [AgentProfile]
    public init(profiles: [AgentProfile] = []) { self.profiles = profiles }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([AgentProfile].self, forKey: .profiles) ?? []
    }
    public func validate() throws {
        guard profiles.count <= 32, Set(profiles.map(\.id)).count == profiles.count else { throw ConfigurationError.invalid }
        var identities: Set<String> = []
        for profile in profiles {
            guard [.claudeCode, .codex, .cursor].contains(profile.provider), !profile.name.isEmpty,
                  profile.name.utf8.count <= 256, !profile.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  identities.insert(profile.provider.rawValue + ":" + profile.name).inserted,
                  !profile.transcriptRoots.isEmpty, profile.transcriptRoots.count <= 32 else { throw ConfigurationError.invalid }
            let prices = profile.pricing ?? []
            guard prices.count <= 64, Set(prices.map(\.model)).count == prices.count else { throw UsagePricingError.invalid }
            for price in prices { try price.validate() }
            for root in profile.transcriptRoots {
                guard root.hasPrefix("/"), root.utf8.count <= 4096, !root.contains("\0"),
                      URL(fileURLWithPath: root).standardizedFileURL.path == root else { throw ConfigurationError.invalid }
            }
        }
    }
    /// Update this one section without discarding unrelated or newer settings keys.
    @discardableResult
    public func saveLocal() throws -> URL? {
        try validate()
        return try SettingsSectionStorage.save(self, key: "activity")
    }
    public static func defaultProfileID(_ provider: AgentKind) -> UUID {
        switch provider {
        case .claudeCode: UUID(uuidString: "3A7D72B1-DCC4-4CE1-A100-000000000001")!
        case .codex: UUID(uuidString: "3A7D72B1-DCC4-4CE1-A100-000000000002")!
        default: UUID(uuidString: "3A7D72B1-DCC4-4CE1-A100-000000000003")!
        }
    }
    public enum ConfigurationError: Error, LocalizedError {
        case invalid
        public var errorDescription: String? { "Use at most 32 unique provider profiles with nonempty names and absolute, normalized transcript roots. Supported observation providers are Claude, Codex, and Cursor; Cursor usage remains unavailable without a documented transcript format." }
    }
    public static func defaultRoots(provider: AgentKind, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        switch provider {
        case .claudeCode: return [home.appendingPathComponent(".claude/projects").path]
        case .codex: return [".codex/sessions", ".codex/archived_sessions"].map { home.appendingPathComponent($0).path }
        case .cursor: return [home.appendingPathComponent(".cursor/projects").path]
        default: return []
        }
    }
}
