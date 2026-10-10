import Foundation
import HarnessCore

/// A single owned queue serializes consent, submission intents and callback commits.
/// No input is persisted; encrypted output and structural request receipts are separate
/// so persistence opt-out can purge prose without authorizing a duplicate submission.
final class AISummaryService: @unchecked Sendable {
    typealias BuildInput = @Sendable (UUID?, Date, Date, Set<SummaryContentCategory>) throws -> AISummaryInput
    private struct Generation { var receipt: AISummaryRecord; var privacyGeneration: Int64; var taskID: UUID?; var appleTask: Task<Void, Never>? }
    private struct Discovery { var token: UUID; var taskID: UUID?; var provider: AIProviderConfiguration; var models: [String: AIModel] = [:]; var cursors: Set<String> = []; var pages = 0; var excluded = 0 }
    private let queue = DispatchQueue(label: "com.harness.ai-summaries", qos: .utility)
    private let network = BoundedHTTPClient(maximumRequests: 4, resourceTimeout: 90)
    private let store: ActivityStore, settingsURL: URL
    private let buildInput: BuildInput
    private let credential: @Sendable (UUID) throws -> String
    private let observeOwned: @Sendable (@Sendable () -> Void) -> Void
    private var settings: AISettings
    private var active = false, failures: [String: String] = [:]
    private var generations: [UUID: Generation] = [:], discoveries: [UUID: Discovery] = [:]
    private var timer: DispatchSourceTimer?
    init(store: ActivityStore, settings: AISettings, settingsURL: URL = HarnessPaths.settingsURL,
         credential: @escaping @Sendable (UUID) throws -> String = { reference in guard let key = try CredentialStore.load(reference)["key"] else { throw AISummaryError.authentication }; return key },
         observeOwned: @escaping @Sendable (@Sendable () -> Void) -> Void = { $0() }, buildInput: @escaping BuildInput) {
        self.store = store; self.settings = settings; self.settingsURL = settingsURL; self.credential = credential; self.observeOwned = observeOwned; self.buildInput = buildInput
    }
    deinit { timer?.cancel(); network.close() }
    func activate() {
        queue.sync {
            guard !active else { return }; active = true
            do {
                try settings.validate()
                // Accepted requests from a retired/crashed generation are never retried.
                var offset = 0
                repeat {
                    // Saving recovery state changes updated order. Page by identity
                    // so every retained receipt is visited exactly once.
                    let page = try store.objectPage(AISummaryRecord.self, kind: "ai-request", offset: offset, limit: 100, orderByIdentity: true)
                    for var record in page where record.state == .submitted {
                        record.state = .uncertain; record.finishedAt = .now; record.failure = AISummaryError.uncertain.localizedDescription; try saveReceipt(record)
                    }
                    guard page.count == 100 else { break }
                    offset += page.count
                } while true
            } catch { failures["service"] = error.localizedDescription }
            let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in self?.observeOwned { [weak self] in self?.automaticOnQueue(now: .now) } }; self.timer = timer; timer.resume()
        }
    }
    func suspend() {
        queue.sync {
            active = false; timer?.cancel(); timer = nil
            for id in Array(generations.keys) { cancelOnQueue(id, state: .uncertain) }
            network.cancelAll(); discoveries.removeAll()
        }
    }
    func purgeCapturedText(surfaceID: String) {
        queue.sync {
            // The store removes all derived summary caches on opt-out. Cancel all
            // accepted callbacks too, preventing a late aggregate from recreating them.
            for id in Array(generations.keys) { cancelOnQueue(id, state: .cancelled) }
        }
    }
    func handle(_ operation: AISummaryOperation) throws -> Data {
        try queue.sync {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            switch operation {
            case .status: return try encoder.encode(statusOnQueue())
            case let .configure(value, expected):
                try value.validate()
                let bytes = try PrivateFile.read(settingsURL)
                let decodedRoot = try bytes.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                guard var root = decodedRoot else { throw AISummaryError.configuration("The settings file is not a JSON object.") }
                let current = try root["aiSummaries"].map { try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: $0)) } ?? AISettings()
                if let expected, current != expected { throw AISummaryError.configuration("Provider configuration changed. Refresh and review the current selection before saving.") }
                root["aiSummaries"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                _ = try PrivateFile.replace(settingsURL, data: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]), expected: bytes)
                for id in Array(generations.keys) { cancelOnQueue(id, state: .cancelled) }
                for item in discoveries.values { if let id = item.taskID { network.cancel(id) } }; discoveries.removeAll()
                settings = value; failures.removeAll()
                // Explicit configuration of an enabled provider authorizes discovery.
                for provider in value.providers where provider.enabled && provider.apiProtocol != .appleOnDevice {
                    do { try refreshOnQueue(provider.id) } catch { failures[provider.id.uuidString] = error.localizedDescription }
                }
                return try encoder.encode(statusOnQueue())
            case let .refreshModels(id): try refreshOnQueue(id); return try encoder.encode(statusOnQueue())
            case let .catalog(id, offset, limit):
                guard (0...5000).contains(offset), (1...500).contains(limit), let provider = settings.providers.first(where: { $0.id == id }),
                      var catalog = try store.object(AIModelCatalog.self, kind: "ai-catalog", id: id.uuidString), matches(catalog, provider) else { throw AISummaryError.unavailable("No matching successful catalog is available, or the page bounds are invalid.") }
                let count = catalog.models.count; catalog.modelCount = count; catalog.models = Array(catalog.models.dropFirst(offset).prefix(limit))
                return try encoder.encode(AIModelCatalogPage(catalog: catalog, nextOffset: offset + limit < count ? offset + limit : nil))
            case let .generate(id, providerID, workspaceID, from, to): return try encoder.encode(try generateOnQueue(id: id, providerID: providerID, workspaceID: workspaceID, from: from, to: to))
            case let .record(id):
                guard let record = try store.object(AISummaryRecord.self, kind: "summary", id: id.uuidString) ?? store.object(AISummaryRecord.self, kind: "ai-request", id: id.uuidString) else { throw AISummaryError.unavailable("This request has expired or was never accepted.") }
                return try encoder.encode(record)
            case let .history(offset, limit):
                guard (0...1_000_000).contains(offset), (1...100).contains(limit) else { throw AISummaryError.configuration("Summary history page size must be 1–100 with a nonnegative offset.") }
                let records = try store.objectPage(AISummaryRecord.self, kind: "ai-request", offset: offset, limit: limit + 1)
                let full = try records.prefix(limit).map { try store.object(AISummaryRecord.self, kind: "summary", id: $0.id.uuidString) ?? $0 }
                return try encoder.encode(AISummaryPage(records: full, nextOffset: records.count > limit ? offset + limit : nil, unavailable: store.availability))
            case let .cancel(id):
                cancelOnQueue(id, state: .cancelled)
                guard let record = try store.object(AISummaryRecord.self, kind: "ai-request", id: id.uuidString) else { throw AISummaryError.unavailable("This request is unavailable.") }
                return try encoder.encode(record)
            }
        }
    }
    private func statusOnQueue() throws -> AIProviderStatus {
        let catalogs = try settings.providers.compactMap { provider -> AIModelCatalog? in
            guard var catalog = try store.object(AIModelCatalog.self, kind: "ai-catalog", id: provider.id.uuidString), matches(catalog, provider) else { return nil }
            catalog.modelCount = catalog.models.count; catalog.models = []; return catalog
        }
        return AIProviderStatus(settings: settings, catalogs: catalogs, refreshing: Array(discoveries.keys), failures: failures, unavailable: store.availability ?? (active ? nil : "Summary service is inactive."))
    }
    private func matches(_ catalog: AIModelCatalog, _ provider: AIProviderConfiguration) -> Bool { catalog.destination == provider.destination && catalog.apiProtocol == provider.apiProtocol && catalog.credentialReference == provider.credentialReference }
    private func provider(_ id: UUID) throws -> AIProviderConfiguration {
        guard active, let value = settings.providers.first(where: { $0.id == id }) else { throw AISummaryError.unavailable("The selected provider or active service is unavailable.") }; try value.validate(requireModel: false); return value
    }
    private func refreshOnQueue(_ id: UUID) throws {
        let provider = try provider(id)
        guard discoveries[id] == nil else { return }
        guard discoveries.count + generations.count < 4 else { throw HTTPFailure.busy }
        if provider.apiProtocol == .appleOnDevice {
            let catalog = AIModelCatalog(provider: provider, models: AppleSummaryGeneration.availableModels(), warning: AppleSummaryGeneration.unavailableReason())
            try store.saveObjects([LedgerObject(kind: "ai-catalog", id: id.uuidString, value: catalog)]); return
        }
        discoveries[id] = Discovery(token: UUID(), provider: provider)
        do { try requestPage(id, cursor: nil) } catch { discoveries.removeValue(forKey: id); throw error }
    }
    private func requestPage(_ id: UUID, cursor: String?) throws {
        guard var discovery = discoveries[id] else { return }
        guard discovery.pages < 32 else { throw AISummaryError.responseLimit }; discovery.pages += 1
        if let cursor { guard discovery.cursors.insert(cursor).inserted else { throw AISummaryError.invalidResponse } }
        let key = try discovery.provider.credentialReference.map(credential)
        let request = try AIModelDiscovery.request(provider: discovery.provider, credential: key, cursor: cursor)
        let token = discovery.token
        discovery.taskID = try network.send(request, maximumResponseBytes: 4 << 20) { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self else { return }; self.observeOwned { [weak self] in self?.finishPage(id, token: token, result: result) }
            }
        }
        discoveries[id] = discovery
    }
    private func finishPage(_ id: UUID, token: UUID, result: Result<HTTPResult, Error>) {
        guard active, var discovery = discoveries[id], discovery.token == token else { return }
        do {
            let response = try result.get(); if let error = AIGeneration.httpError(response.status) { throw error }
            let page = try AIModelDiscovery.parse(response.data, provider: discovery.provider)
            for model in page.models { discovery.models[model.id] = model }; discovery.excluded += page.excludedCount
            guard discovery.models.count <= 5000 else { throw AISummaryError.responseLimit }; discoveries[id] = discovery
            if let cursor = page.nextCursor { try requestPage(id, cursor: cursor); return }
            let unknown = discovery.models.values.filter { $0.supportsTextGeneration == nil }.count
            let warning = "Excluded \(discovery.excluded) non-text/archived models. \(unknown) models have unavailable capability metadata; explicit model IDs remain supported."
            let catalog = AIModelCatalog(provider: discovery.provider, models: discovery.models.values.sorted { $0.id < $1.id }, warning: warning)
            guard try JSONEncoder().encode(catalog).count <= 4 << 20 else { throw AISummaryError.responseLimit }
            try store.saveObjects([LedgerObject(kind: "ai-catalog", id: id.uuidString, value: catalog)]); failures.removeValue(forKey: id.uuidString); discoveries.removeValue(forKey: id)
        } catch {
            failures[id.uuidString] = error is HTTPFailure ? AIGeneration.transportError(error).localizedDescription : error.localizedDescription
            discoveries.removeValue(forKey: id) // Retain the last complete successful catalog.
        }
    }
    private func generateOnQueue(id: UUID, providerID: UUID, workspaceID: UUID?, from: Date, to: Date) throws -> AISummaryRecord {
        if let previous = try store.object(AISummaryRecord.self, kind: "ai-request", id: id.uuidString) {
            guard previous.providerID == providerID, previous.workspaceID == workspaceID, previous.from == from, previous.to == to else { throw AISummaryError.configuration("This request ID already names another submission.") }
            return try store.object(AISummaryRecord.self, kind: "summary", id: id.uuidString) ?? previous
        }
        guard store.availability == nil else { throw AISummaryError.unavailable("Durable encrypted submission receipts are unavailable; no generation was submitted.") }
        let provider = try provider(providerID); try provider.validate(); guard provider.enabled else { throw AISummaryError.configuration("The selected provider is disabled.") }
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, to > from, to.timeIntervalSince(from) <= 90 * 86400 else { throw AISummaryError.configuration("Summary ranges must be ordered and no longer than 90 days.") }
        guard generations.count + discoveries.count < 4 else { throw HTTPFailure.busy }
        guard try store.objectCount(kind: "ai-request") < 512 else { throw AISummaryError.unavailable("The retained submission budget is full; allow history retention to prune closed requests.") }
        let privacyGeneration = try store.summaryPrivacyGeneration()
        let input = try buildInput(workspaceID, from, to, provider.consentedCategories)
        let catalog = try store.object(AIModelCatalog.self, kind: "ai-catalog", id: providerID.uuidString)
        let model = catalog.flatMap { matches($0, provider) ? $0.models.first { $0.id == provider.modelID } : nil }
        let request = provider.apiProtocol == .appleOnDevice ? nil : try AIGeneration.request(provider: provider, credential: provider.credentialReference.map(credential), digest: input.data, model: model)
        if provider.apiProtocol == .appleOnDevice, let reason = AppleSummaryGeneration.unavailableReason() { throw AISummaryError.unavailable(reason) }
        guard try store.summaryPrivacyGeneration() == privacyGeneration else { throw AISummaryError.unavailable("Persistence changed while preparing generation; no request was submitted.") }
        let record = AISummaryRecord(id: id, provider: provider, workspaceID: workspaceID, surfaceIDs: input.surfaceIDs, from: from, to: to)
        try saveReceipt(record) // Commit once before any potentially billable side effect.
        generations[id] = Generation(receipt: record, privacyGeneration: privacyGeneration)
        do {
            if let request {
                generations[id]?.taskID = try network.send(request, maximumResponseBytes: 1 << 20) { [weak self] result in
                    self?.queue.async { [weak self] in
                        guard let self else { return }; self.observeOwned { [weak self] in self?.finishGeneration(id, result: result.map { response in response }) }
                    }
                }
            } else {
                generations[id]?.appleTask = Task { [weak self] in
                    let result: Result<AIGeneratedText, Error>
                    do { result = .success(try await AppleSummaryGeneration.generate(input: input.data, maximumTokens: provider.maximumOutputTokens)) } catch { result = .failure(error) }
                    self?.queue.async { [weak self] in guard let self else { return }; self.observeOwned { [weak self] in self?.finishText(id, result: result) } }
                }
            }
        } catch { finishText(id, result: .failure(error)) }
        return try store.object(AISummaryRecord.self, kind: "ai-request", id: id.uuidString) ?? record
    }
    private func finishGeneration(_ id: UUID, result: Result<HTTPResult, Error>) {
        guard let generation = generations[id], let provider = settings.providers.first(where: { $0.id == generation.receipt.providerID }) else { return }
        do {
            let response = try result.get(); if let error = AIGeneration.httpError(response.status) { throw error }
            finishText(id, result: .success(try AIGeneration.parse(response.data, apiProtocol: provider.apiProtocol)))
        } catch { finishText(id, result: .failure(error is HTTPFailure ? AIGeneration.transportError(error) : error)) }
    }
    private func finishText(_ id: UUID, result: Result<AIGeneratedText, Error>) {
        guard active, var generation = generations.removeValue(forKey: id) else { return }
        generation.receipt.finishedAt = .now
        switch result {
        case let .success(text): generation.receipt.state = .completed; generation.receipt.output = text
        case let .failure(error):
            generation.receipt.state = (error as? AISummaryError).map { if case .uncertain = $0 { return .uncertain }; return .failed } ?? .failed
            generation.receipt.failure = error is AISummaryError ? error.localizedDescription : AISummaryError.uncertain.localizedDescription
        }
        do {
            try store.saveSummary(generation.receipt, privacyGeneration: generation.privacyGeneration)
        } catch { failures["service"] = "The provider finished, but encrypted result storage is unavailable. The accepted request will not be resubmitted." }
    }
    private func cancelOnQueue(_ id: UUID, state: AISummaryState) {
        guard var generation = generations.removeValue(forKey: id) else { return }
        if let task = generation.taskID { network.cancel(task) }; generation.appleTask?.cancel()
        generation.receipt.state = state; generation.receipt.finishedAt = .now; generation.receipt.failure = (state == .cancelled ? AISummaryError.cancelled : .uncertain).localizedDescription
        do { try saveReceipt(generation.receipt) } catch { failures["service"] = "Cancellation was requested; durable result state is unavailable. No automatic retry will occur." }
    }
    private func saveReceipt(_ record: AISummaryRecord) throws { try store.saveObjects([LedgerObject(kind: "ai-request", id: record.id.uuidString, value: record)]) }
    private func automaticOnQueue(now: Date) {
        guard active, store.availability == nil else { return }
        for workspace in settings.automaticWorkspaces {
            do {
                let prior = try store.object(Date.self, kind: "ai-automatic", id: workspace.workspaceID.uuidString) ?? now.addingTimeInterval(-Double(workspace.minimumIntervalMinutes * 60))
                guard now.timeIntervalSince(prior) >= Double(workspace.minimumIntervalMinutes * 60) else { continue }
                // Commit the occurrence before submission. Failure, cancellation, or
                // daemon retirement never causes an automatic billable retry.
                try store.saveObjects([LedgerObject(kind: "ai-automatic", id: workspace.workspaceID.uuidString, value: now)])
                let from = max(prior, now.addingTimeInterval(-86400))
                let probe = try buildInput(workspace.workspaceID, from, now, [.activityTotals])
                let root = try JSONSerialization.jsonObject(with: probe.data) as? [String: Any]
                let totals = root?["activity_totals"] as? [String: Int] ?? [:]
                guard totals.values.contains(where: { $0 > 0 }) else { continue }
                _ = try generateOnQueue(id: UUID(), providerID: workspace.providerID, workspaceID: workspace.workspaceID, from: from, to: now)
            } catch { failures[workspace.workspaceID.uuidString] = error.localizedDescription }
        }
    }
}
