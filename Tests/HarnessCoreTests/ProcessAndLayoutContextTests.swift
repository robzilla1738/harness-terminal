import Foundation
import XCTest
@testable import HarnessCore

final class ProcessCaptureTests: XCTestCase {
    func testLargeOutputOnBothStreamsDoesNotDeadlock() throws {
        // 256 KiB on stdout and stderr: four times a pipe buffer each.
        let script = "yes a | head -c 262144; yes b | head -c 262144 >&2; exit 3"
        let result = try ProcessCapture.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout.count, 262_144)
        XCTAssertEqual(result.stderr.count, 262_144)
    }

    func testStdinIsDelivered() throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        let result = try ProcessCapture.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, input)
    }
}

final class SurfaceContextTests: XCTestCase {
    func testContextJSONEscapesNewlinesAndQuotes() throws {
        let context = ControlPlane.SurfaceContext(
            pid: 42, executable: "vim", cwd: "/tmp/a \"b\"\nc", arguments: ["vim", "x y"], isShell: false
        )
        let json = ControlPlane.contextJSON(context)
        let decoded = try JSONDecoder().decode(ControlPlane.SurfaceContext.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, context)
    }

    func testOlderDaemonContextWithoutArgumentsStillDecodes() throws {
        let json = #"{"pid":1,"executable":"zsh","cwd":"/"}"#
        let decoded = try JSONDecoder().decode(ControlPlane.SurfaceContext.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.arguments, [])
        XCTAssertFalse(decoded.isShell)
    }
}

final class NamedLayoutProgramTests: XCTestCase {
    func testIdlePaneRecordsShell() {
        let idle = ControlPlane.SurfaceContext(pid: 1, executable: "zsh", cwd: "/", arguments: ["-zsh"], isShell: true)
        XCTAssertEqual(NamedLayoutStore.program(for: idle), "shell")
        let loginShellName = ControlPlane.SurfaceContext(pid: 1, executable: "-zsh", cwd: "/")
        XCTAssertEqual(NamedLayoutStore.program(for: loginShellName), "shell")
    }

    func testRunningProgramKeepsItsArguments() {
        let editor = ControlPlane.SurfaceContext(
            pid: 9, executable: "nvim", cwd: "/src",
            arguments: ["/opt/homebrew/bin/nvim", "src/Surface.zig", "+231"]
        )
        XCTAssertEqual(NamedLayoutStore.program(for: editor), "nvim src/Surface.zig +231")
        let spaced = ControlPlane.SurfaceContext(pid: 9, executable: "less", cwd: "/", arguments: ["less", "my notes.txt"])
        XCTAssertEqual(NamedLayoutStore.program(for: spaced), "less 'my notes.txt'")
    }

    func testCaptureFallbackSkipsATabWhoseCommandIsAShell() {
        let tab = Tab(title: "t", cwd: "/w", rootPane: .leaf(PaneLeaf()), currentCommand: "zsh")
        let layout = NamedLayoutStore.capture(name: "x", tab: tab)
        XCTAssertEqual(layout.tree, .leaf(program: "shell", cwd: "/w"))
    }
}

final class SessionViewTests: XCTestCase {
    func testSessionViewListsTabsAndPanes() {
        let first = PaneLeaf()
        let second = PaneLeaf()
        var tab = Tab(title: "edit", cwd: "/src", rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second)))
        tab.activePaneID = second.id
        let session = SessionGroup(name: "Work", tabs: [tab], activeTabID: tab.id)
        let workspace = Workspace(name: "Default", sessions: [session])
        let snapshot = SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id)

        let view = HarnessAPI.sessionView(snapshot: snapshot, sessionID: session.id.uuidString.lowercased())
        XCTAssertEqual(view?.label, "Work")
        XCTAssertEqual(view?.activeTab, tab.id.uuidString)
        XCTAssertEqual(view?.tabs.count, 1)
        XCTAssertEqual(view?.tabs.first?.panes.map(\.surface), [first.surfaceID.uuidString, second.surfaceID.uuidString])
        XCTAssertEqual(view?.tabs.first?.panes.map(\.active), [false, true])
        XCTAssertNil(HarnessAPI.sessionView(snapshot: snapshot, sessionID: UUID().uuidString))
    }
}

final class ReviewFixTests: XCTestCase {
    func testProgramUsesArgv0AndKeepsShellScripts() {
        let truncated = ControlPlane.SurfaceContext(pid: 1, executable: "rust-analyzer-p", cwd: "/", arguments: ["/usr/bin/rust-analyzer-proxy", "--stdio"])
        XCTAssertEqual(NamedLayoutStore.program(for: truncated), "rust-analyzer-proxy --stdio")
        let script = ControlPlane.SurfaceContext(pid: 1, executable: "bash", cwd: "/", arguments: ["bash", "./deploy.sh"])
        XCTAssertEqual(NamedLayoutStore.program(for: script), "bash ./deploy.sh")
        let nested = ControlPlane.SurfaceContext(pid: 1, executable: "zsh", cwd: "/", arguments: ["zsh", "-l"])
        XCTAssertEqual(NamedLayoutStore.program(for: nested), "shell")
    }

    func testLightDefaultMigratesOnceThenAChoiceSticks() throws {
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: Data(#"{"systemLightThemeName":"Zenwritten Light"}"#.utf8))
        XCTAssertEqual(migrated.systemLightThemeName, "Harness Light")
        var chosen = migrated
        chosen.systemLightThemeName = "Zenwritten Light"
        let reloaded = try JSONDecoder().decode(HarnessSettings.self, from: try JSONEncoder().encode(chosen))
        XCTAssertEqual(reloaded.systemLightThemeName, "Zenwritten Light")
    }

    func testAllDigitFragmentsStillResolve() {
        let leaf = PaneLeaf(surfaceID: UUID(uuidString: "48213F00-0000-0000-0000-000000000001")!)
        let tab = Tab(title: "t", rootPane: .leaf(leaf))
        let session = SessionGroup(tabs: [tab], activeTabID: tab.id)
        let workspace = Workspace(sessions: [session], activeSessionID: session.id)
        let snapshot = SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id)
        XCTAssertEqual(TargetResolver.resolve("4821", kind: .surface, in: snapshot), .resolved(leaf.surfaceID.uuidString))
        XCTAssertEqual(TargetResolver.resolve("1", kind: .surface, in: snapshot), .resolved(leaf.surfaceID.uuidString))
        guard case .notFound = TargetResolver.resolve("7", kind: .surface, in: snapshot) else { return XCTFail() }
    }
}

