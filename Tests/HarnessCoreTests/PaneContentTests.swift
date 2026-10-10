import XCTest
@testable import HarnessCore

final class PaneContentTests: XCTestCase {
    func testTypedLayoutsRoundTripUnknownContentAndProjectOnlyResponses() throws {
        let spec = PreviewSpecification(url: "http://127.0.0.1:3000/page?q=1#top", title: "App")
        XCTAssertEqual(try spec.forwardedURL(port: 4567).absoluteString, "http://127.0.0.1:4567/page?q=1#top")
        for value in ["file:///tmp/index.html", "http://example.com", "http://127.1:3000", "http://127.0.00.1", "http://localhost.evil", "http://user:pass@localhost", "http://localhost:0"] {
            XCTAssertThrowsError(try PreviewSpecification(url: value).validatedURL(), value)
        }
        _ = try PreviewSpecification(url: "http://[::1]:8080").validatedURL()
        var editor = SessionEditor(); let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace), tab = try XCTUnwrap(workspace.activeTab), leaf = try XCTUnwrap(tab.rootPane.allLeaves().first)
        XCTAssertTrue(editor.setPaneContent(surfaceID: leaf.surfaceID, content: .preview(spec)))
        let typed = editor.snapshot
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(typed))
        XCTAssertEqual(decoded, typed)
        XCTAssertEqual(typed.projected(for: [DaemonStats.paneContent]), typed)
        XCTAssertTrue(try XCTUnwrap(typed.projected(for: []).activeWorkspace?.activeTab?.rootPane.allLeaves().first).paneContent.isTerminal)
        XCTAssertEqual(typed.activeWorkspace?.activeTab?.rootPane.allLeaves().first?.content, .preview(spec))
        let setup = SavedSetup(name: "App", tabs: [SetupTab(try XCTUnwrap(typed.activeWorkspace?.activeTab))]); try setup.validate()
        XCTAssertEqual(setup.tabs[0].layout.makePaneTree().allLeaves()[0].content, .preview(spec))
        let future = Data(#"{"kind":"future","values":{"large":18446744073709551615,"nested":[true,null,"payload"]}}"#.utf8)
        let content = try JSONDecoder().decode(PaneContent.self, from: future)
        XCTAssertFalse(content.isTerminal)
        XCTAssertEqual(try JSONDecoder().decode(PaneContent.self, from: JSONEncoder().encode(content)), content)
    }
    func testExpandedAgentIdentitiesProjectOnlyAtResponseBoundary() throws {
        var editor = SessionEditor()
        let leaf = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab?.rootPane.allLeaves().first)
        let agent = AgentSnapshot(kind: .muse, executable: "muse", pid: 123)
        XCTAssertTrue(editor.updatePaneActivity(surfaceID: leaf.surfaceID) { $0.agent = agent })
        let canonical = editor.snapshot
        let old = canonical.projected(for: [DaemonStats.paneContent])
        XCTAssertEqual(old.activeWorkspace?.activeTab?.agent?.kind, .generic)
        XCTAssertEqual(old.activeWorkspace?.activeTab?.rootPane.allLeaves().first?.activity?.agent?.kind, .generic)
        XCTAssertEqual(canonical.activeWorkspace?.activeTab?.agent?.kind, .muse)
        XCTAssertEqual(canonical.projected(for: [DaemonStats.paneContent, DaemonStats.agentIdentities]), canonical)
        let run = AgentRun(hostID: UUID(), surfaceID: leaf.surfaceID.uuidString, processGeneration: "birth", pid: 123, provider: .muse)
        XCTAssertEqual(ActivityResponseCompatibility.run(run, capabilities: [DaemonStats.activityState]).provider, .generic)
        XCTAssertEqual(ActivityResponseCompatibility.run(run, capabilities: [DaemonStats.activityState, DaemonStats.agentIdentities]), run)
        // Existing request case names and absent capabilities remain decodable.
        let legacy = try JSONDecoder().decode(IPCRequest.self, from: Data(#"{"listAgents":{}}"#.utf8))
        guard case let .listAgents(capabilities) = legacy else { return XCTFail("Changed request contract") }
        XCTAssertNil(capabilities)
        let modern = IPCRequest.listAgents(capabilities: [DaemonStats.agentIdentities])
        guard case let .listAgents(decoded) = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(modern)) else { return XCTFail("Changed request contract") }
        XCTAssertEqual(decoded, [DaemonStats.agentIdentities])
        enum PreviousRequest: Codable { case listAgents }
        guard case .listAgents = try JSONDecoder().decode(PreviousRequest.self, from: JSONEncoder().encode(modern)) else { return XCTFail("Previous daemon cannot ignore optional capability fields") }
    }

    func testLegacyActivityResponseKeepsCanonicalLaunchAuthority() throws {
        var run = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "birth", pid: 1, provider: .codex)
        run.source = .launch; run.profileSource = .launch; run.directorySource = .launch
        let old = ActivityResponseCompatibility.run(run, capabilities: nil)
        XCTAssertEqual(old.source, .process); XCTAssertEqual(old.profileSource, .process); XCTAssertEqual(old.directorySource, .process)
        XCTAssertEqual(run.source, .launch)
        XCTAssertEqual(ActivityResponseCompatibility.run(run, capabilities: [DaemonStats.activityState]), run)
        let request = Data(#"{"list":{"activeOnly":true,"offset":0,"limit":100}}"#.utf8)
        _ = try JSONDecoder().decode(ActivityOperation.self, from: request)
    }
}
