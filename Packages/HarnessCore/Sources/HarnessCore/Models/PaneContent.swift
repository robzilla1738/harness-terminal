import Foundation

public struct PreviewSpecification: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public init(url: String, title: String? = nil) { self.url = url; self.title = title }
    public func validatedURL() throws -> URL {
        guard !url.isEmpty, url.utf8.count <= 8192, !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: url), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, let host = components.host?.lowercased(), Self.isLoopback(host),
              components.port.map({ (1...65535).contains($0) }) ?? true, let result = components.url,
              title.map({ $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true else { throw PreviewError.invalidURL }
        return result
    }
    public var effectivePort: Int { (try? validatedURL()).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.port } ?? (url.lowercased().hasPrefix("https:") ? 443 : 80) }
    public func forwardedURL(port: Int) throws -> URL {
        guard (1...65535).contains(port), var components = URLComponents(url: try validatedURL(), resolvingAgainstBaseURL: false) else { throw PreviewError.invalidURL }
        components.host = "127.0.0.1"; components.port = port
        guard let result = components.url else { throw PreviewError.invalidURL }; return result
    }
    private static func isLoopback(_ raw: String) -> Bool {
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        if ["localhost", "::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in !octet.isEmpty && octet.allSatisfy({ $0.isASCII && $0.isNumber }) && octet.count <= 3 && UInt8(octet) != nil && (octet.count == 1 || octet.first != "0") }
    }
}
public enum PreviewError: Error, LocalizedError {
    case invalidURL, unsupported, terminal
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Use an HTTP or HTTPS loopback URL with a valid port and no embedded credentials. File navigation and external top-level pages are not supported in preview panes."
        case .unsupported: "This host or client does not support this pane content. Adopt a compatible application update; existing programs are preserved."
        case .terminal: "This action requires a terminal pane. Select a terminal or open a new shell; preview panes have no terminal process or input stream."
        }
    }
}
/// Retains an unknown future pane's semantic JSON so a compatible reader cannot
/// accidentally replace it with a new shell. Unknown content has no executable flow.
public indirect enum PaneJSONValue: Codable, Equatable, Sendable {
    case object([String: PaneJSONValue]), array([PaneJSONValue]), string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw PreviewError.unsupported }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let unsigned = try? value.decode(UInt64.self) { self = .unsigned(unsigned) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([PaneJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: PaneJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(fields): try value.encode(fields)
        case let .array(items): try value.encode(items)
        case let .string(text): try value.encode(text)
        case let .integer(integer): try value.encode(integer)
        case let .unsigned(unsigned): try value.encode(unsigned)
        case let .number(number): try value.encode(number)
        case let .bool(boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }
}
public enum PaneContent: Codable, Equatable, Sendable {
    case terminal
    case preview(PreviewSpecification)
    case unsupported(kind: String, payload: [String: PaneJSONValue])
    public var isTerminal: Bool { if case .terminal = self { return true }; return false }
    public var kind: String { switch self { case .terminal: "terminal"; case .preview: "preview"; case let .unsupported(kind, _): kind } }
    private enum CodingKeys: String, CodingKey { case kind, preview }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "terminal": self = .terminal
        case "preview": self = .preview(try values.decode(PreviewSpecification.self, forKey: .preview))
        default: self = .unsupported(kind: kind, payload: try decoder.singleValueContainer().decode([String: PaneJSONValue].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .unsupported(_, payload): var values = encoder.singleValueContainer(); try values.encode(payload)
        default:
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(kind, forKey: .kind)
            if case let .preview(specification) = self { try values.encode(specification, forKey: .preview) }
        }
    }
}
