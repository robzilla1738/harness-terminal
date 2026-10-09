#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import HarnessCore

/// The C `bind`, which a test method can't name unqualified (NSObject has a `bind` of its own).
private func bindSocket(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    bind(fd, address, length)
}

final class RemoteSocketDetectorTests: XCTestCase {
    func testProbeIsOneBatchModeCommandWithTheScriptQuoted() throws {
        let args = try RemoteSocketDetector.sshArguments(target: "me@devbox", sshArgs: ["-p", "2222"])
        XCTAssertEqual(Array(args.prefix(6)), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-p", "2222"])
        XCTAssertEqual(args[6], "me@devbox")
        XCTAssertTrue(args[7].hasPrefix("sh -c '"))
        XCTAssertThrowsError(try RemoteSocketDetector.sshArguments(target: "-oProxyCommand=x", sshArgs: []))
    }

    func testParseTakesTheLastAbsolutePath() {
        XCTAssertEqual(RemoteSocketDetector.parse("Welcome!\n/run/user/1000/harness/harness.sock\n"), "/run/user/1000/harness/harness.sock")
        XCTAssertNil(RemoteSocketDetector.parse("motd only\n"))
    }

    func testTheScriptFindsALiveSocketLocally() throws {
        // Run the same script against a temp HOME with a real socket in the macOS location.
        // /tmp, not NSTemporaryDirectory(): the macOS path below must fit in sun_path (104).
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("rsd-\(UUID().uuidString.prefix(6))")
        let dir = home.appendingPathComponent("Library/Application Support/Harness")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let socketPath = dir.appendingPathComponent("harness.sock").path
        try XCTSkipIf(socketPath.utf8.count >= 104, "temp path too long for a unix socket")
        let fd = makeUnixStreamSocket()
        defer { _ = sysClose(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bindSocket(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try XCTSkipIf(bound != 0, "temp path too long for a unix socket")
        let result = try ProcessCapture.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", RemoteSocketDetector.script],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(RemoteSocketDetector.parse(String(decoding: result.stdout, as: UTF8.self)), socketPath)
    }
}

final class RemoteHostDraftTests: XCTestCase {
    func testNameSuggestionAndValidation() {
        XCTAssertEqual(RemoteHostDraft.suggestedName(forTarget: "me@devbox.local"), "devbox")
        XCTAssertEqual(RemoteHostDraft.suggestedName(forTarget: "10.0.0.4"), "10.0.0.4")
        XCTAssertEqual(RemoteHostDraft.suggestedName(forTarget: "build"), "build")

        let ok = RemoteHostDraft(name: " devbox ", target: "me@devbox", options: "-p 2222", socket: "/run/user/1000/harness/harness.sock")
        XCTAssertEqual(ok.host, RemoteHost(name: "devbox", sshTarget: "me@devbox", remoteSocketPath: "/run/user/1000/harness/harness.sock", sshArgs: ["-p", "2222"]))
        XCTAssertNil(RemoteHostDraft(name: "x", target: "me@devbox", options: "-o ProxyCommand=evil", socket: "/s").host)
        XCTAssertNil(RemoteHostDraft(name: "x", target: "me@devbox", options: "", socket: "").host)
    }
}

final class RemoteReconnectTests: XCTestCase {
    func testBackoffDoublesThenCaps() {
        XCTAssertEqual((0 ..< 7).map { RemoteReconnect.delay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30])
        let total = (0 ..< RemoteReconnect.maxAttempts).map { RemoteReconnect.delay(attempt: $0) }.reduce(0, +)
        XCTAssertLessThan(total, 240)
    }
}
