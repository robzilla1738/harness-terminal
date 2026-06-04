import Foundation

/// One `harness-cli` subcommand: its canonical name, a one-line summary, any aliases, and whether
/// it accepts `--json`/`--pretty`. Pure data.
public struct CLICommand: Sendable, Equatable {
    public let name: String
    public let summary: String
    /// Alternate spellings dispatched to the same handler (e.g. `bind` → `bind-key`).
    public let aliases: [String]
    /// True for list/show commands that emit machine-readable JSON with `--json [--pretty]`.
    public let supportsJSON: Bool

    public init(_ name: String, _ summary: String, aliases: [String] = [], json: Bool = false) {
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.supportsJSON = json
    }
}

/// The canonical catalog of `harness-cli` subcommands — the single source of truth for shell
/// completions (`CompletionGenerator`, used by `harness-cli completions` and the installer) so the
/// command list never drifts across the fish/zsh/bash scripts. Keep in sync with the dispatch
/// `switch` in `HarnessCLI.main` (a test asserts the documented core commands are present).
public enum CLICommandCatalog {
    public static let commands: [CLICommand] = [
        // Query / inspection
        .init("doctor", "Diagnose the daemon, socket, paths, and integrations", json: true),
        .init("version", "Print CLI and daemon versions", aliases: ["--version", "-v"], json: true),
        .init("ping", "Check the daemon is reachable"),
        .init("daemon-stats", "Daemon pid, uptime, surface/client counts", json: true),
        .init("list-workspaces", "List workspaces", json: true),
        .init("list-surfaces", "List terminal surfaces", json: true),
        .init("list-sessions", "List sidebar sessions", json: true),
        .init("list-windows", "List tabs (all, or one session's)", json: true),
        .init("list-panes", "List panes of a tab", json: true),
        .init("list-agents", "List running agents (state, age, surface)", json: true),
        .init("list-clients", "List connected clients", json: true),
        .init("has-session", "Exit 0 if a session exists, else 1"),
        .init("list-commands", "List known command verbs"),
        .init("get-snapshot", "Dump the full session snapshot as JSON"),
        // Layout
        .init("new-workspace", "Create a workspace"),
        .init("new-session", "Create a session in a workspace"),
        .init("new-tab", "Create a tab in a workspace"),
        .init("new-split", "Split a tab's pane"),
        .init("select-workspace", "Activate a workspace"),
        .init("select-session", "Activate a session"),
        .init("select-tab", "Activate a tab"),
        .init("select-pane", "Select a pane (by id or direction)"),
        .init("close-tab", "Close a tab"),
        .init("close-session", "Close a session"),
        .init("promote-session", "Pin a session to survive a clean quit"),
        .init("demote-session", "Unpin a session (ephemeral again)"),
        .init("kill-pane", "Kill a pane"),
        .init("swap-pane", "Swap two panes"),
        .init("resize-pane", "Resize a pane"),
        .init("zoom-pane", "Toggle pane zoom"),
        .init("break-pane", "Break a pane into its own tab"),
        .init("join-pane", "Join a pane into another tab"),
        .init("move-pane", "Move a pane into another tab"),
        .init("respawn-pane", "Restart a pane's command"),
        .init("rotate-window", "Rotate panes within a tab"),
        .init("select-layout", "Apply a named layout"),
        .init("next-layout", "Cycle to the next layout"),
        .init("previous-layout", "Cycle to the previous layout"),
        .init("renumber-windows", "Renumber a workspace's tabs"),
        .init("rename-tab", "Rename a tab"),
        .init("rename-session", "Rename a session"),
        .init("rename-workspace", "Rename a workspace"),
        .init("link-window", "Share a tab into another session"),
        .init("unlink-window", "Unlink a shared tab"),
        // Pane I/O
        .init("send", "Send literal text to a surface"),
        .init("send-keys", "Send key tokens to a surface"),
        .init("capture-pane", "Capture a pane's contents"),
        .init("pipe-pane", "Pipe a pane's output to a command"),
        .init("copy-mode", "Enter/exit copy mode"),
        .init("attach", "Attach a single pane to this terminal"),
        .init("attach-window", "Attach a tab's full split layout"),
        .init("record", "Record a surface's output to a JSON Lines file"),
        .init("replay", "Replay a recorded session to this terminal"),
        .init("control-mode", "tmux control protocol over stdio", aliases: ["-CC"]),
        // Buffers
        .init("set-buffer", "Set a paste buffer"),
        .init("list-buffers", "List paste buffers", json: true),
        .init("show-buffer", "Print a buffer's contents"),
        .init("delete-buffer", "Delete a buffer"),
        .init("paste-buffer", "Paste a buffer into a surface"),
        .init("save-buffer", "Write a buffer to a file"),
        .init("load-buffer", "Load a buffer from a file"),
        // Options / environment / hooks
        .init("set-option", "Set an option", aliases: ["setw"]),
        .init("show-options", "Show options", aliases: [], json: true),
        .init("set-environment", "Set a pane environment variable", aliases: ["setenv"]),
        .init("show-environment", "Show pane environment", aliases: ["showenv"], json: true),
        .init("bind-hook", "Bind a command to a daemon event"),
        .init("unbind-hook", "Remove a hook"),
        .init("list-hooks", "List hooks", json: true),
        .init("wait-for", "Wait on / signal a channel", aliases: ["wait"]),
        // Keys
        .init("bind-key", "Bind a key to a command", aliases: ["bind"]),
        .init("unbind-key", "Remove a key binding", aliases: ["unbind"]),
        .init("list-keys", "List key bindings"),
        // Agents / notifications / misc
        .init("detect-agent", "Detect the agent running in a surface"),
        .init("notify", "Post a notification for a surface"),
        .init("detach-client", "Detach a connected client"),
        .init("display-message", "Render a format string"),
        // Install / integration
        .init("install", "Install the CLI, completions, and LaunchAgent"),
        .init("install-hooks", "Install agent notification hooks"),
        .init("install-shell-integration", "Install OSC 133 shell integration"),
        .init("completions", "Print a shell completion script (zsh|fish|bash)"),
    ]

    /// Every name a user might type for a command (canonical names + aliases), in catalog order.
    public static var allInvocationNames: [String] {
        commands.flatMap { [$0.name] + $0.aliases }
    }

    /// Canonical names only (no aliases).
    public static var canonicalNames: [String] { commands.map(\.name) }

    /// The list/show commands that accept `--json [--pretty]`.
    public static var jsonCommands: [CLICommand] { commands.filter(\.supportsJSON) }
}
