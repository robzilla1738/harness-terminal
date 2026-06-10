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
        if lexer.unterminatedQuote { throw CommandParseError.unterminatedString }
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
        "respawn-pane", "clear-history", "send-keys", "pipe-pane",
        "synchronize-panes", "synchronize-pane", "setw-synchronize",
        "kill-window", "kill-tab", "rename-window", "rename-tab",
        "new-window", "new-tab", "rotate-window", "select-layout",
        "new-session", "kill-session", "rename-session", "respawn-window",
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
        "clearhist": "clear-history",
        "respawnw": "respawn-window", "refreshc": "refresh-client",
        "renumberw": "renumber-windows",
        "renamew": "rename-window", "rename": "rename-window",
        "renames": "rename-session", "news": "new-session", "kills": "kill-session",
        "nextl": "next-layout", "prevl": "previous-layout", "selectl": "select-layout",
        "lockc": "lock-client", "lock-server": "lock-client",
        "set": "set-option", "setw": "set-window-option",
        "show": "show-options", "showw": "show-window-options",
        "setenv": "set-environment", "showenv": "show-environment",
        "setb": "set-buffer", "pasteb": "paste-buffer", "deleteb": "delete-buffer",
        "lsb": "list-buffers", "showb": "show-buffer",
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
        "display-popup", "if-shell", "join-pane", "jump-next-prompt", "jump-previous-prompt",
        "kill-pane", "kill-session", "kill-window",
        "last-pane", "last-window", "link-window", "list-keys", "lock-client", "move-pane",
        "reattach-surface",
        "move-window", "new-session", "new-window", "next-layout", "next-pane", "next-window",
        "next-workspace", "pipe-pane", "previous-layout", "previous-pane", "previous-window",
        "previous-workspace", "reload-keybindings", "rename-session", "rename-window",
        "renumber-windows", "respawn-pane", "clear-history", "rotate-window", "select-layout", "select-pane",
        "select-window", "select-workspace", "send-keys", "send-prefix", "show-cheatsheet",
        "source-config", "source-file", "swap-pane", "swap-window", "switch-client",
        "synchronize-panes", "unbind-key", "unlink-window", "zoom-pane",
        // Config / buffer / hook verbs (bindable forms of the CLI subcommands).
        "set-option", "set-window-option", "show-options", "show-window-options",
        "set-environment", "show-environment",
        "set-buffer", "paste-buffer", "delete-buffer", "list-buffers", "show-buffer",
        "set-hook", "show-hooks", "unbind-hook", "find-window",
        "refresh-client", "respawn-window", "show-messages",
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
            if let spec = try explicitPaneTargetSpec(from: tokens) {
                // Absolute target (`%id`, `session:window.pane`, `{top}`, …): resolved at
                // translate time; the inner relative target is ignored on this path.
                return .targeted(spec, .selectPane(target: .next))
            }
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
            // tmux `swap-pane [-s src] [-t dst]` — `-s` names the pane to act FROM
            // (default: the caller's active pane); without `-t` the destination is
            // the current pane (tmux behavior), spelled here as a self-target the
            // translator resolves against the caller's focus.
            let source = try explicitPaneTargetSpec(from: tokens, flag: "-s")
            if let spec = try explicitPaneTargetSpec(from: tokens) {
                return .targeted(spec, .swapPane(target: .next, source: source))
            }
            if source != nil, stringValue(for: "-t", in: tokens) == nil, !tokens.contains("-l") {
                return .swapPane(target: .current, source: source)
            }
            let target = try paneTarget(from: tokens, defaultValue: .next)
            return .swapPane(target: target, source: source)
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
                ?? tokens.first(where: { !$0.hasPrefix("-") }) // never feed a flag into TargetSpec.parse
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
        case "reattach-surface": return .reattachSurface
        case "jump-previous-prompt": return .jumpToPreviousPrompt
        case "jump-next-prompt": return .jumpToNextPrompt
        case "send-keys":
            // `send-keys -X <action> [arg]` dispatches a copy-mode command.
            if let xi = tokens.firstIndex(of: "-X"), xi + 1 < tokens.count {
                let actionName = tokens[xi + 1]
                let arg = xi + 2 < tokens.count ? tokens[xi + 2] : nil
                if let action = CopyModeAction(tmuxName: actionName, argument: arg) {
                    return .copyModeCommand(action)
                }
            }
            let positional = tokens.filter { !$0.hasPrefix("-") }
            // `-l` sends the literal text verbatim; `-H` sends raw bytes from hex tokens. Both
            // bypass key-token interpretation (previously the flags were dropped and the words
            // were token-parsed, so a bound `send-keys -l` silently lost its literal meaning).
            if tokens.contains("-H") { return .sendKeysHex(hex: positional) }
            if tokens.contains("-l") { return .sendKeysLiteral(text: positional.joined(separator: " ")) }
            return .sendKeys(keys: positional)
        case "display-message":
            let format = tokens.first { !$0.hasPrefix("-") } ?? ""
            // `-p` prints the rendered format to stdout (scripting) instead of flashing it.
            return tokens.contains("-p") ? .displayMessagePrint(format: format) : .displayMessage(format: format)
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
            let table = canonicalTableName(stringValue(for: "-T", in: tokens) ?? "prefix")
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
            let table = canonicalTableName(stringValue(for: "-T", in: tokens) ?? "prefix")
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
            return .listKeys(table: stringValue(for: "-T", in: tokens).map(canonicalTableName))
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
            return .respawnPane(keepHistory: !(tokens.contains("-k") || tokens.contains("--clear-history")))
        case "clear-history", "clearhist":
            return .clearHistory
        case "move-pane":
            // move-pane -s <src> [-t <dst>] [-h|-v] — like join-pane with an
            // explicit source. `-v` stacks (horizontal divider); default/`-h` is
            // side-by-side. `-t` (dst) is wrapped by the universal target handler
            // — except `move-pane` self-parses, so do it here.
            let direction: SplitDirection = tokens.contains("-v") ? .horizontal : .vertical
            guard let sourceRaw = stringValue(for: "-s", in: tokens), !sourceRaw.isEmpty else {
                throw CommandParseError.missingArgument("move-pane requires -s <source>")
            }
            let source = TargetSpec.parse(sourceRaw)
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
            // Drop the `-p <value>` pair by position, then take the remaining positional as the
            // template — comparing each token to the prompt *value* (the old approach) wrongly
            // dropped a template that happened to equal the prompt string.
            let template = removingFlagPair("-p", in: tokens).first { !$0.hasPrefix("-") } ?? ""
            return .commandPrompt(prompts: prompts, template: template)
        case "confirm-before", "confirm":
            let prompt = stringValue(for: "-p", in: tokens)
            // Drop the `-p <value>` pair by position before taking the command, so a command token
            // equal to the prompt string isn't filtered out.
            let positional = removingFlagPair("-p", in: tokens).filter { !$0.hasPrefix("-") }
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
            return .switchClientTable(table: canonicalTableName(table))
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

        // MARK: Config / buffer / hook verbs (bindable forms of the CLI subcommands)
        case "set-option":
            return try parseSetOption(tokens, defaultScope: "global")
        case "set-window-option":
            // tmux `setw` — a window option; Harness windows are tabs.
            return try parseSetOption(tokens, defaultScope: "tab")
        case "show-options", "show-window-options":
            return .showOptions(scope: optionScope(in: tokens, default: name == "show-window-options" ? "tab" : nil))
        case "set-environment":
            let positional = positionalTokens(tokens, skippingValuesFor: [])
            guard let key = positional.first else {
                throw CommandParseError.missingArgument("set-environment requires a key")
            }
            let unset = tokens.contains("-u")
            let value = positional.dropFirst().joined(separator: " ")
            // tmux errors on a bare key; silently persisting KEY="" would surprise.
            guard unset || !value.isEmpty else {
                throw CommandParseError.missingArgument("set-environment requires a value (or -u to unset)")
            }
            return .setEnvironment(
                global: tokens.contains("-g"),
                key: key,
                value: unset ? nil : value
            )
        case "show-environment":
            return .showEnvironment(global: tokens.contains("-g"))
        case "set-buffer":
            let name = stringValue(for: "-b", in: tokens)
            let text = positionalTokens(tokens, skippingValuesFor: ["-b"]).joined(separator: " ")
            guard !text.isEmpty else { throw CommandParseError.missingArgument("set-buffer requires text") }
            return .setBuffer(name: name, text: text)
        case "paste-buffer":
            return .pasteBuffer(name: stringValue(for: "-b", in: tokens))
        case "delete-buffer":
            guard let name = stringValue(for: "-b", in: tokens)
                ?? positionalTokens(tokens, skippingValuesFor: ["-b"]).first
            else { throw CommandParseError.missingArgument("delete-buffer requires a buffer name") }
            return .deleteBuffer(name: name)
        case "list-buffers":
            return .listBuffers
        case "show-buffer":
            return .showBuffer(name: stringValue(for: "-b", in: tokens))
        case "set-hook":
            // `--if <format>` mirrors the CLI's `bind-hook --if` so a conditional hook
            // can be bound from the `:` prompt / source-file too, not just the CLI.
            let condition = stringValue(for: "--if", in: tokens)
            let positional = positionalTokens(tokens, skippingValuesFor: ["--if"])
            guard positional.count >= 2 else {
                throw CommandParseError.missingArgument("set-hook requires an event and a command")
            }
            return .setHook(
                event: positional[0],
                source: positional.dropFirst().joined(separator: " "),
                condition: condition
            )
        case "show-hooks":
            return .showHooks(event: positionalTokens(tokens, skippingValuesFor: []).first)
        case "unbind-hook":
            guard let raw = positionalTokens(tokens, skippingValuesFor: []).first,
                  let id = UUID(uuidString: raw)
            else { throw CommandParseError.missingArgument("unbind-hook requires a hook id (see show-hooks)") }
            return .unbindHook(id: id)
        case "refresh-client":
            return .refreshClient
        case "respawn-window":
            // Aliases (respawnw/refreshc) resolve via the alias TABLE before the
            // universal `-t` wrap — a case-pattern alias here would skip the wrap,
            // silently respawning the focused window on `respawnw -t <bad>`.
            let keep = !(tokens.contains("-k") || tokens.contains("--clear-history"))
            return .respawnWindow(keepHistory: keep)
        case "show-messages":
            return .showMessages
        case "find-window":
            // `-t <session>` scopes the search; its VALUE must never be mistaken for the
            // search pattern (skipped from the positionals, captured separately).
            let findTarget = stringValue(for: "-t", in: tokens)
            guard let pattern = positionalTokens(tokens, skippingValuesFor: ["-t"]).first else {
                throw CommandParseError.missingArgument("find-window requires a pattern")
            }
            // tmux defaults to matching everything (-CNT); Harness defaults to the cheap
            // snapshot fields (name + title) and adds content capture only with -C.
            let name = tokens.contains("-N")
            let content = tokens.contains("-C")
            let title = tokens.contains("-T")
            let explicit = name || content || title
            return .findWindow(
                pattern: pattern,
                matchName: explicit ? name : true,
                matchContent: content,
                matchTitle: explicit ? title : true,
                target: findTarget
            )

        default:
            throw CommandParseError.unknownCommand(resolveAlias(name) ?? name)
        }
    }

    /// `set-option [-g|-w|-s|-t|-p] [-T <target>] <key> <value>`. Mirrors the CLI scope
    /// flags (`-w` workspace, `-t` tab — Harness's window); the translator resolves a
    /// scoped set without `-T` against the caller's focus chain.
    private static func parseSetOption(_ tokens: [String], defaultScope: String) throws -> Command {
        let scope = optionScope(in: tokens, default: defaultScope) ?? defaultScope
        let target = stringValue(for: "-T", in: tokens)
        let positional = positionalTokens(tokens, skippingValuesFor: ["-T"])
        guard positional.count >= 2 else {
            throw CommandParseError.missingArgument("set-option requires <key> <value>")
        }
        return .setOption(
            scope: scope,
            target: target,
            key: positional[0],
            rawValue: positional.dropFirst().joined(separator: " ")
        )
    }

    /// The CLI's option-scope flag vocabulary (`-g` global, `-w` workspace, `-s` session,
    /// `-t` tab, `-p` pane). Note `-t` is a SCOPE here — these verbs are excluded from the
    /// universal `-t <target>` extraction; explicit targets use `-T`.
    private static func optionScope(in tokens: [String], default defaultScope: String?) -> String? {
        if tokens.contains("-g") { return "global" }
        if tokens.contains("-w") { return "workspace" }
        if tokens.contains("-s") { return "session" }
        if tokens.contains("-t") { return "tab" }
        if tokens.contains("-p") { return "pane" }
        return defaultScope
    }

    /// tmux key-table name aliases. Harness's vi-flavored copy-mode table is named
    /// `copy-mode` (selected when `mode-keys` is vi, the default) — tmux calls that table
    /// `copy-mode-vi`, so accept both everywhere a table name is typed.
    public static func canonicalTableName(_ name: String) -> String {
        name == "copy-mode-vi" ? "copy-mode" : name
    }

    /// Tokens that are not flags and not the value of one of `skippingValuesFor`'s flags.
    /// getopt-style: flag recognition stops at the first positional token or a literal
    /// `--`, so values that begin with `-` (quoted hook commands, buffer payloads,
    /// option/environment values) survive once the positional run starts instead of
    /// being silently dropped as unknown flags.
    private static func positionalTokens(_ tokens: [String], skippingValuesFor valueFlags: [String]) -> [String] {
        var positional: [String] = []
        var index = 0
        var flagsEnded = false
        while index < tokens.count {
            let token = tokens[index]
            if !flagsEnded {
                if token == "--" { flagsEnded = true; index += 1; continue }
                if valueFlags.contains(token) { index += 2; continue }
                if token.hasPrefix("-"), token.count > 1, Int(token) == nil { index += 1; continue }
                flagsEnded = true // first positional ends the flag run (POSIX)
            }
            positional.append(token)
            index += 1
        }
        return positional
    }

    /// `display-menu … <title> <key> <command>` triples (key may be empty as `""`).
    private static func parseMenuItems(_ tokens: [String]) throws -> [Command.MenuItem] {
        let positional = tokens.enumerated().filter { idx, tok in
            !tok.hasPrefix("-") && !(idx > 0 && (tokens[idx - 1] == "-T" || tokens[idx - 1] == "-t"))
        }.map(\.element)
        var items: [Command.MenuItem] = []
        var i = 0
        // Each item is a (title, key, command) triple; a trailing partial group is ignored.
        while i + 3 <= positional.count {
            let title = positional[i], key = positional[i + 1], cmd = positional[i + 2]
            items.append(.init(title: title, key: key.isEmpty ? nil : key, command: (try? parse(cmd)) ?? .displayMessage(format: cmd)))
            i += 3
        }
        return items
    }

    /// Absolute (non-relative) `-t` pane target for select-pane/swap-pane: any value the
    /// full `TargetSpec` grammar accepts (`%id`, `session:window.pane`, `{top}`, an index…).
    /// Returns nil when the tokens carry a directional flag, a relative target (`:.+`/`:.-`/
    /// `!` — `paneTarget`'s fast paths), or no `-t` at all. Throws — never silently
    /// misroutes (the v1.7.1 policy) — when the value parses to nothing actionable (a bare
    /// `:` or `.`); a *name* that doesn't exist parses fine and fails loudly at resolution
    /// instead, matching tmux's "can't find session" behavior.
    private static func explicitPaneTargetSpec(from tokens: [String], flag: String = "-t") throws -> TargetSpec? {
        if flag == "-t" {
            // Directional / relative forms are `paneTarget`'s fast paths, not specs.
            guard !tokens.contains("-L"), !tokens.contains("-R"), !tokens.contains("-U"),
                  !tokens.contains("-D"), !tokens.contains("-l")
            else { return nil }
        }
        guard let raw = stringValue(for: flag, in: tokens) else { return nil }
        if flag == "-t", [":.+", ":.-", "!"].contains(raw) { return nil }
        let spec = TargetSpec.parse(raw)
        guard !spec.isEmpty else {
            throw CommandParseError.invalidArgument(
                "unrecognized pane target '\(raw)' — use %id, session:window.pane, an index, {top}/{bottom}/{left}/{right}, or :.+/:.-/!")
        }
        return spec
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
            default:
                // Unreachable from select-pane/swap-pane (`explicitPaneTargetSpec` intercepts
                // absolute targets first) — kept as the loud backstop for any future caller,
                // preserving the v1.7 no-silent-misroute policy.
                throw CommandParseError.invalidArgument(
                    "unsupported pane target '\(target)' — use -t :.+, -t :.-, -t ! or -L/-R/-U/-D/-l")
            }
        }
        // A dangling -t (flag present, value missing) is a typo, not a request for the default.
        if tokens.contains("-t") {
            throw CommandParseError.missingArgument(
                "-t requires a pane target (:.+, :.-, !, %id, or session:window.pane)")
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
    case invalidArgument(String)
    case unterminatedString

    public var description: String {
        switch self {
        case .emptyInput: return "command input is empty"
        case .expectedCommand: return "expected a command name"
        case let .unknownCommand(name): return "unknown command: \(name)"
        case let .missingFlag(message): return message
        case let .missingArgument(message): return message
        case let .invalidArgument(message): return message
        case .unterminatedString: return "unterminated quoted string"
        }
    }
}

// MARK: - Lexer

private struct Lexer {
    let source: [Character]
    var index: Int = 0
    /// Set when a quoted token runs to EOF with no closing quote — surfaced as a parse error so a
    /// typo like `display-message "hello` fails loudly instead of silently swallowing the rest of
    /// the line as the string's contents.
    var unterminatedQuote = false

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
            if peek == quote { advance() } else { unterminatedQuote = true }
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
