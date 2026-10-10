import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIModelPage: Sendable {
    public var models: [AIModel]
    public var nextCursor: String?
    public var excludedCount: Int
}
public enum AIModelDiscovery {
    public static func request(provider: AIProviderConfiguration, credential: String?, cursor: String? = nil) throws -> URLRequest {
        try provider.validate(requireModel: false)
        guard let base = try provider.validatedEndpoint() else { throw AISummaryError.unavailable("Use the on-device availability check instead of network discovery.") }
        var endpoint: URL
        if provider.preset == .ollama {
            guard base.lastPathComponent == "v1" else { throw AISummaryError.configuration("The Ollama preset uses a /v1 base for generation and /api/tags for model discovery.") }
            endpoint = base.deletingLastPathComponent().appendingPathComponent("api/tags")
        } else { endpoint = base.appendingPathComponent(provider.preset == .grok ? "language-models" : "models") }
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 1024, !cursor.contains("\0") else { throw AISummaryError.invalidResponse }
            guard provider.apiProtocol == .messages || provider.apiProtocol == .gemini else { throw AISummaryError.invalidResponse }
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: provider.apiProtocol == .messages ? "after_id" : "pageToken", value: cursor)]
            guard let value = components.url else { throw AISummaryError.invalidResponse }; endpoint = value
        }
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"; request.timeoutInterval = 15; request.setValue("application/json", forHTTPHeaderField: "Accept")
        try AIAuthentication.apply(provider: provider, credential: credential, request: &request)
        return request
    }
    public static func parse(_ data: Data, provider: AIProviderConfiguration) throws -> AIModelPage {
        guard data.count <= 4 << 20 else { throw AISummaryError.responseLimit }
        let root = try JSONSerialization.jsonObject(with: data)
        let object = root as? [String: Any]
        let values = root as? [[String: Any]] ?? object?[provider.apiProtocol == .gemini || provider.preset == .ollama || provider.preset == .grok ? "models" : "data"] as? [[String: Any]]
        guard let values, values.count <= 5000 else { throw AISummaryError.invalidResponse }
        var models: [String: AIModel] = [:], excluded = 0
        for value in values {
            let id = provider.apiProtocol == .gemini ? value["name"] as? String : value["id"] as? String ?? value["model"] as? String ?? value["name"] as? String
            guard let id, validLabel(id, maximum: 512) else { throw AISummaryError.invalidResponse }
            let rawName = value["display_name"] as? String ?? value["displayName"] as? String ?? value["name"] as? String ?? id
            let name = validLabel(rawName, maximum: 1024) ? rawName : id
            let text: Bool?
            switch provider.apiProtocol == .gemini ? .gemini : provider.preset {
            case .aiGateway: text = (value["type"] as? String).map { $0 == "language" }
            case .anthropic: text = true // The Messages catalog lists Claude models.
            case .gemini: text = (value["supportedGenerationMethods"] as? [String]).map { $0.contains("generateContent") }
            case .openRouter: text = ((value["architecture"] as? [String: Any])?["output_modalities"] as? [String]).map { $0.contains("text") }
            case .mistral: text = (value["capabilities"] as? [String: Any])?["completion_chat"] as? Bool
            case .grok: text = (value["output_modalities"] as? [String]).map { $0.contains("text") } ?? true
            default:
                if let capabilities = value["capabilities"] as? [String: Any], let completion = capabilities["completion_chat"] as? Bool { text = completion }
                else if let modalities = value["output_modalities"] as? [String] { text = modalities.contains("text") }
                else if let kind = value["type"] as? String, ["embedding", "image", "audio", "reranking"].contains(kind) { text = false }
                else { text = nil }
            }
            if text == false || value["archived"] as? Bool == true { excluded += 1; continue }
            let parameters = (value["supported_parameters"] as? [String])?.filter { validLabel($0, maximum: 128) }
            guard parameters.map({ $0.count <= 128 }) ?? true else { throw AISummaryError.invalidResponse }
            let rawMaximum = value["outputTokenLimit"] as? Int ?? value["max_output_tokens"] as? Int ?? (value["top_provider"] as? [String: Any])?["max_completion_tokens"] as? Int
            let maximum = rawMaximum.flatMap { (1...10_000_000).contains($0) ? $0 : nil }
            models[id] = AIModel(id: id, name: name, supportsTextGeneration: text, supportedParameters: parameters, maximumOutputTokens: maximum)
        }
        let next: String?
        if provider.apiProtocol == .messages, object?["has_more"] as? Bool == true {
            guard let last = object?["last_id"] as? String, validLabel(last, maximum: 1024) else { throw AISummaryError.invalidResponse }; next = last
        } else if provider.apiProtocol == .gemini { next = object?["nextPageToken"] as? String }
        else { next = nil }
        guard next.map({ validLabel($0, maximum: 1024) }) ?? true else { throw AISummaryError.invalidResponse }
        return AIModelPage(models: models.values.sorted { $0.id < $1.id }, nextCursor: next, excludedCount: excluded)
    }
    private static func validLabel(_ value: String, maximum: Int) -> Bool { !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}
public enum AIAuthentication {
    public static func apply(provider: AIProviderConfiguration, credential: String?, request: inout URLRequest) throws {
        if let credential {
            guard !credential.isEmpty, credential.utf8.count <= 8192, !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AISummaryError.authentication }
            switch provider.apiProtocol {
            case .messages: request.setValue(credential, forHTTPHeaderField: "x-api-key")
            case .gemini: request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
            default: request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            }
        }
        if provider.apiProtocol == .messages { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    }
}
