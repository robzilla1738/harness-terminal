import Foundation

public enum TmuxSnapshotCapture {
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent("tmux")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw TmuxImportError.unavailable
    }
    /// Only read commands are issued. Field values are queried individually so
    /// tabs, newlines, quotes and backslashes cannot become delimiter/shell syntax.
    public static func capture(executable: URL, socketPath: String? = nil, sessionID: String? = nil, cancelled: () -> Bool = { false }) throws -> TmuxImportSnapshot {
        guard executable.isFileURL, executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path),
              socketPath.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) ?? true,
              sessionID.map({ TmuxLayoutImport.validID($0, prefix: "$") }) ?? true else { throw TmuxImportError.invalid("executable, server socket or session target") }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var options: [String] = []; if let socketPath { options += ["-S", socketPath] }
        func run(_ arguments: [String], limit: Int = 1 << 20) throws -> String {
            guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw ProcessCaptureError.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let output = try ProcessCapture.run(executable, arguments: options + arguments, timeout: min(3, remaining), maxOutputBytes: limit, cancelled: cancelled)
            guard output.status == 0, var text = String(data: output.stdout, encoding: .utf8), !text.contains("\0") else { throw TmuxImportError.unavailable }
            if text.hasSuffix("\n") { text.removeLast() }; return text
        }
        let format = "#{session_id}\t#{window_id}\t#{pane_id}"
        var listArgs = ["list-panes", "-a", "-F", format]
        if let sessionID { listArgs = ["list-panes", "-s", "-t", sessionID, "-F", format] }
        let index = try run(listArgs)
        struct PaneIndex: Hashable { var session: String, window: String, pane: String }
        let entries = try index.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, TmuxLayoutImport.validID(fields[0], prefix: "$"), TmuxLayoutImport.validID(fields[1], prefix: "@"), TmuxLayoutImport.validID(fields[2], prefix: "%") else { throw TmuxImportError.invalid("stable tmux identity fields") }
            return PaneIndex(session: fields[0], window: fields[1], pane: fields[2])
        }
        guard !entries.isEmpty, entries.count <= 256, Set(entries).count == entries.count else { throw TmuxImportError.invalid("pane count; select a smaller session") }
        func field(_ target: String, _ name: String, limit: Int = 16384) throws -> String { try run(["display-message", "-p", "-t", target, "#{" + name + "}"], limit: limit) }
        var sessions: [String: String] = [:], windows: [String: (String, String)] = [:], panes: [String: TmuxPaneRecord] = [:]
        for entry in entries {
            if sessions[entry.session] == nil { sessions[entry.session] = try field(entry.session, "session_name", limit: 8192) }
            if windows[entry.window] == nil { windows[entry.window] = try (field(entry.window, "window_name", limit: 8192), field(entry.window, "window_layout", limit: 1 << 20)) }
            if panes[entry.pane] == nil { panes[entry.pane] = try TmuxPaneRecord(id: entry.pane, directory: field(entry.pane, "pane_current_path", limit: 8193), startupSuggestion: field(entry.pane, "pane_start_command", limit: 16385)) }
        }
        guard try run(listArgs) == index else { throw TmuxImportError.changed }
        for (id, data) in windows { guard try field(id, "window_layout", limit: 1 << 20) == data.1 else { throw TmuxImportError.changed } }
        let grouped = Dictionary(grouping: entries, by: { $0.session + ":" + $0.window })
        let records = try grouped.keys.sorted().map { key -> TmuxWindowRecord in
            guard let entries = grouped[key], let first = entries.first, let sessionName = sessions[first.session], let window = windows[first.window] else { throw TmuxImportError.changed }
            return TmuxWindowRecord(sessionID: first.session, windowID: first.window, sessionName: sessionName, windowName: window.0, layout: window.1, panes: entries.compactMap { panes[$0.pane] })
        }
        let result = TmuxImportSnapshot(windows: records)
        _ = try TmuxLayoutImport.proposals(result)
        return result
    }
}
