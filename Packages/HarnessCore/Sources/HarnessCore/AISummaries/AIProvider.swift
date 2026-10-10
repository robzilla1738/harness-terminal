import Foundation

public enum AIProtocol: String, Codable, Sendable { case responses, messages, gemini, openAICompatible, appleOnDevice }
public enum AIProviderPreset: String, Codable, CaseIterable, Sendable {
    case aiGateway, openAI, anthropic, gemini, openRouter, grok, groq, mistral, deepSeek, ollama, lmStudio, custom, appleOnDevice
    public var displayName: String {
        switch self {
        case .aiGateway: "Vercel AI Gateway"; case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"; case .grok: "Grok"; case .groq: "Groq"; case .mistral: "Mistral"; case .deepSeek: "DeepSeek"
        case .ollama: "Ollama"; case .lmStudio: "LM Studio"; case .custom: "Custom endpoint"; case .appleOnDevice: "Apple on-device"
        }
    }
    public var endpoint: String? {
        switch self {
        case .aiGateway: "https://ai-gateway.vercel.sh/v1"; case .openAI: "https://api.openai.com/v1"; case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"; case .openRouter: "https://openrouter.ai/api/v1"
        case .grok: "https://api.x.ai/v1"; case .groq: "https://api.groq.com/openai/v1"; case .mistral: "https://api.mistral.ai/v1"
        case .deepSeek: "https://api.deepseek.com/v1"; case .ollama: "http://127.0.0.1:11434/v1"; case .lmStudio: "http://127.0.0.1:1234/v1"
        case .custom, .appleOnDevice: nil
        }
    }
    public var apiProtocol: AIProtocol {
        switch self { case .openAI: .responses; case .anthropic: .messages; case .gemini: .gemini; case .appleOnDevice: .appleOnDevice; default: .openAICompatible }
    }
}
public enum SummaryContentCategory: String, Codable, CaseIterable, Sendable {
    case activityTotals, usageTotals, testResults, repositoryDetails, activityMessages, transcriptExcerpts
    public var displayName: String {
        switch self { case .activityTotals: "Activity counts"; case .usageTotals: "Observed usage totals"; case .testResults: "Explicit test results"; case .repositoryDetails: "Repository paths and state"; case .activityMessages: "Captured activity messages"; case .transcriptExcerpts: "Bounded terminal/transcript excerpts" }
    }
}
/// Only references appear in settings. A selection is never switched by discovery.
public struct AIProviderConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var preset: AIProviderPreset
    public var apiProtocol: AIProtocol
    public var baseURL: String?
    public var credentialReference: UUID?
    public var modelID: String
    public var enabled: Bool
    public var consentedCategories: Set<SummaryContentCategory>
    public var consentedDestination: String?
    public var maximumOutputTokens: Int
    public init(id: UUID = UUID(), preset: AIProviderPreset, modelID: String = "") {
        self.id = id; self.preset = preset; name = preset.displayName; apiProtocol = preset.apiProtocol; baseURL = preset.endpoint
        self.modelID = modelID; enabled = false; consentedCategories = [.activityTotals, .usageTotals, .testResults]; maximumOutputTokens = 1024
    }
    private enum CodingKeys: String, CodingKey { case id, name, preset, apiProtocol, baseURL, credentialReference, modelID, enabled, consentedCategories, consentedDestination, maximumOutputTokens }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let preset = try values.decode(AIProviderPreset.self, forKey: .preset)
        self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(), preset: preset, modelID: try values.decodeIfPresent(String.self, forKey: .modelID) ?? "")
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? preset.displayName
        if preset == .custom, !values.contains(.apiProtocol) { throw AISummaryError.configuration("Custom endpoints require an explicit protocol choice.") }
        apiProtocol = try values.decodeIfPresent(AIProtocol.self, forKey: .apiProtocol) ?? preset.apiProtocol
        if values.contains(.baseURL) { baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) }
        credentialReference = try values.decodeIfPresent(UUID.self, forKey: .credentialReference)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        consentedCategories = Set(try values.decodeIfPresent([SummaryContentCategory].self, forKey: .consentedCategories) ?? [.activityTotals, .usageTotals, .testResults])
        consentedDestination = try values.decodeIfPresent(String.self, forKey: .consentedDestination)
        maximumOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maximumOutputTokens) ?? 1024
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name); try values.encode(preset, forKey: .preset); try values.encode(apiProtocol, forKey: .apiProtocol)
        try values.encodeIfPresent(baseURL, forKey: .baseURL); try values.encodeIfPresent(credentialReference, forKey: .credentialReference); try values.encode(modelID, forKey: .modelID); try values.encode(enabled, forKey: .enabled)
        try values.encode(consentedCategories.sorted { $0.rawValue < $1.rawValue }, forKey: .consentedCategories); try values.encodeIfPresent(consentedDestination, forKey: .consentedDestination)
        try values.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
    }
    public func validatedEndpoint() throws -> URL? {
        if apiProtocol == .appleOnDevice { guard preset == .appleOnDevice, baseURL == nil, credentialReference == nil else { throw AISummaryError.configuration("On-device generation has no network endpoint or credential.") }; return nil }
        guard let baseURL, baseURL.utf8.count <= 4096, let components = URLComponents(string: baseURL), let url = components.url,
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !baseURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.scheme == "https" || components.scheme == "http" else { throw AISummaryError.configuration("Use an HTTPS base URL without embedded credentials, query or fragment; loopback HTTP is supported for local endpoints.") }
        if components.scheme == "http" { _ = try PreviewSpecification(url: baseURL).validatedURL() }
        if let port = components.port, !(1...65535).contains(port) { throw AISummaryError.configuration("Invalid endpoint port.") }
        if preset != .custom, apiProtocol != preset.apiProtocol { throw AISummaryError.configuration("The selected preset requires its documented generation protocol; choose Custom endpoint for another protocol.") }
        return url
    }
    public var destination: String { baseURL ?? "Apple on-device; no external destination" }
    public func validate(requireModel: Bool = true) throws {
        _ = try validatedEndpoint()
        guard !name.isEmpty, name.utf8.count <= 256, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              modelID.utf8.count <= 512, !modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (128...8192).contains(maximumOutputTokens), !requireModel || !modelID.isEmpty else { throw AISummaryError.configuration("Provide a name, explicit model ID and output limit of 128–8192 tokens.") }
        if enabled { guard consentedDestination == destination, !consentedCategories.isEmpty else { throw AISummaryError.configuration("Review the exact destination and selected content categories before enabling generation.") } }
        if apiProtocol == .appleOnDevice, requireModel, modelID != "apple-system" { throw AISummaryError.configuration("The on-device adapter uses the apple-system model ID.") }
    }
}
public struct AISettings: Codable, Equatable, Sendable {
    public var version = 1
    public var providers: [AIProviderConfiguration] = []
    public var automaticWorkspaces: [AIAutomaticWorkspace] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, providers, automaticWorkspaces }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        providers = try values.decodeIfPresent([AIProviderConfiguration].self, forKey: .providers) ?? []
        automaticWorkspaces = try values.decodeIfPresent([AIAutomaticWorkspace].self, forKey: .automaticWorkspaces) ?? []
    }
    public func validate() throws {
        guard version == 1, providers.count <= 16, Set(providers.map(\.id)).count == providers.count,
              automaticWorkspaces.count <= 64, Set(automaticWorkspaces.map(\.workspaceID)).count == automaticWorkspaces.count else { throw AISummaryError.configuration("Invalid provider or automatic-workspace budget/identities.") }
        for provider in providers { try provider.validate(requireModel: provider.enabled) }
        for workspace in automaticWorkspaces {
            guard providers.contains(where: { $0.id == workspace.providerID && $0.enabled }), (30...1440).contains(workspace.minimumIntervalMinutes) else { throw AISummaryError.configuration("Automatic summaries require a separately selected workspace, enabled provider and interval of 30–1440 minutes.") }
        }
    }
}
public struct AIAutomaticWorkspace: Codable, Equatable, Sendable {
    public var workspaceID: UUID
    public var providerID: UUID
    public var minimumIntervalMinutes: Int
    public init(workspaceID: UUID, providerID: UUID, minimumIntervalMinutes: Int = 60) { self.workspaceID = workspaceID; self.providerID = providerID; self.minimumIntervalMinutes = minimumIntervalMinutes }
}
public struct AIModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Nil when the catalog supplies no reliable text-generation metadata.
    public var supportsTextGeneration: Bool?
    public var supportedParameters: [String]?
    public var maximumOutputTokens: Int?
    public init(id: String, name: String? = nil, supportsTextGeneration: Bool? = nil, supportedParameters: [String]? = nil, maximumOutputTokens: Int? = nil) {
        self.id = id; self.name = name ?? id; self.supportsTextGeneration = supportsTextGeneration; self.supportedParameters = supportedParameters; self.maximumOutputTokens = maximumOutputTokens
    }
}
public struct AIModelCatalog: Codable, Sendable {
    public var providerID: UUID
    public var destination: String
    public var apiProtocol: AIProtocol
    public var credentialReference: UUID?
    public var models: [AIModel]
    public var modelCount: Int?
    public var fetchedAt: Date
    public var warning: String?
    public init(provider: AIProviderConfiguration, models: [AIModel], warning: String? = nil) { providerID = provider.id; destination = provider.destination; apiProtocol = provider.apiProtocol; credentialReference = provider.credentialReference; self.models = models; modelCount = models.count; fetchedAt = .now; self.warning = warning }
}
public enum AISummaryError: Error, LocalizedError {
    case configuration(String), unavailable(String), invalidResponse, responseLimit, cancelled, timedOut, authentication, rateLimited, budget, provider(Int), uncertain
    public var errorDescription: String? {
        switch self {
        case let .configuration(reason): reason
        case let .unavailable(reason): "AI summary unavailable: " + reason + " The deterministic digest remains available."
        case .invalidResponse: "The selected provider returned no supported text response. The deterministic digest remains available."
        case .responseLimit: "The response exceeded the configured output limit. No automatic retry was submitted."
        case .cancelled: "Generation was canceled. Submission may have been billable; it will not be retried automatically."
        case .timedOut: "Generation timed out. Submission may have been billable; it will not be retried automatically."
        case .authentication: "The provider rejected authentication. Update its credential reference through secure local input."
        case .rateLimited: "The provider reported a rate/allowance limit. No automatic retry was submitted."
        case .budget: "The provider reported a budget or payment limit. No automatic retry was submitted."
        case let .provider(code): "The selected provider returned HTTP \(code). The deterministic digest remains available; no automatic retry was submitted."
        case .uncertain: "Generation delivery is uncertain and may have been billable. Inspect this request; it will not be retried automatically."
        }
    }
}
