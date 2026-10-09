# Harness

[![CI](https://github.com/robzilla1738/harness-terminal/actions/workflows/ci.yml/badge.svg)](https://github.com/robzilla1738/harness-terminal/actions/workflows/ci.yml)

The native macOS terminal that keeps your sessions running and tells you the moment a coding agent needs you.

Every pane renders on Harness's own GPU engine. Your splits and sessions live in a background daemon, so they can survive quitting the app when persistence is enabled — and retained scrollback can be replayed after a daemon restart. You can drive or attach to them from the command line, including a headless or remote daemon over SSH. And Harness watches the agents you run inside it (Claude Code, Codex, Cursor, and more), with optional hooks and program reports to surface requests for attention behind other tabs.

One self-contained app. The terminal engine, daemon, and CLI are first-party Swift. Sparkle is the only Swift package dependency, and only the GUI links it. Lua 5.1 is vendored and linked by the CLI alone. The daemon does not link Lua.

## Download

**Harness 2.1** adds secure QR setup for the iPhone and iPad companion, LAN/Tailscale
connection guidance, and terminal-input refinements. Saved layouts, broader search, native
color emoji, and the full changes are documented in the [changelog](CHANGELOG.md).
See the [release-readiness review](docs/RELEASE-READINESS-2026-10-09.md) and
[performance results](docs/SCORECARD.md) for measured results and remaining acceptance work.

**[Download Harness for macOS →](https://github.com/robzilla1738/harness-terminal/releases/latest/download/Harness.dmg)**

Open the DMG, drag `Harness.app` to Applications, and launch it normally. The release is signed, notarized, and built for Apple silicon Macs running macOS 15 or later.

Verify the SHA-256 checksum against the value published on the [GitHub release page](https://github.com/robzilla1738/harness-terminal/releases/latest).

Prefer to build it yourself? Jump to [Build from source](#build-from-source).

## Why Harness

- **It's a real terminal first.** GPU rendering, accurate sRGB color by default, opt-in converted Display-P3 vivid color, ligatures, native color emoji, inline images (Sixel / Kitty / iTerm2), and 514 bundled themes, including 25 original Harness palettes and black and light defaults. Block and box-drawing glyphs are drawn procedurally, so borders tile without seams at any font.
- **Your work outlives the window.** Sessions, tabs, and splits are owned by a daemon. Quit and reopen to resume them, scrollback included. Retained output and its resize history are persisted for replay after a daemon restart. Older logs use the legacy replay path; see the [restoration limits](docs/RELEASE-READINESS-2026-10-09.md). Attach the same session from a second window or another machine.
- **It's scriptable, locally or remotely.** `harness-cli` drives the whole thing — open tabs, send keys, capture a pane, resize, swap, zoom — so your tooling can build the layout it needs. Point any command at a headless or remote daemon with `--host <name>`; the daemon and CLI run on Linux too, so a remote box can host your sessions.
- **It watches your agents.** Harness detects Claude Code, Codex, Cursor, and others by their process tree, shows which session is running what, and pings you when an agent stops or asks for approval. `Cmd+Shift+U` jumps you to the one that's waiting and skips the ones still thinking.

## How it feels

Harness ranges from a plain, get-out-of-your-way terminal to a full session manager. Pick the level in **Settings → Terminal → Experience**:

- **Plain Terminal** — fast and quiet. No command prefix, no status bar. The preset turns off global persistence; unpinned sessions close on a clean quit unless you enable Keep sessions running.
- **Persistent Terminal** — the same clean look, but sessions survive quitting and you can attach to them from the CLI.
- **Full Terminal** — everything: command prefix, status line, copy mode, paste buffers, panes, and the full `harness-cli` command set.
- **Agent Workspace** — persistent project workspaces with agent detection and notifications turned up front.

These are presets: the **Keep sessions running** setting and per-session pins determine actual quit behavior. See [Experience modes](docs/MODES.md).

New installs start in Persistent: the quiet look, and sessions survive quitting. An existing settings file that never stored a mode stays Full, so an upgrade does not hide the prefix or the status line. Moving over from another setup? See [docs/MIGRATION.md](docs/MIGRATION.md) — Harness can import an existing terminal config (colors, font, padding) on first run.

## Workspace workflows

**Session → Activity**, **Saved Setups**, **Recently Closed**, and **Search All Sessions** bring ongoing work together across attached hosts. The command palette also exposes these actions. See [Workspace workflows](docs/WORKSPACE-WORKFLOWS.md) for behavior, limits, and CLI examples.

## Features

- GPU-accelerated rendering by Harness's own terminal engine — accurate sRGB output by default, opt-in converted Display-P3 vivid color, a themed translucent canvas, and program output left untouched unless you opt into theme recoloring; damage-driven redraws keep selection drags, find highlights, IME composition, and streaming output cheap, full-rate on ProMotion displays, and covered or minimized windows stop rendering entirely
- Mainstream-GPU-terminal polish: live re-wrap while resizing (with a grid-size overlay), word / line / block selection, middle-click paste, alternate-screen wheel scrolling, focus reporting, hollow unfocused cursor, minimum contrast, follow-macOS appearance with separate light and dark theme picks (Settings ▸ Appearance), bold-is-bright control, and paste protection
- Quick terminal: a Quake-style dropdown on a global hotkey (Settings ▸ Keys), sliding over whatever app is frontmost and persisting like any other session
- Terminal bell (`\a`): audible and/or visual feedback on the focused surface, a bell badge on background tabs, and tmux `visual-bell`/`bell-action` bridging
- Find bar (⌘F) with regular-expression and case-sensitivity toggles; matches highlight across scrollback
- Title-bar tabs level with the traffic lights, each with an app tile (`>_` for a shell, the brand tile for an agent) and a live status mark (working, needs you, done, error). `⌘\` switches to sidebar mode, which lists every session by name with its tabs beneath
- A sessions popover (`⌃⌘S`, or the stacked-squares button): filter or create a session by typing, ✓ on the current one, New Session, Add Remote Host
- Every pane is an inset card with a header (identity, split-right / split-down; double-click to zoom), horizontal / vertical splits, and grouped sessions with shared window lists
- Workspace Overview (`⌘⇧O`): every tab as a live tile, the ones waiting on you first; type to filter, arrows and ↩ to jump
- Session layout persists across quits (daemon-owned, attach from the CLI or over SSH); if the daemon restarts under a pane, a quiet "Reconnecting…" chip rides the ~1-minute automatic backoff before the click-to-re-grab overlay takes over
- Persistent scrollback: a pane's history is written to disk per surface and restored when the daemon restarts — set the scrollback limit to 0 to remove the line cap. Raw output and decoded history each have a separate 512 MiB ceiling; active grids, snapshots, and rendering caches are additional memory. Wide rows may reach the decoded ceiling sooner
- Remote & headless daemon: run `HarnessDaemon` on a headless or remote box (Linux included) and drive it with `harness-cli --host <name>` over your own SSH. Add Remote Host… needs only the SSH destination: it detects the daemon socket and tests the connection, and a dropped tunnel reconnects itself
- `harness-cli` for automation and agent hooks: `run --wait -- make test` exits with the command's status, targets take names, positions, or ID fragments (`--surface 2`, `--tab logs`), and exit statuses are documented (3 = no such target, 4 = daemon unreachable)
- Color/theme diagnostics from the CLI: `harness-cli color-check` and `harness-cli theme-preview --theme <name>` print deterministic SGR pages for eyeballing fidelity in Harness itself
- Command set: `send-keys`, `capture-pane`, `kill-pane`, `resize-pane`, `zoom-pane`, `swap-pane`, `rename-tab`, `attach`, `find-window`, `kill-server`, `start-server`, `respawn-window`, `refresh-client`, and more
- Command prefix keymap (default `Ctrl-A`) with a live cheatsheet (prefix `?`)
- Detection and sourced identities for 23 coding CLIs, including Claude Code, Codex, Cursor, Gemini, Copilot, Amp, Aider, OpenCode, Pi, and more. Compact fixed-brand badges replace agent color customization; see the [complete identity catalog and source notices](Apps/Harness/Resources/AgentLogos/README.md). Detection is separate from per-tool hook support
- Agent alerts as desktop notifications and a notification bell, with a switch per event in Settings ▸ Notifications (needs you, finished, failed, bell, long command finished); `Cmd+Shift+U` jumps to whoever is waiting
- One-line hook install: `harness-cli install-hooks <agent>`
- Command palette (`Cmd+K`) and a native macOS Settings window (`Cmd+,`)
- 514 bundled color themes, including 25 original Harness palettes: Graphite as the new-install default, pure-black Harness Obsidian, blue-teal Harness Deep Sea, Harness Navy, and eight light options, plus `.harnesstheme` export / import for sharing — double-click (or Open With) a theme file to install it, optionally applying its colors immediately. Settings ▸ Colors ▸ Theme saves the colors on screen as a named theme or exports them; saved and imported themes list in the theme menu
- Shell integration (OSC 133), auto-injected at spawn for bash / zsh / fish: prompt marks for jump-to-prompt and a command success / failure gutter, no install step (opt out with `set-option shell-integration off`; manual snippets remain in [docs/shell-integration/](docs/shell-integration/README.md))
- Inline images that stay put across reflow and scroll into history
- Cursor-anchored Insert Path popup (`⌥⌘I`) with Folder/Project fuzzy search, keyboard navigation, and shell-quoted insertion; drag file-backed folders or images into a pane to insert paths
- Set Harness as the default terminal for SSH/Telnet/man-page links and `.command` / `.tool` files from Settings > Terminal
- Automatic, signed background updates (Sparkle + EdDSA)
- Program status (OSC 7501): a pane can report working, blocked, done, or error, and that mark shows on the tab, the session row, and ⌘⇧U. See [docs/PROGRAM-STATUS.md](docs/PROGRAM-STATUS.md)
- `harness-cli api` for a JSON method list, schemas, and calls, plus `events --follow` for a live event stream
- Lua 5.1 config at `~/.config/harness/init.lua` (`HARNESS_CONFIG` overrides the path). It runs in the CLI. The daemon does not run it
- Two pane densities (comfortable cards with headers, or compact 1-point borders), lighter translucent panes against darker chrome, and automatic contrast correction on a light canvas
- Fresh windows target 100 columns × 30 rows using the configured font and padding. Size/position memory defaults on and preserves saved sizes. An optional machine indicator defaults off in Settings → Appearance
- Several machines at once: each remote host opens in its own window next to your local ones, all live, and the sidebar groups every machine's sessions. Each attach is your SSH tunnel to that daemon

## harness-cli

Harness launches its daemon automatically; the CLI talks to it.

```bash
harness-cli list-surfaces
harness-cli new-session --workspace Default --cwd ~/Code/myproject
harness-cli new-tab --workspace Default --cwd ~/Code/myproject
harness-cli send-keys --surface "$HARNESS_SURFACE" --keys "ls -la Enter"
harness-cli notify --surface "$HARNESS_SURFACE" --title Agent --body "Needs approval"
harness-cli color-check
harness-cli theme-preview --theme "Harness Graphite"
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

On a fresh install, `Harness.app` opens a one-shot first-run tour (Welcome → Overview →
Notifications → Command line → Ready; reopen it from Help ▸ Welcome to Harness). Its
Notifications step offers permission and agent-hook installation as separate optional
actions. Skipping setup never prompts later just because an agent event arrives. Its optional Command line step performs the same local installation:
it copies `harness-cli` and `HarnessDaemon`, registers the LaunchAgent only when none is
working (so the daemon your sessions run in keeps running), adds a PATH block with a backup
to the shells you use (your login shell plus any shell that already has a profile), and
writes fish completions when fish is one of them. It respects `ZDOTDIR` and
`XDG_CONFIG_HOME`, preserves existing bash login profiles and dotfile symlinks, and reports
unreadable profiles without replacing them. Isolated preview builds leave system
permissions, shell profiles, agent settings, and the regular installation unchanged.
After an update, Harness shows release
highlights (suppressible via the `update-banner` option).

## Remote & headless daemons

`HarnessDaemon` can run on a headless box (no GUI) or a remote machine — including
Linux — and you can drive it from any `harness-cli` command with a global
`--host <name>` flag. The transport is an SSH tunnel that forwards the remote
daemon's control socket, so it reuses your existing SSH trust with no new
credentials.

```bash
# On the remote box: run the daemon. `harness-cli socket-path` there prints its socket.
# On your machine: register the remote, then target it with --host on any command.
harness-cli remote add --name devbox --ssh me@devbox --socket "$(ssh me@devbox harness-cli socket-path)"
harness-cli remote list
harness-cli ping --host devbox
harness-cli new-session --host devbox --cwd ~/Code
harness-cli send-keys --host devbox --surface <id> --keys "ls -la Enter"
harness-cli capture-pane --host devbox --surface <id>
harness-cli remote remove --name devbox
```

Pass extra SSH options (port, identity file, jump host) with `--ssh-arg`, e.g.
`--ssh-arg -p --ssh-arg 2222 --ssh-arg -i --ssh-arg ~/.ssh/devbox`.

### Connect an iPhone or iPad

With SSH enabled and Harness 2.1 or later installed, enter `/remote` in Harness’s command prompt or choose **Connect Phone or iPad** in the command palette. In a shell, run `harness-cli pair`. Scan the compact QR code in the [native iOS companion](https://github.com/robzilla1738/harness-ios), verify the computer, and enter your account password once to install a device key. The code contains public metadata only.

The Mac pairing window offers discovered LAN addresses, connected Tailscale addresses, **Set Up Tailscale**, and **Refresh**. Use the same tailnet on both devices for access away from home; ordinary SSH/Remote Login permissions still apply. Custom addresses and ports use `harness-cli pair --host reachable-hostname --port 22`. See [mobile connection and troubleshooting details](docs/MOBILE-BRIDGE.md#pairing-and-files).

The companion groups work by host, workspace and session, uses the shared terminal engine and Metal renderer, includes touch scrolling and terminal shortcuts, and supports up to four visible panes on iPad. Its current distribution is source/development builds; an App Store release is not included in this terminal release.

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
| New window | `Cmd+N` |
| New tab | `Cmd+T` |
| New session | `Cmd+Shift+N` |
| Close pane (the tab when it's the only pane) / close tab | `Cmd+W` / `Option+Cmd+W` |
| Split horizontal / vertical | `Cmd+D` / `Cmd+Shift+D` |
| Select pane by direction | `Option+Cmd+Arrow` |
| Previous / next pane | `Cmd+[` / `Cmd+]` |
| Zoom pane / equalize splits | `Shift+Cmd+Return` / `Ctrl+Cmd+=` |
| Switch to tab 1–9 | `Cmd+1` … `Cmd+9` |
| Previous / next tab | `Cmd+Shift+[` / `Cmd+Shift+]` |
| Jump to waiting agent | `Cmd+Shift+U` |
| Tab peek / Workspace Overview | `Ctrl+Cmd+P` / `Cmd+Shift+O` |
| Switch session | `Ctrl+Cmd+S` |
| Find / next / previous | `Cmd+F` / `Cmd+G` / `Cmd+Shift+G` |
| Reopen closed tab | `Cmd+Shift+T` |
| Go to directory | `Option+Cmd+G` |
| Every shortcut, searchable | `Cmd+/` |
| Command palette | `Cmd+K` |
| Settings | `Cmd+,` |
| Toggle sidebar | `Cmd+\` |

The command prefix (default `Ctrl-A`, on in the Full preset) adds the full tmux-style pane / session keymap on top — press prefix then `?` for its cheatsheet.

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

CI (on pushes to `main` and on pull requests) builds debug and release and runs the whole suite with the live daemon tests switched on, on `macos-26` with Xcode 26.6, the same toolchain releases are built with. It also builds `Harness.xcodeproj`, and builds and tests the headless daemon and CLI on Linux (Swift 6.0; advisory for now). The live tests spin up a real daemon over a Unix socket and a real PTY, so run them locally before changing the daemon, IPC, or PTY code.

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
- Xcode 26.6 or later (to build from source; CI and releases use 26.6)
- For a headless/remote daemon: any machine with Swift 6.0 (macOS or Linux) — build the daemon + CLI with `swift build -c release` (the GUI app, renderer, and Sparkle are macOS-only and are dropped from the Linux build)

## Documentation

- [Experience modes](docs/MODES.md) — Plain / Persistent / Full / Agent
- [Sessions & panes guide](docs/MULTIPLEXER_GUIDE.md) — prefix, panes, sessions, copy mode, attach from anywhere
- [Harness and Rex](docs/COMPARISON.md) — an honest feature comparison, including what's not planned
- [tmux parity ledger](docs/TMUX_PARITY.md) — capability status, adaptations for the daemon-owned model, explicitly rejected tmux features with rationale
- [tmux-style capabilities PDF](docs/HARNESS_TMUX_CAPABILITIES.pdf) — printable setup, shortcuts, commands, attach, copy mode, and troubleshooting
- [Release runbook](docs/RELEASE.md) — signed/notarized DMG, GitHub Actions release workflow, and Sparkle appcast publishing
- [Migration](docs/MIGRATION.md) — bringing your config and habits across
- [Keybindings](docs/KEYBINDINGS.md) · [Commands](docs/COMMANDS.md) · [Program status](docs/PROGRAM-STATUS.md) · [Shell integration](docs/shell-integration/README.md) · [Agent hooks](docs/agent-hooks/README.md)
- [Changelog](CHANGELOG.md) — release history
- [Third-party notices](docs/THIRD-PARTY-NOTICES.md)

## License

MIT
