import Foundation
import XCTest
import HarnessCore
@testable import HarnessDaemonCore

final class AISummaryServiceTests: XCTestCase {
    func testLocalHTTPDiscoverySubmissionDedupCancellationPrivacyAndRecovery() throws {
        let root = URL(fileURLWithPath: "/tmp/hai-" + UUID().uuidString.prefix(8)); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-u", "-c", Self.serverScript, root.path]; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let portFile = root.appendingPathComponent("port"); XCTAssertTrue(wait { (try? String(contentsOf: portFile, encoding: .utf8)).flatMap(Int.init) != nil }); let port = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 46, count: 32))
        #else
        let protection = HistoryProtection.system()
        #endif
        let store = ActivityStore(url: root.appendingPathComponent("activity.sqlite"), protection: protection), settingsURL = root.appendingPathComponent("settings.json"), surface = UUID().uuidString
        let input = AISummaryInput(data: Data(#"{"activity_totals":{"turnsCompleted":250}}"#.utf8), surfaceIDs: [surface])
        func provider(_ path: String, api: AIProtocol = .responses) -> AIProviderConfiguration {
            var value = AIProviderConfiguration(preset: .custom, modelID: "fixture-model"); value.apiProtocol = api; value.baseURL = "http://127.0.0.1:" + port + path; value.enabled = true; value.consentedDestination = value.destination; return value
        }
        let normal = provider("/normal"), delayed = provider("/delay"), limited = provider("/rate"), paged = provider("/paged", api: .messages)
        var settings = AISettings(); settings.providers = [normal, delayed, limited, paged]
        let service = AISummaryService(store: store, settings: AISettings(), settingsURL: settingsURL, buildInput: { _, _, _, _ in input }); service.activate(); defer { service.suspend() }
        _ = try service.handle(.configure(settings, expected: AISettings()))
        func status() throws -> AIProviderStatus { try JSONDecoder().decode(AIProviderStatus.self, from: service.handle(.status)) }
        XCTAssertTrue(wait { (try? status().refreshing.isEmpty) == true })
        XCTAssertEqual(try status().catalogs.first { $0.providerID == paged.id }?.modelCount, 2)
        XCTAssertEqual(try status().catalogs.first { $0.providerID == normal.id }?.modelCount, 1000, "Large model catalogs survive encrypted ledger storage")
        XCTAssertTrue(try status().catalogs.allSatisfy { $0.models.isEmpty }, "Status carries bounded metadata; model contents are paginated")
        let page1 = try JSONDecoder().decode(AIModelCatalogPage.self, from: service.handle(.catalog(providerID: paged.id, offset: 0, limit: 1))); XCTAssertEqual(page1.nextOffset, 1)
        let page2 = try JSONDecoder().decode(AIModelCatalogPage.self, from: service.handle(.catalog(providerID: paged.id, offset: 1, limit: 1))); XCTAssertNil(page2.nextOffset); XCTAssertNotEqual(page1.catalog.models.first?.id, page2.catalog.models.first?.id)
        let largePage = try JSONDecoder().decode(AIModelCatalogPage.self, from: service.handle(.catalog(providerID: normal.id, offset: 999, limit: 1)))
        XCTAssertEqual(largePage.catalog.models.count, 1); XCTAssertNil(largePage.nextOffset)
        XCTAssertThrowsError(try LedgerObject(kind: "summary", id: UUID().uuidString, value: String(repeating: "x", count: 65_536)), "Ordinary activity records retain their smaller bound")
        try Data().write(to: root.appendingPathComponent("fail-discovery")); _ = try service.handle(.refreshModels(providerID: paged.id)); XCTAssertTrue(wait { (try? status().refreshing.isEmpty) == true }); XCTAssertEqual(try status().catalogs.first { $0.providerID == paged.id }?.modelCount, 2); XCTAssertNotNil(try status().failures[paged.id.uuidString]); try FileManager.default.removeItem(at: root.appendingPathComponent("fail-discovery"))
        let from = Date().addingTimeInterval(-3600), to = Date()
        func submit(_ provider: AIProviderConfiguration, id: UUID = UUID()) throws -> AISummaryRecord { try JSONDecoder().decode(AISummaryRecord.self, from: service.handle(.generate(id: id, providerID: provider.id, workspaceID: nil, from: from, to: to))) }
        func record(_ id: UUID) throws -> AISummaryRecord { try JSONDecoder().decode(AISummaryRecord.self, from: service.handle(.record(id: id))) }
        func posts() -> Int { ((try? String(contentsOf: root.appendingPathComponent("requests"), encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("POST ") }.count }
        let first = try submit(normal); XCTAssertTrue(wait { (try? record(first.id).state) == .completed }); XCTAssertEqual(try record(first.id).output?.text, "PRIVATE_AI_PROSE_SENTINEL"); XCTAssertEqual(try record(first.id).output?.reportedModel, "reported-version")
        let count = posts(); _ = try submit(normal, id: first.id); XCTAssertEqual(posts(), count, "Identical request IDs never make a second POST")
        XCTAssertThrowsError(try submit(limited, id: first.id), "Request IDs cannot silently change provider")
        let rate = try submit(limited); XCTAssertTrue(wait { (try? record(rate.id).state) == .failed }); XCTAssertTrue(try XCTUnwrap(record(rate.id).failure).contains("rate")); let afterRate = posts(); _ = try submit(limited, id: rate.id); XCTAssertEqual(posts(), afterRate)
        let cancel = try submit(delayed); XCTAssertTrue(wait { posts() > afterRate }); _ = try service.handle(.cancel(id: cancel.id)); XCTAssertEqual(try record(cancel.id).state, .cancelled)
        let privateRequest = try submit(delayed); XCTAssertTrue(wait { posts() > afterRate + 1 }); try store.removeCapturedText(surfaceID: surface); try Data().write(to: root.appendingPathComponent("gate")); XCTAssertTrue(wait { (try? record(privateRequest.id).state) != .submitted }); XCTAssertNil(try record(privateRequest.id).output); XCTAssertEqual(try record(privateRequest.id).state, .cancelled); XCTAssertNil(try record(first.id).output, "Opt-out purges previously completed aggregate prose")
        // Recovery must reach recent submissions beyond a full history page.
        let retained = try (0..<500).map { _ -> LedgerObject in
            var receipt = AISummaryRecord(id: UUID(), provider: normal, workspaceID: nil, surfaceIDs: [], from: from, to: to)
            receipt.state = .completed; receipt.finishedAt = .now
            return try LedgerObject(kind: "ai-request", id: receipt.id.uuidString, value: receipt)
        }
        try store.saveObjects(retained)
        let pending = AISummaryRecord(id: UUID(), provider: normal, workspaceID: nil, surfaceIDs: [surface], from: from, to: to)
        try store.saveObjects([LedgerObject(kind: "ai-request", id: pending.id.uuidString, value: pending)])
        service.suspend(); let replacement = AISummaryService(store: store, settings: settings, settingsURL: settingsURL, buildInput: { _, _, _, _ in input }); replacement.activate(); defer { replacement.suspend() }
        let recovered = try JSONDecoder().decode(AISummaryRecord.self, from: replacement.handle(.record(id: pending.id))); XCTAssertEqual(recovered.state, .uncertain)
        let beforeRetry = posts(); _ = try replacement.handle(.generate(id: pending.id, providerID: normal.id, workspaceID: nil, from: from, to: to)); XCTAssertEqual(posts(), beforeRetry, "Daemon recovery never retries a possibly billable request")
        XCTAssertThrowsError(try replacement.handle(.configure(AISettings(), expected: AISettings())), "Stale provider edits are refused")
        #if os(macOS)
        let disk = try Data(contentsOf: root.appendingPathComponent("activity.sqlite")) + ((try? Data(contentsOf: root.appendingPathComponent("activity.sqlite-wal"))) ?? Data()); XCTAssertFalse(String(decoding: disk, as: UTF8.self).contains("PRIVATE_AI_PROSE_SENTINEL"))
        #endif
    }
    private func wait(_ condition: () -> Bool) -> Bool { let end = Date().addingTimeInterval(5); while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.02) }; return condition() }
    private static let serverScript = #"""
import http.server, threading, pathlib, sys, json, time
root=pathlib.Path(sys.argv[1]); lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,code,body):
        data=json.dumps(body).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass
    def observe(self):
        with lock:
            with (root/'requests').open('a') as output: output.write(self.command+' '+self.path+'\n')
    def do_GET(self):
        self.observe()
        if (root/'fail-discovery').exists(): return self.reply(500,{'error':'fixture'})
        if self.path.startswith('/paged/'):
            more='after_id=' not in self.path
            return self.reply(200,{'data':[{'id':'first' if more else 'second'}],'has_more':more,'last_id':'first' if more else 'second'})
        if self.path.startswith('/normal/'):
            return self.reply(200,{'data':[{'id':f'fixture-model-{i:04d}','name':'Catalog entry '+('x'*80)} for i in range(1000)]})
        return self.reply(200,{'data':[{'id':'fixture-model'}]})
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0'))); self.observe()
        if self.path.startswith('/rate/'): return self.reply(429,{'error':'private provider error body'})
        if self.path.startswith('/delay/'):
            end=time.monotonic()+4
            while not (root/'gate').exists() and time.monotonic()<end: time.sleep(.01)
        return self.reply(200,{'model':'reported-version','status':'completed','output':[{'type':'message','role':'assistant','content':[{'type':'output_text','text':'PRIVATE_AI_PROSE_SENTINEL'}]}]})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port)); server.serve_forever()
"""#
}
