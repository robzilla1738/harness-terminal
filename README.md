# Harness

Native macOS terminal for organizing AI agents and dev sessions — Harness's own GPU renderer, cmux-style workspaces, harness-cli automation.

## Experience modes

Harness is simple like Ghostty by default, powerful like tmux when you enable it, and
agent-focused like cmux when you want it — all on **one** daemon-backed session core. Pick a
mode in **Settings → Appearance → Experience** (see [docs/MODES.md](docs/MODES.md)):

- **Plain Terminal** — a fast native terminal: no prefix key, no status bar, sessions close when you quit.
- **Persistent Terminal** — same clean UI, but sessions survive quitting and attach from the CLI.
- **Tmux Compatibility** — prefix key, status line, copy mode, buffers, targets, attach/detach.
- **Agent Workspace** — persistent project workspaces with agent detection, notifications, and jump-to-agent.

New installs start in Plain; upgrades keep what you had (Tmux). Migrating from Ghostty or tmux?
See [docs/MIGRATION.md](docs/MIGRATION.md).

## Features

- GPU-accelerated terminals rendered by **Harness's own terminal engine** — crisp Display-P3 / sRGB color, themed translucent canvas with untouched program output, no external dependencies (`swift build` resolves zero packages)
- Optional Ghostty config import — match your existing colors, opacity, blur, font, and padding
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

## Comparison

| Feature | Harness v1.0 | Ghostty | cmux | tmux |
|---------|----------------|---------|------|------|
| Native macOS app | Yes | Yes | Yes | No |
| GPU-rendered terminal (own engine) | Yes | Yes | Yes | N/A |
| Ghostty-config import (theme/opacity/blur) | Yes | Yes | No | No |
| Workspaces + agent sidebar | Yes | Limited | Yes | DIY |
| harness-cli automation | Yes | No | Yes | Yes |
| Scriptable send-keys / capture-pane / resize-pane | Yes | No | Limited | Yes |
| In-app prefix keymap (`Ctrl-A`) | Yes | No | No | Yes |
| Auto-detected agent status (Codex / Claude Code / Cursor / …) | Yes | No | No | No |
| Live shell detach/reattach | v1.1 | No | Partial | Yes |

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

### v1.0.0 quality gate

See [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md) before tagging a release.

## Requirements

- macOS 14.0+
- Xcode 16+ / Swift 6.0

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Related: [experience modes](docs/MODES.md),
[migration](docs/MIGRATION.md), [reliability & security](docs/RELIABILITY.md),
[tmux parity](docs/TMUX_PARITY.md), [Ghostty comparison](docs/GHOSTTY_COMPARISON.md).

## Agent documentation

Coding agents: see [claude.md](claude.md) and [agents.md](agents.md) (identical handbook).

## License

MIT
