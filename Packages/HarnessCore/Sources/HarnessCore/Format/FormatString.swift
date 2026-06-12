import Foundation

/// Lightweight templating used by the status line, hooks, `display-message`,
/// and `display-popup`. Tokens are spelled `#{name}` with optional spec
/// modifiers — `#{=10:name}` truncates, `#{?cond,then,else}` is a ternary.
/// The supported tokens are the ones common to multiplexer status bars: pane
/// IDs/titles, session/tab/workspace names, cwd, git branch, agent state,
/// timestamp.
///
/// Unknown tokens evaluate to the empty string rather than throwing so a
/// user-customized status line with a typo still renders.
public enum FormatString {
    // MARK: - Process-lifetime caches

    // DateFormatter is expensive to construct (~0.3 ms per call) and the status line re-evaluates
    // every 750 ms, so creating one per `#{time:…}` evaluation wastes significant CPU. Cache by
    // ICU format string — the ICU pattern (not the raw strftime pattern) is the key because that
    // is the stable post-translation form.
    //
    // `nonisolated(unsafe)`: `@unchecked Sendable` / actor isolation can't be applied to a static
    // on an enum; the companion NSLock serializes all reads and writes, matching the pattern in
    // `AgentDetector` (same codebase). The cache is bounded to 32 entries to prevent an adversarial
    // status format from growing it without limit.
    private static let dateFormatterLock = NSLock()
    nonisolated(unsafe) private static var dateFormatterCache: [String: DateFormatter] = [:]
    private static let dateFormatterCacheLimit = 32

    // `ProcessInfo.hostName` and `NSUserName()` are stable for the lifetime of the process (a
    // hostname change requires a network-stack restart, and the logged-in user never changes mid-
    // session). Per-process caching matches tmux's behaviour and avoids a gethostbyname/getpwuid
    // round-trip on every 750 ms status-line tick.
    private static let processIdentityLock = NSLock()
    nonisolated(unsafe) private static var cachedHostName: String? = nil
    nonisolated(unsafe) private static var cachedUserName: String? = nil

    /// Cached hostname — resolved once per process lifetime (matches tmux behaviour).
    private static func hostName() -> String {
        processIdentityLock.lock()
        defer { processIdentityLock.unlock() }
        if let cached = cachedHostName { return cached }
        let name = ProcessInfo.processInfo.hostName
        cachedHostName = name
        return name
    }

    /// Cached username — resolved once per process lifetime.
    private static func userName() -> String {
        processIdentityLock.lock()
        defer { processIdentityLock.unlock() }
        if let cached = cachedUserName { return cached }
        let name = NSUserName()
        cachedUserName = name
        return name
    }

    /// Return (creating if absent) a `DateFormatter` for the given ICU `format` string. Thread-safe;
    /// bounded to `dateFormatterCacheLimit` entries (oldest-insertion eviction: a real LRU would need
    /// an ordered dict; given ≤a few distinct time formats in any one config the ordering is fine).
    private static func dateFormatter(icuFormat: String) -> DateFormatter {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        if let cached = dateFormatterCache[icuFormat] { return cached }
        let formatter = DateFormatter()
        formatter.dateFormat = icuFormat
        // Evict one arbitrary entry once the cap is hit, keeping memory bounded.
        if dateFormatterCache.count >= dateFormatterCacheLimit,
           let evictKey = dateFormatterCache.keys.first
        {
            dateFormatterCache.removeValue(forKey: evictKey)
        }
        dateFormatterCache[icuFormat] = formatter
        return formatter
    }

    public static func evaluate(_ source: String, context: FormatContext) -> String {
        evaluateStyled(source, context: context).map(\.text).joined()
    }

    /// Evaluate to styled segments: `#{…}` tokens expand to text in the current style, and
    /// `#[fg=…,bg=…,attrs]` directives change the style for following text. `evaluate(_:)` is
    /// just this joined — for input without any `#[…]` it returns a single default-styled
    /// segment, so the plain path is byte-identical.
    public static func evaluateStyled(_ source: String, context: FormatContext) -> [StyledSegment] {
        var segments: [StyledSegment] = []
        var style = FormatStyle()
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            segments.append(style.applied(to: current))
            current = ""
        }
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            if ch == "#" {
                let after = source.index(after: i)
                if after < source.endIndex, source[after] == "{" {
                    let start = source.index(i, offsetBy: 2)
                    if let end = matchBrace(in: source, from: start) {
                        current += evaluateToken(String(source[start..<end]), context: context)
                        i = source.index(after: end)
                        continue
                    }
                } else if after < source.endIndex, source[after] == "[" {
                    let start = source.index(i, offsetBy: 2)
                    if let end = source[start...].firstIndex(of: "]") {
                        flush()
                        applyStyleDirective(String(source[start..<end]), to: &style)
                        i = source.index(after: end)
                        continue
                    }
                }
            }
            current.append(ch)
            i = source.index(after: i)
        }
        flush()
        return segments
    }

    private static func matchBrace(in source: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var i = start
        while i < source.endIndex {
            let ch = source[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = source.index(after: i)
        }
        return nil
    }

    private static func evaluateToken(_ body: String, context: FormatContext) -> String {
        // Ternary: #{?cond,then,else}
        if body.hasPrefix("?") {
            return evaluateConditional(String(body.dropFirst()), context: context)
        }
        // Truncation: #{=N:body}
        if body.hasPrefix("="), let colon = body.firstIndex(of: ":"),
           let parsed = Int(body[body.index(after: body.startIndex)..<colon])
        {
            // A negative width would trap `String.prefix(_:)` (it requires maxLength >= 0).
            // Status formats are user-authored (`set-option -g status-left "#{=-5:…}"`) and
            // re-evaluated every frame in both the GUI status bar and the ssh compositor, so a
            // stray `-` must degrade to empty, never crash. Clamp instead of trapping; N == 0
            // already yields "" through the same path.
            let count = max(0, parsed)
            let inner = String(body[body.index(after: colon)...])
            let resolved = evaluate(wrap(inner), context: context)
            // Truncate by display columns, not Swift Character count: a CJK/emoji glyph is two
            // cells, so a character-count prefix would overrun the requested width in the status
            // bar (matching the display-width-aware status clipping). DisplayWidth.prefix also cuts
            // on grapheme boundaries, so a combining sequence is never split.
            return DisplayWidth.prefix(resolved, maxColumns: count)
        }
        // Strftime time formatter: #{time:%H:%M}
        //
        // DateFormatter.dateFormat takes ICU patterns, not strftime. Feeding it
        // `%H:%M` produces `%11:%5` (%=literal, H=hour-with-no-padding,
        // M=month-in-year) — visibly wrong. We translate strftime to ICU here
        // so the user-facing syntax matches the standard strftime / date(1)
        // format the docstring promises.
        //
        // The formatter is retrieved from the process-lifetime cache (keyed on the ICU form)
        // rather than allocated fresh on every tick — the status line re-evaluates at 750 ms
        // and DateFormatter construction costs ~0.3 ms, which is the dominant work per frame.
        if body.hasPrefix("time:") {
            let format = String(body.dropFirst("time:".count))
            let icu = strftimeToICU(format)
            let formatter = dateFormatter(icuFormat: icu)
            return formatter.string(from: context.now)
        }
        // Operators (tmux): equality, regex match, regex substitution, arithmetic.
        if body.hasPrefix("==:") { return operatorEquals(String(body.dropFirst(3)), context: context) }
        if body.hasPrefix("!=:") { return operatorEquals(String(body.dropFirst(3)), context: context, negate: true) }
        if body.hasPrefix("||:") { return operatorLogical(String(body.dropFirst(3)), context: context, and: false) }
        if body.hasPrefix("&&:") { return operatorLogical(String(body.dropFirst(3)), context: context, and: true) }
        if body.hasPrefix("m:") { return operatorMatch(String(body.dropFirst(2)), context: context) }
        if body.hasPrefix("s/") { return operatorSubstitute(body, context: context) }
        if body.hasPrefix("e|") { return operatorMath(body, context: context) }
        if body.hasPrefix("n:") { return operatorLength(String(body.dropFirst(2)), context: context) }
        if body.hasPrefix("T:") { return operatorExpandTwice(String(body.dropFirst(2)), context: context) }
        if body.hasPrefix("a:") { return operatorChar(String(body.dropFirst(2)), context: context) }
        if let padded = operatorPad(body, context: context) { return padded }
        return resolve(token: body, context: context)
    }

    // MARK: - Operators

    private static func operatorEquals(_ body: String, context: FormatContext, negate: Bool = false) -> String {
        let parts = topLevelSplit(body, on: ",")
        guard parts.count >= 2 else { return "" }
        let a = evaluate(parts[0], context: context)
        let b = evaluate(parts[1], context: context)
        return (a == b) != negate ? "1" : ""
    }

    /// `#{||:A,B}` / `#{&&:A,B}` — logical or / and. An operand is "true" when it expands non-empty
    /// (tmux's truthiness), so these compose with `#{?…}` like comparisons do.
    private static func operatorLogical(_ body: String, context: FormatContext, and: Bool) -> String {
        let parts = topLevelSplit(body, on: ",")
        guard parts.count >= 2 else { return "" }
        let a = !evaluate(parts[0], context: context).isEmpty
        let b = !evaluate(parts[1], context: context).isEmpty
        return (and ? (a && b) : (a || b)) ? "1" : ""
    }

    // The argument to these modifiers is a *format string* (tmux semantics): bare text is literal
    // and `#{…}` expands — so we `evaluate` it directly rather than wrapping it as a single token.

    /// `#{n:body}` — the display-column width of the expanded body (tmux's length modifier).
    private static func operatorLength(_ body: String, context: FormatContext) -> String {
        String(DisplayWidth.columns(of: evaluate(body, context: context)))
    }

    /// `#{T:body}` — expand the body, then expand the *result* again as a format string. The
    /// idiomatic way to store a format in a user-var and render it (`#{T:#{@my_format}}`).
    private static let maxExpandDepth = 32
    private static func operatorExpandTwice(_ body: String, context: FormatContext) -> String {
        // T: re-expands its own produced output, so a self-referential user option
        // (`@v = "#{T:#{@v}}"`) would recurse until the daemon's stack overflows. Bound the
        // re-expansion depth; past the limit, stop expanding (render empty) rather than crash.
        guard context.expansionDepth < maxExpandDepth else { return "" }
        var inner = context
        inner.expansionDepth += 1
        return evaluate(evaluate(body, context: inner), context: inner)
    }

    /// `#{a:N}` — the character whose decimal Unicode scalar value is N (`#{a:65}` → "A").
    private static func operatorChar(_ body: String, context: FormatContext) -> String {
        let arg = evaluate(body, context: context).trimmingCharacters(in: .whitespaces)
        guard let code = UInt32(arg), let scalar = Unicode.Scalar(code) else { return "" }
        return String(scalar)
    }

    /// `#{pN:body}` — pad the expanded body with spaces to at least N display columns
    /// (left-justified). Returns nil when `body` isn't the `p<digits>:` shape, so tokens that merely
    /// start with `p` (e.g. `pane_…`) fall through to normal resolution. Never truncates.
    private static func operatorPad(_ body: String, context: FormatContext) -> String? {
        guard body.hasPrefix("p"), let colon = body.firstIndex(of: ":") else { return nil }
        let widthStr = body[body.index(after: body.startIndex)..<colon]
        guard !widthStr.isEmpty, let width = Int(widthStr), width >= 0 else { return nil }
        let resolved = evaluate(String(body[body.index(after: colon)...]), context: context)
        let cols = DisplayWidth.columns(of: resolved)
        return cols >= width ? resolved : resolved + String(repeating: " ", count: width - cols)
    }

    private static func operatorMatch(_ body: String, context: FormatContext) -> String {
        let parts = topLevelSplit(body, on: ",")
        guard parts.count >= 2 else { return "" }
        let pattern = evaluate(parts[0], context: context)
        let str = evaluate(parts[1], context: context)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        return regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil ? "1" : ""
    }

    /// `#{s/RE/REP/[flags]:STRING}` — regex substitution (all matches; REP is literal). `i`
    /// flag = case-insensitive. Invalid regex → the unmodified string.
    private static func operatorSubstitute(_ body: String, context: FormatContext) -> String {
        guard body.count > 1 else { return "" }
        let delim = body[body.index(after: body.startIndex)] // char after 's'
        let pieces = splitTop(String(body.dropFirst(2)), by: delim, max: 3)
        guard pieces.count == 3, let colon = pieces[2].firstIndex(of: ":") else { return "" }
        let re = pieces[0], rep = pieces[1]
        let flags = String(pieces[2][pieces[2].startIndex..<colon])
        let target = evaluate(String(pieces[2][pieces[2].index(after: colon)...]), context: context)
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: re, options: options) else { return target }
        let template = NSRegularExpression.escapedTemplate(for: rep)
        return regex.stringByReplacingMatches(in: target, range: NSRange(target.startIndex..., in: target), withTemplate: template)
    }

    /// `#{e|OP|A|B}` — arithmetic (`+ - * / %`) on two evaluated operands.
    private static func operatorMath(_ body: String, context: FormatContext) -> String {
        let parts = topLevelSplit(String(body.dropFirst(2)), on: "|")
        guard parts.count >= 3 else { return "" }
        let op = parts[0].first.map(String.init) ?? "+"
        let a = Double(evaluate(parts[1], context: context).trimmingCharacters(in: .whitespaces)) ?? 0
        let b = Double(evaluate(parts[2], context: context).trimmingCharacters(in: .whitespaces)) ?? 0
        let result: Double
        switch op {
        case "-": result = a - b
        case "*": result = a * b
        case "/": result = b == 0 ? 0 : a / b
        case "%": result = b == 0 ? 0 : a.truncatingRemainder(dividingBy: b)
        default: result = a + b
        }
        // Only stringify as an integer when the value is finite, whole, AND fits in Int.
        // `Int(Double)` traps on infinite/NaN or out-of-range magnitudes (e.g.
        // `#{e|*|1e10|1e10}` = 1e20 > Int.max, or an operand that parses to +inf), and
        // status formats re-render every frame, so a trap here would crash-loop the
        // renderer / daemon — the same "degrade to text, never crash" invariant the
        // negative-width clamp upholds.
        if result.isFinite, result == result.rounded(), let whole = Int(exactly: result) {
            return String(whole)
        }
        return String(result)
    }

    /// Split into at most `max` pieces by `delim` (no nesting awareness — for `s///` parts).
    private static func splitTop(_ s: String, by delim: Character, max: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in s {
            if ch == delim, result.count < max - 1 {
                result.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Style directives (`#[…]`)

    private struct FormatStyle {
        var fg: FormatColor?
        var bg: FormatColor?
        var bold = false, italic = false, underline = false, reverse = false, dim = false
        func applied(to text: String) -> StyledSegment {
            StyledSegment(text: text, fg: fg, bg: bg, bold: bold, italic: italic, underline: underline, reverse: reverse, dim: dim)
        }
    }

    private static func applyStyleDirective(_ body: String, to style: inout FormatStyle) {
        for raw in body.split(separator: ",") {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p == "default" || p == "none" { style = FormatStyle(); continue }
            if p.hasPrefix("fg=") { style.fg = parseFormatColor(String(p.dropFirst(3))); continue }
            if p.hasPrefix("bg=") { style.bg = parseFormatColor(String(p.dropFirst(3))); continue }
            switch p {
            case "bold", "bright": style.bold = true
            case "nobold", "nobright": style.bold = false
            case "italics", "italic": style.italic = true
            case "noitalics": style.italic = false
            case "underscore", "underline": style.underline = true
            case "nounderscore": style.underline = false
            case "reverse", "inverse": style.reverse = true
            case "noreverse": style.reverse = false
            case "dim": style.dim = true
            case "nodim": style.dim = false
            default: break
            }
        }
    }

    private static func parseFormatColor(_ raw: String) -> FormatColor? {
        FormatColor.parse(raw)
    }

    /// Wrap a bare body in #{…} so nested truncation can re-use the evaluator.
    private static func wrap(_ body: String) -> String {
        body.contains("#{") ? body : "#{\(body)}"
    }

    private static func evaluateConditional(_ body: String, context: FormatContext) -> String {
        // Split on top-level commas. Commas inside #{...} are protected.
        let parts = topLevelSplit(body, on: ",")
        guard parts.count >= 2 else { return "" }
        // Evaluate the test as a full expression so a nested operator/comparison works, e.g.
        // `#{?#{==:#{pane_current_command},vim},…,…}` (common in real `.tmux.conf`): a wrapped
        // `#{…}` test runs through the token evaluator, a bare variable name resolves directly.
        // (Previously the test was only ever resolved as a bare token, so any nested operator read
        // as "unknown" → empty → falsy, and the else-branch always won.)
        let test = parts[0]
        let condition = test.contains("#{")
            ? evaluate(test, context: context)
            : evaluateToken(test, context: context)
        let truthy = !condition.isEmpty && condition != "0" && condition != "false"
        if truthy { return evaluate(parts[1], context: context) }
        if parts.count >= 3 { return evaluate(parts[2], context: context) }
        return ""
    }

    private static func topLevelSplit(_ source: String, on separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            if ch == "{" { depth += 1; current.append(ch) }
            else if ch == "}" { depth -= 1; current.append(ch) }
            else if ch == separator, depth == 0 {
                result.append(current); current = ""
            } else {
                current.append(ch)
            }
            i = source.index(after: i)
        }
        result.append(current)
        return result
    }

    /// Translate strftime-style format directives (`%H`, `%M`, `%Y`, …) into
    /// the ICU pattern syntax that `DateFormatter.dateFormat` consumes.
    /// Unknown `%x` sequences pass through unchanged; bare letters get
    /// single-quoted so ICU treats them as literals.
    private static func strftimeToICU(_ source: String) -> String {
        var result = ""
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            if ch == "%" {
                let next = source.index(after: i)
                if next < source.endIndex {
                    let token = source[next]
                    let icu: String
                    switch token {
                    case "H": icu = "HH"      // 00–23
                    case "I": icu = "hh"      // 01–12
                    case "M": icu = "mm"      // 00–59
                    case "S": icu = "ss"      // 00–59
                    case "p": icu = "a"       // AM/PM
                    case "Y": icu = "yyyy"
                    case "y": icu = "yy"
                    case "m": icu = "MM"      // month 01–12
                    case "d": icu = "dd"      // day 01–31
                    case "e": icu = "d"
                    case "j": icu = "DDD"
                    case "a": icu = "EEE"
                    case "A": icu = "EEEE"
                    case "b", "h": icu = "MMM"
                    case "B": icu = "MMMM"
                    case "%": icu = "%"
                    default: icu = "%\(token)"
                    }
                    result += icu
                    i = source.index(after: next)
                    continue
                }
            }
            if ch.isLetter {
                result += "'\(ch)'"
            } else if ch == "'" {
                result += "''"
            } else {
                result.append(ch)
            }
            i = source.index(after: i)
        }
        return result
    }

    /// Compact human duration for `#{command_duration}`: sub-second in ms, then s / m s / h m.
    private static func formatCommandDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60, secs = total % 60
        if minutes < 60 { return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s" }
        let hours = minutes / 60, mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    private static func resolve(token: String, context: FormatContext) -> String {
        // User options (`#{@name}`): resolved by the builder into `userOptions`. Unset → empty.
        if token.hasPrefix("@") { return context.userOptions[token] ?? "" }
        switch token {
        // The command that triggered the current hook (`command-error`'s failing command).
        case "hook": return context.hookCommand ?? ""
        // tmux renders pane ids as `%id`; the `%` prefix matches the `-t` pane grammar
        // (TargetSpec.parsePaneToken) so a displayed id round-trips straight into a target,
        // exactly like session_id (`$`) and window_id (`@`) below.
        case "pane_id": return context.paneID.map { "%" + $0 } ?? ""
        case "pane_title", "pane_name": return context.paneTitle ?? ""
        case "pane_cwd", "pane_current_path": return context.paneCwd ?? ""
        case "cwd_basename":
            guard let cwd = context.paneCwd else { return "" }
            return (cwd as NSString).lastPathComponent
        // Flag tokens render tmux's "1"/"0" (conditionals treat "0" and "" as falsy
        // either way, but the literal output should be uniform across the vocabulary).
        case "pane_active": return context.paneActive ? "1" : "0"
        case "pane_index": return context.paneIndex.map(String.init) ?? ""
        case "pane_pid": return context.panePID.map(String.init) ?? ""
        case "pane_current_command": return context.paneCurrentCommand ?? ""
        case "pane_width": return context.paneWidth.map(String.init) ?? ""
        case "pane_height": return context.paneHeight.map(String.init) ?? ""
        case "pane_dead": return context.paneDead.map { $0 ? "1" : "0" } ?? ""
        case "pane_dead_status": return context.paneExitStatus.map(String.init) ?? ""
        case "history_bytes": return context.historyBytes.map(String.init) ?? ""
        case "session_name": return context.sessionName ?? ""
        // tmux-style identifiers, matching the `-t` target grammar ($session/@window) so a
        // displayed id round-trips straight back into a target argument.
        case "session_id": return context.sessionID.map { "$" + $0 } ?? ""
        case "window_id": return context.windowID.map { "@" + $0 } ?? ""
        case "session_windows": return context.sessionWindows.map(String.init) ?? ""
        case "session_attached": return context.sessionAttached.map(String.init) ?? ""
        case "session_group": return context.sessionGroup ?? ""
        case "tab_name", "window_name": return context.tabName ?? ""
        case "tab_index", "window_index": return context.tabIndex.map(String.init) ?? ""
        case "window_panes": return context.windowPanes.map(String.init) ?? ""
        case "window_active": return context.windowActive.map { $0 ? "1" : "0" } ?? ""
        case "workspace_name": return context.workspaceName ?? ""
        case "agent_kind": return context.agentKind ?? ""
        case "agent_activity": return context.agentActivity ?? ""
        // Last finished command's runtime in the pane (OSC 133 C→D), compact-human form
        // ("850ms", "12s", "3m 5s"). GUI vantage only — daemon/CLI contexts render empty.
        case "command_duration": return context.commandDurationSeconds.map(formatCommandDuration) ?? ""
        case "git_branch": return context.gitBranch ?? ""
        case "client_name": return context.clientName ?? ""
        case "client_width": return context.clientWidth.map(String.init) ?? ""
        case "client_height": return context.clientHeight.map(String.init) ?? ""
        case "client_tty": return context.clientTTY ?? ""
        case "client_termname": return context.clientTermname ?? ""
        case "window_flags": return context.windowFlags ?? ""
        case "window_zoomed_flag": return (context.windowFlags?.contains("Z") ?? false) ? "1" : ""
        // Alert flags as standalone 0/1 vars, derived from the same `#{window_flags}`
        // characters the daemon sets (`#` activity, `~` silence, `!` bell).
        case "window_activity_flag": return (context.windowFlags?.contains("#") ?? false) ? "1" : "0"
        case "window_silence_flag": return (context.windowFlags?.contains("~") ?? false) ? "1" : "0"
        case "window_bell_flag": return (context.windowFlags?.contains("!") ?? false) ? "1" : "0"
        case "pid": return context.serverPID.map(String.init) ?? ""
        case "socket_path": return HarnessPaths.socketURL.path
        case "version": return HarnessVersion.short
        // Resolved once per process — hostname/username are stable for the process lifetime
        // (a hostname change needs a network-stack restart; user never changes mid-session).
        case "host", "hostname": return hostName()
        case "host_short":
            let host = hostName()
            return host.split(separator: ".").first.map(String.init) ?? host
        case "user", "username": return userName()
        default: return ""
        }
    }
}

/// All values a `FormatString` token can resolve against. Built on demand by
/// the caller (status line bar, hook executor, display-message handler) from
/// the current snapshot.
public struct FormatContext: Sendable {
    public var paneID: String?
    public var paneTitle: String?
    public var paneCwd: String?
    public var paneActive: Bool
    public var paneIndex: Int?
    public var sessionName: String?
    public var tabName: String?
    public var tabIndex: Int?
    public var workspaceName: String?
    public var agentKind: String?
    public var agentActivity: String?
    public var gitBranch: String?
    public var clientName: String?
    /// tmux-style window flags: `Z` zoomed, `*` active, `#` activity, `!` bell, `M` marked.
    public var windowFlags: String?
    /// The command that triggered the current hook, surfaced as `#{hook}` (set for `command-error`).
    public var hookCommand: String? = nil
    public var now: Date
    // Extended tmux-parity fields. All optional: a builder fills what its vantage point
    // knows (the daemon has PTY facts, the attach client has tty facts) and the rest
    // render as empty tokens.
    /// PID of the pane's root shell process (`#{pane_pid}`).
    public var panePID: Int?
    /// Foreground process name (`#{pane_current_command}`).
    public var paneCurrentCommand: String?
    public var paneWidth: Int?
    public var paneHeight: Int?
    /// Whether the pane's process has exited while `remain-on-exit` kept it (`#{pane_dead}`).
    public var paneDead: Bool?
    public var paneExitStatus: Int?
    public var historyBytes: Int?
    /// Bare UUID strings — `resolve` adds the tmux-style `$`/`@` prefixes.
    public var sessionID: String?
    public var windowID: String?
    public var sessionWindows: Int?
    public var windowPanes: Int?
    public var windowActive: Bool?
    public var sessionAttached: Int?
    /// Group name once grouped sessions land; empty until then.
    public var sessionGroup: String?
    /// Daemon PID (`#{pid}`); nil in client-side contexts.
    public var serverPID: Int?
    public var clientWidth: Int?
    public var clientHeight: Int?
    public var clientTTY: String?
    public var clientTermname: String?
    /// User options (`@`-prefixed, e.g. `@my_var`) resolved for this vantage point's scope chain.
    /// Keyed by the full option name *including* the `@`, matching `#{@name}` and the OptionStore
    /// key. The builder fills it from the OptionStore; `#{@unset}` renders empty.
    public var userOptions: [String: String] = [:]

    /// Last finished command's duration in seconds (`#{command_duration}`). Filled by the GUI
    /// (OSC 133 timing arrives via the host delegate); daemon/CLI contexts leave it nil.
    public var commandDurationSeconds: Double? = nil

    /// Recursion guard for `#{T:…}` (expand-twice): bounds re-expansion of produced output so a
    /// self-referential user option (`@v = "#{T:#{@v}}"`) can't recurse until the daemon's stack
    /// overflows. Internal plumbing — builders never set it (defaults to 0).
    var expansionDepth: Int = 0

    public init(
        paneID: String? = nil,
        paneTitle: String? = nil,
        paneCwd: String? = nil,
        paneActive: Bool = false,
        paneIndex: Int? = nil,
        sessionName: String? = nil,
        tabName: String? = nil,
        tabIndex: Int? = nil,
        workspaceName: String? = nil,
        agentKind: String? = nil,
        agentActivity: String? = nil,
        gitBranch: String? = nil,
        clientName: String? = nil,
        windowFlags: String? = nil,
        now: Date = Date()
    ) {
        self.paneID = paneID
        self.paneTitle = paneTitle
        self.paneCwd = paneCwd
        self.paneActive = paneActive
        self.paneIndex = paneIndex
        self.sessionName = sessionName
        self.tabName = tabName
        self.tabIndex = tabIndex
        self.workspaceName = workspaceName
        self.agentKind = agentKind
        self.agentActivity = agentActivity
        self.gitBranch = gitBranch
        self.clientName = clientName
        self.windowFlags = windowFlags
        self.now = now
    }
}
