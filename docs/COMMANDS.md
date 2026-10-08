# Harness command reference

These are the commands Harness accepts from the `:` prompt, key bindings, hooks, and `harness-cli`.

The 2026-06 parity series added bindable forms of the config/buffer/hook verbs
(`set-option`/`set`/`setw`, `show-options`, `set-environment`/`setenv`, `set-buffer`,
`paste-buffer`, `delete-buffer`, `list-buffers`, `show-buffer`, `set-hook`, `show-hooks`,
`unbind-hook`), plus `find-window`, `refresh-client`, `respawn-window`, `show-messages`,
grouped sessions (`new-session -t <session>`), and full `-t` targets on
`select-pane`/`swap-pane`. tmux-parity status, adaptations, and divergences live in
[TMUX_PARITY.md](TMUX_PARITY.md).

## Running commands and targets

```bash
harness-cli ls                                       # sessions → tabs → panes, * = active
harness-cli run --split right --wait -- make test   # exits with make's status
harness-cli run --label logs -- tail -f app.log      # new tab; prints its surface id
harness-cli send-keys -b 2 --keys "q"                # pane 2 of the current tab
make 2>&1 | harness-cli send -b logs                 # send reads stdin without --text
harness-cli wait -b logs --for 10m                   # exits with the pane's status
harness-cli inspect                                  # everything about this pane
harness-cli new api -- npm run dev                   # a session running a command
```

| Command | Effect |
|---|---|
| `ls [--json]` | Every session, its tabs, and their panes, with positions, short ids, status, `*` on the active ones, and `← here` on the caller's pane. |
| `inspect [<pane>] [-s <session>] [--json]` | One pane (ids, cwd, program, agent, size, program status, process tree) or one session (`api call pane.view` / `session.view`). With no target, the caller's pane. |
| `new [<name>] [--cwd DIR] [--json] [-- COMMAND…]` | Create a session in the caller's workspace and select it. A command runs in the session's shell, so the session outlives it. Prints the session id, or `{session, surface}`. |
| `wait (-b <pane>) [--for DURATION] [--until child\|command]` | Wait for the pane's program to exit, or for its prompt to report a finished command, and exit with that status. `--for 90`, `30s`, `10m`, `2h`; running out exits 1. `wait <channel>` is still tmux's `wait-for`. |
| `keymap [--json]` / `actions [--json]` | Every key binding (KEY, ACTION, ARGS, SOURCE: `keybindings`, `palette` for a shortcut assigned in the command palette, or the Lua layer `default`/`config`/`app`; a Lua function binding shows as `(lua function)`); every Lua action and built-in command. |
| `run [--split right\|below\|left\|above] [--ratio PCT] [--cwd DIR] [--label TEXT] [--surface TARGET] [--no-focus] [--keep-open] [--wait] [--timeout SECS] [--json] -- COMMAND…` | Start a command in a new tab, or in a split of the current (or `--surface`) pane. The pane closes when the command exits unless `--keep-open`. `--wait` blocks and exits with the command's status (with `--keep-open` it waits for the command's shell-integration mark instead). Prints the new surface id, or `{surface, pane, tab}` with `--json`. |

**Targets.** Anywhere `--session`, `--tab`, `--window`, `--surface`, or `--pane` takes an ID, it also takes, in this order:

1. the full ID (any case);
2. a label: a session's name, a tab's title, or the tab title of a pane that is alone in its tab;
3. a 1-based position: sessions of the caller's workspace, tabs of its session, panes of its tab;
4. a unique ID prefix or suffix of at least 4 characters.

No match, or more than one, exits 3 and names the candidates. `has-session` keeps tmux's contract (exit 1 when missing).

**Short flags.** `-s` is `--session`, `-w` is `--tab`, `-b` is `--pane`, and `-S` is `--host`. A command with its own tmux meaning for the letter keeps it: `set-option -s/-w`, `show-options`, `set-environment`, `capture-pane -S` (start line), and `wait-for -S` (signal).

**The caller's pane.** Inside a pane, the daemon sets `HARNESS_SURFACE`, `HARNESS_PANE`, `HARNESS_TAB`, and `HARNESS_SESSION`. Pane commands (`send`, `send-keys`, `capture-pane`, `pipe-pane`, `respawn-pane`, `clear-history`, `copy-mode`, `process`, `notify`, `inspect`, `kill-pane`, `zoom-pane`, `break-pane`, `select-pane`, `resize-pane`) act on that pane when given no target, and positions count from its session and tab. Outside a pane, or with `--host`, they use what the window is showing. `--surface` and `--pane` are interchangeable: either names the same terminal.

**JSON.** Commands that create something print the new id, or `{"tab": "…"}` (or `session`, `pane`, `workspace`, `hook`) with `--json`. The list and inspect commands print JSON with `--json`, indented with `--pretty`. `remote list --json` prints the saved hosts and whether each tunnel is up.

**Exit statuses.** 0 ok, 1 failed, 2 usage, 3 target not found or ambiguous, 4 daemon unreachable (local, or the SSH tunnel for `--host`), 130 interrupted. `run --wait` and `api call pane.wait` exit with the waited-for program's own status.

## Pane operations

| Command | What it does |
|---|---|
| `split-window` (alias `split-window -h`) | Split active pane side-by-side (vertical divider). |
| `split-window -v` | Split active pane top/bottom (horizontal divider). |
| `kill-pane` | Close the active pane. Collapses the parent branch. |
| `zoom-pane` (alias `resize-pane -Z`) | Toggle full-tab zoom on the active pane. |
| `select-pane -L` / `-R` / `-U` / `-D` | Move focus to the neighboring pane in that direction. |
| `select-pane` (no flag) | Cycle forward by flat pane order. |
| `select-pane -l` | Jump to the last (most-recently-active) pane in the tab. |
| `select-pane -m` / `-M` | Mark / unmark the active pane (the implicit `join-pane` source). |
| `swap-pane [-s <source>] [-t <dest>]` | Swap two panes: `-s` names the pane to act FROM (default: the active pane), `-t` the destination (relative `:.+`/`:.-`/`!` or any absolute target; default: the next pane in flat order). |
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
| `last-window` | Jump to the session's most-recently-active tab. |
| `link-window -t <session>` | Add a linked copy of the active tab to `<session>` (shared live surfaces; the daemon ref-counts them). |
| `unlink-window` | Remove the active tab if it is a link (its surfaces survive in the other linked copy). |

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

`select-pane` / `swap-pane` accept exactly `-t :.+` (next), `-t :.-` (previous), and
`-t !` (last). Any other `-t` value — or a dangling `-t` — is a parse error naming the
accepted forms; it is never silently routed to the next pane.

## Sessions / workspaces

| Command | Effect |
|---|---|
| `new-session [-s name]` | Add a session row in the active workspace; in bindable form, accepts a universal `-t <session>` target for grouping with another session's windows. |
| `kill-session` | Close the active session. |
| `rename-session [name]` | Interactive or inline. |
| `next-session` / `previous-session` | Cycle sessions in the active workspace. |
| `select-session <0..N>` | Focus session by index in the active workspace. |
| `select-workspace <0..N>` | Focus workspace by index. |
| `next-workspace` / `previous-workspace` | Cycle workspaces. |
| `next-pane` / `previous-pane` / `last-pane` | Cycle the active pane (sugar for `select-pane -t :.+/:.-/-l`); bindable. |
| `choose-tree` | Open an interactive session/tab/pane picker showing the full tree. |
| `choose-session` | Open an interactive session picker. |
| `choose-window` | Open an interactive tab picker for the active session. |
| `choose-buffer` | Open an interactive paste buffer picker. |
| `choose-client` | Open an interactive client picker. |

### Inspection (CLI / control mode)

These query the current Harness state and do not change your layout.

| Command | Effect |
|---|---|
| `list-sessions` | One line per session: `<id>: <name> (<n> windows)`. |
| `list-windows [--session <name\|uuid>]` | Tabs across all sessions, or one session's. |
| `list-panes [--tab <uuid>]` | Panes of the targeted (or active) tab, index-prefixed, active flagged. |
| `has-session --session <name\|uuid>` | Scripting verb: exit `0` if it exists, `1` if not; prints nothing. |
| `daemon-stats [--json]` | Daemon pid, version, uptime, surfaces, scrollback, clients, how many idle panes are parked and how small their history is held, and how long startup took (layout load, respawning surfaces, socket ready). A pane parks after a minute without output: its history is kept LZ4-compressed until it prints again (on macOS; a Linux daemon keeps it as it is). |
| `list-commands` | Print the bindable command vocabulary. |
| `list-agents [--waiting]` | List all running agents with state, age, and surface ID. `--waiting` filters to agents that need a response. |
| `events` | Print session, pane, and agent events as JSON lines. |
| `process [--surface <id>]` | Print a surface's foreground process as JSON. Defaults to the caller's pane, else the active one. |
| `size-mode <smallest\|owner>` | Set multi-client PTY sizing; it survives a daemon restart. `smallest` is the default (every attached client votes). `owner` follows the client that took the surface: the others reflow their own view (or show the owner's grid when a full-screen program is running), and their pane header reads **Viewing at C×R · Take**. Take Size is also in the pane's menu and the command palette. Each change emits `pane.owner_changed`. |
| `take-surface --surface <id> [--client <uuid>]` | Make one attached client the size owner of a surface. |
| `save-layout --name <name>` | Save the active tab's split tree, each pane's directory, and the command line running in it (an idle pane saves as a plain shell). |
| `restore-layout --name <name> [--dry-run]` | Recreate a saved layout as a new session in the active workspace. `--dry-run` prints the steps instead. |
| `find-files` | Find paths locally or on a configured remote host. Does not need the daemon. |
| `copy-file` | Copy a file locally or over the SSH remote connection. Does not need the daemon. |

### Local diagnostics

These CLI commands are pure local output and do not require the daemon.

| Command | Effect |
|---|---|
| `harness-cli color-check` | Print a deterministic SGR diagnostic page: ANSI 0-15, the 256-color cube, grayscale ramp, truecolor primaries, gradients, text attributes, and foreground/background combinations. |
| `harness-cli theme-preview [--theme <name>] [--all]` | Print realistic prompt, git/build, diagnostic, agent-state, selection/search, and ANSI-swatch examples for one theme or every built-in theme. |
| `show-cheatsheet` | Toggle the live prefix-binding cheatsheet overlay (same as `prefix ?`). |

## Modes

| Command | Effect |
|---|---|
| `jump-previous-prompt` | Scroll the active pane up to the previous OSC 133 shell prompt mark. Requires shell integration. In the GUI also View ▸ Previous Prompt (⌘↑). |
| `jump-next-prompt` | Scroll the active pane down to the next OSC 133 shell prompt mark. Requires shell integration. In the GUI also View ▸ Next Prompt (⌘↓). |
| `select-last-output` | Select the last finished command's output — the lines between the last two OSC 133 prompt marks — scrolling to reveal it. In the GUI also View ▸ Select Last Command Output (⇧⌘A). |
| `copy-mode` | Open the vim-style copy-mode viewer for the active pane. |
| `copy-mode -X <action> [arg]` | Run an in-mode copy command: `cursor-left/right/up/down`, `next-word`/`previous-word`, `start-of-line`/`end-of-line`, `history-top`/`history-bottom`, `page-up`/`page-down`/`halfpage-up`/`halfpage-down`, `begin-selection`/`select-line`/`rectangle-toggle`/`clear-selection`, `search-forward`/`search-backward`/`search-again`/`search-reverse`, `copy-selection`/`copy-selection-and-cancel`/`copy-pipe "<cmd>"`, `paste`, `cancel`. Also `send-keys -X <action>`. Rebind with `bind-key -T copy-mode <key> <command>`. |
| `detach-client` | Detach the calling client (CLI attach) or fire SIGTERM-like handling. |
| `reattach-surface` | Re-grab a pane that was released to headless (the GUI's View ▸ Reattach Pane). |
| `lock-client` (alias `lock-session`, `lock-server`) | Blank the client behind a lock overlay until a key unlocks it. |
| `clock-mode` | Full-pane clock overlay (tmux's clock); any key dismisses. |

### Attaching from a plain terminal

`harness-cli attach --surface <id> [--read-only] [--history] [--detach-keys <bytes>]` connects a single pane (raw
passthrough). It paints the pane's current screen, colors, cursor, and input modes included,
then goes live, the way tmux attaches; `--history` replays the whole scrollback into your
terminal first instead. `--read-only` watches: your keys (other than the detach keys) aren't
sent and your terminal's size doesn't resize the pane. Detaching turns off any mouse, paste,
or alternate-screen mode the pane's program left on.
`harness-cli attach-window [--tab <id>] [--detach-keys <bytes>]` renders a whole
tab's **split layout** — every pane with borders, a status line, and the active
pane's cursor — into any plain terminal (incl. over ssh). Without `--tab` it
attaches the active tab. Inside: the prefix (`Ctrl-A`) then `o` / `;` cycles the
active pane, `d` detaches; `SIGWINCH` re-lays-out live; splitting/killing panes
in the GUI re-composites automatically.

## Remote daemons (over SSH)

Drive a daemon running on another machine — including a headless or Linux box — by
registering it and then passing a global `--host <name>` flag to any client command.
The transport forwards the remote daemon's Unix control socket over `ssh -N -L`, so it
reuses your existing SSH trust (keys/agent/config); no new credentials or crypto.

| Command | Effect |
|---|---|
| `remote add --name <name> --ssh <user@host> --socket <remote-path> [--ssh-arg <arg> …]` | Register a remote daemon. `--socket` is the daemon's control-socket path on the remote (run `harness-cli socket-path` there to print it). Repeat `--ssh-arg` to pass extra ssh options. |
| `socket-path` | Print this machine's daemon control-socket path (what `remote add --socket` wants). Needs no running daemon. |
| `remote list [--json]` | List registered remotes (`name  ssh-target  socket`), with `[connected]` when any Harness process holds its tunnel. |
| `remote remove --name <name>` | Forget a remote and tear down its tunnel. |
| `<command> … --host <name>` | Run any client command against the named remote instead of the local daemon (`ping`, `new-session`, `send-keys`, `capture-pane`, `doctor`, …). Exception: `attach-window` always renders the **local** daemon — run it on the machine whose daemon you want to see (see the multiplexer guide). |

In the app, **Remote ▸ *host* ▸ Connect** opens that machine in a window of its own; your other windows, local or on other hosts, stay where they are and keep streaming. The window in front decides which daemon commands, shortcuts, and the palette act on. The sidebar lists every connected machine's sessions; picking one on another machine brings its window forward (or opens one). **Disconnect** closes that host's windows and its tunnel; its sessions keep running there. Windows on remote hosts reopen at launch once their host answers.

In the app, pasting or dropping an image or file into a pane on a remote host uploads it to that host first (owner-only, swept after a day, up to 11 MB) and pastes the remote path. **Remote ▸ Suggest Tailscale Peers…** probes your online peers over SSH and lists the ones running Harness first, with their socket already filled in. A pane's menu has **Copy Watch Command**: a `harness-cli [--host …] attach --read-only --surface …` line for watching it from any terminal.

Allowed `--ssh-arg` options are validated: `-p` (port), `-i` (identity file), `-J` (jump
host), `-l` (login user), and the flag-only `-4 -6 -A -a -T -q -v` (also `-vv`, `-vvv`). Example:
`remote add --name devbox --ssh me@devbox --socket "$(ssh -p 2222 me@devbox harness-cli socket-path)" --ssh-arg -p --ssh-arg 2222`.

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
| `bind-key [-r] [-T <table>] <spec> <command...>` | Bind a key in a named table. `-r` makes it repeatable, so the prefix stays armed briefly while the key repeats. |
| `unbind-key [-T <table>] <spec>` | Remove a binding. |
| `list-keys [-T <table>]` | Print bindings; one table per `[table]` header. |

Table names: `root`, `prefix`, `copy-mode` (tmux's `copy-mode-vi` is accepted everywhere
a table is named — parser, CLI, `switch-client -T`), `copy-mode-emacs`, `command`.

## Options

| Command | Effect |
|---|---|
| `set-option [-g\|-w\|-s\|-t\|-p] [-T <target>] <key> <value>` | Set a typed option in the chosen scope. Coerces `on`/`off`/`true`/`false`/integers. Bindable as `set`; a scoped set without `-T` resolves against the caller's focus (CLI: the calling pane via `$HARNESS_SURFACE`). |
| `setw <key> <value>` (alias `set-window-option`) | Window (tab) option for the focused/calling tab — same scope in the CLI, the `:` prompt, and a sourced `.tmux.conf`. |
| `show-options [-g\|-w\|-s\|-t\|-p]` (alias `show`) | Dump options for the chosen scope (or all). |
| `show-window-options` (alias `showw`) | Dump options at the tab (window) scope. |
| `set-environment [-g] [-u] <key> [value]` (alias `setenv`) | Session (default) or global environment variable; `-u` unsets; a bare key errors. |
| `show-environment [-g]` (alias `showenv`) | Dump the environment table. |

Built-in defaults include:

- `status` (bool, default `on`) — show the bottom status line.
- `status-left`, `status-right`, `status-center` — `FormatString` source for the three status segments.
- `mouse` (bool, default `on`) — enable mouse reporting / pane-click selection.
- `mode-keys` (string, default `vi`) — copy-mode key style.
- `set-clipboard` (bool, default `on`) — mirror yank → NSPasteboard.
- `allow-clipboard-read` (bool, default `off`) — let programs read the clipboard with OSC 52 (`ESC ] 52 ; c ; ?`). Off because anything in the pane, including a remote shell, could read it.
- `history-limit` (int, default `10000`) — scrollback line cap.
- `base-index` / `pane-base-index` (int, default `0`) — first window / pane index for `-t` targets and index display.
- `renumber-windows` (bool, default `off`) — renumber tab indices contiguously when a tab closes.
- `update-banner` (bool, default `on`) — show first-run/what's-new terminal banner on startup.
- `allow-rename` (bool, default `on`) — allow programs to set the pane title via OSC.
- `automatic-rename` (bool, default `on`) — automatically name tabs from foreground process; disabled after manual rename.
- `monitor-activity` (bool, default `off`) — flag non-current windows on output (`#`).
- `monitor-silence` (int, default `0`) — flag non-current windows after N seconds of silence (`~`); 0 = off.
- `monitor-bell` (bool, default `on`) — flag non-current windows on terminal bell (`!`).
- `window-style` / `window-active-style` (string) — base styles for inactive / active panes (e.g., `fg=default,bg=default`).
- `pane-style` / `pane-active-style` (string) — pane border styles.
- `pane-border-status` (string, default `off`) — show pane border labels (`off` / `top` / `bottom`).
- `pane-border-format` (string) — `FormatString` for the pane border label.
- `remain-on-exit` (bool, default `on`) — keep dead panes visible so `respawn-pane` can revive them.
- `repeat-time` (int, default `500`) — how long (ms) the prefix stays armed after a repeatable binding (`bind -r`).
- `display-time` (int, default `750`) — how long (ms) `display-message` and status toasts stay visible.
- `set-titles` (bool, default `off`) — apply `set-titles-string` to the outer terminal (OSC 2) on attach clients.
- `set-titles-string` (string) — `FormatString` for the outer terminal title.
- `detach-on-destroy` (bool, default `on`) — detach `attach-window` clients when their session is destroyed; off re-targets the most recent surviving session.

## Hooks

| Command | Effect |
|---|---|
| `bind-hook <event> <command...> [--if <format>]` | Bind a command to an event. The optional `--if` is a `FormatString` whose result must be non-empty/non-zero to fire. |
| `unbind-hook --id <uuid>` | Remove a hook by its ID. |
| `list-hooks [--event <event>]` | List bound hooks. |
| `set-hook [--if <format>] <event> "<command>"` | Bindable form (the `:` prompt, `bind-key`, `source-file`) of `bind-hook`. |
| `show-hooks [<event>]` / `unbind-hook <uuid>` | Bindable list/remove forms. |

Events: `after-new-tab`, `after-new-session`, `after-kill-tab`, `after-split-pane`, `after-kill-pane`, `after-resize-pane`, `session-created`, `session-renamed`, `session-closed`, `window-renamed`, `window-linked`, `window-unlinked`, `window-layout-changed`, `alert-activity`, `alert-silence`, `alert-bell`, `pane-exited`, `client-attached`, `client-detached`, `agent-state-changed`, `notification-posted`, `command-error`, `pane-focus-in`, `pane-focus-out`, `window-pane-changed`. Hook commands format with the EVENT's subject (e.g. `#{session_name}` in `session-closed` names the closed session).

## JSON API

`harness-cli api` is the self-describing API. `api list` and `api describe <method>` print JSON Schema and do not need a running daemon. `api call <method> --args '{...}'` plans the call before it mutates anything.

Exit codes for `api`, distinct from the older tmux-style verbs: `0` ok, `1` the call failed or timed out, `2` unknown method or bad arguments, `3` the target is missing or ambiguous (the message lists the matches, and nothing is changed), `4` the daemon is not reachable, `130` interrupted. `pane.wait` is the exception on success: the process exits with the child's status.

From inside a pane the daemon sets `HARNESS_SESSION`, `HARNESS_TAB`, `HARNESS_PANE`, `HARNESS_SURFACE`, and `HARNESS_SERVER` (the socket path). A script can split, wait, and zoom without hard-coding an id. Outside a pane, an omitted target means what the window is showing: the active session, tab, or pane. `HARNESS_SERVER` is the socket `api` and the rest of the CLI use when `--host` is absent.

| Method | What it does |
|---|---|
| `server.version` | Daemon version and build. |
| `session.list` / `session.view` | Sessions, or one session. |
| `session.create` / `session.label` | Create a session (optionally from a layout tree), or rename one. |
| `tab.create` / `tab.close` / `tab.label` / `tab.move` / `tab.focus` | Open a tab (`cwd`, `command`), close, rename, move to a 0-based `index` or into another `session` (`"new"` gives it a session of its own), select. |
| `pane.split` | Split. `direction` is `horizontal` or `vertical` (default `vertical`). `command` is an executable path. `false` runs `/usr/bin/false`. |
| `pane.view` | Everything about one pane in one call: ids, cwd, program, agent, size, program status, process tree. |
| `pane.zoom` / `pane.focus` / `pane.label` / `pane.close` | Zoom, focus, rename the pane's tab, close. |
| `pane.swap` / `pane.move` / `pane.detach` | Swap with `with`; move next to `to` on a `side` (`left`, `right`, `above`, `below`; a pane alone in its tab takes the tab with it); break out into its own tab. |
| `pane.resize` / `pane.focus_direction` | Move a divider (`direction`, `amount` cells); focus the neighbour in `direction`. |
| `pane.write` / `pane.send_key` | Write text, or send key tokens. Cursor keys follow DECCKM. `hex: true` sends raw bytes. |
| `pane.capture` | `text`, `html`, or `vt`. `trim` drops trailing whitespace. `unwrap` joins soft-wrapped rows. `screen` captures only the visible screen, without scrollback (cheaper: no history is parsed). |
| `pane.process` / `pane.pwd` / `pane.title` / `pane.size` | Process tree, working directory as a `file://` URL plus the owner, tab title, cell size. `pane.view` returns all of these at once. |
| `pane.list_dir` | Names in a directory on the daemon that owns the pane. The root is that pane's cwd unless `path` is set. `find-files` stays a separate SSH `find`. |
| `pane.program_status` | OSC 7501 records. See [PROGRAM-STATUS.md](PROGRAM-STATUS.md). |
| `pane.wait` | Wait until the child exits (`until: child`) or OSC 133 D (`until: command`). Default timeout is 30 seconds. Timeout exits 1. |
| `pane.theme` | Set one pane's theme through a profile rule. |
| `pane.reset` | RIS (`ESC c`). |
| `client.list` / `client.disconnect` | Connected clients, or disconnect one by `id`. |

Targets resolve exactly like the CLI's `-t`: a full id, a unique id prefix, a 1-based position, or a case-insensitive label (an unnamed session is `Session N`, as the sidebar shows it). A pane target takes either its pane id or its surface id. `session:`, `tab:`, `pane:`, and `client:` must match that kind. More than one match exits 3 and lists them; nothing is changed.

Every bindable command is also a method: `api call split-window --args '{"args":"-h"}'` runs `split-window -h` against the calling pane (`HARNESS_SURFACE`) or the active one. A command that only means something inside the app (overlays, copy-mode keys) exits 1 and says so.

`events` with no `--follow` is still a one-shot JSON snapshot. `events --follow` is a live stream of `type` plus `payload`. A terminal gets one human line per event; `--json` keeps NDJSON. The default scope is the current session when `HARNESS_SESSION` is set, otherwise every session. `--session` pins one session. `--all` includes server events such as `client.connected`. The stream also emits `keymap.changed`, `hosts.changed`, `client.connection` when an SSH tunnel drops, and `server.tailscale_status` only when `tailscale status` is installed. Those are server events, so they need `--all`.

Follow types are `tab.created`, `tab.closed`, `tab.renamed`, `tab.activated` (a tab was selected), `pane.created` (splits and a new tab's first pane), `pane.focused`, `pane.closed`, `pane.owner_changed`, `session.renamed`, `session.created`, `session.closed`, `session.view`, `client.connected`, `client.disconnected`, `terminal.title`, `terminal.pwd` (a `file://` URL plus the owner pid and name), `terminal.bell` (every bell; `monitor-bell` only gates the tab flag), `terminal.child_exited`, `terminal.process`, `terminal.notification`, `terminal.progress`, `terminal.clipboard` (a `length`, not the copied text; an OSC 52 read is not an event), `terminal.program_status`, `terminal.program_status_removed`, and `agent.state`. An unknown name is delivered, not rejected. Extra payload fields are ignored. Every name is `domain.verb`; the older `session_created`, `session_destroyed`, `program_status_changed`, `program_status_removed`, and `tailscale_status_changed` still work in Lua `harness.on` / `harness.wait` for now.

## Lua config

`~/.config/harness/init.lua` is Lua 5.1, including `io`, `os`, and `require`. `HARNESS_CONFIG` overrides the path. The daemon does not run Lua. There is no file watcher.

| Command | Effect |
|---|---|
| `config check [--file path]` | Print the path, whether the file exists, and the binding, removal, mode, and action counts. A syntax error exits 1. |
| `config reload [--file path]` | Load the file and publish the keymap. A syntax error keeps the previous keymap. `--remote`, or `HARNESS_TUNNEL=1`, exits 1 and does not read the file. |
| `do <name> [--file path] [--args json] [--for a,b] [--all] [--fail-fast]` (or `--action <name>`) | Run one action. An unknown argument exits 2 and the action does not run. `--all` needs a reachable daemon (exit 4 otherwise). |
| `do <file.lua>` / `do -e '<lua>'` / `do -` `[--args json]` | Run a script (from a file, inline, or stdin) after loading the config, so its actions are callable. `--args` becomes `harness.args`. A script that registers `harness.on` handlers keeps running until `harness.stop([code])` or Ctrl-C (exit 130). |
| `do --binding <key>` | Run the Lua function the config binds to `<key>`. The app does this when you press it. |

`harness.bind`, `harness.unbind`, `harness.mode`, `harness.action`, `harness.host`, `harness.queue`, and `harness.invoke` work in the config file and in scripts. `harness.on`, `harness.wait`, `harness.sleep`, and `harness.stop` are for scripts and actions; a `harness.on` in the config file is a warning and is ignored. A bind whose second value is `{ mode = "name" }` enters that mode.

**The API from Lua.** Every [JSON API](#json-api) method is a function: `harness.pane.split{ direction = "horizontal" }` is `harness.call("pane.split", { direction = "horizontal" })`. Both run the same executor as `api call`, against the script's daemon (`--host` included). They return the result as a table, or `nil, message, exit code` (3 for a missing or ambiguous target, 4 when the daemon is unreachable). Targets work the same way: ids, labels, positions, prefixes, and the caller's pane by default. The functions are generated from the method list, so `api list` is also the Lua reference.

- `harness.layout.pane{ command = …, cwd = … }`, `.horizontal([ratio,] a, b, …)` (side by side), and `.vertical(…)` build the `layout` that `session.create` and `pane.split` take.
- `harness.args` is the table from `do … --args '{json}'`.
- `harness.log([level,] message)` writes to stderr and to `show-messages`.

**Function bindings.** `harness.bind("cmd+k", function() … end)` works from the app, not only from `do`. The app never loads Lua: the key is consumed and `harness-cli do --binding cmd+k` runs the function, so a press costs one process launch (tens of milliseconds) and the function can't decline the key. For a key that must be instant, bind a command or an action instead.

- `harness.on(type, fn)` calls `fn(event)` for each event of that type (`"*"` for all), with the payload fields on the table (`event.tab`, `event.pane`, …).
- `harness.wait(filter, { timeout = s })` blocks for the next matching event. The filter is a type name, a function, or a table whose every field must match (`{ type = "terminal.child_exited", pane = id }`). On `terminal.child_exited` it returns the exit code. A timeout returns `nil, "timeout"`.
- `harness.queue("split-window -h")` queues a command line, in the same language as the `:` prompt and key bindings. From a key or the palette the app runs it; from a shell it goes to the daemon.

```bash
harness-cli do -e 'harness.on("tab.created", function(e) print("new tab " .. e.tab) harness.stop() end)'
harness-cli do -e 'for _, s in ipairs(harness.session.list().sessions) do print(s.label) end'
```

A GUI action from a tunneled client runs only when Remote Control is on. A local client can always run one. See [MULTIPLEXER_GUIDE.md](MULTIPLEXER_GUIDE.md) for a ten-line `init.lua`.

## Scripting

| Command | Effect |
|---|---|
| `send-keys <tokens…>` | Inject keystrokes (`C-c`, `Up`, `Enter`, etc.) into the active pane. |
| `capture-pane [--scrollback] [-S <start>] [-E <end>] [-e] [-J] [-p]` | Print a pane's contents. `-S`/`-E` pick a line range (negative counts back from the bottom), `-e` keeps escapes, `-J` joins soft-wrapped lines. |
| `capture-pane --format text\|vt\|html [--trim] [--unwrap] [--screen]` | The same capture as `api call pane.capture`. `--screen` captures only the visible screen, without scrollback (cheaper: no history is parsed). |
| `send-prefix` | Send the prefix key to the active pane. |
| `display-message <format>` | Render a `FormatString` and surface as a non-blocking status toast. |
| `command-prompt [-p <prompt1,prompt2,…>] "<template>"` | Open the command prompt pre-filled with a template; `%%` / `%1` are replaced by user-typed values. Multiple `-p` prompts are asked in sequence. |
| `display-popup [-E <command>]` | Open a floating terminal pane. With `-E <command>`, run `<command>` in the popup and close it on exit. |
| `display-menu [-T <title>] <name> <key> <command> …` | Show a native popup menu built from `name`/`key`/`command` triples. Key may be empty (`""`). |
| `wait-for [-S \| -L \| -U] <channel>` | Named-channel synchronisation. No flag: block until the channel is signalled. `-S`: signal the channel (unblocking any waiters). `-L`: lock (exclusive, blocks if held). `-U`: unlock. `wait <channel>` does the same. |
| `find-window [-N] [-T] [-C] [-t <session>] <pattern>` | Focus the first window matching by name/title (default) or pane content (`-C`). `-t` scopes the search to one session. No match fails loudly in every front-end. |
| `respawn-window [-k] [-t <target>]` (alias `respawnw`) | Respawn every pane in the window; `-k` clears scrollback. |
| `refresh-client` (alias `refreshc`) | Re-pull options and snapshot for the calling client. |
| `show-messages` | Print the recent `display-message` log (client- and hook-fired). |
| `run-shell [-b] <command>` | Spawn a subprocess. `-b` captures stdout into a paste buffer. |
| `pipe-pane ["<cmd>"]` | Pipe the active pane's live output to `<cmd>`; with no command, toggle an existing pipe off. |
| `confirm-before [-p "<prompt>"] "<command>"` | Ask for confirmation, then run `<command>`. |
| `if-shell <condition> <then> [<else>]` | Run `<condition>` in the shell; on exit 0 run `<then>`, else `<else>`. |
| `source-config` (alias `source`, `reload-config`) | Re-import the imported terminal config and refresh chrome. |
| `reload-keybindings` | Re-read `keybindings.json` so an external edit takes effect. |

## Composition

| Form | Effect |
|---|---|
| `a ; b ; c` | Sequence. Commits each in order; later steps see the post-state of earlier ones. |
| `"literal text"` / `'literal text'` | Quoted arguments preserve whitespace and `;`. An unterminated quote is a parse error (it is **not** silently swallowed to end of line). |

See `docs/KEYBINDINGS.md` for the default key tables and `Packages/HarnessCore/Sources/HarnessCore/Format/FormatString.swift` for the `FormatString` token list and operators.
