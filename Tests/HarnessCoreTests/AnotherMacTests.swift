import XCTest
@testable import HarnessCore

/// Another Mac: two owning filesystems, sidebar groups, size ownership, Tailscale
/// confirm-before-save, and the follow events. These call the functions the daemon
/// and the app call. They do not stand up two daemons in one process.
final class AnotherMacTests: XCTestCase {
    func testTwoSocketsListDirReturnsTheOwningDaemonsPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-listdir-\(UUID().uuidString)", isDirectory: true)
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        let child = left.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: left.appendingPathComponent("alpha.txt"))
        try Data("b".utf8).write(to: right.appendingPathComponent("beta.txt"))
        try Data("c".utf8).write(to: child.appendingPathComponent("inside.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let leftListing = PaneDirectory.listing(cwd: left.path, path: nil)
        let rightListing = PaneDirectory.listing(cwd: right.path, path: nil)
        XCTAssertEqual(leftListing.root, PaneDirectory.root(cwd: left.path, path: nil))
        XCTAssertEqual(rightListing.root, right.path)
        XCTAssertEqual(Set(leftListing.entries.map(\.name)), ["alpha.txt", "child"])
        XCTAssertEqual(rightListing.entries.map(\.name), ["beta.txt"])
        XCTAssertTrue(leftListing.entries.first { $0.name == "child" }?.directory == true)
        XCTAssertFalse(leftListing.entries.contains { $0.name == "beta.txt" })
        XCTAssertFalse(rightListing.entries.contains { $0.name == "alpha.txt" })

        XCTAssertEqual(PaneDirectory.root(cwd: left.path, path: nil), left.path)
        XCTAssertEqual(PaneDirectory.root(cwd: "", path: nil), "/")
        XCTAssertEqual(PaneDirectory.root(cwd: left.path, path: ""), left.path)
        let replaced = PaneDirectory.listing(cwd: left.path, path: right.path)
        XCTAssertEqual(replaced.root, (right.path as NSString).standardizingPath)
        XCTAssertEqual(replaced.entries.map(\.name), ["beta.txt"])
        let joined = PaneDirectory.listing(cwd: left.path, path: "child")
        XCTAssertEqual(joined.root, (left.path as NSString).appendingPathComponent("child"))
        XCTAssertEqual(joined.entries.map(\.name), ["inside.txt"])

        let decoded = PaneDirectory.decode(PaneDirectory.json(cwd: right.path, path: nil))
        XCTAssertEqual(decoded, rightListing)

        let quoted = PaneDirectory.insertion(["/Users/me/My Files"])
        XCTAssertEqual(quoted, ShellQuoting.quote("/Users/me/My Files"))
        XCTAssertEqual(quoted, "'/Users/me/My Files'")
        XCTAssertEqual(PaneDirectory.goToDirectory("/Users/me/My Files"), "cd \(quoted)")

        let catalog = APICatalog(panes: [
            APIPaneRecord(surfaceID: "surface-a", paneID: "pane-a", tabID: "tab", sessionID: "session", label: "shell"),
        ])
        let plan = HarnessAPI.plan(
            method: "pane.list_dir",
            arguments: ["pane": .string("shell"), "path": .string(right.path)],
            catalog: catalog,
            environment: APIEnvironment(environment: [:])
        )
        guard case let .query(.listDir(surfaceID, path)) = plan else {
            return XCTFail("expected list_dir, got \(plan)")
        }
        XCTAssertEqual(surfaceID, "surface-a")
        XCTAssertEqual(path, right.path)
    }

    func testDirectoryNavigationPreservesSpacesInNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-path-\(UUID())")
        let folder = root.appendingPathComponent(" folder ")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: folder.appendingPathComponent("file.txt"))
        for path in [folder.path, " folder "] {
            let listing = PaneDirectory.listing(cwd: root.path, path: path)
            XCTAssertEqual(listing.root, folder.path)
            XCTAssertEqual(listing.entries.map(\.name), ["file.txt"])
        }
        XCTAssertEqual(PaneDirectory.root(cwd: root.path, path: "  "), root.appendingPathComponent("  ").path)
    }

    func testNonOwnerPrimaryResizeLeavesOwnerSizeUnchangedAndAlternateDoesNotReflow() {
        var arbiter = SurfaceSizeArbiter(mode: .owner)
        let surface = "surface"
        let owner = OwnerResize.effect(
            arbiter: &arbiter, client: 1, surface: surface, rows: 40, cols: 120, alternateScreen: false
        )
        XCTAssertEqual(owner.pty, SurfaceSize(rows: 40, cols: 120))
        XCTAssertNil(owner.localReflow)
        XCTAssertEqual(arbiter.effectiveSize(surface), SurfaceSize(rows: 40, cols: 120))
        XCTAssertEqual(arbiter.owner(of: surface), 1)

        let primary = OwnerResize.effect(
            arbiter: &arbiter, client: 2, surface: surface, rows: 24, cols: 80, alternateScreen: false
        )
        XCTAssertNil(primary.pty)
        XCTAssertEqual(primary.localReflow, SurfaceSize(rows: 24, cols: 80))
        XCTAssertEqual(arbiter.effectiveSize(surface), SurfaceSize(rows: 40, cols: 120))

        let alternate = OwnerResize.effect(
            arbiter: &arbiter, client: 2, surface: surface, rows: 24, cols: 80, alternateScreen: true
        )
        XCTAssertNil(alternate.pty)
        XCTAssertNil(alternate.localReflow)
        XCTAssertEqual(arbiter.effectiveSize(surface), SurfaceSize(rows: 40, cols: 120))

        let handed = arbiter.disconnect(client: 1, surface: surface)
        XCTAssertEqual(arbiter.owner(of: surface), 2)
        XCTAssertEqual(handed, SurfaceSize(rows: 24, cols: 80))
        XCTAssertEqual(arbiter.effectiveSize(surface), SurfaceSize(rows: 24, cols: 80))

        var smallest = SurfaceSizeArbiter(mode: .smallest)
        let shared = OwnerResize.effect(
            arbiter: &smallest, client: 3, surface: surface, rows: 30, cols: 90, alternateScreen: false
        )
        XCTAssertEqual(shared.pty, SurfaceSize(rows: 30, cols: 90))
        XCTAssertNil(shared.localReflow)
    }

    func testSidebarGroupsSessionsUnderTheOwningDaemon() {
        let groups = DaemonSidebar.groups(
            localTitle: "This Mac",
            sessions: [
                DaemonSidebarSession(id: "local-1", name: "shell", owner: ""),
                DaemonSidebarSession(id: "remote-1", name: "build", owner: "devbox"),
            ],
            remoteHosts: ["devbox"],
            remoteDetail: RemoteAttach.explanation
        )
        XCTAssertEqual(groups.map(\.id), ["local", "devbox"])
        XCTAssertEqual(groups[0].title, "This Mac")
        XCTAssertEqual(groups[0].sessions.map(\.id), ["local-1"])
        XCTAssertEqual(groups[0].sessions[0].owner, DaemonSidebar.localID)
        XCTAssertEqual(groups[1].sessions.map(\.id), ["remote-1"])
        XCTAssertEqual(groups[1].detail, "This remote session is your daemon on that machine, over your SSH.")
        XCTAssertEqual(groups[1].detail, RemoteAttach.explanation)
        XCTAssertEqual(DaemonSidebar.splitDaemon(owner: "devbox"), "devbox")
        XCTAssertEqual(DaemonSidebar.splitDaemon(owner: ""), DaemonSidebar.localID)

        let remoteOnly = DaemonSidebar.groups(
            localTitle: "This Mac",
            sessions: [DaemonSidebarSession(id: "remote-1", name: "build", owner: "devbox")],
            remoteHosts: ["devbox"],
            remoteDetail: RemoteAttach.explanation
        )
        XCTAssertEqual(remoteOnly.first?.id, DaemonSidebar.localID)
        XCTAssertTrue(remoteOnly.first?.sessions.isEmpty == true)
    }

    func testTailscalePeersAreStoredOnlyAfterConfirmAndFollowEventsNeedTheCommand() throws {
        let json = """
        {"Self":{"HostName":"this-mac","DNSName":"this-mac.tail.ts.","Online":true},\
        "Peer":{"n1":{"HostName":"devbox","DNSName":"devbox.tail.ts.","TailscaleIPs":["100.1.2.3"],"Online":true},\
        "n2":{"HostName":"offline","DNSName":"offline.tail.ts.","Online":false}}}
        """
        let peers = TailscalePeers.parse(Data(json.utf8))
        XCTAssertEqual(peers.map(\.hostName), ["devbox"])
        XCTAssertEqual(peers[0].suggestedSSH, "user@devbox.tail.ts")
        XCTAssertFalse(TailscalePeers.joinsTailnet(TailscalePeers.statusArguments))
        XCTAssertEqual(TailscalePeers.statusArguments, ["tailscale", "status", "--json"])

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RemoteHostStore(fileURL: file)
        XCTAssertNil(TailscalePeers.confirmedHost(name: "devbox", sshTarget: "user@devbox", socketPath: " "))
        XCTAssertTrue(store.load().isEmpty)
        let host = try XCTUnwrap(TailscalePeers.confirmedHost(
            name: " devbox ", sshTarget: " user@devbox ", socketPath: " /tmp/harness.sock "
        ))
        XCTAssertEqual(host, RemoteHost(name: "devbox", sshTarget: "user@devbox", remoteSocketPath: "/tmp/harness.sock"))
        XCTAssertTrue(store.load().isEmpty, "confirming a host must not write the store")
        XCTAssertTrue(store.upsert(host).saved)
        XCTAssertEqual(store.load(), [host])

        XCTAssertNil(FollowEvent.tailscaleStatusChanged(commandPresent: false, peerCount: 4))
        let status = try XCTUnwrap(FollowEvent.tailscaleStatusChanged(commandPresent: true, peerCount: 2))
        XCTAssertEqual(status.type, "server.tailscale_status")
        XCTAssertEqual(status.payload["server"], .bool(true))
        XCTAssertEqual(status.payload["peers"], .int(2))

        let dropped = FollowEvent.clientConnection(state: "dropped", client: "client-2", host: "devbox")
        XCTAssertEqual(dropped.type, "client.connection")
        XCTAssertEqual(dropped.payload["server"], .bool(true))
        XCTAssertFalse(FollowSubscription(includeServer: false).accepts(dropped))
        XCTAssertFalse(FollowSubscription(includeServer: false).accepts(status))
        XCTAssertTrue(FollowSubscription(includeServer: true).accepts(dropped))
        XCTAssertTrue(FollowSubscription(includeServer: true).accepts(status))
    }

    func testFindFilesStaysAdHocSSHAndAttachUsesTheTunnelSocket() {
        let args = ControlPlane.sshFindArguments(target: "user@devbox", extra: ["-p", "22"], root: "/home/me")
        XCTAssertEqual(args.first, "ssh")
        XCTAssertTrue(args.contains { $0.contains("find ") })
        XCTAssertFalse(args.contains { $0.contains("list_dir") })

        XCTAssertFalse(RemoteAttach.isTunnel(.localControlSocket))
        XCTAssertFalse(RemoteAttach.isTunnel(.tcp(host: "127.0.0.1", port: 9)))
        let tunnel = HarnessPaths.tunnelsDirectory.appendingPathComponent("devbox.sock").path
        XCTAssertTrue(RemoteAttach.isTunnel(.unix(path: tunnel)))
        XCTAssertEqual(
            RemoteAttach.explanation,
            "This remote session is your daemon on that machine, over your SSH."
        )
        XCTAssertTrue(RemoteControlPolicy.allowsGUI(tunnel: false, enabled: false))
        XCTAssertFalse(RemoteControlPolicy.allowsGUI(tunnel: true, enabled: false))
        XCTAssertTrue(RemoteControlPolicy.allowsGUI(tunnel: true, enabled: true))
    }

    func testExactlyOneClientAnswersQueriesInEitherMode() {
        var smallest = SurfaceSizeArbiter(mode: .smallest)
        _ = smallest.vote(client: 1, surface: "s", rows: 40, cols: 120)
        _ = smallest.vote(client: 2, surface: "s", rows: 30, cols: 90)
        XCTAssertEqual(smallest.responder(of: "s"), 2, "the most recent voter answers")
        _ = smallest.disconnect(client: 2)
        XCTAssertEqual(smallest.responder(of: "s"), 1)

        var owner = SurfaceSizeArbiter(mode: .owner)
        _ = owner.vote(client: 1, surface: "s", rows: 40, cols: 120)
        _ = owner.vote(client: 2, surface: "s", rows: 30, cols: 90)
        XCTAssertEqual(owner.responder(of: "s"), 1, "the owner answers")
    }
}
