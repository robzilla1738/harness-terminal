# Experience modes

Harness presents four **experience modes**. A mode changes which controls are visible, the
default session-persistence policy, and how prominent agent workflows are.

Switch modes any time in **Settings → Terminal → Experience**. A new install starts in
**Persistent**. A settings file that never stored `experienceMode` still opens as **Full
Terminal**, so an upgrade does not hide a prefix key or status line you already had.

| Mode | Prefix key | Status line | Sessions survive a clean quit | Agent workflows |
|------|:---------:|:-----------:|:-----------------------------:|:---------------:|
| **Plain Terminal** | — | — | No (ephemeral) | available |
| **Persistent Terminal** | — | — | Yes | available |
| **Full Terminal** | ✓ | ✓ | Yes | available |
| **Agent Workspace** | optional | optional | Yes | foregrounded |

## 1. Plain Terminal

A fast native terminal. No prefix key, no status bar, no multiplexer terminology — it feels
like an ordinary terminal. Sessions are **ephemeral**: closing the app cleanly closes its
shells. Splits and tabs are still available via the menu shortcuts (`⌘D`, `⌘⇧D`, `⌘T`).

## 2. Persistent Terminal

Visually identical to Plain, but sessions **survive** a clean quit and can be attached and
driven from the CLI (`harness-cli attach`, `attach-window`). Promote/demote individual
sessions (see *Persistence*, below).

## 3. Full Terminal

The full multiplexer surface: the prefix key (default `Ctrl-A`), the status line, copy mode,
paste buffers, `-t session:window.pane` targets, the command prompt, and attach/detach. See the
[multiplexer guide](MULTIPLEXER_GUIDE.md) for the tour; [MIGRATION.md](MIGRATION.md) covers
bringing an existing setup over.

## 4. Agent Workspace

Persistent project workspaces with AI-agent detection, waiting/done/error notifications, and
jump-to-agent (`⌘⇧U`) foregrounded. The prefix + status line are **available but off by default**
— enable them without leaving the mode (see *Opting into the prefix + status line*).

## Persistence (ephemeral vs. persistent)

Persistence is evaluated on a **clean quit only**. A crash never tears sessions down; any
orphaned ephemeral sessions are cleaned up on the next clean quit.

A session survives a clean quit iff:

```
keepSessionsOnQuit (global)  ||  session.persistent (per-session pin)
```

- **Global** `keepSessionsOnQuit` keeps its classic "keep everything" meaning and is set by the
  mode (Plain → off; Persistent/Full/Agent → on). It's the *Settings → Terminal → Sessions →
  "Keep sessions running"* toggle.
- **Per-session** `persistent` pins one session so it survives even when the global switch is
  off (Plain mode). Promote/demote:
  - GUI: right-click a session in the sidebar (⌘\ shows it) → **Keep running after quit**
    (always offered; while the global switch is on it reads *Keep running after quit (all
    sessions kept)*, since every session survives anyway).
  - CLI: `harness-cli promote-session --session <uuid>` / `demote-session --session <uuid>`.

## Opting into the prefix + status line without switching modes

The prefix and status line can be overridden independently of the selected mode (Settings →
Terminal → Experience → **Command prefix** / **Status line**):

- Auto — derive from the mode.
- On — show the prefix and status line in any mode.
- Off — hide them even in Full Terminal mode.

Blanking the prefix key in Settings → Keys disables it outright.
