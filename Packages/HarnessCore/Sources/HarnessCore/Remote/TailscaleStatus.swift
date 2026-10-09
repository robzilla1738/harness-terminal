import Foundation

/// Read-only discovery. Joining a tailnet and installing its VPN remain in Tailscale.
public struct TailscaleStatus: Equatable, Sendable {
    public var address: String?
    public var message: String
    public var installed: Bool

    public static func discover() -> Self {
        let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return Self(message: "Install Tailscale on this computer and your phone, then sign in to the same Tailscale account.", installed: false)
        }
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["TAILSCALE_BE_CLI"] = "1"
            let output = try ProcessCapture.run(URL(fileURLWithPath: path), arguments: ["status", "--json"],
                environment: environment, timeout: 3, maxOutputBytes: 2 * 1024 * 1024)
            guard output.status == 0 else {
                return Self(message: "Open Tailscale and connect, then choose Refresh.", installed: true)
            }
            return try parse(output.stdout)
        } catch {
            return Self(message: "Tailscale status is unavailable. Open Tailscale, check its connection, then choose Refresh.", installed: true)
        }
    }

    public static func parse(_ data: Data) throws -> Self {
        struct Status: Decodable {
            var BackendState: String
            var TailscaleIPs: [String]?
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.BackendState == "Running", let address = status.TailscaleIPs?.first(where: { $0.contains(".") }) else {
            return Self(message: "Open Tailscale and connect, then choose Refresh.", installed: true)
        }
        return Self(address: address, message: "Tailscale is connected. Sign in to the same Tailscale account on your phone and turn its connection on.", installed: true)
    }
}
