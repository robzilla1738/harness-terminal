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
    public static func evaluate(_ source: String, context: FormatContext) -> String {
        var result = ""
        var i = source.startIndex
        while i < source.endIndex {
            let ch = source[i]
            if ch == "#", source.index(after: i) < source.endIndex, source[source.index(after: i)] == "{" {
                let start = source.index(i, offsetBy: 2)
                if let end = matchBrace(in: source, from: start) {
                    let body = String(source[start..<end])
                    result += evaluateToken(body, context: context)
                    i = source.index(after: end)
                    continue
                }
            }
            result.append(ch)
            i = source.index(after: i)
        }
        return result
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
           let count = Int(body[body.index(after: body.startIndex)..<colon])
        {
            let inner = String(body[body.index(after: colon)...])
            let resolved = evaluate(wrap(inner), context: context)
            if resolved.count <= count { return resolved }
            return String(resolved.prefix(count))
        }
        // Strftime time formatter: #{time:%H:%M}
        //
        // DateFormatter.dateFormat takes ICU patterns, not strftime. Feeding it
        // `%H:%M` produces `%11:%5` (%=literal, H=hour-with-no-padding,
        // M=month-in-year) — visibly wrong. We translate strftime to ICU here
        // so the user-facing syntax matches the standard strftime / date(1)
        // format the docstring promises.
        if body.hasPrefix("time:") {
            let format = String(body.dropFirst("time:".count))
            let formatter = DateFormatter()
            formatter.dateFormat = strftimeToICU(format)
            return formatter.string(from: context.now)
        }
        return resolve(token: body, context: context)
    }

    /// Wrap a bare body in #{…} so nested truncation can re-use the evaluator.
    private static func wrap(_ body: String) -> String {
        body.contains("#{") ? body : "#{\(body)}"
    }

    private static func evaluateConditional(_ body: String, context: FormatContext) -> String {
        // Split on top-level commas. Commas inside #{...} are protected.
        let parts = topLevelSplit(body, on: ",")
        guard parts.count >= 2 else { return "" }
        let condition = resolve(token: parts[0], context: context)
        let truthy = !condition.isEmpty && condition != "0" && condition != "false"
        if truthy { return evaluate(wrapInline(parts[1]), context: context) }
        if parts.count >= 3 { return evaluate(wrapInline(parts[2]), context: context) }
        return ""
    }

    private static func wrapInline(_ part: String) -> String {
        // If the part looks like a format string (has `#{`), pass through.
        // Otherwise treat as literal text — that matches user intuition for
        // `#{?agent_activity,● working,}` where `● working` is a literal.
        part.contains("#{") ? part : part
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

    private static func resolve(token: String, context: FormatContext) -> String {
        switch token {
        case "pane_id": return context.paneID ?? ""
        case "pane_title", "pane_name": return context.paneTitle ?? ""
        case "pane_cwd", "pane_current_path": return context.paneCwd ?? ""
        case "cwd_basename":
            guard let cwd = context.paneCwd else { return "" }
            return (cwd as NSString).lastPathComponent
        case "pane_active": return context.paneActive ? "1" : ""
        case "pane_index": return context.paneIndex.map(String.init) ?? ""
        case "session_name": return context.sessionName ?? ""
        case "tab_name", "window_name": return context.tabName ?? ""
        case "tab_index", "window_index": return context.tabIndex.map(String.init) ?? ""
        case "workspace_name": return context.workspaceName ?? ""
        case "agent_kind": return context.agentKind ?? ""
        case "agent_activity": return context.agentActivity ?? ""
        case "git_branch": return context.gitBranch ?? ""
        case "client_name": return context.clientName ?? ""
        case "window_flags": return context.windowFlags ?? ""
        case "window_zoomed_flag": return (context.windowFlags?.contains("Z") ?? false) ? "1" : ""
        case "host", "hostname": return ProcessInfo.processInfo.hostName
        case "user", "username": return NSUserName()
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
    public var now: Date

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
