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
        let canonical = resolveAlias(name) ?? name
        // Universal `-t <target>` handling: for the leaf verbs in
        // `universalTargetCommands`, strip the `-t <spec>` pair and wrap the result
        // in `.targeted` so the target resolves centrally at translate time (tmux's
        // context-sensitive `-t`). An allowlist (not a denylist) keeps `-t` intact
        // for verbs that interpret it themselves (select/move/swap, menu) or that
        // carry a nested command with its own `-t` (bind-key, if-shell, …).
        if universalTargetCommands.contains(canonical),
           let raw = stringValue(for: "-t", in: tokens) {
            let spec = TargetSpec.parse(raw)
            let reduced = removingFlagPair("-t", in: tokens)
            let inner = try buildCommand(name: name, tokens: reduced)
            return spec.isEmpty ? inner : .targeted(spec, inner)
        }
        return try buildCommand(name: name, tokens: tokens)
    }

    /// Leaf verbs that accept a universal `-t session:window.pane` target. Aliases
    /// resolve to the canonical hyphen form before this check; the `-tab` synonyms
    /// (not in the alias table) are listed explicitly.
    private static let universalTargetCommands: Set<String> = [
        "split-window", "kill-pane", "zoom-pane", "resize-pane", "break-pane",
        "respawn-pane", "send-keys", "pipe-pane",
        "synchronize-panes", "synchronize-pane", "setw-synchronize",
        "kill-window", "kill-tab", "rename-window", "rename-tab",
        "new-window", "new-tab", "rotate-window", "select-layout",
        "new-session", "kill-session", "rename-session",
        // `link-window` is excluded: its leaf parser interprets `-t` itself as the
        // target session to link into, so stripping it here would leave it empty.
        "unlink-window",
    ]

    private static func removingFlagPair(_ flag: String, in tokens: [String]) -> [String] {
        guard let i = tokens.firstIndex(of: flag) else { return tokens }
        var out = tokens
        if i + 1 < out.count { out.remove(at: i + 1) }
        out.remove(at: i)
        return out
    }

    /// tmux command-name aliases (the short forms in muscle memory) → canonical
    /// Harness verb, so `neww`, `splitw`, `killp`, `selectp`, `resizep`, … all work.
    private static let aliases: [String: String] = [
        "neww": "new-window", "splitw": "split-window", "killp": "kill-pane",
        "killw": "kill-window", "selectp": "select-pane", "selectw": "select-window",
        "resizep": "resize-pane", "swapp": "swap-pane", "swapw": "swap-window",
        "movew": "move-window", "rotatew": "rotate-window", "breakp": "break-pane",
        "joinp": "join-pane", "respawnp": "respawn-pane", "movep": "move-pane",
        "renumberw": "renumber-windows",
        "renamew": "rename-window", "rename": "rename-window",
        "renames": "rename-session", "news": "new-session", "kills": "kill-session",
        "nextl": "next-layout", "prevl": "previous-layout", "selectl": "select-layout",
        "lockc": "lock-client", "lock-server": "lock-client",
    ]

    private static func resolveAlias(_ name: String) -> String? { aliases[name] }

    /// The bindable command vocabulary — every verb `buildCommand` accepts (what a user can put
    /// in `bind-key`, the `:` prompt, a hook, or `display-popup -e`). Backs `harness-cli
    /// list-commands`. `CommandParserTests.testKnownVerbsAreAllParseable` guards it from drifting
    /// out of sync with the switch below.
    public static let knownVerbs: [String] = [
        "bind-key", "break-pane", "choose-buffer", "choose-client", "choose-session",
        "choose-tree", "choose-window", "clock-mode", "command-prompt", "confirm-before",
        "copy-mode", "detach", "display-menu", "display-message", "display-panes",
        "display-popup", "if-shell", "join-pane", "kill-pane", "kill-session", "kill-window",
        "last-pane", "last-window", "link-window", "list-keys", "lock-client", "move-pane",
        "move-window", "new-session", "new-window", "next-layout", "next-pane", "next-window",
        "next-workspace", "pipe-pane", "previous-layout", "previous-pane", "previous-window",
        "previous-workspace", "reload-keybindings", "rename-session", "rename-window",
        "renumber-windows", "respawn-pane", "rotate-window", "select-layout", "select-pane",
        "select-window", "select-workspace", "send-keys", "send-prefix", "show-cheatsheet",
        "source-config", "source-file", "swap-pane", "swap-window", "switch-client",
        "synchronize-panes", "unbind-key", "unlink-window", "zoom-pane",
    ]

    private static func buildCommand(name rawName: String, tokens: [String]) throws -> Command {
        let name = resolveAlias(rawName) ?? rawName
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
            if tokens.contains("-m") { return .markPane(set: true) }
            if tokens.contains("-M") { return .markPane(set: false) }
            let target = try paneTarget(from: tokens, defaultValue: .next)
            return .selectPane(target: target)
        // Convenience verbs for the directional cycle (`select-pane -t :.+/:.-` and the
        // tmux `last-pane`). Bindable like any other verb.
        case "next-pane":
            return .selectPane(target: .next)
        case "previous-pane":
            return .selectPane(target: .previous)
        case "last-pane":
            return .selectPane(target: .last)
        case "join-pane":
            // `-v` → stacked (horizontal divider); default/`-h` → side by side.
            if tokens.contains("-v") { return .joinPane(direction: .horizontal) }
            return .joinPane(direction: .vertical)
        case "synchronize-panes", "synchronize-pane", "setw-synchronize":
            let value = tokens.first { !$0.hasPrefix("-") }
            switch value {
            case "on", "true", "1": return .synchronizePanes(set: true)
            case "off", "false", "0": return .synchronizePanes(set: false)
            default: return .synchronizePanes(set: nil)
            }
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
            // Accept `select-window 3`, `-t :3`, or `-t session:3` / `-t session:!`.
            let targetRaw = stringValue(for: "-t", in: tokens)
                ?? tokens.first(where: { ($0.first?.isNumber ?? false) || $0.contains(":") })
                ?? tokens.last
            let spec = targetRaw.map(TargetSpec.parse) ?? TargetSpec()
            if case let .byIndex(n)? = spec.window {
                return spec.session != nil ? .targeted(spec, .selectWindow(index: n)) : .selectWindow(index: n)
            }
            if let bare = spec.bareToken, let n = Int(bare) {
                return spec.session != nil ? .targeted(spec, .selectWindow(index: n)) : .selectWindow(index: n)
            }
            if spec.session != nil || spec.window != nil {
                // Session- or relative-addressed window: resolve centrally.
                return .targeted(spec, .selectWindow(index: 0))
            }
            throw CommandParseError.missingFlag("select-window requires a window index")
        case "move-window", "move-tab":
            guard let raw = tokens.first(where: { ($0.first?.isNumber ?? false) || $0.hasPrefix(":") }),
                  let index = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            else { throw CommandParseError.missingFlag("move-window requires a target index (-t :<n>)") }
            return .moveWindow(toIndex: index)
        case "swap-window", "swap-tab":
            guard let raw = tokens.first(where: { ($0.first?.isNumber ?? false) || $0.hasPrefix(":") }),
                  let index = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            else { throw CommandParseError.missingFlag("swap-window requires a target index (-t :<n>)") }
            return .swapWindow(withIndex: index)
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
        case "copy-mode":
            // `copy-mode -X <action> [arg]` is an in-mode command; bare is "enter".
            if let xi = tokens.firstIndex(of: "-X"), xi + 1 < tokens.count {
                let actionName = tokens[xi + 1]
                let arg = xi + 2 < tokens.count ? tokens[xi + 2] : nil
                if let action = CopyModeAction(tmuxName: actionName, argument: arg) {
                    return .copyModeCommand(action)
                }
            }
            return .copyMode
        case "display-panes", "displayp": return .displayPanes
        case "detach", "detach-client": return .detachClient
        case "send-keys":
            // `send-keys -X <action> [arg]` dispatches a copy-mode command.
            if let xi = tokens.firstIndex(of: "-X"), xi + 1 < tokens.count {
                let actionName = tokens[xi + 1]
                let arg = xi + 2 < tokens.count ? tokens[xi + 2] : nil
                if let action = CopyModeAction(tmuxName: actionName, argument: arg) {
                    return .copyModeCommand(action)
                }
            }
            return .sendKeys(keys: tokens.filter { !$0.hasPrefix("-") })
        case "display-message":
            let format = tokens.first { !$0.hasPrefix("-") } ?? ""
            return .displayMessage(format: format)
        case "run-shell":
            guard let cmd = tokens.first(where: { !$0.hasPrefix("-") }) else {
                throw CommandParseError.missingArgument("run-shell requires a command string")
            }
            return .runShell(shellCommand: cmd, captureToBuffer: tokens.contains("-b"))
        case "if-shell", "if":
            // if-shell <condition> <then-command> [<else-command>]
            let positional = tokens.filter { !$0.hasPrefix("-") }
            guard positional.count >= 2 else {
                throw CommandParseError.missingArgument("if-shell requires a condition and a command")
            }
            let then = try parse(positional[1])
            let otherwise = positional.count >= 3 ? try parse(positional[2]) : nil
            return .ifShell(condition: positional[0], then: then, otherwise: otherwise)
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
            // `-r` (repeatable) is a flag, not the key spec — pull it out first.
            let repeatable = remaining.contains("-r")
            remaining.removeAll { $0 == "-r" }
            guard !remaining.isEmpty else {
                throw CommandParseError.missingArgument("bind-key requires a key spec")
            }
            let spec = remaining.removeFirst()
            guard !remaining.isEmpty else {
                throw CommandParseError.missingArgument("bind-key requires a command")
            }
            let inner = try parse(remaining.joined(separator: " "))
            return .bindKey(table: table, spec: spec, command: inner, repeatable: repeatable)
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
        case "move-pane":
            // move-pane -s <src> [-t <dst>] [-h|-v] — like join-pane with an
            // explicit source. `-v` stacks (horizontal divider); default/`-h` is
            // side-by-side. `-t` (dst) is wrapped by the universal target handler
            // — except `move-pane` self-parses, so do it here.
            let direction: SplitDirection = tokens.contains("-v") ? .horizontal : .vertical
            let source = TargetSpec.parse(stringValue(for: "-s", in: tokens) ?? "")
            let move = Command.movePane(direction: direction, source: source)
            if let dstRaw = stringValue(for: "-t", in: tokens) {
                let dst = TargetSpec.parse(dstRaw)
                if !dst.isEmpty { return .targeted(dst, move) }
            }
            return move
        case "renumber-windows":
            return .renumberWindows

        // MARK: Phase 6 — command completeness
        case "last-window", "last-tab":
            return .lastWindow
        case "send-prefix":
            return .sendPrefix
        case "source-file", "source-keys":
            guard let path = tokens.first(where: { !$0.hasPrefix("-") }) else {
                throw CommandParseError.missingArgument("source-file requires a path")
            }
            return .sourceFile(path: (path as NSString).expandingTildeInPath)
        case "command-prompt":
            // command-prompt [-p prompt1,prompt2] "<template with %% / %1 …>"
            let prompts = stringValue(for: "-p", in: tokens)?
                .split(separator: ",").map(String.init) ?? []
            let template = tokens.last { !$0.hasPrefix("-") && $0 != stringValue(for: "-p", in: tokens) } ?? ""
            return .commandPrompt(prompts: prompts, template: template)
        case "confirm-before", "confirm":
            let prompt = stringValue(for: "-p", in: tokens)
            let positional = tokens.filter { !$0.hasPrefix("-") && $0 != prompt }
            guard let cmd = positional.first else {
                throw CommandParseError.missingArgument("confirm-before requires a command")
            }
            return .confirmBefore(prompt: prompt, command: try parse(cmd))
        case "choose-tree":
            return .choose(scope: .tree)
        case "choose-session":
            return .choose(scope: .session)
        case "choose-window":
            return .choose(scope: .window)
        case "choose-buffer":
            return .choose(scope: .buffer)
        case "choose-client":
            return .choose(scope: .client)
        case "pipe-pane", "pipep":
            let cmd = tokens.first { !$0.hasPrefix("-") }
            return .pipePane(shellCommand: cmd)

        // MARK: Phase 7 — server admin & integration
        case "lock-client", "lock-session", "lock-server", "lock":
            return .lockClient
        case "clock-mode":
            return .clockMode
        case "switch-client", "switchc":
            // `-T <table>` selects the key table for the next key press (modal bindings).
            guard let table = stringValue(for: "-T", in: tokens) else {
                throw CommandParseError.missingArgument("switch-client requires -T <table>")
            }
            return .switchClientTable(table: table)
        case "link-window", "linkw":
            guard let target = stringValue(for: "-t", in: tokens) ?? tokens.first(where: { !$0.hasPrefix("-") }) else {
                throw CommandParseError.missingArgument("link-window requires a target session (-t <session>)")
            }
            return .linkWindow(targetSessionName: target)
        case "unlink-window", "unlinkw":
            return .unlinkWindow
        case "display-popup", "popup":
            let command = stringValue(for: "-E", in: tokens) ?? tokens.first { !$0.hasPrefix("-") }
            return .displayPopup(command: command)
        case "display-menu", "menu":
            return .displayMenu(items: try parseMenuItems(tokens))

        default:
            throw CommandParseError.unknownCommand(resolveAlias(name) ?? name)
        }
    }

    /// `display-menu … <title> <key> <command>` triples (key may be empty as `""`).
    private static func parseMenuItems(_ tokens: [String]) throws -> [Command.MenuItem] {
        let positional = tokens.enumerated().filter { idx, tok in
            !tok.hasPrefix("-") && !(idx > 0 && (tokens[idx - 1] == "-T" || tokens[idx - 1] == "-t"))
        }.map(\.element)
        var items: [Command.MenuItem] = []
        var i = 0
        while i + 2 < positional.count + 1, i + 2 <= positional.count {
            // Need at least title, key, command (3 tokens).
            guard i + 2 < positional.count + 0 || i + 3 <= positional.count else { break }
            if i + 3 > positional.count { break }
            let title = positional[i], key = positional[i + 1], cmd = positional[i + 2]
            items.append(.init(title: title, key: key.isEmpty ? nil : key, command: (try? parse(cmd)) ?? .displayMessage(format: cmd)))
            i += 3
        }
        return items
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
