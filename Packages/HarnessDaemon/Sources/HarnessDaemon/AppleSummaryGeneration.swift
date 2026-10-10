import Foundation
import HarnessCore
#if os(macOS) && canImport(FoundationModels)
import FoundationModels
#endif

enum AppleSummaryGeneration {
    static func unavailableReason() -> String? {
        #if os(macOS) && canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable { return nil }
        return "The Apple on-device model requires supported macOS 26 hardware, Apple Intelligence enabled, and a downloaded available model."
        #else
        return "The Apple on-device model is unavailable on this platform."
        #endif
    }
    static func availableModels() -> [AIModel] { unavailableReason() == nil ? [AIModel(id: "apple-system", name: "Apple system on-device model", supportsTextGeneration: true)] : [] }
    static func generate(input: Data, maximumTokens: Int) async throws -> AIGeneratedText {
        #if os(macOS) && canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard let prompt = String(data: input, encoding: .utf8), input.count <= 16384 else { throw AISummaryError.responseLimit }
            if let reason = unavailableReason() { throw AISummaryError.unavailable(reason) }
            return try await withThrowingTaskGroup(of: AIGeneratedText.self) { group in
                group.addTask {
                    let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [], instructions: AIGeneration.instructions)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: min(8192, maximumTokens)))
                    try Task.checkCancellation(); guard response.content.utf8.count <= 32768 else { throw AISummaryError.responseLimit }
                    return AIGeneratedText(text: response.content, reportedModel: "apple-system", truncated: false)
                }
                group.addTask { try await Task.sleep(for: .seconds(90)); throw AISummaryError.timedOut }
                defer { group.cancelAll() }; guard let text = try await group.next() else { throw AISummaryError.cancelled }; return text
            }
        }
        #endif
        throw AISummaryError.unavailable(unavailableReason() ?? "The on-device model is unavailable.")
    }
}
