import Foundation

public struct TailscalePeer: Equatable, Sendable {
    public var hostName: String
    public var dnsName: String
    public var ips: [String]

    public init(hostName: String, dnsName: String, ips: [String]) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.ips = ips
    }

    /// Suggested SSH target. The user still confirms it before anything is stored.
    public var suggestedSSH: String {
        let host = dnsName.isEmpty ? hostName : dnsName
        return host.isEmpty ? "" : "user@\(host)"
    }
}

/// Reads `tailscale status --json` when that command exists. Suggests peers.
/// Nothing is stored until the user confirms the SSH target and the socket.
/// The status command is not `tailscale up`; this process does not join a tailnet.
public enum TailscalePeers {
    public static let statusArguments = ["tailscale", "status", "--json"]

    public static func joinsTailnet(_ arguments: [String]) -> Bool {
        arguments.contains("up")
    }

    public static func parse(_ data: Data) -> [TailscalePeer] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers = object["Peer"] as? [String: Any] ?? [:]
        var rows: [TailscalePeer] = []
        for value in peers.values {
            guard let peer = value as? [String: Any] else { continue }
            if let online = peer["Online"] as? Bool, !online { continue }
            let host = string(peer["HostName"])
            let dns = string(peer["DNSName"]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let ips = peer["TailscaleIPs"] as? [String] ?? []
            guard !host.isEmpty || !dns.isEmpty else { continue }
            rows.append(TailscalePeer(hostName: host, dnsName: dns, ips: ips))
        }
        return rows.sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
    }

    /// A host to store, or nil when the user has not confirmed both the SSH target and the socket.
    public static func confirmedHost(name: String, sshTarget: String, socketPath: String) -> RemoteHost? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssh = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let socket = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !ssh.isEmpty, !socket.isEmpty else { return nil }
        return RemoteHost(name: name, sshTarget: ssh, remoteSocketPath: socket)
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }
}
