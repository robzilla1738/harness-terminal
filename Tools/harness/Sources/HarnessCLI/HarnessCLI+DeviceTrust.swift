import Foundation
import HarnessCore
import HarnessRemoteProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension HarnessCLI {
    /// Device trust is edited on the host, never through the companion request channel.
    static func handleDeviceTrust(_ args: [String]) throws {
        guard args.count == 3, ["install", "remove"].contains(args[1]), args[2] == "--stdin", isatty(STDIN_FILENO) == 0 else {
            throw RemoteFailure(code: "badArguments", message: "Use mobile-key install|remove --stdin with a plain Ed25519 public key redirected on the host.")
        }
        let deadline = Date().addingTimeInterval(5)
        var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RemoteFailure(code: "inputTimeout", message: "Public-key input did not finish within five seconds") }
            let ready = poll(&descriptor, 1, max(1, Int32(remaining * 1000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw RemoteFailure(code: "inputTimeout", message: "Public-key input did not finish within five seconds") }
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= 4096 else { throw RemoteFailure(code: "badKey", message: "Public-key input failed or exceeded 4096 bytes") }
            if count == 0 { break }; data.append(contentsOf: bytes.prefix(count))
        }
        guard let key = String(data: data, encoding: .utf8) else { throw RemoteFailure(code: "badKey", message: "Public key must be UTF-8") }
        if args[1] == "install" { try MobileDeviceKeys.install(key); print("Managed device public key installed; unrelated SSH keys preserved.") }
        else { print(try MobileDeviceKeys.remove(key) ? "Managed device public key removed." : "Managed device public key was not present.") }
    }
}
