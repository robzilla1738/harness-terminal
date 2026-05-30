# Harness command reference

Every action — keystroke binding, palette entry, `:` prompt, hook firing, `harness-cli` subcommand — resolves to a `Command` value in `HarnessCore/Commands/Command.swift`. The textual form below is what the parser accepts (in `keybindings.json`, the `:` prompt, `bind-key`, etc.); the right column is the IPC + UI effect.

## Pane operations

| Command | What it does |
|---|---|
| `split-window` (alias `split-window -h`) | Split active pane side-by-side (vertical divider). |
| `split-window -v` | Split active pane top/bottom (horizontal divider). |
| `kill-pane` | Close the active pane. Collapses the parent branch. |
| `zoom-pane` (alias `resize-pane -Z`) | Toggle full-tab zoom on the active pane. |
| `select-pane -L` / `-R` / `-U` / `-D` | Directional navigation. Resolved by daemon tree walk. |
| `select-pane` (no flag) | Cycle forward by flat pane order. |
| `select-pane -l` | Jump to the last (most-recently-active) pane in the tab. |
| `select-pane -m` / `-M` | Mark / unmark the active pane (the implicit `join-pane` source). |
| `swap-pane` | Swap the active pane with the next pane in flat order. |
| `join-pane` (alias `join-pane -v` for top/bottom) | Join the marked pane into the active pane as a split. |
| `resize-pane -L` / `-R` / `-U` / `-D` `N` | Shift the parent divider `N` units. |
| `respawn-pane` (alias `respawn-pane -k` to clear scrollback) | Kill and re-spawn the shell with the same surface ID. |
| `break-pane` | Move the active pane to a new tab in the same session. |
| `move-pane -s <target> [-h\|-v]` | Move the `-s` source pane into the `-t` (or active) pane as a split. Like `join-pane` with an explicit source. |
| `rotate-window` (alias `rotate-window -D` for reverse) | Cycle children at every branch. |
| `display-panes` | Overlay a number on each pane; press the digit to jump to it. |
| `synchronize-panes [on\|off]` | Toggle mirroring typed input to every pane in the tab. |

## Tabs / windows

| Command | Effect |
|---|---|
| `new-window` (alias `new-tab`) | Add a tab to the active session. |
| `kill-window` (alias `kill-tab`) | Close the active tab. |
| `rename-window [-N name]` | Inline rename if `-N` given, else interactive. |
| `next-window` / `previous-window` | Cycle tab focus. |
| `select-window -t :<n>` | Select tab by index. |
| `move-window -t :<n>` | Reorder the active tab to index `n` within its session. |
| `swap-window -t :<n>` | Swap the active tab with the tab at index `n`. |
| `select-layout <name>` | Apply one of `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`. |
| `next-layout` / `previous-layout` | Cycle through built-in layouts. |
| `renumber-windows` | Renumber the session's tab indices contiguously (also fires on tab close when the `renumber-windows` option is on). |

### Targets (`-t session:window.pane`)

Most leaf verbs (`split-window`, `kill-pane`, `kill-window`, `send-keys`,
`new-window`, `resize-pane`, `rename-window`, `select-layout`, …) accept a
universal `-t` target that resolves centrally, so a command can act on a pane
other than the focused one:

- **session**: `name`, `$<uuid>`, `+` / `-` (next / previous).
- **window**: index, `name`, `@<uuid>`, `!` (last/MRU), `+` / `-`, `^` / `{start}`
  (first), `$` / `{end}` (highest index).
- **pane**: index, `%<uuid>`, `!` / `{last}`, `+` / `-`, `{top}` / `{bottom}` /
  `{left}` / `{right}`.

Any component may be omitted (`api:`, `:2`, `:2.1`, `%<uuid>`). Indices honor
`base-index` / `pane-base-index`. `select-pane` keeps its directional/relative
form; `select-window -t session:N` is supported.

## Sessions / workspaces

| Command | Effect |
|---|---|
| `new-session [-s name]` | Add a session row in the active workspace. |
| `kill-session` | Close the active session. |
| `rename-session [name]` | Interactive or inline. |
| `select-workspace <0..N>` | Focus workspace by index. |
| `next-workspace` / `previous-workspace` | Cycle workspaces. |

## Modes

| Command | Effect |
|---|---|
| `copy-mode` | Open the vim-style copy-mode viewer for the active pane. |
| `copy-mode -X <action> [arg]` | Run an in-mode copy command: `cursor-left/right/up/down`, `next-word`/`previous-word`, `start-of-line`/`end-of-line`, `history-top`/`history-bottom`, `page-up`/`page-down`/`halfpage-up`/`halfpage-down`, `begin-selection`/`select-line`/`rectangle-toggle`/`clear-selection`, `search-forward`/`search-backward`/`search-again`/`search-reverse`, `copy-selection`/`copy-selection-and-cancel`/`copy-pipe "<cmd>"`, `paste`, `cancel`. Also `send-keys -X <action>`. Rebind with `bind-key -T copy-mode <key> <command>`. |
| `detach-client` | Detach the calling client (CLI attach) or fire SIGTERM-like handling. |

### Attaching from a plain terminal

`harness-cli attach --surface <id>` connects a single pane (raw passthrough).
`harness-cli attach-window [--tab <id>] [--detach-keys <bytes>]` renders a whole
tab's **split layout** — every pane with borders, a status line, and the active
pane's cursor — into any plain terminal (incl. over ssh). Without `--tab` it
attaches the active tab. Inside: the prefix (`Ctrl-A`) then `o` / `;` cycles the
active pane, `d` detaches; `SIGWINCH` re-lays-out live; splitting/killing panes
in the GUI re-composites automatically.

## Buffers (paste store)

| Command | Effect |
|---|---|
| `set-buffer (--data <text> \| --stdin) [--name <name>]` | Store data in a buffer; auto-name `buffer0/1/…` if `--name` omitted. |
| `list-buffers` | List name/size/preview/created-at. |
| `show-buffer [--name <name>]` | Dump bytes to stdout. |
| `delete-buffer --name <name>` | Remove. |
| `paste-buffer --surface <uuid> [--name <name>] [-p\|--bracketed]` | Write buffer contents to a surface's PTY; `-p` wraps in bracketed-paste markers. |
| `save-buffer [--name <name>] <path>` | Write a paste buffer to a file. |
| `load-buffer [--name <name>] <path>` | Read a file into a new paste buffer. |

## Bindings

| Command | Effect |
|---|---|
| `bind-key [-r] [-T <table>] <spec> <command...>` | Bind a key in a named table. Recursive — `<command>` parses to a `Command`. `-r` makes it repeatable (the prefix stays armed briefly so the key repeats). |
| `unbind-key [-T <table>] <spec>` | Remove a binding. |
| `list-keys [-T <table>]` | Print bindings; one table per `[table]` header. |

## Options

| Command | Effect |
|---|---|
| `set-option [-g\|-w\|-s\|-t\|-p] [-T <target>] <key> <value>` | Set a typed option in the chosen scope. Coerces `on`/`off`/`true`/`false`/integers. |
| `show-options [-g\|-w\|-s\|-t\|-p]` | Dump options for the chosen scope (or all). |

Built-in defaults include:

- `status` (bool, default `on`) — show the bottom status line.
- `status-left`, `status-right`, `status-center` — `FormatString` source for the three status segments.
- `mouse` (bool, default `on`) — enable mouse reporting / pane-click selection.
- `mode-keys` (string, default `vi`) — copy-mode key style.
- `set-clipboard` (bool, default `on`) — mirror yank → NSPasteboard.
- `history-limit` (int, default `10000`) — scrollback line cap.
- `base-index` / `pane-base-index` (int, default `0`) — first window / pane index for `-t` targets and index display.
- `renumber-windows` (bool, default `off`) — renumber tab indices contiguously when a tab closes.

## Hooks

| Command | Effect |
|---|---|
| `bind-hook <event> <command...> [--if <format>]` | Bind a command to an event. The optional `--if` is a `FormatString` whose result must be non-empty/non-zero to fire. |
| `unbind-hook --id <uuid>` | Remove a hook by its ID. |
| `list-hooks [--event <event>]` | List bound hooks. |

Events: `after-new-tab`, `after-new-session`, `after-kill-tab`, `after-split-pane`, `after-kill-pane`, `after-resize-pane`, `pane-exited`, `client-attached`, `client-detached`, `agent-state-changed`, `notification-posted`.

## Scripting

| Command | Effect |
|---|---|
| `send-keys <tokens…>` | Inject keystrokes (`C-c`, `Up`, `Enter`, etc.) into the active pane. |
| `display-message <format>` | Render a `FormatString` and surface as a non-blocking status toast. |
| `run-shell [-b] <command>` | Spawn a subprocess. `-b` captures stdout into a paste buffer. |
| `if-shell <condition> <then> [<else>]` | Run `<condition>` in the shell; on exit 0 run `<then>`, else `<else>`. |
| `source-config` (alias `source`, `reload-config`) | Re-import Ghostty config and refresh chrome. |
| `reload-keybindings` | Re-read `keybindings.json` so an external edit takes effect. |

## Composition

| Form | Effect |
|---|---|
| `a ; b ; c` | Sequence. Commits each in order; later steps see the post-state of earlier ones. |
| `"literal text"` / `'literal text'` | Quoted arguments preserve whitespace and `;`. |

See `docs/KEYBINDINGS.md` for the default key tables and `Packages/HarnessCore/Sources/HarnessCore/Format/FormatString.swift` for the full `FormatString` token list.
