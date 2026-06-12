# Harness as a terminal multiplexer

Harness is a native terminal multiplexer: a prefix key, splits, tabs, sessions, copy mode,
detach/attach, and a `:` command line — all driven by one shared verb vocabulary
(`split-window`, `new-window`, `kill-pane`, `copy-mode`…). It is **self-contained**: the daemon,
the session model, the compositor, and the VT engine are all first-party Swift, with no external
runtime under the hood.

This guide is the narrative "how it works + shortcuts" tour. For exhaustive references see:

- [HARNESS_TMUX_CAPABILITIES.pdf](HARNESS_TMUX_CAPABILITIES.pdf) — printable setup and shortcuts guide.
- [KEYBINDINGS.md](KEYBINDINGS.md) — every default binding + the key-spec syntax.
- [COMMANDS.md](COMMANDS.md) — the full command grammar.
- [MIGRATION.md](MIGRATION.md) — moving an existing terminal/multiplexer setup over.
- [MODES.md](MODES.md) — Plain / Persistent / Full / Agent experience modes.

---

## 1. The mental model

The hierarchy, top to bottom:

| Term | What it is |
|---|---|
| **Workspace** | A named group of sessions (one active workspace at a time). |
| **Session** | A sidebar entry with its own tab bar. Survives quit if pinned/kept. |
| **Tab** | One tab in a session: title, cwd, git branch, agent, and a split tree. |
| **Pane** | A single terminal (a leaf in the tab's split tree). |
| **Surface** | The daemon-owned PTY behind a pane (`$HARNESS_SURFACE`). |

The terms "tab" and "window" are used interchangeably in the verbs (`new-window` makes a tab; the
`next-window`/`previous-window` verbs move between tabs).

**Who owns what:** a background **daemon** (`HarnessDaemon`, kept alive by launchd) owns all
session truth and every PTY. The app and `harness-cli` are just clients — so your shells keep
running when the app quits, across crashes, and you can reattach from another window or over ssh.

---

## 2. The prefix key

Most multiplexer commands start with a **prefix** keystroke, then a second key.

- **Default prefix: `Ctrl-A`** (the screen/`C-a` convention).
- Change it in **Settings ▸ Keys** (or `settings.prefixKey`); set it empty to disable the prefix
  entirely (then drive everything from the `:` prompt, the `Cmd-K` palette, and macOS shortcuts).
- Press **`prefix ?`** any time for a live cheatsheet generated from your current bindings.

> The prefix layer only appears in modes that show Harness controls (Full/Agent modes, or when
> Harness controls are set to On). In Plain mode you lean on the macOS `Cmd` shortcuts instead.

Everything below that says "`prefix X`" means: tap the prefix, release, then tap `X`.

---

## 3. Panes and splits

| Keys | Action |
|---|---|
| `prefix %` | Split **side-by-side** (new pane on the right) |
| `prefix "` | Split **top/bottom** (new pane below) |
| `prefix ←/→/↑/↓` | Move focus to the pane in that direction |
| `prefix o` / `prefix ;` | Cycle to the next / previous pane |
| `prefix l` | Jump to the last (most-recently-active) pane |
| `prefix z` | **Zoom** the active pane to fill the tab (toggle) |
| `prefix x` | Kill the active pane |
| `prefix Shift+←/→/↑/↓` | Resize the pane (hold under the prefix to keep nudging) |
| `prefix q` | Show numbered pane overlay — press a digit to jump |
| `prefix Space` | Cycle through the layout presets |

**Layouts:** `even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled` —
cycle with `prefix Space`, or pick one with `:select-layout tiled`. Also `rotate-window`,
`break-pane` (pop a pane into its own tab), and `join-pane`.

**Move a pane between tabs:** `prefix m` marks the active pane, then `prefix j` joins that marked
pane into the current one (Harness's `move-pane`/`join-pane`).

**Type to several panes at once:** `prefix S` toggles `synchronize-panes` for the tab.

> macOS shortcuts work too: `Cmd-D` splits side-by-side, `Cmd-Shift-D` splits top/bottom.
> In the GUI, directional pane nav is the **arrow keys**; the `attach-window` compositor (§10)
> uses **`hjkl`** instead.

---

## 4. Tabs (windows)

| Keys | Action |
|---|---|
| `prefix c` | New tab |
| `prefix ,` | Rename the current tab |
| `Cmd-1` … `Cmd-9` | Jump straight to tab 1–9 (shown as `⌘N` on the pills) |
| `Cmd-Shift-[` / `Cmd-Shift-]` | Previous / next tab |
| `Cmd-T` / `Cmd-W` | New tab / close tab |

Tab titles auto-follow the pane's working directory (or the running agent), so the strip stays
readable without manual renaming.

---

## 5. Sessions and workspaces

Sessions are the sidebar rows; each has its own tab strip. **Sessions are always visible** in the
sidebar rather than something you "attach" to one at a time.

- New session / workspace from the sidebar `+`, the palette, or `harness-cli new-session` /
  `new-workspace`.
- `prefix n` / `prefix p` move to the next / previous tab in the active session.
- `prefix (` / `prefix )` move to the previous / next session in the active workspace.
- `prefix 0` ... `prefix 9` jump to workspace 0 through 9.
- **Persistence** (see [MODES.md](MODES.md)): a session survives a *clean* quit if the global
  "keep sessions on quit" is on **or** the session is pinned. Pin/unpin from the sidebar context
  menu or `harness-cli promote-session` / `demote-session`. A crash leaves everything running.
- `Cmd-Shift-N` makes a new workspace.

**Grouped sessions:** `harness-cli new-session --group-with <session>` creates an independent session
sharing the target session's window list (linked windows with shared surfaces). Every member sees the
same tab bar; opening or closing a tab propagates to all members. Members may have divergent split
layouts within each shared tab. See [TMUX_PARITY.md](TMUX_PARITY.md#at-parity) for full details.

---

## 6. Copy mode (scrollback, selection, search)

Enter with **`prefix [`**. Copy mode is modal and vim-flavored (`mode-keys vi`):

| Keys | Action |
|---|---|
| `h` `j` `k` `l` | Move the cursor |
| `0` / `$` | Start / end of line |
| `w` / `b` | Next / previous word |
| `g` / `G` | Top / bottom of history |
| `PageUp`/`PageDown`, `C-u`/`C-d` | Page / half-page scroll |
| `[` / `]` | **Jump to previous / next shell prompt** (needs OSC 133 — see §12) |
| `v` / `V` / `C-v` | Start char / line / rectangle (block) selection |
| `/` … `Enter`, `?` | Search forward / backward; `n` / `N` cycle matches |
| `y` or `Enter` | Yank selection to the clipboard **and** a paste buffer, then exit |
| `p` | Paste the most recent buffer into the pane |
| `q` / `Escape` | Leave copy mode |

Yanks land in named **paste buffers** (`harness-cli set-buffer` / `list-buffers` /
`paste-buffer`) as well as the system clipboard. Prefer emacs motions? Set `mode-keys emacs`
(then `C-b/C-f/C-n/C-p`, `M-[`/`M-]` for prompt jumps). Copy mode is fully rebindable via
`bind-key -T copy-mode <key> <command>`.

---

## 7. Detach and reattach

Your shells live in the daemon, so a pane can be "released" and re-grabbed without killing
anything.

- **`prefix d`** detaches the calling client.
- In the app: **View ▸ Detach Pane** releases the active pane — it dims with a
  *"Pane released — click to re-grab"* overlay and stops updating while the PTY keeps running.
  **View ▸ Reattach Pane** (or a click on the overlay) re-grabs it and replays scrollback.
- Two windows (or an ssh `attach-window`) can watch the same session; detaching one leaves the
  others live. The PTY only goes away when its tab/pane is actually closed.

---

## 8. The command line and `:` prompt

Anything you can bind, you can type.

- **`prefix :`** or **`Cmd-;`** opens the command prompt; it accepts any command string
  (`split-window -v`, `select-layout tiled`, `bind-key -T prefix S new-session`), with `↑`/`↓`
  history.
- **`Cmd-K`** opens the command palette (fuzzy actions + themes).
- From a shell, **`harness-cli <verb>`** runs the same vocabulary (and a lot more — buffers,
  hooks, options, layout ops). Run `harness-cli` with no args for the full list.
- Rebind anything: `harness-cli bind-key C-x x kill-pane`, multi-step with `;`
  (`bind-key C-x s "split-window -h ; copy-mode"`). Bindings persist in
  `~/Library/Application Support/Harness/keybindings.json` (merged under the defaults, so deleting
  one restores the default). Full details in [KEYBINDINGS.md](KEYBINDINGS.md).
- **Hooks** fire commands on events (`after-new-tab`, `pane-exited`, `agent-state-changed`, …):
  `harness-cli bind-hook after-split-pane 'display-message "split!"'`. Use `set-hook --if` with
  a format condition to make a hook conditional: `set-hook pane-exited --if "#{?pane_dead,1,0}"
  'display-message pane exited'`. Lifecycle events include `session-created/renamed/closed`,
  `window-linked/unlinked/layout-changed`, and alert events (`alert-activity`, `alert-silence`,
  `alert-bell`). See [TMUX_PARITY.md](TMUX_PARITY.md#at-parity) for the full list.
- **Paste buffers** store text in named slots: `harness-cli set-buffer -b myname 'text'`,
  `paste-buffer -b myname` (into the active pane), `list-buffers`, `show-buffer -b myname`,
  `delete-buffer -b myname`. All bindable so copy-mode `y` yanks to both the clipboard and a
  paste buffer.

---

## 9. Options and configuration

Harness uses a scoped option store with a fallback chain: `pane → tab → session → workspace → global`.
This means you can set a global default and override it per-session, tab, or pane.

- **`set-option -g key value`** (or `set`) sets a global option.
- **`-s`** / **`-w`** / **`-t`** / **`-p`** select the session / workspace / tab / pane SCOPE;
  without `-T <target>` the write resolves against your focus (the CLI uses the calling pane
  via `$HARNESS_SURFACE`), and `-T <target>` pins an explicit one.

Common options include `status` (show/hide status bar), `mode-keys` (vi/emacs in copy mode),
`allow-rename` (let programs change tab title), `history-limit`, `base-index` (start window
numbers at 0 or 1), and `set-titles` (OSC 2 titles for attach clients). The **`setw`** alias is
shorthand for `set-window-option` and defaults the scope to `tab` — so `setw synchronize-panes on`
mirrors input across the focused tab's panes, in the GUI and the ssh compositor alike. All forms
are bindable and persist to disk.

See [COMMANDS.md](COMMANDS.md) for the full option reference and [TMUX_PARITY.md](TMUX_PARITY.md#at-parity)
for scope details.

---

## 10. Attach over ssh — the compositor

`harness-cli attach-window` renders a tab's **entire split layout** — every pane, borders,
the status line, the active cursor — into any plain terminal, including over ssh. It's
Harness-native and fully client-side:

```bash
harness-cli attach-window                       # the active tab
harness-cli attach-window --session work          # a named session
harness-cli attach --surface <uuid>               # a single pane only
```

Inside the compositor the prefix (`Ctrl-A`) drives: `%` / `"` split, `x` kill, `z` zoom,
**`hjkl`** select pane (note: `hjkl`, not arrows), `o` / `;` cycle, `c` new tab, `n` / `p` tab,
`d` detach. Copy-mode and SGR mouse work too. Detach keys default to `Ctrl-A d`; override with
`--detach-keys`. There's also a programmatic **control mode** (`harness-cli control-mode` / `-CC`).

### Driving a headless or remote daemon

The compositor above attaches to a daemon on *your* Mac. You can also point the CLI at a daemon
running on **another machine** — headless, or on Linux — and control it remotely. Register the
remote once, then add `--host <name>` to any command:

```bash
# On the remote box, the daemon listens on a Unix socket (harness-cli doctor prints its path).
harness-cli remote add --name devbox --ssh me@devbox --socket "/home/me/.config/harness/harness.sock"
harness-cli new-session --host devbox --cwd ~/Code
harness-cli send-keys  --host devbox --surface <id> --keys "make test Enter"
harness-cli capture-pane --host devbox --surface <id>
harness-cli doctor       --host devbox          # health-check the remote daemon
```

(`--host` works on the client commands above; `attach-window` always renders the
*local* daemon, so run it on the machine whose daemon you want to see.)

Harness forwards the remote socket over `ssh -N -L`, reusing your existing SSH trust — no new
credentials. Because the daemon owns scrollback and persists it to disk, a remote session's
history survives the daemon restarting on that box. See
[COMMANDS.md → Remote daemons](COMMANDS.md#remote-daemons-over-ssh) for `remote list` / `remote
remove` and `--ssh-arg`.

### Server administration

Two commands manage the daemon lifecycle:

- **`harness-cli kill-server`** sends `SIGTERM` to the local daemon, stopping it gracefully.
  launchd's `KeepAlive` respawns it, restoring all sessions from disk — so shells and scrollback
  survive. For a permanent shutdown, use `launchctl bootout` (see `harness-cli doctor`).
- **`harness-cli start-server`** ensures the daemon is running (a no-op if it already is).

Both are local-only; with `--host`, they error loudly instead of targeting the wrong daemon.

### Strict targeting and error handling

Every command using a `-t <target>` grammar (`session:window.pane`, `$session-id`, `@session-name`,
`%pane-id`, named indices, etc.) applies **strict resolution**: if a named component doesn't match
(e.g., `kill-pane -t nonexistent:0`), the command fails with `.unresolved` instead of silently
acting on a fallback. This prevents accidental misroutes. The resolution happens centrally in
`CommandIPCTranslator`, so every front-end (GUI, attach-window compositor, CLI, hooks) behaves
identically. See [TMUX_PARITY.md](TMUX_PARITY.md#at-parity) under "Targeting" for the full
grammar and `base-index` / `pane-base-index` option details.

---

## 11. Window search and filtering

**`find-window`** searches for a tab by name, title, or pane content and focuses it:

```bash
:find-window pattern         # match tab name or title (default)
:find-window -N pattern      # search name only
:find-window -T pattern      # search title only
:find-window -C pattern      # search pane content (slower)
:find-window -t work pattern # scope the search to one session
```

Patterns are fnmatch-style globs. The first match in snapshot order is focused; if multiple matches
would be useful, use `choose-window` instead.

---

## 12. Shell integration (prompt marks + the success/failure gutter)

Harness understands **OSC 133** semantic prompts. Once installed, each shell prompt is marked and
each command's exit status is recorded, which powers:

- A **left-margin gutter stripe** per prompt: **green** = exit 0, **red** = non-zero, neutral =
  command still running / unknown.
- **Jump-to-prompt** navigation: ⌘↑ / ⌘↓ in the GUI (View ▸ Previous/Next Prompt), `[` / `]` in
  copy mode, and the live-view `jump-previous-prompt` / `jump-next-prompt` commands (bind them
  or run from the `:` prompt).
- **Select last command output**: ⇧⌘A (View ▸ Select Last Command Output) or the
  `select-last-output` command — selects the lines between the last two prompt marks and
  scrolls to reveal them.
- **`#{command_duration}`**: the last finished command's runtime, as a format token for
  `display-message`, hooks, and pane-border formats (GUI contexts).

Turn it on with one command (it writes the script under the Harness home and wires a guarded,
idempotent, backed-up `source` line into your rc):

```bash
harness-cli install-shell-integration            # auto-detects $SHELL
harness-cli install-shell-integration all          # bash + zsh + fish
```

Restart your shell (or open a new pane). The snippet is a no-op outside a Harness pane — it gates
on `$HARNESS` (exported by the daemon into every pane). Details:
[shell-integration/README.md](shell-integration/README.md).

### Per-host / per-command profiles

Re-theme a pane while it's somewhere dangerous — e.g. a red canvas over ssh to production.
Configure under `"profiles"` in `settings.json` (first matching rule wins; saved changes apply
live):

```json
"profiles": [
  {"host": "*.prod.example.com", "theme": "Red Alert"},
  {"command": "ssh", "theme": "Dracula"}
]
```

- `host` is a glob over the pane's **OSC 7 hostname** — reliable switching needs shell
  integration on both ends (the local shell's OSC 7 reverts the override when `ssh` exits).
- `command` is a glob over the pane's **foreground process name** (tracked automatically —
  no integration needed).
- The override re-themes the terminal **canvas only**, per pane; window chrome keeps the
  global theme, and nothing is ever written back to your settings.

---

## 13. Agent hooks (notifications)

Harness detects coding agents (Claude Code, Codex, Cursor, Pi, Hermes, OpenClaw, and more) and
can notify you when one stops or needs input. For the agents with a hook mechanism, wire it up
once:

```bash
harness-cli install-hooks claude-code      # or codex | cursor | pi | hermes | openclaw
```

It deep-merges into the agent's own config (e.g. `~/.claude/settings.json`), backing it up first
— never clobbering. Agents without a hook mechanism (aider, gemini, goose, opencode) are detected
automatically and notify via Harness's activity path, so there's nothing to install for them.

### Output triggers

Watch terminal output for patterns and react — highlight the match in the scrollback or post a
notification. Configure under `"triggers"` in `settings.json` (saved changes apply live):

```json
"triggers": [
  {"pattern": "ERROR", "action": "highlight"},
  {"pattern": "Tests? failed", "match": "regex", "action": "notify"}
]
```

- `match`: `literal` (default) or `regex`; `action`: `highlight` (default) or `notify`;
  `enabled: false` parks a rule without deleting it.
- Lines are scanned as they **complete** (the cursor moves past them) — never mid-write, never
  on the alternate screen (full-screen TUIs), and never from replayed history on reopen.
- `notify` has a 10s per-rule cooldown so repeating output can't storm notifications.
- Bounded by design: at most 32 rules, and scanning is rate-budgeted (~2% of the output
  pipeline) — a flood degrades to sampling recent lines instead of slowing the terminal.

---

## 14. macOS shortcuts (no prefix)

| Shortcut | Action | | Shortcut | Action |
|---|---|---|---|---|
| `Cmd-T` / `Cmd-W` | New / close tab | | `Cmd-K` | Command palette |
| `Cmd-D` / `Cmd-Shift-D` | Split H / V | | `Cmd-;` | Command prompt |
| `Cmd-1`…`Cmd-9` | Switch to tab N | | `Cmd-,` | Settings |
| `Cmd-Shift-[` / `]` | Prev / next tab | | `Cmd-\` | Toggle sidebar |
| `Cmd-Shift-N` | New workspace | | `Cmd-+` / `-` / `0` | Font bigger / smaller / reset |
| `Cmd-Shift-U` | Jump to next notification | | `prefix ?` | Cheatsheet |

> Coming from another multiplexer? [MIGRATION.md](MIGRATION.md) has a key-by-key translation table
> and a tested path for bringing your config and bindings over. You can migrate a `.tmux.conf` by
> running `:source-file ~/.tmux.conf` from the prompt — lines like `bind`, `set`, `setw`, and `setenv`
> parse and execute as-is (see [TMUX_PARITY.md](TMUX_PARITY.md#invariants-this-ledger-protects)
> for the one-mechanism guarantee).

---

## 15. One-screen cheat sheet

```
PREFIX = Ctrl-A   (Settings ▸ Keys to change;  prefix ? = live cheatsheet)

PANES        prefix %  split →      prefix "  split ↓
             prefix ←→↑↓  focus     prefix o/;  cycle     prefix l  last
             prefix z  zoom         prefix x  kill        prefix q  numbers
             prefix S-←→↑↓  resize   prefix Space  layouts
             prefix m / j  mark / join pane     prefix S  sync-panes

TABS         prefix c  new          prefix ,  rename
             Cmd-1..9  jump N        Cmd-Shift-[ ]  prev/next

SESSIONS     prefix (/)  previous/next session

COPY MODE    prefix [  enter        hjkl move   v/V/C-v select   y yank
             / ? search  n/N next   [ ] jump prompt           q/Esc exit

CLIENT       prefix d  detach       View ▸ Detach/Reattach Pane
             attach over ssh:  harness-cli attach-window [--session NAME]

COMMAND      prefix :  or Cmd-;     Cmd-K palette     harness-cli <verb>

SETUP        harness-cli install                      (CLI + daemon + completion)
             harness-cli install-shell-integration    (OSC 133 prompt gutter)
             harness-cli install-hooks <agent>        (agent notifications)
```
