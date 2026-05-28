import Foundation

/// Parses a textual command sequence (e.g. `split-window -h ; copy-mode`) into
/// a `Command` tree. Used by the `:` command prompt, `harness-cli run`,
/// `bind-key`, `keybindings.json`, and `display-popup -e <command>`.
///
/// Grammar:
///   sequence  ::= statement (";" statement)*
///   statement ::= name token*
///   token     ::= word | "'" string "'" | '"' string '"'
///   name      ::= [a-z][a-z0-9-]*
///   flags     ::= "-x" or "-x value"
///
/// Unknown commands return `CommandParseError.unknownCommand` so users get a
/// clear error message at the prompt rather than a silent no-op.
public enum CommandParser {
    public static func parse(_ source: String) throws -> Command {
        var lexer = Lexer(source: source)
        var commands: [Command] = []
        while !lexer.atEnd {
            lexer.skipWhitespace()
            if lexer.peek == ";" { lexer.advance(); continue }
            if lexer.atEnd { break }
            let statement = try parseStatement(&lexer)
            commands.append(statement)
            lexer.skipWhitespace()
            if lexer.peek == ";" { lexer.advance() }
        }
        if commands.isEmpty { throw CommandParseError.emptyInput }
        if commands.count == 1 { return commands[0] }
        return .sequence(commands)
    }

    private static func parseStatement(_ lexer: inout Lexer) throws -> Command {
        guard let name = lexer.nextWord() else {
            throw CommandParseError.expectedCommand
        }
        let tokens = lexer.collectStatementTokens()
        return try buildCommand(name: name, tokens: tokens)
    }

    private static func buildCommand(name: String, tokens: [String]) throws -> Command {
        switch name {
        case "split-window":
            // Convention here mirrors the rest of Harness: `.vertical` means
            // a vertical divider → panes sit side by side; `.horizontal` means
            // a horizontal divider → panes stack top/bottom. `-v` requests the
            // top/bottom split; default and `-h` request side-by-side.
            if tokens.contains("-v") { return .splitWindow(direction: .horizontal) }
            return .splitWindow(direction: .vertical)
        case "kill-pane":
            return .killPane
        case "zoom-pane", "resize-pane":
            if tokens.contains("-Z") || name == "zoom-pane" { return .zoomPane }
            // resize-pane -L 5 / -R 5 / -U 5 / -D 5
            let dir: ResizeDirection
            if tokens.contains("-L") { dir = .left }
            else if tokens.contains("-R") { dir = .right }
            else if tokens.contains("-U") { dir = .up }
            else if tokens.contains("-D") { dir = .down }
            else { throw CommandParseError.missingFlag("resize-pane requires -L|-R|-U|-D or -Z") }
            let amount = numericTrailing(in: tokens) ?? 1
            return .resizePane(direction: dir, amount: amount)
        case "select-pane":
            let target = try paneTarget(from: tokens, defaultValue: .next)
            return .selectPane(target: target)
        case "swap-pane":
            let target = try paneTarget(from: tokens, defaultValue: .next)
            return .swapPane(target: target)
        case "new-window", "new-tab":
            return .newWindow
        case "kill-window", "kill-tab":
            return .killWindow
        case "rename-window", "rename-tab":
            let name = tokens.first { !$0.hasPrefix("-") }
            return .renameWindow(newName: name)
        case "next-window", "next-tab":
            return .nextWindow
        case "previous-window", "previous-tab":
            return .previousWindow
        case "select-window", "select-tab":
            guard let raw = tokens.first(where: { $0.first?.isNumber ?? false }) ?? tokens.last,
                  let index = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            else { throw CommandParseError.missingFlag("select-window requires a window index") }
            return .selectWindow(index: index)
        case "new-session":
            let name = stringValue(for: "-s", in: tokens) ?? tokens.first { !$0.hasPrefix("-") }
            return .newSession(name: name)
        case "kill-session":
            return .killSession
        case "rename-session":
            let name = tokens.first { !$0.hasPrefix("-") }
            return .renameSession(newName: name)
        case "select-workspace", "select-workspace-index":
            guard let raw = tokens.first(where: { $0.first?.isNumber ?? false }),
                  let index = Int(raw)
            else { throw CommandParseError.missingFlag("select-workspace requires an index") }
            return .selectWorkspace(index: index)
        case "next-workspace": return .nextWorkspace
        case "previous-workspace": return .previousWorkspace
        case "copy-mode": return .copyMode
        case "detach", "detach-client": return .detachClient
        case "send-keys":
            return .sendKeys(keys: tokens.filter { !$0.hasPrefix("-") })
        case "display-message":
            let format = tokens.first { !$0.hasPrefix("-") } ?? ""
            return .displayMessage(format: format)
        case "run-shell":
            guard let cmd = tokens.first(where: { !$0.hasPrefix("-") }) else {
                throw CommandParseError.missingArgument("run-shell requires a command string")
            }
            return .runShell(shellCommand: cmd)
        case "bind-key", "bind":
            // bind-key -T <table> <spec> <command...>
            let table = stringValue(for: "-T", in: tokens) ?? "prefix"
            // tokens after the table flag/spec belong to the inner command.
            // Strategy: filter out "-T", the table name, take the next token as
            // spec, and re-join the rest as the inner command source.
            var remaining = tokens
            if let i = remaining.firstIndex(of: "-T"), i + 1 < remaining.count {
                remaining.remove(at: i + 1)
                remaining.remove(at: i)
            }
            guard !remaining.isEmpty else {
                throw CommandParseError.missingArgument("bind-key requires a key spec")
            }
            let spec = remaining.removeFirst()
            guard !remaining.isEmpty else {
                throw CommandParseError.missingArgument("bind-key requires a command")
            }
            let inner = try parse(remaining.joined(separator: " "))
            return .bindKey(table: table, spec: spec, command: inner)
        case "unbind-key", "unbind":
            let table = stringValue(for: "-T", in: tokens) ?? "prefix"
            var remaining = tokens
            if let i = remaining.firstIndex(of: "-T"), i + 1 < remaining.count {
                remaining.remove(at: i + 1)
                remaining.remove(at: i)
            }
            guard let spec = remaining.first else {
                throw CommandParseError.missingArgument("unbind-key requires a key spec")
            }
            return .unbindKey(table: table, spec: spec)
        case "list-keys":
            return .listKeys(table: stringValue(for: "-T", in: tokens))
        case "source-config", "source", "reload-config":
            return .sourceConfig
        case "reload-keybindings":
            return .reloadKeybindings
        case "show-cheatsheet":
            return .showCheatsheet
        case "select-layout":
            // `select-layout <name>` or `select-layout next` / `previous`.
            let value = tokens.first { !$0.hasPrefix("-") } ?? ""
            switch value {
            case "next", "+": return .nextLayout
            case "previous", "-": return .previousLayout
            default: return .selectLayout(name: value)
            }
        case "next-layout":
            return .nextLayout
        case "previous-layout":
            return .previousLayout
        case "rotate-window":
            let forward = !tokens.contains("-D")
            return .rotateWindow(forward: forward)
        case "break-pane":
            return .breakPane
        case "respawn-pane":
            return .respawnPane(keepHistory: !tokens.contains("-k"))
        default:
            throw CommandParseError.unknownCommand(name)
        }
    }

    private static func paneTarget(from tokens: [String], defaultValue: Command.PaneTarget) throws -> Command.PaneTarget {
        if tokens.contains("-L") { return .left }
        if tokens.contains("-R") { return .right }
        if tokens.contains("-U") { return .up }
        if tokens.contains("-D") { return .down }
        if tokens.contains("-l") { return .last }
        if let target = stringValue(for: "-t", in: tokens) {
            switch target {
            case ":.+": return .next
            case ":.-": return .previous
            case "!": return .last
            default: return .next
            }
        }
        return defaultValue
    }

    private static func stringValue(for flag: String, in tokens: [String]) -> String? {
        guard let i = tokens.firstIndex(of: flag), i + 1 < tokens.count else { return nil }
        return tokens[i + 1]
    }

    private static func numericTrailing(in tokens: [String]) -> Int? {
        for token in tokens.reversed() where !token.hasPrefix("-") {
            if let value = Int(token) { return value }
        }
        return nil
    }
}

public enum CommandParseError: Error, CustomStringConvertible, Equatable {
    case emptyInput
    case expectedCommand
    case unknownCommand(String)
    case missingFlag(String)
    case missingArgument(String)

    public var description: String {
        switch self {
        case .emptyInput: return "command input is empty"
        case .expectedCommand: return "expected a command name"
        case let .unknownCommand(name): return "unknown command: \(name)"
        case let .missingFlag(message): return message
        case let .missingArgument(message): return message
        }
    }
}

// MARK: - Lexer

private struct Lexer {
    let source: [Character]
    var index: Int = 0

    init(source: String) { self.source = Array(source) }

    var atEnd: Bool { index >= source.count }
    var peek: Character? { atEnd ? nil : source[index] }

    mutating func advance() { index += 1 }

    mutating func skipWhitespace() {
        while let ch = peek, ch.isWhitespace { advance() }
    }

    /// Read the next bare word (terminator: whitespace or `;`).
    mutating func nextWord() -> String? {
        skipWhitespace()
        guard let first = peek, first != ";" else { return nil }
        var word = ""
        while let ch = peek, !ch.isWhitespace, ch != ";" { word.append(ch); advance() }
        return word.isEmpty ? nil : word
    }

    /// Read the next token, supporting quoted strings.
    mutating func nextToken() -> String? {
        skipWhitespace()
        guard let first = peek, first != ";" else { return nil }
        if first == "'" || first == "\"" {
            let quote = first
            advance()
            var value = ""
            while let ch = peek, ch != quote {
                if ch == "\\" {
                    advance()
                    if let escaped = peek { value.append(escaped); advance() }
                } else {
                    value.append(ch); advance()
                }
            }
            if peek == quote { advance() }
            return value
        }
        return nextWord()
    }

    /// Drain every token in the current statement (until end of input or `;`).
    mutating func collectStatementTokens() -> [String] {
        var tokens: [String] = []
        while let token = nextToken() { tokens.append(token) }
        return tokens
    }
}
