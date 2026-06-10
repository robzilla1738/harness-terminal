# tmux parity — status, adaptations, and deliberate divergences

Harness targets **capability parity** with tmux, not byte-for-byte emulation: Harness is a
native GUI terminal with a daemon-owned session model, so a handful of tmux concepts are
*adapted* to that architecture and a few are *rejected* with rationale. This document is
the single honest ledger. Updated last for v1.9.0 (the #114 roadmap's full run, #115–#138,
plus #139): quick terminal, bell feedback with `visual-bell`/`bell-action` bridging,
unlimited scrollback (`scrollback 0` → disk-capped), `clear-history`, `status-interval`/
`status-position`, bindable `send-keys -l`/`-H`, `display-message -p`, copy-mode jump-to-char,
and the Kitty graphics control protocol (ack/query/transmit-once/delete). The 2026-06
close-out series was PRs #102–#108. User-facing usage lives in
[HARNESS_TMUX_CAPABILITIES.md](HARNESS_TMUX_CAPABILITIES.md), grammar in
[COMMANDS.md](COMMANDS.md).

## At parity

| Area | Notes |
|---|---|
| Sessions / windows / panes | Full lifecycle: new/kill/rename/select/move/swap/link/unlink/break/join/respawn (pane **and** window), renumber, last-window/pane, rotate, zoom, layouts (incl. main-horizontal/vertical), `synchronize-panes` |
| **Grouped sessions** | `new-session -t <session>` (CLI: `--group-with`): shared window list, per-member focus (a new member starts on the group's current window); window create/kill propagates group-wide — kill matches by surface overlap, so it still propagates after members' split layouts diverge. Built atop linked windows — see ADAPT below |
| Targeting | Full `-t` grammar everywhere (`session:window.pane`, `$`/`@`/`%` ids, indexes, `!`, `{last}`, `{top}/{bottom}/{left}/{right}`, `^`/`$`), with `base-index`/`pane-base-index`. STRICT resolution: a named component that doesn't match makes the command `.unresolved` at the one translator choke point, so *every* targeted verb (kill/respawn/send-keys/…) fails loudly in every front-end — never a silent misroute. `swap-pane` takes `-s` too |
| Copy mode | vi + emacs tables (`copy-mode-vi` accepted as the vi table's name), `-X` action set: motions (char/line, word + **word-end**, **jump-to-char** `f`/`F`/`t`/`T` + `;`/`,`, **big-WORD** W/B/E [whitespace-delimited], **other-end**, **goto-line**, visible-window top/middle/bottom-line, back-to-indentation, page/half-page, history top/bottom, prompt jumps), selection, rectangle, search, copy-pipe; mouse; in GUI **and** the `attach-window` compositor |
| Paste buffers | set/get/list/delete/paste/choose, save/load (CLI), bindable verbs |
| Options | Scoped store (global/workspace/session/tab/pane + fallback chain), `set`/`setw`/`show` bindable, status-line set (incl. **`status-interval`** — periodic status redraw so `#{time:…}` ticks, in the GUI footer **and** the `attach-window` compositor, default 15s/`0` disables), styles, monitoring, **`visual-bell`/`bell-action`** (bridged to the GUI bell — `bell-action off`/`none` silences it, `visual-bell on/off/both` overrides the audible/visual split), `display-time`, `set-titles(+string)`, `detach-on-destroy`, `remain-on-exit`, `repeat-time`, **`persist-scrollback`** (per-pane secrets-at-rest control — see [SECURITY-POSTURE.md](SECURITY-POSTURE.md)), … **`@`-prefixed user options** (set + read via `#{@name}`). `set-option` **validates the key**: an unknown name errors loudly (no silent persist) — known/recognized options and `@`-options pass |
| `status-position` | **Honored** (top/bottom) in both the GUI status footer (the split↔footer constraints swap; extra `status 2..5` rows always stack away from the terminal so the main line sits against it) and the `attach-window` compositor (`PaneRectSolver` reserves the band via `yOrigin`; `GridCompositor` paints it at the matching edge). Live-updates from Settings ▸ Advanced |
| Hooks | `set-hook`/`show-hooks` + full lifecycle events: after-* command events, `session-created/renamed/closed`, `window-renamed/linked/unlinked/layout-changed`, **`command-error`** (failing command as `#{hook}`), **`pane-focus-in`/`-out`**, **`window-pane-changed`**, alert-activity/silence/bell, client-attached/detached, pane-exited (+ Harness-only agent events) |
| Format strings | ~50 `#{…}` variables (pane/session/window/client/server) + **`#{@user-options}`** + `#{hook}` + operators (`#{?,,}` with nested tests, `==`/`!=`, `\|\|`/`&&`, `m:`, `s///`, `e\|op\|`, `n:` length, `T:` double-expand, `a:` char-from-code, `=N:` truncation, `pN:` pad, `time:` strftime). IDs render with target-grammar prefixes so they round-trip into `-t` |
| Key tables | root/prefix/copy-mode(+emacs)/command + `switch-client -T` modal tables, `bind -r` repeat, tombstoned unbinds |
| Scripting | `send-keys` (incl. bindable `-l` literal / `-H` hex), `capture-pane` (+ ranges/escapes), **`clear-history`** (drop a pane's scrollback without respawning the shell — distinct from `respawn-pane -k`, which replaces the process), `pipe-pane`, `run-shell`, `if-shell`, `wait-for -S/-L/-U`, `display-message` (+ `-p` print-to-stdout) / `show-messages`, `command-prompt`, `confirm-before`, `source-file` (a `.tmux.conf`'s bind/set/setw/setenv lines parse as-is), choose-tree/session/window/buffer/client, `find-window`, control mode (`-CC`) |
| Misc | display-popup/menu, clock-mode, lock-client, multi-client smallest-size voting, environment tables (global/session), auto-injected OSC 133 shell integration at spawn (`shell-integration` option to opt out; bash needs ≥ 4.4 — stock macOS 3.2 spawns untouched — and injected bash panes report `login_shell` off and skip `~/.bash_logout` on exit, the documented costs of the `--posix`+`$ENV` vehicle) |

## Adapted (same capability, Harness-shaped)

| tmux | Harness adaptation | Why |
|---|---|---|
| `attach-session` | `harness-cli attach` / `attach-window` (compositor) | The GUI is the primary attached client; terminal attach is the remote/SSH path |
| `start-server` / `kill-server` | `harness-cli start-server` (ensure via launchctl) / `kill-server` (SIGTERM; launchd KeepAlive respawns with sessions restored — `launchctl bootout` for a permanent stop) | launchd supervises the daemon; pretending otherwise would lie |
| Grouped-session **layout** sharing | Window *create/kill* propagates (overlap-matched, divergence-safe); per-window split layouts may diverge between members. Killing the group's LAST window leaves each member an independent default window (Harness sessions never die from a window kill; tmux would destroy the whole group) | tmux shares one window object; Harness links windows (clones sharing live surfaces) — the model that also powers `link-window` |
| `default-terminal` | Aliases the `terminal-identity` option | TERM is pinned (`xterm-256color`); identity (TERM_PROGRAM/XTVERSION) is the meaningful adjustable |
| `set-titles` | Applies to the **outer** terminal of attach clients (OSC 2) | The GUI owns native window titles |
| `find-window` multi-match | Focuses the first match in snapshot order | tmux opens a picker; a filtered chooser may come later |
| `find-window` default scope | Bare default searches window name + title; pane content needs an explicit `-C` (tmux's bare default is the full `-CNT`); `-t <session>` scopes the search to one session (a `-t` naming a missing session matches nothing, never a silent global search) | Content search captures every pane — opt-in keeps the common name search snapshot-cheap |
| `window-layout-changed` hook | Fires on explicit layout verbs (select/next/previous-layout, rotate); splits/kills/resizes fire their own `after-*` events instead | One event per user intent — tmux fires it for every geometry change |
| `respawn-window` / `respawn-pane` `-k` | `-k` clears scrollback history; panes respawn regardless of running state | tmux's `-k` kills a still-running command (Harness respawn always replaces the process) |
| `refresh-client` | Re-pulls options + snapshot; tmux's size/flag arguments are ignored | Client geometry is vote-driven (see `aggressive-resize`) |
| `set-option` scopes | Bare `set` defaults to **global** (tmux: the current session); `-s` selects the **session** scope (tmux: server). tmux's server scope ≈ Harness global | One fallback chain (pane→tab→session→workspace→global) instead of two option trees |
| `session_attached` | Count of registered daemon clients (subscription **or** identify) | Harness has no per-session attach registry; the GUI attaches everything |
| Option scope flags | `-w` = workspace, `-t` = tab (tmux's window), `-T <target>` for explicit targets | Harness has a workspace level above sessions; documented in COMMANDS.md |
| `send-keys` named-key encoding | Encoded by the same engine `InputEncoder` as physical keypresses (one encoder), but in **normal cursor-key mode** — the daemon is a byte-pipe with no live per-surface emulator, so it can't consult the target's DECCKM/Kitty state the way tmux does | Normal-mode sequences are what nearly all apps accept; `-H` injects raw bytes when an exact app-mode sequence is required |

## Rejected (with rationale)

| tmux | Why not |
|---|---|
| `escape-time` | No escape-sequence ambiguity to time out: input parsing is event-based (GUI) / Kitty-keyboard-aware, not raw-byte-timing |
| `terminal-overrides` | Harness owns its renderer; there is no terminfo negotiation layer to override |
| `suspend-client` | No terminal-suspend concept for a GUI window or the compositor |
| `customize-mode` | Settings (GUI) is the customize surface |
| `pane-mode-changed` hook | Copy-mode state is client-local by architecture (GUI overlay / compositor); the daemon never sees mode entry |
| `aggressive-resize` | Inherently on: surfaces are sized by per-surface client votes, so only clients actually viewing a window vote |
| `server-access` | The daemon is single-user by construction: the control socket is 0600 and every connection is peer-credential-checked against the owning UID — there is no multi-user surface to ACL |

## Deferred (tracked, unimplemented)

- `window-size` (smallest/largest/latest vote aggregation) + `resize-window` manual override
- `destroy-unattached` enforcement
- `word-separators`, `wrap-search` (copy-mode engine plumbing)
- `find-window` multi-match picker; `-C` content search from hooks (front-ends only today)
- `list-*` `-F` format-string output (rows are fixed-shape + `--json`)
- `show-prompt-history` (command-prompt keeps no input history yet)

## Invariants this ledger protects

1. **No silent misroutes or silently-ignored config.** An unrecognized or unresolvable `-t`
   errors loudly in every front-end (parse-time for nonsense, resolve-time for missing names);
   likewise `set-option` rejects an unknown option key rather than persisting a value nothing
   reads (`@`-prefixed user options always pass). v1.7.1 policy, extended for option keys.
2. **One mechanism for config migration.** `source-file` takes a `.tmux.conf`'s bind/set/
   setw/setenv lines unchanged (`TmuxMigrationTests`).
3. **Adaptations are documented here before they ship.** If behavior diverges from tmux
   and this file doesn't say why, that's a bug in this file.
