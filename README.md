# Harness

Native macOS terminal for organizing AI agents and dev sessions — Ghostty rendering, cmux-style workspaces, harness-cli automation.

## Features

- GPU-accelerated terminals via [libghostty](https://github.com/Lakr233/libghostty-spm)
- Ghostty config import — same colors, opacity, blur, font, padding by default
- Workspaces + sidebar sessions + per-session tabs + horizontal/vertical splits
- Session layout persistence (daemon-owned JSON)
- **harness-cli** for automation and agent hooks
- **tmux-style commands**: `send-keys`, `capture-pane`, `kill-pane`, `resize-pane`, `zoom-pane`, `swap-pane`, `rename-tab`, `attach`
- **In-app prefix keymap** (default `Ctrl-A`) with cheatsheet (prefix `?`)
- Agent auto-detection (Codex / Claude Code / Cursor / Pi / Hermes / OpenClaw / Aider / Gemini / Goose) with per-agent dot color + sidebar chip
- Agent notifications (desktop + sidebar + pane rings), jump-to-waiting (`Cmd+Shift+U`) skips panes still generating
- One-line hook install: `harness-cli install-hooks <agent>`
- Command palette (`Cmd+K`), Settings (`Cmd+,`)
- 400+ color themes via GhosttyTheme

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
| GPU libghostty | Yes | Yes | Yes | N/A |
| Ghostty-config aware (theme/opacity/blur) | Yes | Yes | No | No |
| Workspaces + agent sidebar | Yes | Limited | Yes | DIY |
| harness-cli automation | Yes | No | Yes | Yes |
| tmux-style send-keys / capture-pane / resize-pane | Yes | No | Limited | Yes |
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

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Agent documentation

Coding agents: see [claude.md](claude.md) and [agents.md](agents.md) (identical handbook).

## License

MIT
