import Foundation

extension RemotePairingInfo {
    /// Public connection metadata only. Both QR and clipboard use the same link.
    public func connectionURL() throws -> URL {
        try validate()
        var url = URLComponents()
        url.scheme = "harness"
        url.host = "connect"
        url.queryItems = [URLQueryItem(name: "v", value: String(version)),
                          URLQueryItem(name: "host", value: host),
                          URLQueryItem(name: "port", value: String(port)),
                          URLQueryItem(name: "user", value: username),
                          URLQueryItem(name: "key", value: fingerprint),
                          URLQueryItem(name: "exe", value: executablePath)]
        if let alternateHosts, !alternateHosts.isEmpty {
            url.queryItems?.append(URLQueryItem(name: "routes", value: String(decoding: try JSONEncoder().encode(alternateHosts), as: UTF8.self)))
        }
        guard let result = url.url else { throw Self.invalidCode }
        return result
    }

    public static func parseConnectionCode(_ source: String) throws -> Self {
        guard source.utf8.count <= 16_384 else { throw invalidCode }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let info: Self
        if source.hasPrefix("{") {
            info = try JSONDecoder().decode(Self.self, from: Data(source.utf8))
        } else {
            guard let url = URLComponents(string: source), url.scheme == "harness", url.host == "connect",
                  url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
                  let items = url.queryItems, Set(items.map(\.name)).count == items.count,
                  Set(items.map(\.name)).subtracting(["routes"]) == Set(["v", "host", "port", "user", "key", "exe"]) else { throw invalidCode }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            guard let version = Int(values["v"] ?? ""), let port = Int(values["port"] ?? "") else { throw invalidCode }
            info = Self(version: version, host: values["host"] ?? "", port: port,
                        username: values["user"] ?? "", fingerprint: values["key"] ?? "", executablePath: values["exe"] ?? "",
                        alternateHosts: try values["routes"].map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) })
        }
        try info.validate()
        return info
    }

    public func validate() throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let routes = [host] + (alternateHosts ?? [])
        guard routes.count <= 5, Set(routes).count == routes.count,
              routes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && $0.rangeOfCharacter(from: forbidden.union(CharacterSet(charactersIn: "/\\?#@"))) == nil }) else { throw Self.invalidCode }
        guard version == 1, (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 512,
              host.rangeOfCharacter(from: forbidden.union(CharacterSet(charactersIn: "/\\?#@"))) == nil,
              !username.isEmpty, username.utf8.count <= 128, username.rangeOfCharacter(from: forbidden) == nil,
              fingerprint.hasPrefix("SHA256:"), fingerprint.count == 50,
              Data(base64Encoded: String(fingerprint.dropFirst(7)) + "=")?.count == 32,
              executablePath.hasPrefix("/"), executablePath.utf8.count <= 4096,
              executablePath.rangeOfCharacter(from: .controlCharacters) == nil else { throw Self.invalidCode }
    }

    public static func isTailscaleAddress(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.hasSuffix(".ts.net") || name.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { (0...255).contains($0) }
            && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static var invalidCode: RemoteFailure {
        RemoteFailure(code: "pairingCode", message: "This is not a supported Harness connection code. Run /remote in Harness to show a new code.")
    }
}
