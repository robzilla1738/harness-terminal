import Foundation
import HarnessCore

final class NotificationService: @unchecked Sendable {
    private struct PendingDelivery: Codable, Sendable {
        var id = UUID()
        var notice: NotificationNotice
        var sinkID: UUID?
        var due: Date
        var expires: Date
        var attempts = 0
        var coalesced = 1
    }
    private let queue = DispatchQueue(label: "com.harness.notifications")
    private let inputSlots = DispatchSemaphore(value: 128)
    private var lastSettingsRead = Date.distantPast
    private var settingsBytes: Data?
    private var settingsFailure: String?
    private var commandThreshold: Double
    private let settingsURL: URL
    private let store: ActivityStore
    private let network = BoundedHTTPClient(maximumRequests: 4)
    private var settings: NotificationPolicySettings
    private var controls: [String: AgentNotificationControl] = [:]
    private var pending: [UUID: PendingDelivery] = [:]
    private struct Attempt { var id: UUID; var taskID: UUID }
    private var inFlight: [UUID: Attempt] = [:]
    private var diagnostics: [NotificationDeliveryDiagnostic] = []
    private var lastDelivery: [UUID: Date] = [:]
    private var lastDesktop = Date.distantPast
    private var observed: [UUID: AgentRun] = [:]
    private var timer: DispatchSourceTimer?
    private var accepting = false
    private var failure: String?
    var onDesktop: (@Sendable (DesktopNotificationDelivery) -> Void)?
    init(store: ActivityStore, settings: HarnessSettings, settingsURL: URL = HarnessPaths.settingsURL) {
        commandThreshold = Double(max(0, settings.commandFinishedThresholdSeconds))
        self.settingsURL = settingsURL
        self.store = store; self.settings = NotificationPolicySettings(legacy: settings)
    }
    deinit { timer?.cancel(); network.close() }
    func start() {
        do { try activate() } catch { queue.sync { failure = error.localizedDescription } }
    }
    func activate() throws {
        try queue.sync {
            guard !accepting else { return }
            var offset = 0, current: [UUID: AgentRun] = [:]
            repeat {
                let page = try store.list(activeOnly: true, offset: offset, limit: 500)
                guard current.count + page.runs.count <= 4096 else { throw LedgerError.limit }
                for run in page.runs { current[run.id] = run }
                guard let next = page.nextOffset else { break }; offset = next
            } while true
            observed = current
            let recovered = try store.objectPage(PendingDelivery.self, kind: "notification-pending", limit: 129)
            guard recovered.count <= 128 else { throw LedgerError.limit }
            let recoveredControls = try store.objectPage(AgentNotificationControl.self, kind: "notification-control", limit: 501)
            guard recoveredControls.count <= 500 else { throw LedgerError.limit }
            controls = Dictionary(uniqueKeysWithValues: recoveredControls.map { ($0.scopeIdentifier, $0) })
            pending = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
            diagnostics = try store.object([NotificationDeliveryDiagnostic].self, kind: "notification-diagnostics", id: "recent") ?? []
            for sink in settings.sinks { lastDelivery[sink.id] = try store.object(Date.self, kind: "notification-throttle", id: sink.id.uuidString) }
            lastDesktop = try store.object(Date.self, kind: "notification-throttle", id: "desktop") ?? .distantPast
            diagnostics = Array(diagnostics.suffix(100)); accepting = true; failure = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.deliverDue() }; timer.resume(); self.timer = timer
        }
    }
    func suspend() {
        queue.sync {
            accepting = false; timer?.cancel(); timer = nil
            network.cancelAll(); inFlight.removeAll()
        }
    }
    var isActive: Bool { queue.sync { accepting } }
    func status() -> NotificationPolicyStatus {
        queue.sync {
            overflowLock.lock(); let overflow = overflowed; overflowLock.unlock()
            return NotificationPolicyStatus(settings: settings, controls: controls.values.sorted { $0.surfaceID < $1.surfaceID }, diagnostics: diagnostics, unavailable: overflow ? "Notification input reached its bounded queue; some alerts were dropped." : (settingsFailure ?? failure ?? (accepting ? nil : "Notification delivery is inactive.")))
        }
    }
    func configure(_ value: NotificationPolicySettings) throws {
        try value.validate()
        try queue.sync {
            guard accepting else { throw LedgerError.noLease }
            for sink in value.sinks where sink.enabled && sink.kind != .ntfy {
                guard let reference = sink.credentialReference else { throw NotificationPolicyError.credential }
                let credential = try CredentialStore.load(reference)
                let notice = NotificationNotice(surfaceID: nil, event: .agentWaiting, title: "Harness")
                _ = try NotificationPayload.request(notice: notice, sink: sink, credentials: credential)
            }
            _ = try SettingsSectionStorage.save(value, key: "notificationPolicy", url: settingsURL, rootValues: ["systemNotificationsEnabled": value.banners, "notificationSoundEnabled": value.chimes], events: value.events)
            settings = value
            // Previously accepted payloads must not outlive a revoked destination or consent.
            for item in Array(pending.values) {
                if let sink = item.sinkID, !value.sinks.contains(where: { $0.id == sink && $0.enabled }) { try finish(item, outcome: "destination disabled") }
            }
        }
    }
    func control(_ value: AgentNotificationControl) throws {
        guard UUID(uuidString: value.surfaceID) != nil,
              value.snoozedUntil.map({ $0.timeIntervalSinceNow <= 30 * 86400 && $0.timeIntervalSince1970.isFinite }) ?? true else { throw NotificationPolicyError.invalid }
        try queue.sync {
            guard accepting, controls.count < 500 || controls[value.scopeIdentifier] != nil else { throw LedgerError.limit }
            try store.saveObjects([LedgerObject(kind: "notification-control", id: value.scopeIdentifier, value: value)])
            controls[value.scopeIdentifier] = value
            if value.muted || (value.snoozedUntil.map { $0 > .now } ?? false) {
                for item in Array(pending.values) where item.notice.surfaceID == value.surfaceID && (value.runID == nil || value.runID == item.notice.runID) { try finish(item, outcome: "muted or snoozed") }
            }
        }
    }
    func purgeCapturedText(surfaceID: String) throws {
        try queue.sync {
            for var item in Array(pending.values) where item.notice.surfaceID == surfaceID {
                if let attempt = inFlight.removeValue(forKey: item.id) { network.cancel(attempt.taskID) }
                item.notice.title = "Harness"; item.notice.message = ""; item.notice.repository = nil
                try save(item)
            }
        }
    }
    func commandCompleted(_ span: ShellCommandSpan) {
        guard span.observedTiming == true else { return }
        let duration = Date().timeIntervalSince(span.startedAt)
        guard duration.isFinite, duration >= 0 else { return }
        let outcome = span.exitCode.map { $0 == 0 ? "succeeded" : "failed (exit \($0))" } ?? "completed (exit status unavailable)"
        var notice = NotificationNotice(surfaceID: span.surfaceID, event: .commandFinished, title: "Command " + outcome, message: "Observed command duration: \(Int(duration)) seconds.")
        if let stream = span.streamIdentity, let end = span.endSequence { notice.observationIdentity = stream + ":command:" + String(end) }
        submit(notice, commandDuration: duration)
    }
    func submit(_ notice: NotificationNotice, commandDuration: TimeInterval? = nil) {
        guard inputSlots.wait(timeout: .now()) == .success else { reportOverflow(); return }
        queue.async { [weak self] in
            guard let self else { return }; defer { inputSlots.signal() }
            if let commandDuration, commandDuration < commandThreshold { return }
            do { try enqueue(notice) } catch { failure = error.localizedDescription }
        }
    }
    func observe(_ run: AgentRun) {
        guard inputSlots.wait(timeout: .now()) == .success else { reportOverflow(); return }
        queue.async { [weak self] in
            guard let self else { return }; defer { inputSlots.signal() }
            guard accepting, run.parentRunID == nil else { return }
            let previous = observed[run.id]
            if run.process == .exited { observed.removeValue(forKey: run.id) } else { observed[run.id] = run }
            // A process-only observation never asserts completion or a need for input.
            guard run.source == .hook || run.source == .osc || run.source == .exit else { return }
            let event: NotificationEvent
            if run.turn == .failed || run.attention == .error {
                guard previous?.turn != .failed || previous?.lastTurnID != run.lastTurnID else { return }; event = .failed
            } else if run.attention == .needsInput || run.attention == .needsApproval {
                guard previous?.attention != run.attention || previous?.lastTurnID != run.lastTurnID else { return }; event = .agentWaiting
            } else if run.turn == .completed {
                guard previous?.turn != .completed || previous?.lastTurnID != run.lastTurnID else { return }; event = .agentFinished
            } else { return }
            do {
                try enqueue(NotificationNotice(surfaceID: run.surfaceID, runID: run.id, event: event, provider: run.provider.displayName,
                    title: run.provider.displayName, message: run.message ?? event.title, repository: run.launch?.directory))
            } catch { failure = error.localizedDescription }
        }
    }
    private func control(for notice: NotificationNotice) -> AgentNotificationControl? {
        guard let surface = notice.surfaceID else { return nil }
        let pane = controls[surface]
        let run = notice.runID.flatMap { controls["run:" + $0.uuidString] }
        return AgentNotificationControl(surfaceID: surface, runID: notice.runID,
            muted: (pane?.muted ?? false) || (run?.muted ?? false),
            snoozedUntil: [pane?.snoozedUntil, run?.snoozedUntil].compactMap { $0 }.max())
    }
    private func enqueue(_ original: NotificationNotice) throws {
        guard accepting else { return }
        if let identity = original.observationIdentity {
            guard identity.utf8.count <= 256 else { throw NotificationPolicyError.invalid }
            if try store.object(Bool.self, kind: "notification-observed", id: identity) == true { return }
        }
        let control = control(for: original)
        let allowed = settings.allows(original.event, at: .now, muted: control?.muted ?? false, snoozedUntil: control?.snoozedUntil)
        var notice = original
        if let surface = notice.surfaceID, try store.object(Bool.self, kind: "capture-policy", id: surface) == true {
            notice.title = "Harness"; notice.message = ""; notice.repository = nil
        }
        var destinations: [UUID?] = allowed ? settings.sinks.filter(\.enabled).map { Optional($0.id) } : []
        if allowed && (settings.banners || settings.chimes || settings.speech) { destinations.append(nil) }
        var staged: [PendingDelivery] = []
        for sink in destinations {
            if var item = pending.values.first(where: { $0.sinkID == sink && $0.notice.surfaceID == notice.surfaceID && $0.notice.event == notice.event && inFlight[$0.id] == nil && $0.attempts == 0 && $0.due > .now }) {
                var latest = notice; latest.id = item.notice.id; item.notice = latest; item.coalesced += 1
                staged.append(item)
            } else {
                staged.append(PendingDelivery(notice: notice, sinkID: sink, due: notice.at.addingTimeInterval(settings.burstSeconds), expires: notice.at.addingTimeInterval(settings.deliveryExpirySeconds)))
            }
        }
        guard pending.count + staged.filter({ pending[$0.id] == nil }).count <= 128 else { throw LedgerError.limit }
        var records = try staged.map { try LedgerObject(kind: "notification-pending", id: $0.id.uuidString, value: $0) }
        if let identity = original.observationIdentity { records.append(try LedgerObject(kind: "notification-observed", id: identity, value: true)) }
        try store.saveObjects(records)
        for item in staged { pending[item.id] = item }
    }
    private func save(_ item: PendingDelivery) throws {
        try store.saveObjects([LedgerObject(kind: "notification-pending", id: item.id.uuidString, value: item)])
        pending[item.id] = item
    }
    private func deliverDue() {
        guard accepting else { return }
        reloadSettingsIfDue()
        for var item in pending.values.sorted(by: { $0.due < $1.due }) {
            do {
                // Expiry and revoked policy also cancel requests already in flight.
                // A request already received by its destination cannot be recalled.
                guard item.expires > .now else { try finish(item, outcome: "expired"); continue }
                let control = control(for: item.notice)
                guard settings.allows(item.notice.event, at: .now, muted: control?.muted ?? false, snoozedUntil: control?.snoozedUntil) else { try finish(item, outcome: "policy suppressed"); continue }
                if let sinkID = item.sinkID {
                    guard let sink = settings.sinks.first(where: { $0.id == sinkID && $0.enabled }) else { try finish(item, outcome: "destination disabled"); continue }
                    guard inFlight[item.id] == nil, item.due <= .now else { continue }
                    guard inFlight.count < 4, !pending.values.contains(where: { $0.sinkID == sinkID && inFlight[$0.id] != nil }) else { continue }
                    if Date().timeIntervalSince(lastDelivery[sinkID] ?? .distantPast) < sink.minimumInterval { continue }
                    let credentials = try sink.credentialReference.map(CredentialStore.load) ?? [:]
                    var notice = item.notice
                    if item.coalesced > 1 { notice.message += " (\(item.coalesced) updates)" }
                    let request = try NotificationPayload.request(notice: notice, sink: sink, credentials: credentials)
                    guard item.attempts < 3 else { try finish(item, outcome: "prior delivery outcome uncertain; attempt limit reached"); continue }
                    item.attempts += 1; try save(item)
                    try store.saveObjects([LedgerObject(kind: "notification-throttle", id: sinkID.uuidString, value: Date())])
                    let jobID = item.id, attemptID = UUID()
                    let taskID = try network.send(request, maximumResponseBytes: 16384) { [weak self] result in
                        self?.queue.async { [weak self] in self?.completed(jobID, attemptID: attemptID, result: result) }
                    }
                    inFlight[jobID] = Attempt(id: attemptID, taskID: taskID)
                    lastDelivery[sinkID] = .now
                } else {
                    guard settings.banners || settings.chimes || settings.speech else { try finish(item, outcome: "desktop delivery disabled"); continue }
                    guard item.due <= .now else { continue }
                    guard Date().timeIntervalSince(lastDesktop) >= 2 else { continue }
                    var notice = item.notice
                    if item.coalesced > 1 { notice.message += " (\(item.coalesced) updates)" }
                    // Commit completion before dispatch: a daemon handover must not replay a banner.
                    try store.saveObjects([LedgerObject(kind: "notification-throttle", id: "desktop", value: Date())])
                    try finish(item, outcome: "offered to attached desktop"); lastDesktop = .now
                    onDesktop?(DesktopNotificationDelivery(notice: notice, settings: settings))
                }
            } catch { failure = error.localizedDescription; do { try finish(item, outcome: "configuration or storage unavailable") } catch { failure = error.localizedDescription } }
        }
    }
    private func reloadSettingsIfDue() {
        guard Date().timeIntervalSince(lastSettingsRead) >= 2 else { return }
        lastSettingsRead = .now
        do {
            guard let bytes = try PrivateFile.read(settingsURL), bytes != settingsBytes else { return }
            let fresh = try HarnessSettings.reload(data: bytes)
            settings = NotificationPolicySettings(legacy: fresh)
            commandThreshold = Double(max(0, fresh.commandFinishedThresholdSeconds))
            settingsBytes = bytes; settingsFailure = nil
        } catch { settingsFailure = "Notification settings could not be reloaded; the last working policy remains active." }
    }
    private func completed(_ id: UUID, attemptID: UUID, result: Result<HTTPResult, Error>) {
        // Cancellation can finish after a redacted replacement has been submitted.
        // Only the matching attempt may consume that delivery's pending state.
        guard accepting, inFlight[id]?.id == attemptID, var item = pending[id] else { return }
        inFlight.removeValue(forKey: id)
        do {
            if case let .success(response) = result, (200..<300).contains(response.status) {
                if item.sinkID.flatMap({ id in settings.sinks.first { $0.id == id } })?.kind == .pushover {
                    guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], (json["status"] as? Int) == 1 else { try finish(item, outcome: "Pushover rejected delivery"); return }
                }
                try finish(item, outcome: "delivered"); return
            }
            let retryable: Bool
            var retryAfter: Double?
            switch result {
            case .failure: retryable = true
            case let .success(response):
                retryable = response.status == 429 || response.status >= 500
                retryAfter = response.retryAfter.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
            if retryable && item.attempts < 3 && item.expires > Date() {
                let delay = min(60, max(pow(2, Double(item.attempts)), retryAfter ?? 0)) + Double.random(in: 0...1)
                item.due = Date().addingTimeInterval(delay); try save(item)
            } else {
                let code: String
                if case let .success(response) = result { code = "HTTP \(response.status)" } else { code = "transport failed" }
                try finish(item, outcome: code)
            }
        } catch { failure = error.localizedDescription }
    }
    private func finish(_ item: PendingDelivery, outcome: String) throws {
        if let attempt = inFlight.removeValue(forKey: item.id) { network.cancel(attempt.taskID) }
        try store.removeObjects(kind: "notification-pending", ids: [item.id.uuidString]); pending.removeValue(forKey: item.id)
        diagnostics.append(NotificationDeliveryDiagnostic(sinkID: item.sinkID, noticeID: item.notice.id, outcome: outcome))
        diagnostics = Array(diagnostics.suffix(100))
        try store.saveObjects([LedgerObject(kind: "notification-diagnostics", id: "recent", value: diagnostics)])
    }
    func reportOverflow() {
        overflowLock.lock(); overflowed = true; overflowLock.unlock()
    }
    private let overflowLock = NSLock()
    private var overflowed = false
}
