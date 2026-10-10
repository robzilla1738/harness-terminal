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
        .init("uninstall", "Remove owned local tools/service; live shells require --if-empty or explicit --force; preserves user data"),
        .init("socket-path", "Print this machine's daemon control-socket path"),
        .init("run", "Run a command in a new tab or split; --wait exits with its status", json: true),
        .init("ls", "Sessions, tabs, and panes as a tree", json: true),
        .init("inspect", "Everything about one pane, or a session with -s", json: true),
        .init("new", "Create a session here, optionally running a command", json: true),
        .init("wait", "Wait for a pane's program to exit, with its status", json: false),
        .init("keymap", "Every key binding, from keybindings.json and the Lua config", json: true),
        .init("actions", "Lua actions and built-in commands", json: true),
        .init("version", "Print CLI and daemon versions", aliases: ["--version", "-v"], json: true),
        .init("color-check", "Print ANSI/256/truecolor diagnostic swatches"),
        .init("import", "Preview tmux layouts, iTerm2 colors or Ghostty settings; --dry-run writes nothing", json: true),
        .init("theme-preview", "Print deterministic themed sample output"),
        .init("ping", "Check the daemon is reachable"),
        .init("daemon-stats", "Daemon pid, uptime, surface/client counts", json: true),
        .init("list-workspaces", "List workspaces", json: true),
        .init("list-surfaces", "List terminal surfaces", json: true),
        .init("list-sessions", "List sidebar sessions", json: true),
        .init("list-windows", "List tabs (all, or one session's)", json: true),
        .init("list-panes", "List panes of a tab", json: true),
        .init("list-agents", "List running agents (state, age, surface)", json: true),
        .init("notifications", "Local notification policy: status, configure --stdin, mute, snooze, credential-set --stdin, credential-remove", json: true),
        .init("awake", "Inspect or override daemon idle-sleep policy: status, auto, on, off", json: true),
        .init("resume-agent", "Prepare or insert an exact conversation; opt into per-pane restore (--run, --surface, --prepare, --auto-restore on|off)", json: true),
        .init("activity-profile", "Manage approved local transcript profiles: list, set, remove", json: true),
        .init("history-recover", "Resume encrypted history after key unlock [--unlock]"),
        .init("usage", "Observed usage and limits [--days 1–90] [--json]", json: true),
        .init("digest", "Recorded activity digest [--days 1–90] [--surface uuid | --repositories --offset n] [--json]", json: true),
        .init("summary", "Explicit optional AI providers, current model catalogs, bounded generation, cancellation and encrypted history", json: true),
        .init("agents", "List durable executions [--active] [--run <uuid>] [--offset n] [--limit n]", json: true),
        .init("mcp-install", "Print MCP client configuration; --write applies a backed-up edit"),
        .init("mcp", "Run the approved stdio MCP server [--allow-write]"),
        .init("hook-policy", "Review/trust local declarative guardrails, preview/install provider hooks, disable and inspect redacted audit", json: true),
        .init("agent-hook", "Capture a bounded local provider hook (--contract <adapter>)"),
        .init("list-clients", "List connected clients", json: true),
        .init("has-session", "Exit 0 if a session exists, else 1"),
        .init("list-commands", "List known command verbs"),
        .init("get-snapshot", "Dump the full session snapshot as JSON"),
        // Layout
        .init("new-workspace", "Create a workspace", json: true),
        .init("new-session", "Create a session in a workspace", json: true),
        .init("new-tab", "Create a tab in a workspace", json: true),
        .init("new-split", "Split a tab's pane", json: true),
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
        .init("break-pane", "Break a pane into its own tab", json: true),
        .init("join-pane", "Join a pane into another tab", json: true),
        .init("move-pane", "Move a pane into another tab", json: true),
        .init("respawn-pane", "Restart a pane's command"),
        .init("clear-history", "Clear a pane's scrollback without respawning", aliases: ["clearhist"]),
        .init("rotate-window", "Rotate panes within a tab"),
        .init("select-layout", "Apply a named layout"),
        .init("next-layout", "Cycle to the next layout"),
        .init("previous-layout", "Cycle to the previous layout"),
        .init("renumber-windows", "Renumber a workspace's tabs"),
        .init("rename-tab", "Rename a tab"),
        .init("rename-session", "Rename a session"),
        .init("rename-workspace", "Rename a workspace"),
        .init("link-window", "Share a tab into another session", json: true),
        .init("unlink-window", "Unlink a shared tab"),
        // Pane I/O
        .init("send", "Send literal text to a surface"),
        .init("send-keys", "Send key tokens to a surface"),
        .init("capture-pane", "Capture a pane's contents"),
        .init("pipe-pane", "Pipe a pane's output to a command"),
        .init("copy-mode", "Enter/exit copy mode"),
        .init("attach", "Attach a single pane to this terminal"),
        .init("mobile-bridge", "Versioned companion protocol over a non-PTY SSH channel"),
        .init("mobile-key", "Install or remove a trusted device public key locally using --stdin"),
        .init("mobile-setup", "Connection metadata and SSH host fingerprint for phone pairing"),
        .init("pair", "Show a QR code to connect Harness on your phone (--host, --port, --link)", json: true),
        .init("attach-window", "Attach a tab's full split layout"),
        .init("record", "Passively record output and actual PTY geometry to a protected archive"),
        .init("recording", "Review, protect legacy recordings and export reviewed plaintext asciicasts"),
        .init("replay", "Replay a recorded session to this terminal"),
        .init("control-mode", "tmux control protocol over stdio", aliases: ["-CC"]),
        .init("kill-server", "Stop the local daemon (--if-empty or --force)"),
        .init("daemon-replace", "Replace the application daemon while preserving shells [--binary <path>]"),
        .init("daemon-restart", "Restart the local session service (--if-empty or --force)"),
        .init("start-server", "Ensure the daemon is running"),
        .init("show-messages", "Recent display-message log"),
        // Buffers
        .init("set-buffer", "Set a paste buffer"),
        .init("list-buffers", "List paste buffers", json: true),
        .init("show-buffer", "Print a buffer's contents"),
        .init("delete-buffer", "Delete a buffer"),
        .init("paste-buffer", "Paste a buffer into a surface"),
        .init("save-buffer", "Write a buffer to a file"),
        .init("load-buffer", "Load a buffer from a file"),
        // Options / environment / hooks
        .init("set-option", "Set an option", aliases: ["setw", "set-window-option"]),
        .init("show-options", "Show options", aliases: [], json: true),
        .init("set-environment", "Set a pane environment variable", aliases: ["setenv"]),
        .init("show-environment", "Show pane environment", aliases: ["showenv"], json: true),
        .init("bind-hook", "Bind a command to a daemon event", json: true),
        .init("unbind-hook", "Remove a hook"),
        .init("list-hooks", "List hooks", json: true),
        .init("wait-for", "Wait on / signal a channel"),
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
        .init("remote", "Manage remote daemons or pair a phone (list|add|remove|pair)", json: true),
        .init("daemon", "Run the daemon in the foreground (execs HarnessDaemon)"),
        .init("size-mode", "Set multi-client sizing to smallest or owner"),
        .init("take-surface", "Take size ownership of a surface"),
        .init("save-layout", "Save the active tab as a named layout"),
        .init("restore-layout", "Restore a named layout"),
        .init("events", "Print session, pane, and agent events as JSON lines", json: true),
        .init("api", "List, describe, or call the JSON API", json: true),
        .init("schedule", "Review, save, inspect and cancel explicit local one-shot/cron/event schedules", json: true),
        .init("fanout", "Launch providers at one pinned base; inspect, compare, cancel, explicitly test and protect cleanup", json: true),
        .init("worktree", "Create, compare, inspect and safely clean up managed worktrees", json: true),
        .init("plugin", "Review, approve, list, invoke or revoke trusted local Lua plugins", json: true),
        .init("config", "Check or reload ~/.config/harness/init.lua"),
        .init("do", "Run a custom action"),
        .init("process", "Print a surface's foreground process as JSON", json: true),
        .init("find-files", "Find file paths locally or on a remote host"),
        .init("copy-file", "Copy a file locally or over the SSH remote connection"),
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
