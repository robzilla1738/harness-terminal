# Harness

[![CI](https://github.com/robzilla1738/harness-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/robzilla1738/harness-cli/actions/workflows/ci.yml)

A native macOS terminal with its own GPU engine, a built-in multiplexer, and an eye on the coding agents in your panes. It does what you used to need a terminal and tmux for, in one app, with no external dependencies.

## Experience modes

By default it stays out of your way. Turn on the multiplexer when you want splits, sessions, and a status line — it's the same fast core either way. Pick a mode in **Settings → Appearance → Experience** (see [docs/MODES.md](docs/MODES.md)):

- **Plain Terminal** — a fast native terminal: no prefix key, no status bar, sessions close when you quit.
- **Persistent Terminal** — same clean UI, but sessions survive quitting and attach from the CLI.
- **Multiplexer** — prefix key, status line, copy mode, buffers, targets, attach/detach.
- **Agent Workspace** — persistent project workspaces with agent detection, notifications, and jump-to-agent.

New installs start in Plain. Coming from tmux or another terminal? See [docs/MIGRATION.md](docs/MIGRATION.md).

## Features

- GPU-accelerated terminals rendered by **Harness's own terminal engine** — crisp Display-P3 / sRGB color, themed translucent canvas with untouched program output, no external dependencies (`swift build` resolves zero packages)
- Switching from Ghostty? Optional one-time config import brings your colors, opacity, blur, font, and padding across
- Workspaces + sidebar sessions + per-session tabs + horizontal/vertical splits
- Session layout persistence (daemon-owned JSON)
- **harness-cli** for automation and agent hooks
- **Harness command system**: `send-keys`, `capture-pane`, `kill-pane`, `resize-pane`, `zoom-pane`, `swap-pane`, `rename-tab`, `attach`
- **In-app prefix keymap** (default `Ctrl-A`) with cheatsheet (prefix `?`)
- Agent auto-detection (Codex / Claude Code / Cursor / Pi / Hermes / OpenClaw / Aider / Gemini / Goose) with per-agent dot color + sidebar chip
- Agent notifications (desktop + sidebar + pane rings), jump-to-waiting (`Cmd+Shift+U`) skips panes still generating
- One-line hook install: `harness-cli install-hooks <agent>`
- Command palette (`Cmd+K`), Settings (`Cmd+,`)
- 485 built-in color themes + `.harnesstheme` export/import for sharing
- Shell integration (OSC 133): prompt marks for jump-to-prompt + command success/failure gutter — bash/zsh/fish snippets in [docs/shell-integration/](docs/shell-integration/README.md)
- Inline images (Sixel / Kitty / iTerm2) that persist across reflow and into scrollback

## Download and install

### Build from source

```bash
git clone https://github.com/robzilla1738/harness-cli.git harness
cd harness
make release
open Harness.app
```

### Xcode development

`Harness.xcodeproj` is generated from `project.yml` with XcodeGen.

```bash
xcodegen generate
open Harness.xcodeproj
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

The Xcode app target builds and bundles `HarnessDaemon` and `harness-cli` into `Harness.app/Contents/MacOS/`, so running from Xcode uses the same helper layout as the release app.

### Install harness-cli

```bash
# From the app bundle or build output:
Harness.app/Contents/MacOS/harness-cli install

# Or after building:
.build/release/harness-cli install

# Add to PATH (printed by install):
export PATH="$HOME/Library/Application Support/Harness/bin:$PATH"
```

## harness-cli

Ensure Harness is running (launches `HarnessDaemon` automatically):

```bash
harness-cli list-workspaces
harness-cli list-surfaces
harness-cli new-workspace --name api
harness-cli new-session --workspace api --cwd ~/Code/myproject
harness-cli new-tab --workspace api --cwd ~/Code/myproject
harness-cli notify --surface "$HARNESS_SURFACE" --title Agent --body "Needs approval"
```

## Agent hooks

See [docs/agent-hooks/README.md](docs/agent-hooks/README.md).

```bash
harness-cli notify --surface "$HARNESS_SURFACE" --body "Approval required"
```

`HARNESS_SURFACE` is set automatically in every Harness terminal pane.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| New workspace | `Cmd+Shift+N` |
| New tab | `Cmd+T` |
| Close tab | `Cmd+W` |
| Split horizontal / vertical | `Cmd+D` / `Cmd+Shift+D` |
| Jump to notification | `Cmd+Shift+U` |
| Command palette | `Cmd+K` |
| Settings | `Cmd+,` |
| Toggle sidebar | `Cmd+\` |
| Switch workspace 1–9 | `Cmd+1` … `Cmd+9` |
| Previous / next tab | `Cmd+Shift+[` / `Cmd+Shift+]` |

## What it replaces

Harness is one app where you used to run a terminal and a multiplexer side by side.

| | Harness | Ghostty (terminal) | tmux (multiplexer) |
|---|---|---|---|
| GPU-native macOS terminal, own engine | ✅ | ✅ | — |
| Persistent sessions, attach / detach | ✅ | — | ✅ |
| Same session in two windows, or over SSH | ✅ | — | ✅ |
| Scriptable from the CLI (send-keys, capture-pane, resize) | ✅ | — | ✅ |
| Prefix keymap, copy mode, status line | ✅ | — | ✅ |
| Inline images (Sixel / Kitty / iTerm2) | ✅ | ✅ | — |
| OSC 133 prompt marks + success/failure gutter | ✅ | ✅ | — |
| Auto-detects coding agents and notifies you | ✅ | — | — |

## Distribution

```bash
make release          # Harness.app + embedded harness-cli
make dmg              # Harness.dmg for drag-to-Applications install
```

### Code signing and notarization

```bash
export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="app-specific-password"
make release
./Scripts/sign-and-notarize.sh
make dmg
```

Regenerate the Dock icon after updating `AppIcon.appiconset`:

```bash
./Scripts/generate-app-icon.sh
```

## Requirements

- macOS 14.0+
- Xcode 16+ / Swift 6.0

## Documentation

- [How it works](docs/ARCHITECTURE.md) — daemon, terminal engine, IPC, compositor
- [Experience modes](docs/MODES.md) — Plain / Persistent / Multiplexer / Agent
- [Multiplexer guide](docs/TMUX_GUIDE.md) — prefix, panes, sessions, copy mode, attach from anywhere
- [Migration](docs/MIGRATION.md) — moving over from tmux or another terminal
- [Keybindings](docs/KEYBINDINGS.md) · [Commands](docs/COMMANDS.md) · [Shell integration](docs/shell-integration/README.md) · [Agent hooks](docs/agent-hooks/README.md)
- [Reliability & security](docs/RELIABILITY.md)

## License

MIT
