import Foundation
import HarnessCore
import XCTest
@testable import HarnessDaemonCore

final class TranscriptUsageTests: XCTestCase {
    private func protection() throws -> HistoryProtection {
        #if os(macOS)
        return try HistoryProtection(keyMaterial: Data(repeating: 91, count: 32))
        #else
        return .system()
        #endif
    }
    func testCommittedCursorsCumulativeWatermarksPartialLinesAndRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("husage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for provider in [AgentKind.codex, .claudeCode] {
            let file = root.appendingPathComponent(provider.rawValue + ".jsonl")
            let store = ActivityStore(url: root.appendingPathComponent(provider.rawValue + ".sqlite"), protection: try protection())
            let profile = AgentProfile(name: "fixture", provider: provider, transcriptRoots: [root.path])
            let host = UUID(), service = TranscriptUsageService(store: store, hostID: host, warm: false, settings: ActivitySettings(profiles: [profile]))
            var run = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 1, provider: provider, profile: "fixture")
            run.conversationID = "fixture-conversation"
            let timestamp = Date().formatted(.iso8601)
            func observation(_ input: Int, _ output: Int, id: String = "a") -> String {
                if provider == .codex {
                    return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)},\"last_token_usage\":{\"input_tokens\":10}},\"rate_limits\":{\"primary\":{\"used_percent\":40,\"window_minutes\":300,\"resets_at\":2000000000}}}}"
                }
                return "{\"timestamp\":\"\(timestamp)\",\"type\":\"assistant\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}"
            }
            let initial = observation(10, 3)
            try Data((initial + "\n" + initial + "\n").utf8).write(to: file)
            service.bind(run, path: file.path); service.refreshNow()
            func summary() throws -> ProfileUsage {
                try XCTUnwrap(service.summary(from: Date().addingTimeInterval(-86400), to: Date().addingTimeInterval(86400)).profiles.first)
            }
            XCTAssertEqual(try summary().counters.input, 10)
            XCTAssertEqual(try summary().counters.output, 3)
            // Same-message observations can increase output, but must not repeat input.
            let partial = observation(10, 5)
            let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd()
            try writer.write(contentsOf: Data(partial.utf8)); try writer.close()
            service.refreshNow(); XCTAssertEqual(try summary().counters.output, 3)
            let newline = try FileHandle(forWritingTo: file); try newline.seekToEnd(); try newline.write(contentsOf: Data([10])); try newline.close()
            service.refreshNow(); XCTAssertEqual(try summary().counters.input, 10); XCTAssertEqual(try summary().counters.output, 5)
            // Inode rotation and truncation repeat prior records. Persistent watermark
            // identities deduplicate independently of file offsets and execution IDs.
            let rotated = file.appendingPathExtension("old")
            try FileManager.default.moveItem(at: file, to: rotated)
            try Data((initial + "\n" + partial + "\n").utf8).write(to: file)
            service.refreshNow(); XCTAssertEqual(try summary().counters.input, 10); XCTAssertEqual(try summary().counters.output, 5)
            var resumed = run; resumed.id = UUID()
            service.bind(resumed, path: file.path); service.refreshNow()
            XCTAssertEqual(try summary().counters.input, 10)
            // A rate-limit-only Codex observation carries no usage values.
            if provider == .codex {
                let update = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"used_percent\":42}}}}\n"
                let append = try FileHandle(forWritingTo: file); try append.seekToEnd(); try append.write(contentsOf: Data((update + partial + "\n").utf8)); try append.close()
                service.refreshNow(); XCTAssertEqual(try summary().counters.input, 10); XCTAssertEqual(try summary().limits.first?.usedPercent, 40)
            }
            service.suspend()
        }
    }

    func testModelPricingRetainsLegacyUnknownCoverageAndCommittedContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("husage-pricing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: try protection())
        let profile = AgentProfile(name: "fixture", provider: .claudeCode, transcriptRoots: [root.path], pricing: [UsagePrice(model: "fixture-model", currency: "USD", input: 2, output: 10, cachedInput: 1, cacheCreation: 3)])
        let now = Date(), day = floor(now.timeIntervalSince1970 / 86400) * 86400
        struct OldBucket: Codable { var profileID: UUID; var profile: String; var provider: AgentKind; var from: Date; var to: Date; var counters: UsageCounters; var observedAt: Date }
        let old = OldBucket(profileID: profile.id, profile: profile.name, provider: profile.provider, from: Date(timeIntervalSince1970: day), to: Date(timeIntervalSince1970: day + 86400), counters: UsageCounters(input: 12, output: 5), observedAt: now)
        try store.saveObjects([LedgerObject(kind: "usage", id: profile.id.uuidString + ":" + String(Int64(day)), value: old, at: old.to)])
        let file = root.appendingPathComponent("transcript.jsonl")
        let line = "{\"timestamp\":\"\(now.formatted(.iso8601))\",\"type\":\"assistant\",\"message\":{\"id\":\"priced\",\"model\":\"fixture-model\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":100000,\"cache_read_input_tokens\":200000,\"cache_creation_input_tokens\":100000}}}\n"
        try Data((line + line).utf8).write(to: file)
        let host = UUID(), service = TranscriptUsageService(store: store, hostID: host, warm: false, settings: ActivitySettings(profiles: [profile]))
        let run = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 1, provider: profile.provider, profile: profile.name)
        service.bind(run, path: file.path); service.refreshNow(); service.suspend()
        let result = try XCTUnwrap(service.summary(from: old.from, to: old.to).profiles.first)
        XCTAssertEqual(result.counters.input, 1_000_012)
        XCTAssertEqual(result.costs?.first?.amount, Decimal(string: "3.5"))
        XCTAssertEqual(result.costs?.first?.incomplete, true, "Legacy tokens have no trustworthy model attribution")
        try store.flush()
        let reopened = TranscriptUsageService(store: store, hostID: host, warm: false, settings: ActivitySettings(profiles: [profile]))
        reopened.refreshNow(); reopened.suspend()
        XCTAssertEqual(try reopened.summary(from: old.from, to: old.to).profiles.first?.costs?.first?.amount, Decimal(string: "3.5"))
    }

    func testRepositoryUsageExcludesHistoricalAndCrossExecutionBaselinesAndSurvivesClosedDetailRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hrepo-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), host = UUID(), store = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: try protection())
        let profile = AgentProfile(name: "fixture", provider: .codex, transcriptRoots: [root.path], pricing: [UsagePrice(model: "fixture-model", currency: "USD", input: 1_000_000, output: 0)])
        let service = TranscriptUsageService(store: store, hostID: host, warm: false, settings: ActivitySettings(profiles: [profile]))
        defer { service.suspend() }
        var first = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "first", pid: 1, provider: .codex, profile: profile.name, at: now.addingTimeInterval(-20))
        first.directory = root.appendingPathComponent("main").path
        first.repository = GitRepository(worktree: first.directory!, commonDirectory: root.appendingPathComponent("common.git").path)
        first.conversationID = "shared-conversation"; try store.save(first)
        let file = root.appendingPathComponent("transcript.jsonl")
        func line(_ seconds: TimeInterval, _ total: Int) -> String {
            "{\"timestamp\":\"\(now.addingTimeInterval(seconds).formatted(.iso8601))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":0}}}}\n"
        }
        let context = "{\"type\":\"turn_context\",\"payload\":{\"model\":\"fixture-model\"}}\n"
        try Data((context + line(-30, 100) + line(-15, 120) + line(-10, 150)).utf8).write(to: file)
        service.bind(first, path: file.path); service.refreshNow()
        for index in 0..<301 {
            _ = try store.record(RunEvent(runID: first.id, kind: .toolCompleted, source: .hook, at: now.addingTimeInterval(-10), toolID: "tool-\(index)"), reducing: &first)
        }
        var second = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "second", pid: 2, provider: .codex, profile: profile.name, at: now.addingTimeInterval(-5))
        second.directory = root.appendingPathComponent("linked-worktree").path
        second.repository = GitRepository(worktree: second.directory!, commonDirectory: first.repository!.commonDirectory)
        second.conversationID = first.conversationID; try store.save(second)
        service.bind(second, path: file.path)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data((line(-3, 160) + line(-1, 175)).utf8)); try handle.close()
        service.refreshNow(); service.suspend()
        let from = now.addingTimeInterval(-60), to = now.addingTimeInterval(60)
        let usage = try XCTUnwrap(service.summary(from: from, to: to).profiles.first)
        XCTAssertEqual(usage.counters.input, 175)
        XCTAssertEqual(usage.costs?.first?.amount, 45, "Only deltas with an observed baseline in the same execution have trustworthy current-model pricing")
        XCTAssertEqual(usage.costs?.first?.incomplete, true)
        var page = try store.repositoryDigests(hostID: host, from: from, to: to, offset: 0, limit: 1)
        let report = try XCTUnwrap(page.reports.first)
        XCTAssertEqual(report.repository, first.repository?.commonDirectory)
        XCTAssertEqual(report.worktrees.count, 2); XCTAssertNil(page.nextOffset)
        XCTAssertEqual(report.totals.executions, 2); XCTAssertEqual(report.totals.toolsCompleted, 301)
        XCTAssertEqual(report.usage.first?.counters.input, 45)
        XCTAssertTrue(report.usage.first?.limits.isEmpty ?? false, "Account-wide limits never join repository totals")
        let (totals, timeline, truncated) = try store.digestEvents(from: from, to: to)
        XCTAssertEqual(report.totals.toolsCompleted, totals.toolsCompleted); XCTAssertEqual(timeline.count, 200); XCTAssertTrue(truncated)
        XCTAssertThrowsError(try store.repositoryDigests(hostID: host, from: from, to: to, offset: 0, limit: 1, cancelled: { true }))
        first.endedAt = now; first.process = .exited; second.endedAt = now; second.process = .exited
        try store.save(first); try store.save(second); try store.prune(now: now.addingTimeInterval(15 * 86400))
        XCTAssertNil(try store.run(first.id)); XCTAssertNil(try store.run(second.id))
        page = try store.repositoryDigests(hostID: host, from: from, to: to, offset: 0, limit: 1)
        XCTAssertEqual(page.reports.first?.usage.first?.counters.input, 45, "Usage attribution survives the shorter closed-detail retention")
        try store.removeCapturedText(surfaceID: first.surfaceID)
        page = try store.repositoryDigests(hostID: host, from: from, to: to, offset: 0, limit: 1)
        XCTAssertEqual(page.reports.first?.usage.first?.counters.input, 15)
        XCTAssertEqual(page.reports.first?.worktrees, [second.repository!.worktree])
    }

    func testCoverageWarningsPersistAndOnlyObservedNewWindowsShowResetEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("husage-coverage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.jsonl"), database = root.appendingPathComponent("activity.sqlite")
        let profile = AgentProfile(name: "fixture", provider: .codex, transcriptRoots: [root.path]), host = UUID()
        let settings = ActivitySettings(profiles: [profile])
        let store = ActivityStore(url: database, protection: try protection())
        let service = TranscriptUsageService(store: store, hostID: host, warm: false, settings: settings)
        var run = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 1, provider: .codex, profile: "fixture")
        run.conversationID = "conversation"; try store.save(run)
        let old = Date().addingTimeInterval(-60), boundary = Date().addingTimeInterval(-30)
        func line(_ at: Date, _ used: Int, _ reset: Date) -> String {
            "{\"timestamp\":\"\(at.formatted(.iso8601))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":\(used),\"resets_at\":\(Int(reset.timeIntervalSince1970))}}}}\n"
        }
        try Data(("invalid JSON\n" + line(old, 95, boundary)).utf8).write(to: file)
        service.bind(run, path: file.path); service.refreshNow()
        var summary = try service.summary(from: .now.addingTimeInterval(-86400), to: .now.addingTimeInterval(86400))
        XCTAssertFalse(summary.profiles.first?.coverageWarnings?.isEmpty ?? true)
        XCTAssertNil(summary.profiles.first?.limits.first?.resetObservedAt, "Predicted time passing is not reset evidence")
        let append = try FileHandle(forWritingTo: file); try append.seekToEnd()
        try append.write(contentsOf: Data(line(.now, 2, .now.addingTimeInterval(300)).utf8)); try append.close()
        service.refreshNow(); service.refreshNow(); service.suspend(); try store.flush()
        let reopened = ActivityStore(url: database, protection: try protection())
        let reader = TranscriptUsageService(store: reopened, hostID: host, warm: false, settings: settings)
        reader.refreshNow(); reader.suspend()
        summary = try reader.summary(from: .now.addingTimeInterval(-86400), to: .now.addingTimeInterval(86400))
        XCTAssertFalse(summary.profiles.first?.coverageWarnings?.isEmpty ?? true)
        XCTAssertNotNil(summary.profiles.first?.limits.first?.resetObservedAt)
        XCTAssertNil(summary.profiles.first?.counters.input, "A limit-only observation never invents zero tokens")
    }
    func testKeyRecoveryKeepsCommittedUsageCursorsAndWatermarksAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("husage-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.jsonl"), database = root.appendingPathComponent("activity.sqlite")
        let store = ActivityStore(url: database, protection: .unavailable("Locked"))
        let profile = AgentProfile(name: "fixture", provider: .claudeCode, transcriptRoots: [root.path])
        let host = UUID(), settings = ActivitySettings(profiles: [profile])
        let service = TranscriptUsageService(store: store, hostID: host, warm: false, settings: settings)
        var run = AgentRun(hostID: host, surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 1, provider: .claudeCode, profile: "fixture")
        run.conversationID = "private conversation"; try store.save(run)
        let timestamp = Date().formatted(.iso8601)
        let line = "{\"timestamp\":\"\(timestamp)\",\"type\":\"assistant\",\"message\":{\"id\":\"message\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n"
        try Data(line.utf8).write(to: file)
        service.bind(run, path: file.path); service.refreshNow(); service.suspend()
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertThrowsError(try store.recover(protection: .unavailable("Still locked")))
        try store.recover(protection: try protection()); XCTAssertNil(store.availability)
        try service.activate()
        // Force rotation to read the same observation after the index protection changes.
        try FileManager.default.removeItem(at: file); try Data((line + line).utf8).write(to: file)
        service.refreshNow(); service.suspend(); try store.flush()
        let reopened = ActivityStore(url: database, protection: try protection())
        let reader = TranscriptUsageService(store: reopened, hostID: host, warm: false, settings: settings)
        reader.refreshNow(); reader.suspend()
        let summary = try reader.summary(from: Date().addingTimeInterval(-86400), to: Date().addingTimeInterval(86400))
        XCTAssertEqual(summary.profiles.first?.counters.input, 10)
        XCTAssertEqual(summary.profiles.first?.counters.output, 5)
        XCTAssertEqual(try reopened.run(run.id)?.conversationID, "private conversation")
        #if os(macOS)
        for disk in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where disk.lastPathComponent != file.lastPathComponent {
            XCTAssertNil(try Data(contentsOf: disk).range(of: Data("private conversation".utf8)))
        }
        #endif
    }

    func testDigestTotalsAreIndependentOfTimelineAndOptOutRemovesText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdigest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: try protection())
        let now = Date()
        var run = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 1, provider: .codex, at: now)
        try store.save(run)
        for index in 0..<301 {
            _ = try store.record(RunEvent(runID: run.id, kind: .toolCompleted, source: .hook, at: now, toolID: "tool-\(index)", message: "captured fixture text"), reducing: &run)
        }
        let (totals, timeline, truncated) = try store.digestEvents(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        XCTAssertEqual(totals.toolsCompleted, 301); XCTAssertEqual(timeline.count, 200); XCTAssertTrue(truncated)
        let service = AgentActivityService(store: store, hostID: run.hostID)
        try service.setPersistence(surfaceID: run.surfaceID, enabled: false)
        XCTAssertEqual(try store.events(runID: run.id).count, 0)
        let observation = try ProviderHookAdapter.parse(Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"private conversation\",\"turn_id\":\"t\"}".utf8), contract: .codex202610)
        _ = try service.report(HookReport(surfaceID: run.surfaceID, senderPID: 1, profile: "default", observation: observation), paneID: nil, generation: "fixture", pid: 1, sequence: 8)
        XCTAssertNil(try store.run(run.id)?.conversationID)
        XCTAssertEqual(try store.events(runID: run.id).count, 0)
        let repeated = try service.report(HookReport(surfaceID: run.surfaceID, senderPID: 1, profile: "default", observation: observation), paneID: nil, generation: "fixture", pid: 1, sequence: 9)
        XCTAssertEqual(repeated.id, run.id, "Private hooks retain execution identity after captured profile text has been removed")
        XCTAssertEqual(try store.list(surfaceID: run.surfaceID).runs.count, 1)
    }
}
