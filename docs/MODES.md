# Experience modes

Harness presents four **experience modes** on top of **one** daemon-backed session core.
A mode never forks the session/PTY path — the daemon always owns PTYs, child processes,
scrollback, resize, attach/detach, and persistence. A mode only changes *what's exposed*:
which chrome is visible, the default session-persistence policy, and how prominent agent
workflows are.

Switch modes any time in **Settings → Appearance → Experience**. New installs start in
**Plain**; an install that predates modes migrates to **Tmux** so nothing you already had
(prefix key, status line) disappears.

| Mode | Prefix key | Status line | Sessions survive a clean quit | Agent workflows |
|------|:---------:|:-----------:|:-----------------------------:|:---------------:|
| **Plain Terminal** | — | — | No (ephemeral) | available |
| **Persistent Terminal** | — | — | Yes | available |
| **Tmux Compatibility** | ✓ | ✓ | Yes | available |
| **Agent Workspace** | optional | optional | Yes | foregrounded |

## 1. Plain Terminal

A fast native terminal. No prefix key, no status bar, no multiplexer terminology — it feels
like a normal terminal (the spirit of Ghostty). Sessions are **ephemeral**: closing the app
cleanly closes its shells. Splits and tabs are still available via the menu shortcuts
(`⌘D`, `⌘⇧D`, `⌘T`).

## 2. Persistent Terminal

Visually identical to Plain, but sessions **survive** a clean quit and can be attached and
driven from the CLI (`harness-cli attach`, `attach-window`). Promote/demote individual
sessions (see *Persistence*, below).

## 3. Tmux Compatibility

The full multiplexer surface: the prefix key (default `Ctrl-A`), the status line, copy mode,
paste buffers, tmux-style `-t session:window.pane` targets, the command prompt, attach/detach,
and tmux/Ghostty config import. See [TMUX_PARITY.md](TMUX_PARITY.md).

## 4. Agent Workspace

Persistent project workspaces with AI-agent detection, waiting/done/error notifications, and
jump-to-agent (`⌘⇧U`) foregrounded. tmux controls are **available but off by default** —
enable them without leaving the mode (see *Opting into tmux controls*).

## Persistence (ephemeral vs. persistent)

Persistence is daemon-owned and evaluated on a **clean quit only** — a daemon or GUI crash
never tears sessions down (surviving a crash is always a feature; a crash's orphans are reaped
on the next clean quit).

A session survives a clean quit iff:

```
keepSessionsOnQuit (global)  ||  session.persistent (per-session pin)
```

- **Global** `keepSessionsOnQuit` keeps its classic "keep everything" meaning and is set by the
  mode (Plain → off; Persistent/Tmux/Agent → on). It's the *Settings → Terminal → "Keep
  sessions running after the window closes"* toggle.
- **Per-session** `persistent` pins one session so it survives even when the global switch is
  off (Plain mode). Promote/demote:
  - GUI: right-click a session in the sidebar → **Keep running after quit** (shown only when the
    global switch is off, so the checkmark can't lie).
  - CLI: `harness-cli promote-session --session <uuid>` / `demote-session --session <uuid>`.

## Opting into tmux controls without switching modes

`tmuxControlsEnabled` (in `settings.json`) overrides the mode's chrome default:

- `null` (default) — derive from the mode (only Tmux shows the prefix + status line).
- `true` — show the prefix + status line in any mode (e.g. an Agent user who wants the prefix).
- `false` — hide them even in Tmux mode.

The single gate `HarnessSettings.showsTmuxChrome` (mode default, overridden by
`tmuxControlsEnabled`) is what `PrefixKeymap`, `StatusLineView`, and onboarding all consult, so
they never drift. Blanking the prefix key in Settings → Keys disables it outright (it no longer
silently falls back to `Ctrl-A`).

## How it maps to the code

| Concern | Where |
|---------|-------|
| Mode enum + derived policy | `HarnessCore/Settings/ExperienceMode.swift` |
| Stored mode + `showsTmuxChrome` / `effectivePrefixKey` | `HarnessCore/Settings/HarnessSettings.swift` |
| Prefix gating (install/remove the monitor) | `HarnessApp/UI/PrefixKeymap.swift` |
| Status-line gating | `HarnessApp/UI/StatusLineView.swift` |
| Mode picker + side-effects | `HarnessApp/Settings/SettingsViewController.swift` |
| Per-session pin | `SessionGroup.persistent`, `SessionEditor.setSessionPersistent` |
| Ephemeral reap | `SessionEditor.ephemeralSessionIDs`, IPC `closeEphemeralSessions`, `AppDelegate.applicationWillTerminate` |
