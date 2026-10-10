import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct TranscriptBinding: Codable, Sendable {
    var id: String, surfaceID: String, runID: UUID, profileID: UUID, profile: String
    var provider: AgentKind, path: String, scope: String, contract: TranscriptContract
    var lastBoundAt: Date? = nil
    var runStartedAt: Date? = nil
}
private struct TranscriptCursor: Codable {
    var device: UInt64, inode: UInt64, offset: Int64, anchor: Data
    var coverageWarnings: [String]? = nil
    var model: String? = nil
}
struct UsageWatermark: Codable {
    var counters: UsageCounters
    var seed: String? = nil
    var counterAt: Date? = nil
    var counterRunID: UUID? = nil
}
private struct UsageBucket: Codable, Sendable {
    var profileID: UUID, profile: String, provider: AgentKind, from: Date, to: Date
    var counters: UsageCounters, observedAt: Date
    var models: [String: UsageCounters]? = nil
    var unknownModel: UsageCounters? = nil
}
private struct ProfileLimits: Codable { var profileID: UUID, limits: [ObservedLimit] }

/// All transcript reads and accounting run on one bounded, cancellable owner queue,
/// never on the PTY reader or while holding the registry lock.
final class TranscriptUsageService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.harness.transcript-usage", qos: .utility)
    private let slots = DispatchSemaphore(value: 128)
    private let store: ActivityStore
    private let hostID: UUID
    private var timer: DispatchSourceTimer?
    private var accepting: Bool
    private var settings: ActivitySettings
    private var bindings: [String: TranscriptBinding] = [:]
    private var fileFailures: [String: String] = [:]
    private var coverageWarnings: [String: [String]] = [:]
    private var bindingFailures: [String: (id: UUID, provider: AgentKind, profile: String, reason: String)] = [:]
    private var serviceFailure: String?
    private var lastPrune = Date.distantPast
    private var nextBindingIndex = 0
    init(store: ActivityStore, hostID: UUID, warm: Bool, settings: ActivitySettings = HarnessSettings.load().activity) {
        self.store = store; self.hostID = hostID; accepting = !warm; self.settings = settings
        do { try reloadBindings() }
        catch { serviceFailure = "Transcript binding recovery is incomplete: " + error.localizedDescription }
        if !warm { startTimer() }
    }
    private let overflowLock = NSLock()
    private var overflowed = false
    private func reloadBindings() throws {
        var offset = 0, loaded: [String: TranscriptBinding] = [:]
        while true {
            let page = try store.objectPage(TranscriptBinding.self, kind: "transcript-binding", offset: offset, limit: 500)
            guard loaded.count + page.count <= 4096 else { throw LedgerError.limit }
            for var binding in page {
                if binding.lastBoundAt == nil { binding.lastBoundAt = try store.objectUpdatedAt(kind: "transcript-binding", id: binding.id) }
                loaded[binding.id] = binding
            }
            if page.count < 500 { break }; offset += page.count
        }
        bindings = loaded
    }
    deinit { timer?.cancel() }
    private func startTimer() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 3)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume(); timer = source
    }
    func bind(_ run: AgentRun, path: String) {
        guard slots.wait(timeout: .now()) == .success else {
            overflowLock.lock(); overflowed = true; overflowLock.unlock()
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            guard accepting else { return }
            do {
                let profile = try resolveProfile(run)
                guard run.provider == .claudeCode || run.provider == .codex else { throw UsageAccountingError.unsupported }
                let canonical = try approvedPath(path, roots: profile.transcriptRoots)
                let prior = bindings.values.first { $0.profileID == profile.id && $0.path == canonical }
                let scope = try prior?.scope ?? store.opaqueIdentifier(profile.id.uuidString + ":" + (run.conversationID ?? canonical), domain: "usage-conversation")
                let id = try prior?.id ?? store.opaqueIdentifier(profile.id.uuidString + ":" + canonical, domain: "transcript-file")
                var binding = TranscriptBinding(id: id, surfaceID: run.surfaceID, runID: run.id, profileID: profile.id,
                    profile: profile.name, provider: run.provider, path: canonical, scope: scope,
                    contract: run.provider == .codex ? .codexRollout2026 : .claudeJSONL2026, lastBoundAt: .now)
                guard bindings.count < 4096 || bindings[id] != nil else { throw LedgerError.limit }
                binding.runStartedAt = run.startedAt
                try store.saveObjects([LedgerObject(kind: "transcript-binding", id: id, value: binding)])
                bindings[id] = binding
                bindingFailures.removeValue(forKey: run.provider.rawValue + ":" + run.profile)
            } catch {
                let key = run.provider.rawValue + ":" + run.profile
                if bindingFailures.count < 64 || bindingFailures[key] != nil {
                    bindingFailures[key] = (bindingFailures[key]?.id ?? UUID(), run.provider, run.profile, error.localizedDescription)
                } else { serviceFailure = "Usage profile failures exceeded the bounded diagnostics budget; configure approved roots before reporting additional profiles." }
            }
        }
    }
    func setPersistence(surfaceID: String, enabled: Bool) {
        queue.sync {
            if !enabled { bindings = bindings.filter { $0.value.surfaceID != surfaceID } }
        }
    }
    func suspend() { queue.sync { accepting = false; timer?.cancel(); timer = nil } }
    func activate() throws {
        try queue.sync {
            try reloadBindings()
            accepting = true; startTimer()
        }
    }
    func configure(_ value: ActivitySettings) throws {
        try value.validate()
        try queue.sync {
            for prior in settings.profiles {
                if let next = value.profiles.first(where: { $0.id == prior.id }), next.provider != prior.provider { throw ActivitySettings.ConfigurationError.invalid }
            }
            _ = try value.saveLocal()
            settings = value
        }
    }
    func configuration() -> ActivitySettings { queue.sync { settings } }
    func refreshNow() { queue.sync { tick() } }
    private func tick() {
        guard accepting else { return }
        if Date().timeIntervalSince(lastPrune) > 3600 {
            do {
                for binding in Array(bindings.values) {
                    let run = try store.run(binding.runID)
                    let expired = run?.endedAt.map { $0 < Date().addingTimeInterval(-14 * 86400) }
                        ?? (run == nil && (binding.lastBoundAt ?? .distantFuture) < Date().addingTimeInterval(-14 * 86400))
                    if expired {
                        try store.removeTranscriptBinding(binding.id)
                        bindings.removeValue(forKey: binding.id); fileFailures.removeValue(forKey: binding.id); coverageWarnings.removeValue(forKey: binding.id)
                    }
                }
                try store.prune(); lastPrune = .now
            } catch { serviceFailure = "Usage metadata retention could not complete: " + error.localizedDescription }
        }
        // Each pass consumes at most 4 MiB total, with a fair rotating order.
        var budget = 4 << 20
        let ordered = bindings.values.sorted(by: { $0.id < $1.id })
        let start = nextBindingIndex % max(1, ordered.count)
        for index in 0..<ordered.count {
            let binding = ordered[(start + index) % ordered.count]
            nextBindingIndex = (start + index + 1) % max(1, ordered.count)
            guard budget > 0 else { break }
            do {
                if try store.object(Bool.self, kind: "capture-policy", id: binding.surfaceID) == true { bindings.removeValue(forKey: binding.id); continue }
                fileFailures.removeValue(forKey: binding.id)
                budget -= try read(binding, maximumBytes: min(1 << 20, budget))
            } catch { fileFailures[binding.id] = error.localizedDescription }
        }
    }
    private func resolveProfile(_ run: AgentRun) throws -> AgentProfile {
        if let profile = settings.profiles.first(where: { $0.provider == run.provider && $0.name == run.profile }) { return profile }
        guard run.profile == "default" else { throw TranscriptError.profile }
        return AgentProfile(id: ActivitySettings.defaultProfileID(run.provider), name: "default", provider: run.provider, transcriptRoots: ActivitySettings.defaultRoots(provider: run.provider))
    }
    private func approvedPath(_ path: String, roots: [String]) throws -> String {
        guard path.utf8.count <= 4096, path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension == "jsonl",
              let file = realpath(path, nil) else { throw TranscriptError.path }
        defer { free(file) }
        let canonical = String(cString: file)
        for root in roots {
            guard root.hasPrefix("/"), let resolved = realpath(root, nil) else { continue }
            let approved = String(cString: resolved); free(resolved)
            if canonical.hasPrefix(approved + "/") { return canonical }
        }
        throw TranscriptError.path
    }
    private func read(_ binding: TranscriptBinding, maximumBytes: Int) throws -> Int {
        let configured = settings.profiles.first { $0.id == binding.profileID }
        guard (configured?.provider == binding.provider) || (binding.profile == "default" && binding.profileID == ActivitySettings.defaultProfileID(binding.provider)) else { throw TranscriptError.profile }
        let roots = configured?.transcriptRoots ?? ActivitySettings.defaultRoots(provider: binding.provider)
        guard try approvedPath(binding.path, roots: roots) == binding.path else { throw TranscriptError.path }
        let fd = open(binding.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw TranscriptError.unavailable }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { throw TranscriptError.path }
        // Validate the actual opened file after resolving parent components as well.
        #if os(macOS)
        var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &actual) == 0, try approvedPath(String(decoding: actual.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), roots: roots) == binding.path else { throw TranscriptError.path }
        #else
        let actual = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
        guard try approvedPath(actual, roots: roots) == binding.path else { throw TranscriptError.path }
        #endif
        var cursor = try store.object(TranscriptCursor.self, kind: "transcript-cursor", id: binding.id)
            ?? TranscriptCursor(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), offset: 0, anchor: Data())
        if cursor.device != UInt64(info.st_dev) || cursor.inode != UInt64(info.st_ino) || info.st_size < cursor.offset {
            cursor = TranscriptCursor(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), offset: 0, anchor: Data(), coverageWarnings: cursor.coverageWarnings)
        } else if !cursor.anchor.isEmpty {
            var bytes = [UInt8](repeating: 0, count: cursor.anchor.count)
            let count = pread(fd, &bytes, bytes.count, off_t(cursor.offset - Int64(bytes.count)))
            if count != bytes.count || Data(bytes) != cursor.anchor { cursor.offset = 0; cursor.anchor = Data(); cursor.model = nil }
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = pread(fd, &bytes, bytes.count, off_t(cursor.offset))
        guard count >= 0 else { throw TranscriptError.unavailable }
        coverageWarnings[binding.id] = cursor.coverageWarnings ?? []
        if count == 0 { return 0 }
        let data = Data(bytes.prefix(count))
        let recordedRun = try store.run(binding.runID)
        let runStartedAt = recordedRun?.startedAt ?? binding.runStartedAt
        let runEndedAt = recordedRun?.endedAt
        var position = 0, pending: [String: LedgerObject] = [:], watermarks: [String: UsageWatermark] = [:], buckets: [String: UsageBucket] = [:], runBuckets: [String: RunUsageBucket] = [:]
        var limits: ProfileLimits? = nil
        for end in data.indices where data[end] == 10 {
            let line = Data(data[position..<end]); position = end + 1
            guard !line.isEmpty else { continue }
            guard line.count <= ProviderTranscriptAdapter.maximumLineBytes else { throw TranscriptError.line }
            // A non-JSON or evolving record is skipped explicitly while subsequent valid
            // observations remain available; malformed usage never advances its watermark.
            do {
                if let model = try ProviderTranscriptAdapter.modelContext(line, contract: binding.contract) { cursor.model = model }
                guard let observation = try ProviderTranscriptAdapter.usage(line, contract: binding.contract) else { continue }
                let markSeed = binding.scope + ":" + observation.watermarkID
                let markID = try store.opaqueIdentifier(markSeed, domain: "usage-watermark")
                let old = try watermarks[markID] ?? store.object(UsageWatermark.self, kind: "usage-watermark", id: markID) ?? UsageWatermark(counters: UsageCounters())
                let delta = try observation.counters.increment(since: old.counters)
                var merged = old.counters
                if let n = observation.counters.input { merged.input = n }
                if let n = observation.counters.output { merged.output = n }
                if let n = observation.counters.cachedInput { merged.cachedInput = n }
                if let n = observation.counters.cacheCreation { merged.cacheCreation = n }
                if let n = observation.counters.reasoning { merged.reasoning = n }
                var watermark = UsageWatermark(counters: merged, seed: markSeed, counterAt: old.counterAt, counterRunID: old.counterRunID)
                var observationRecords: [String: LedgerObject] = [:]
                var updatedBucket: (String, UsageBucket)?
                var updatedRunBucket: (String, RunUsageBucket)?
                var updatedLimits: ProfileLimits?
                let at = observation.at ?? Date()
                if observation.at == nil {
                    cursor.coverageWarnings = Array(Set((cursor.coverageWarnings ?? []) + ["Some usage observations have no timestamp and cannot be assigned to report dates."])).sorted()
                }
                let withinRun = observation.at != nil && runStartedAt.map { at >= $0 } == true && (runEndedAt.map { at <= $0 } ?? true)
                let hasReportedCounters = [observation.counters.input, observation.counters.output, observation.counters.cachedInput, observation.counters.cacheCreation, observation.counters.reasoning].contains { $0 != nil }
                let trustedBaseline = old.counterRunID == binding.runID && old.counterAt.map { previous in
                    runStartedAt.map { previous >= $0 } == true && previous <= at
                } == true
                if hasReportedCounters, observation.at != nil, old.counterAt == nil || at >= old.counterAt! {
                    watermark.counterAt = at; watermark.counterRunID = withinRun ? binding.runID : nil
                }
                // Timestamp-less records retain freshness but cannot invent a day of usage.
                if observation.at != nil {
                    let day = floor(at.timeIntervalSince1970 / 86400) * 86400
                    let bucketID = binding.profileID.uuidString + ":" + String(Int64(day))
                    var bucket = try buckets[bucketID] ?? store.object(UsageBucket.self, kind: "usage", id: bucketID)
                        ?? UsageBucket(profileID: binding.profileID, profile: binding.profile, provider: binding.provider,
                            from: Date(timeIntervalSince1970: day), to: Date(timeIntervalSince1970: day + 86400), counters: UsageCounters(), observedAt: at)
                    let hasTokens = [delta.input, delta.output, delta.cachedInput, delta.cacheCreation, delta.reasoning].contains { $0 != nil }
                    if hasTokens {
                        // Existing buckets predate model attribution. Preserve their
                        // unknown coverage before adding the first attributed record.
                        if bucket.models == nil, bucket.unknownModel == nil,
                           [bucket.counters.input, bucket.counters.output, bucket.counters.cachedInput, bucket.counters.cacheCreation, bucket.counters.reasoning].contains(where: { $0 != nil }) {
                            bucket.unknownModel = bucket.counters
                        }
                        let hasBaseline = [old.counters.input, old.counters.output, old.counters.cachedInput, old.counters.cacheCreation, old.counters.reasoning].contains { $0 != nil }
                        // The first Codex total may include earlier models in the
                        // conversation. Only later observed deltas have current-model
                        // attribution; never price an entire conversation as one turn.
                        let model = observation.model ?? (binding.provider == .codex && hasBaseline && trustedBaseline ? cursor.model : nil)
                        if let model, bucket.models?[model] != nil || (bucket.models?.count ?? 0) < 64 {
                            var counts = bucket.models?[model] ?? UsageCounters(); try counts.add(delta)
                            if bucket.models == nil { bucket.models = [:] }; bucket.models?[model] = counts
                        } else {
                            var counts = bucket.unknownModel ?? UsageCounters(); try counts.add(delta); bucket.unknownModel = counts
                        }
                    }
                    try bucket.counters.add(delta); bucket.observedAt = max(bucket.observedAt, at)
                    updatedBucket = (bucketID, bucket)
                    observationRecords["bucket:" + bucketID] = try LedgerObject(kind: "usage", id: bucketID, value: bucket, at: bucket.to)
                    if hasTokens, withinRun, binding.provider != .codex || trustedBaseline {
                        let id = binding.runID.uuidString + ":" + String(Int64(day)) + ":" + binding.profileID.uuidString
                        var runBucket = try runBuckets[id] ?? store.object(RunUsageBucket.self, kind: "run-usage", id: id)
                            ?? RunUsageBucket(runID: binding.runID, profileID: binding.profileID, provider: binding.provider, profile: binding.profile, from: bucket.from, to: bucket.to, observedAt: at)
                        try runBucket.counters.add(delta); runBucket.observedAt = max(runBucket.observedAt, at)
                        updatedRunBucket = (id, runBucket)
                        observationRecords["run-bucket:" + id] = try LedgerObject(kind: "run-usage", id: id, value: runBucket, at: runBucket.to)
                    }
                }
                if !observation.limits.isEmpty {
                    let prior = try limits ?? store.object(ProfileLimits.self, kind: "profile-limits", id: binding.profileID.uuidString)
                    var windows = Dictionary(uniqueKeysWithValues: (prior?.limits ?? []).map { ($0.window, $0) })
                    for var value in observation.limits where windows[value.window] == nil || windows[value.window]!.observedAt < value.observedAt {
                        if let previous = windows[value.window] {
                            value.resetObservedAt = previous.resetObservedAt
                            if let oldBoundary = previous.predictedReset, let nextBoundary = value.predictedReset,
                               oldBoundary <= value.observedAt, nextBoundary > oldBoundary, value.usedPercent < previous.usedPercent {
                                value.resetObservedAt = value.observedAt
                            }
                        }
                        windows[value.window] = value
                    }
                    updatedLimits = ProfileLimits(profileID: binding.profileID, limits: windows.values.sorted { $0.window < $1.window })
                }
                observationRecords["mark:" + markID] = try LedgerObject(kind: "usage-watermark", id: markID, value: watermark)
                if let (id, bucket) = updatedBucket { buckets[id] = bucket }
                if let (id, bucket) = updatedRunBucket { runBuckets[id] = bucket }
                if let updatedLimits { limits = updatedLimits }
                watermarks[markID] = watermark
                pending.merge(observationRecords) { _, new in new }
            } catch {
                let isJSONError = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 3840
                guard error is UsageAccountingError || isJSONError else { throw error }
                let warning = error is UsageAccountingError ? "Some usage records were invalid or cumulative accounting decreased; those records were not added." : "Some provider transcript records could not be decoded; report coverage is incomplete."
                cursor.coverageWarnings = Array(Set((cursor.coverageWarnings ?? []) + [warning])).sorted()
            }
        }
        coverageWarnings[binding.id] = cursor.coverageWarnings ?? []
        guard position > 0 else {
            if data.count >= ProviderTranscriptAdapter.maximumLineBytes { throw TranscriptError.line }
            return count
        }
        if let limits { pending["limits"] = try LedgerObject(kind: "profile-limits", id: binding.profileID.uuidString, value: limits) }
        cursor.offset += Int64(position)
        cursor.anchor = Data(data[max(0, position - 64)..<position])
        pending["cursor"] = try LedgerObject(kind: "transcript-cursor", id: binding.id, value: cursor)
        try store.saveObjects(Array(pending.values))
        return count
    }
    func summary(from: Date, to: Date) throws -> UsageSummary {
        try queue.sync {
            var profiles: [UUID: ProfileUsage] = [:]
            var modelCounts: [UUID: [String: UsageCounters]] = [:], unknownCounts: [UUID: UsageCounters] = [:]
            for binding in bindings.values { profiles[binding.profileID] = ProfileUsage(id: binding.profileID, profile: binding.profile, provider: binding.provider, unavailable: "No supported usage observation is available.") }
            for configured in settings.profiles { profiles[configured.id] = ProfileUsage(id: configured.id, profile: configured.name, provider: configured.provider, unavailable: "No supported usage observation is available.") }
            for bucket in try store.objects(UsageBucket.self, kind: "usage") where bucket.from < to && bucket.to > from {
                var profile = profiles[bucket.profileID] ?? ProfileUsage(id: bucket.profileID, profile: bucket.profile, provider: bucket.provider)
                for (model, counts) in bucket.models ?? [:] {
                    var current = modelCounts[bucket.profileID]?[model] ?? UsageCounters(); try current.add(counts)
                    modelCounts[bucket.profileID, default: [:]][model] = current
                }
                // Legacy buckets without model detail supply unknown coverage, not guessed prices.
                if let unknown = bucket.unknownModel ?? (bucket.models == nil ? bucket.counters : nil) {
                    var current = unknownCounts[bucket.profileID] ?? UsageCounters(); try current.add(unknown); unknownCounts[bucket.profileID] = current
                }
                try profile.counters.add(bucket.counters); profile.observedAt = max(profile.observedAt ?? .distantPast, bucket.observedAt)
                profile.unavailable = nil; profiles[bucket.profileID] = profile
            }
            for (id, var profile) in profiles {
                if let observation = try store.object(ProfileLimits.self, kind: "profile-limits", id: id.uuidString) { profile.limits = observation.limits }
                let reasons = bindings.values.filter { $0.profileID == id }.compactMap { fileFailures[$0.id] }
                if !reasons.isEmpty { profile.unavailable = Array(Set(reasons)).sorted().joined(separator: " ") }
                let warnings = try bindings.values.filter { $0.profileID == id }.flatMap { binding in
                    if let cached = coverageWarnings[binding.id] { return cached }
                    return try store.object(TranscriptCursor.self, kind: "transcript-cursor", id: binding.id)?.coverageWarnings ?? []
                }
                profile.coverageWarnings = Array(Set(warnings)).sorted()
                if let pricing = settings.profiles.first(where: { $0.id == id })?.pricing, !pricing.isEmpty {
                    profile.costs = try UsagePricing.estimate(models: modelCounts[id] ?? [:], unknownModel: unknownCounts[id], provider: profile.provider, prices: pricing)
                }
                profiles[id] = profile
            }
            for failure in bindingFailures.values {
                if let id = profiles.first(where: { $0.value.provider == failure.provider && $0.value.profile == failure.profile })?.key { profiles[id]?.unavailable = failure.reason }
                else {
                    let id = failure.id
                    profiles[id] = ProfileUsage(id: id, profile: failure.profile, provider: failure.provider, unavailable: failure.reason)
                }
            }
            overflowLock.lock(); let overflow = overflowed; overflowLock.unlock()
            let health = [store.availability, serviceFailure, overflow ? "Usage binding reached its bounded queue; some transcripts were not observed." : nil].compactMap { $0 }.joined(separator: " ")
            return UsageSummary(hostID: hostID, from: Date(timeIntervalSince1970: floor(from.timeIntervalSince1970 / 86400) * 86400), to: Date(timeIntervalSince1970: ceil(to.timeIntervalSince1970 / 86400) * 86400), profiles: profiles.values.sorted { ($0.profile, $0.provider.rawValue, $0.id.uuidString) < ($1.profile, $1.provider.rawValue, $1.id.uuidString) }, historyUnavailable: health.isEmpty ? nil : health)
        }
    }
}
private enum TranscriptError: Error, LocalizedError {
    case profile, path, unavailable, line
    var errorDescription: String? {
        switch self {
        case .profile: "Configure this provider profile's approved transcript roots before reading usage."
        case .path: "Transcript is outside the profile's approved roots or is not an owned JSONL file."
        case .unavailable: "The provider transcript is temporarily unavailable."
        case .line: "A transcript line exceeds the capture limit; usage capture is paused for this file."
        }
    }
}
