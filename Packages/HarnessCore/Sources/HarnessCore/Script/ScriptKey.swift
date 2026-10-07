import Foundation

/// One chord in the config-file key model (`cmd+shift+=`, `ctrl+[KeyA]`).
/// This is not `KeySpec`: that parser keeps hyphen prefixes, and there `meta` means option.
/// Here `meta`, `super`, and `win` mean command, and sequences are separated by `>`.
public struct ScriptChord: Equatable, Hashable, Sendable {
    public var modifiers: KeySpec.Modifiers
    public var key: String
    public var physical: Bool

    public init(modifiers: KeySpec.Modifiers = [], key: String, physical: Bool = false) {
        self.modifiers = modifiers
        self.key = key
        self.physical = physical
    }

    public var isEscape: Bool { !physical && modifiers.isEmpty && key == "escape" }

    public var spec: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(physical ? "[\(key)]" : key)
        return parts.joined(separator: "+")
    }
}

public struct ScriptSpec: Equatable, Sendable {
    public var mode: String?
    public var sequence: [ScriptChord]

    public var spec: String {
        let body = sequence.map(\.spec).joined(separator: ">")
        if let mode { return "\(mode)/\(body)" }
        return body
    }
}

public enum ScriptKey {
    public static func parse(_ raw: String) -> ScriptSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var mode: String?
        var body = trimmed
        if let slash = trimmed.firstIndex(of: "/"), bracketStartsLater(trimmed, slash) {
            let name = String(trimmed[..<slash])
            guard isModeName(name) else { return nil }
            mode = name
            body = String(trimmed[trimmed.index(after: slash)...])
        }
        guard !body.isEmpty else { return nil }
        var sequence: [ScriptChord] = []
        for part in body.split(separator: ">", omittingEmptySubsequences: false) {
            guard let chord = parseChord(String(part)) else { return nil }
            sequence.append(chord)
        }
        guard !sequence.isEmpty else { return nil }
        return ScriptSpec(mode: mode, sequence: sequence)
    }

    public static func isModeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter && $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    public static func isActionName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(".") && !name.contains(where: \.isWhitespace)
    }

    private static func bracketStartsLater(_ text: String, _ slash: String.Index) -> Bool {
        guard let bracket = text.firstIndex(of: "[") else { return true }
        return slash < bracket
    }

    private static func parseChord(_ raw: String) -> ScriptChord? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        var modifiers = KeySpec.Modifiers()
        var rest = token
        while let plus = rest.firstIndex(of: "+") {
            let head = String(rest[..<plus])
            guard let modifier = modifier(head) else { break }
            modifiers.insert(modifier)
            rest = String(rest[rest.index(after: plus)...])
        }
        guard let key = parseKey(rest) else { return nil }
        return ScriptChord(modifiers: modifiers, key: key.name, physical: key.physical)
    }

    private static func modifier(_ raw: String) -> KeySpec.Modifiers? {
        switch raw.lowercased() {
        case "cmd", "command", "super", "meta", "win": return .command
        case "ctrl", "control": return .control
        case "alt", "opt", "option": return .option
        case "shift": return .shift
        default: return nil
        }
    }

    private static func parseKey(_ raw: String) -> (name: String, physical: Bool)? {
        if raw.hasPrefix("["), raw.hasSuffix("]"), raw.count > 2 {
            let code = String(raw.dropFirst().dropLast())
            guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return (code, true)
        }
        let named = raw.lowercased()
        if namedKeys.contains(named) { return (named, false) }
        if raw.count == 1 { return (raw, false) }
        return nil
    }

    private static let namedKeys: Set<String> = {
        var names: Set<String> = [
            "enter", "escape", "tab", "space", "backspace", "delete",
            "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
        ]
        for number in 1...12 { names.insert("f\(number)") }
        return names
    }()
}
