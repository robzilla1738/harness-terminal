# Harness

[![CI](https://github.com/robzilla1738/harness-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/robzilla1738/harness-terminal/actions/workflows/ci.yml)

The native macOS terminal that keeps your sessions running and tells you the moment a coding agent needs you.

Every pane renders on Harness's own GPU engine. Your splits and sessions live in a background daemon, so they survive quitting the app — and their scrollback survives a daemon restart. You can drive or attach to them from the command line, including a headless or remote daemon over SSH. And Harness watches the agents you run inside it (Claude Code, Codex, Cursor, and more), so an approval prompt never sits unseen behind another tab.

One self-contained app. The terminal engine, daemon, and CLI are all first-party Swift; the only external dependency is Sparkle (the macOS auto-update framework, GUI-only).

## Download

**[Download Harness for macOS →](https://github.com/robzilla1738/harness-terminal/releases/latest/download/Harness.dmg)**

Open the DMG, drag `Harness.app` to Applications, and launch it normally. The release is signed, notarized, and built for Apple silicon Macs running macOS 15 or later.

Verify the SHA-256 checksum against the value published on the [GitHub release page](https://github.com/robzilla1738/harness-terminal/releases/latest).

Prefer to build it yourself? Jump to [Build from source](#build-from-source).

## Why Harness

- **It's a real terminal first.** GPU rendering, accurate sRGB color by default, opt-in converted Display-P3 vivid color, ligatures, inline images (Sixel / Kitty / iTerm2), and 490 built-in themes with a muted Harness default. Block and box-drawing glyphs are drawn procedurally, so borders tile without seams at any font.
- **Your work outlives the window.** Sessions, tabs, and splits are owned by a daemon. Quit and reopen and everything is exactly where you left it, scrollback included — history is persisted to disk and restored even if the daemon restarts. Attach the same session from a second window or another machine.
- **It's scriptable, locally or remotely.** `harness-cli` drives the whole thing — open tabs, send keys, capture a pane, resize, swap, zoom — so your tooling can build the layout it needs. Point any command at a headless or remote daemon with `--host <name>`; the daemon and CLI run on Linux too, so a remote box can host your sessions.
- **It watches your agents.** Harness detects Claude Code, Codex, Cursor, and others by their process tree, shows which session is running what, and pings you when an agent stops or asks for approval. `Cmd+Shift+U` jumps you to the one that's waiting and skips the ones still thinking.

## How it feels

Harness ranges from a plain, get-out-of-your-way terminal to a full session manager. Pick the level in **Settings → Terminal → Experience**:

- **Plain Terminal** — fast and quiet. No command prefix, no status bar. Sessions close when you quit, like any terminal.
- **Persistent Terminal** — the same clean look, but sessions survive quitting and you can attach to them from the CLI.
- **Full Terminal** — everything: command prefix, status line, copy mode, paste buffers, panes, and the full `harness-cli` command set.
- **Agent Workspace** — persistent project workspaces with agent detection and notifications turned up front.

New installs start in Plain. Moving over from another setup? See [docs/MIGRATION.md](docs/MIGRATION.md) — Harness can import an existing terminal config (colors, font, padding) on first run.

## Features

- GPU-accelerated rendering by Harness's own terminal engine — accurate sRGB output by default, opt-in converted Display-P3 vivid color, a themed translucent canvas, and program output left untouched unless you opt into theme recoloring; damage-driven redraws keep selection drags, find highlights, IME composition, and streaming output cheap, full-rate on ProMotion displays, and covered or minimized windows stop rendering entirely
- Mainstream-GPU-terminal polish: live re-wrap while resizing (with a grid-size overlay), word / line / block selection, middle-click paste, alternate-screen wheel scrolling, focus reporting, hollow unfocused cursor, minimum contrast, auto light/dark themes, bold-is-bright control, and paste protection
- Quick terminal: a Quake-style dropdown on a global hotkey (Settings ▸ Keys), sliding over whatever app is frontmost and persisting like any other session
- Terminal bell (`\a`): audible and/or visual feedback on the focused surface, a bell badge on background tabs, and tmux `visual-bell`/`bell-action` bridging
- Find bar (⌘F) with regular-expression and case-sensitivity toggles; matches highlight across scrollback
- Sidebar sessions, per-session tabs, and horizontal / vertical splits — group sessions with shared window lists
- Session layout persists across quits (daemon-owned, attach from the CLI or over SSH); if the daemon restarts under a pane, a quiet "Reconnecting…" chip rides the ~1-minute automatic backoff before the click-to-re-grab overlay takes over
- Persistent scrollback: a pane's history is written to disk per surface and restored when the daemon restarts — set the scrollback limit to 0 for unlimited history (disk-capped only)
- Remote & headless daemon: run `HarnessDaemon` on a headless or remote box (Linux included) and drive it with `harness-cli --host <name>` over an SSH tunnel — register hosts with `harness-cli remote add`
- `harness-cli` for automation and agent hooks
- Color/theme diagnostics from the CLI: `harness-cli color-check` and `harness-cli theme-preview --theme <name>` print deterministic SGR pages for eyeballing fidelity in Harness itself
- Command set: `send-keys`, `capture-pane`, `kill-pane`, `resize-pane`, `zoom-pane`, `swap-pane`, `rename-tab`, `attach`, `find-window`, `kill-server`, `start-server`, `respawn-window`, `refresh-client`, and more
- Command prefix keymap (default `Ctrl-A`) with a live cheatsheet (prefix `?`)
- Agent detection for Claude Code, Codex, Cursor, Grok, Pi, Hermes, OpenClaw, OpenCode, Aider, Gemini, and Goose — each with a brand color and a sidebar chip
- Agent alerts as desktop banners and a sidebar bell; `Cmd+Shift+U` jumps to whoever is waiting
- One-line hook install: `harness-cli install-hooks <agent>`
- Command palette (`Cmd+K`) and a native macOS Settings window (`Cmd+,`)
- 490 built-in color themes with a muted Harness default, plus `.harnesstheme` export / import for sharing — double-click (or Open With) a theme file to install it, optionally applying its colors immediately
- Shell integration (OSC 133), auto-injected at spawn for bash / zsh / fish: prompt marks for jump-to-prompt and a command success / failure gutter, no install step (opt out with `set-option shell-integration off`; manual snippets remain in [docs/shell-integration/](docs/shell-integration/README.md))
- Inline images that stay put across reflow and scroll into history
- Drag file-backed folders or images into a pane to insert shell-quoted paths
- Set Harness as the default terminal for SSH/Telnet/man-page links and `.command` / `.tool` files from Settings > Terminal
- Automatic, signed background updates (Sparkle + EdDSA)

## harness-cli

Harness launches its daemon automatically; the CLI talks to it.

```bash
harness-cli list-surfaces
harness-cli new-session --workspace Default --cwd ~/Code/myproject
harness-cli new-tab --workspace Default --cwd ~/Code/myproject
harness-cli send-keys --surface "$HARNESS_SURFACE" --keys "ls -la Enter"
harness-cli notify --surface "$HARNESS_SURFACE" --title Agent --body "Needs approval"
harness-cli color-check
harness-cli theme-preview --theme "Harness Default"
```

Install it onto your `PATH`:

```bash
# From the app bundle:
/Applications/Harness.app/Contents/MacOS/harness-cli install

# Or from a source build:
.build/release/harness-cli install

# Then add the printed path to your shell profile:
export PATH="$HOME/Library/Application Support/Harness/bin:$PATH"
```

The first-run setup in `Harness.app` performs the same local installation for new
users: it copies `harness-cli` and `HarnessDaemon`, registers the LaunchAgent,
adds PATH blocks for zsh/bash/fish with backups, installs fish completions, asks
for notification permission, and offers detected agent hooks. On a fresh install, Harness displays
a one-shot welcome tour; after an update, it shows release highlights (suppressible via the `update-banner` option).

## Remote & headless daemons

`HarnessDaemon` can run on a headless box (no GUI) or a remote machine — including
Linux — and you can drive it from any `harness-cli` command with a global
`--host <name>` flag. The transport is an SSH tunnel that forwards the remote
daemon's control socket, so it reuses your existing SSH trust with no new
credentials.

```bash
# On the remote box: run the daemon and note its socket path (harness-cli doctor prints it).
# On your machine: register the remote, then target it with --host on any command.
harness-cli remote add --name devbox --ssh me@devbox --socket "/home/me/.config/harness/harness.sock"
harness-cli remote list
harness-cli ping --host devbox
harness-cli new-session --host devbox --cwd ~/Code
harness-cli send-keys --host devbox --surface <id> --keys "ls -la Enter"
harness-cli capture-pane --host devbox --surface <id>
harness-cli remote remove --name devbox
```

Pass extra SSH options (port, identity file, jump host) with `--ssh-arg`, e.g.
`--ssh-arg -p --ssh-arg 2222 --ssh-arg -i --ssh-arg ~/.ssh/devbox`.

## Agent hooks

`HARNESS_SURFACE` is set in every Harness pane, so an agent can ping the exact tab it's running in:

```bash
harness-cli install-hooks claude-code
harness-cli notify --surface "$HARNESS_SURFACE" --body "Approval required"
```

Per-agent setup lives in [docs/agent-hooks/README.md](docs/agent-hooks/README.md). Agents without a hook mechanism still notify you through Harness's built-in activity detection once they're running.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| New tab | `Cmd+T` |
| New session | `Cmd+Shift+N` |
| Close tab | `Cmd+W` |
| Split horizontal / vertical | `Cmd+D` / `Cmd+Shift+D` |
| Switch to tab 1–9 | `Cmd+1` … `Cmd+9` |
| Previous / next tab | `Cmd+Shift+[` / `Cmd+Shift+]` |
| Jump to waiting agent | `Cmd+Shift+U` |
| Command palette | `Cmd+K` |
| Settings | `Cmd+,` |
| Toggle sidebar | `Cmd+\` |

The command prefix (default `Ctrl-A`) adds the full pane / session keymap on top — press prefix then `?` for the cheatsheet.

## Build from source

```bash
git clone https://github.com/robzilla1738/harness-terminal.git harness
cd harness
make release
open Harness.app
```

Validate a source checkout before shipping changes:

```bash
swift build
swift test                              # fast, deterministic suite
HARNESS_LIVE_DAEMON_TESTS=1 swift test  # adds the real socket / PTY / security tests
make bench
```

CI runs all three on every push: the deterministic suite, the live daemon tests, and a release build. The live tests spin up a real daemon over a Unix socket and a real PTY, so run them locally before changing the daemon, IPC, or PTY code.

`make bench` runs opt-in release benchmarks and prints machine-readable JSON timing lines. Treat those as a structural baseline, not a pass/fail gate — GPU and timing numbers vary by machine.

Renderer tests use structural offscreen readbacks by default. Set `HARNESS_WRITE_RENDER_SNAPSHOTS=1` when running `swift test --filter MetalRendererTests` to write PNGs under `/tmp/HarnessRenderSnapshots` for human debugging only.

### Develop in Xcode

`Harness.xcodeproj` is generated from `project.yml` with XcodeGen. The app target builds and bundles `HarnessDaemon` and `harness-cli` into `Harness.app/Contents/MacOS/`, so an Xcode run uses the same helper layout as the release app.

```bash
xcodegen generate
open Harness.xcodeproj
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build test
```

## Requirements

- Apple silicon Mac running macOS 15.0 or later for the downloadable DMG
- Xcode 16+ / Swift 6.0 (to build from source)
- For a headless/remote daemon: any machine with Swift 6.0 (macOS or Linux) — build the daemon + CLI with `swift build -c release` (the GUI app, renderer, and Sparkle are macOS-only and are dropped from the Linux build)

## Documentation

- [Experience modes](docs/MODES.md) — Plain / Persistent / Full / Agent
- [Sessions & panes guide](docs/MULTIPLEXER_GUIDE.md) — prefix, panes, sessions, copy mode, attach from anywhere
- [tmux parity ledger](docs/TMUX_PARITY.md) — capability status, adaptations for the daemon-owned model, explicitly rejected tmux features with rationale
- [tmux-style capabilities PDF](docs/HARNESS_TMUX_CAPABILITIES.pdf) — printable setup, shortcuts, commands, attach, copy mode, and troubleshooting
- [Release runbook](docs/RELEASE.md) — signed/notarized DMG, GitHub Actions release workflow, and Sparkle appcast publishing
- [Migration](docs/MIGRATION.md) — bringing your config and habits across
- [Keybindings](docs/KEYBINDINGS.md) · [Commands](docs/COMMANDS.md) · [Shell integration](docs/shell-integration/README.md) · [Agent hooks](docs/agent-hooks/README.md)
- [Changelog](CHANGELOG.md) — release history
- [Third-party notices](docs/THIRD-PARTY-NOTICES.md)

## License

MIT
