# Harness as a terminal multiplexer — the tmux guide

Harness is a native terminal multiplexer. If you've used **tmux**, you already know how to drive
it: same muscle memory (a prefix key, splits, windows, copy mode, detach/attach, a `:` command
line), the same verb vocabulary (`split-window`, `new-window`, `kill-pane`, `copy-mode`…). The
difference is that it's **Harness-owned and self-contained** — there is no tmux, libtmux,
cmux, or any other dependency under the hood. The daemon, the session model, the compositor, and
the VT engine are all first-party Swift.

This guide is the narrative "how it works + shortcuts" tour. For exhaustive references see:

- [KEYBINDINGS.md](KEYBINDINGS.md) — every default binding + the key-spec syntax.
- [COMMANDS.md](COMMANDS.md) — the full command grammar.
- [MIGRATION.md](MIGRATION.md) — a tested path for moving a tmux setup over.
- [MODES.md](MODES.md) — Plain / Persistent / Multiplexer / Agent experience modes.

---

## 1. The mental model

Harness nests sessions a little differently from tmux. The hierarchy, top to bottom:

| Harness term | tmux analog | What it is |
|---|---|---|
| **Workspace** | *(server)* | A named group of sessions (one active workspace at a time). |
| **Session** | `session` | A sidebar entry with its own tab bar. Survives quit if pinned/kept. |
| **Tab** | `window` | One tab in a session: title, cwd, git branch, agent, and a split tree. |
| **Pane** | `pane` | A single terminal (a leaf in the tab's split tree). |
| **Surface** | *(pane's pty)* | The daemon-owned PTY behind a pane (`$HARNESS_SURFACE`). |

So a Harness **tab is a tmux window**, and a Harness **session** groups tabs the way the sidebar
shows them. The terms "tab" and "window" are used interchangeably in the verbs (`new-window`
makes a tab; the `next-window`/`previous-window` verbs move between tabs).

**Who owns what:** a background **daemon** (`HarnessDaemon`, kept alive by launchd) owns all
session truth and every PTY. The app and `harness-cli` are just clients — so your shells keep
running when the app quits, across crashes, and you can reattach from another window or over ssh.

---

## 2. The prefix key

Like tmux, most multiplexer commands start with a **prefix** keystroke, then a second key.

- **Default prefix: `Ctrl-A`** (tmux ships `Ctrl-B`; Harness picks the screen/`C-a` convention).
- Change it in **Settings ▸ Keys** (or `settings.prefixKey`); set it empty to disable the prefix
  entirely (then drive everything from the `:` prompt, the `Cmd-K` palette, and macOS shortcuts).
- Press **`prefix ?`** any time for a live cheatsheet generated from your current bindings.

> The prefix layer only appears in modes that show tmux chrome (Tmux/Agent modes, or when you
> turn `tmuxControlsEnabled` on). In Plain mode you lean on the macOS `Cmd` shortcuts instead.

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
> In the GUI, directional pane nav is the **arrow keys**; the `attach-window` compositor (§9)
> uses **`hjkl`** instead.

---

## 4. Tabs (windows)

| Keys | Action |
|---|---|
| `prefix c` | New tab |
| `prefix n` / `prefix p` | Next / previous tab |
| `prefix ,` | Rename the current tab |
| `Cmd-1` … `Cmd-9` | Jump straight to tab 1–9 (shown as `⌘N` on the pills) |
| `Cmd-Shift-[` / `Cmd-Shift-]` | Previous / next tab |
| `Cmd-T` / `Cmd-W` | New tab / close tab |

Tab titles auto-follow the pane's working directory (or the running agent), so the strip stays
readable without manual renaming.

---

## 5. Sessions and workspaces

Sessions are the sidebar rows; each has its own tab strip. Unlike tmux, **sessions are always
visible** in the sidebar rather than something you "attach" to one at a time.

- New session / workspace from the sidebar `+`, the palette, or `harness-cli new-session` /
  `new-workspace`.
- **Persistence** (see [MODES.md](MODES.md)): a session survives a *clean* quit if the global
  "keep sessions on quit" is on **or** the session is pinned. Pin/unpin from the sidebar context
  menu or `harness-cli promote-session` / `demote-session`. A crash leaves everything running.
- `Cmd-Shift-N` makes a new workspace.

---

## 6. Copy mode (scrollback, selection, search)

Enter with **`prefix [`** (tmux-style). Copy mode is modal and vim-flavored (`mode-keys vi`):

| Keys | Action |
|---|---|
| `h` `j` `k` `l` | Move the cursor |
| `0` / `$` | Start / end of line |
| `w` / `b` | Next / previous word |
| `g` / `G` | Top / bottom of history |
| `PageUp`/`PageDown`, `C-u`/`C-d` | Page / half-page scroll |
| `[` / `]` | **Jump to previous / next shell prompt** (needs OSC 133 — see §10) |
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

- **`prefix d`** detaches the calling client (tmux's detach).
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
  `harness-cli bind-hook after-split-pane 'display-message "split!"'`.

---

## 9. Attach over ssh — the compositor

`harness-cli attach-window` renders a tab's **entire split layout** — every pane, borders,
the status line, the active cursor — into any plain terminal, including over ssh. This is the
tmux "attach to my session from anywhere" experience, Harness-native and client-side:

```bash
harness-cli attach-window                       # the active tab
harness-cli attach-window --session work          # a named session
harness-cli attach --surface <uuid>               # a single pane only
```

Inside the compositor the prefix (`Ctrl-A`) drives: `%` / `"` split, `x` kill, `z` zoom,
**`hjkl`** select pane (note: `hjkl`, not arrows), `o` / `;` cycle, `c` new tab, `n` / `p` tab,
`d` detach. Copy-mode and SGR mouse work too. Detach keys default to `Ctrl-A d`; override with
`--detach-keys`. There's also tmux **control mode** (`harness-cli control-mode` / `-CC`) for
programmatic clients.

---

## 10. Shell integration (prompt marks + the success/failure gutter)

Harness understands **OSC 133** semantic prompts. Once installed, each shell prompt is marked and
each command's exit status is recorded, which powers:

- A **left-margin gutter stripe** per prompt: **green** = exit 0, **red** = non-zero, neutral =
  command still running / unknown.
- **Jump-to-prompt** navigation: `[` / `]` in copy mode, and the live-view `jump-previous-prompt`
  / `jump-next-prompt` commands (bind them or run from the `:` prompt).

Turn it on with one command (it writes the script under the Harness home and wires a guarded,
idempotent, backed-up `source` line into your rc):

```bash
harness-cli install-shell-integration            # auto-detects $SHELL
harness-cli install-shell-integration all          # bash + zsh + fish
```

Restart your shell (or open a new pane). The snippet is a no-op outside a Harness pane — it gates
on `$HARNESS` (the `$TMUX` analog the daemon exports into every pane). Details:
[shell-integration/README.md](shell-integration/README.md).

---

## 11. Agent hooks (notifications)

Harness detects coding agents (Claude Code, Codex, Cursor, Pi, Hermes, OpenClaw, and more) and
can notify you when one stops or needs input. For the agents with a hook mechanism, wire it up
once:

```bash
harness-cli install-hooks claude-code      # or codex | cursor | pi | hermes | openclaw
```

It deep-merges into the agent's own config (e.g. `~/.claude/settings.json`), backing it up first
— never clobbering. Agents without a hook mechanism (aider, gemini, goose, opencode) are detected
automatically and notify via Harness's activity path, so there's nothing to install for them.

---

## 12. macOS shortcuts (no prefix)

| Shortcut | Action | | Shortcut | Action |
|---|---|---|---|---|
| `Cmd-T` / `Cmd-W` | New / close tab | | `Cmd-K` | Command palette |
| `Cmd-D` / `Cmd-Shift-D` | Split H / V | | `Cmd-;` | Command prompt |
| `Cmd-1`…`Cmd-9` | Switch to tab N | | `Cmd-,` | Settings |
| `Cmd-Shift-[` / `]` | Prev / next tab | | `Cmd-\` | Toggle sidebar |
| `Cmd-Shift-N` | New workspace | | `Cmd-+` / `-` / `0` | Font bigger / smaller / reset |
| `Cmd-Shift-U` | Jump to next notification | | `prefix ?` | Cheatsheet |

---

## 13. Coming from tmux — quick translation

| You'd type in tmux | In Harness |
|---|---|
| `tmux` (start) | Just open Harness, or `harness-cli new-session` |
| `prefix c` / `,` / `&` | Same (new / rename / kill tab) |
| `prefix %` / `"` | Same (splits) |
| `prefix o` / `q` / `z` / `x` | Same (cycle / numbers / zoom / kill) |
| `prefix [` then vi keys | Same (copy mode) |
| `prefix d` | Same (detach) — or View ▸ Detach Pane |
| `prefix :` command-prompt | Same `:` prompt |
| `tmux a` (attach) | `harness-cli attach-window` (full layout, incl. ssh) |
| `tmux send-keys` | `harness-cli send-keys --surface <id> --keys "…"` |
| `tmux capture-pane` | `harness-cli capture-pane --surface <id>` (`-S/-E/-e/-J`) |
| `$TMUX` set inside a pane | `$HARNESS` (and `$HARNESS_SURFACE` for the pane id) |

Default prefix differs (`Ctrl-A` vs tmux's `Ctrl-B`) — change it in Settings if you want `Ctrl-B`.
A few tmux concepts (grouped sessions, some session-lifecycle options) are deliberately left out
where they clash with Harness's model. A tested migration walkthrough is in
[MIGRATION.md](MIGRATION.md).

---

## 14. One-screen cheat sheet

```
PREFIX = Ctrl-A   (Settings ▸ Keys to change;  prefix ? = live cheatsheet)

PANES        prefix %  split →      prefix "  split ↓
             prefix ←→↑↓  focus     prefix o/;  cycle     prefix l  last
             prefix z  zoom         prefix x  kill        prefix q  numbers
             prefix S-←→↑↓  resize   prefix Space  layouts
             prefix m / j  mark / join pane     prefix S  sync-panes

TABS         prefix c  new          prefix n/p  next/prev   prefix ,  rename
             Cmd-1..9  jump N        Cmd-Shift-[ ]  prev/next

COPY MODE    prefix [  enter        hjkl move   v/V/C-v select   y yank
             / ? search  n/N next   [ ] jump prompt           q/Esc exit

SESSION      prefix d  detach       View ▸ Detach/Reattach Pane
             attach over ssh:  harness-cli attach-window [--session NAME]

COMMAND      prefix :  or Cmd-;     Cmd-K palette     harness-cli <verb>

SETUP        harness-cli install                      (CLI + daemon + completion)
             harness-cli install-shell-integration    (OSC 133 prompt gutter)
             harness-cli install-hooks <agent>        (agent notifications)
```
