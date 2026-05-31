# Harness Architecture

Harness is a native macOS terminal **and** multiplexer in one self-contained,
dependency-free Swift codebase — `swift build` resolves **zero** external packages.
The GPU terminal, the theme system, the session multiplexer, and the automation CLI
are all first-party.

## Processes

- **Harness.app** — AppKit GUI: workspace sidebar, session sidebar, per-session tab bar,
  and native Metal terminal surfaces (`HarnessTerminalSurfaceView`). A thin client over the
  daemon.
- **HarnessDaemon** — the single source of truth. Owns the real PTYs (`RealPty`), the child
  processes, scrollback, resize, attach/detach, hooks, options, and the persisted session
  layout. Runs under launchd `KeepAlive`, so sessions survive an app quit or crash.
- **harness-cli** — CLI client over `~/Library/Application Support/Harness/harness.sock`.
  Also hosts the `attach` / `attach-window` compositor and control mode (`-CC`).

## Session authority

All layout mutations (workspace / session / tab / split / select / notify) flow through
**HarnessDaemon**. `SurfaceRegistry` is the only writer of the on-disk layout; the app and
CLI are clients that subscribe to snapshot pushes (`NotificationBus.snapshotChanged`) rather
than polling. Surface identity is unified via `HARNESS_SURFACE=<uuid>` in every pane's shell
environment.

One command vocabulary drives every front-end: `Command` → `CommandParser` →
`CommandIPCTranslator` → `IPCRequest` → `SurfaceRegistry` / `SessionEditor`. The GUI, CLI,
ssh compositor, control mode, and hooks all share that single translator, so no front-end is
special-cased and `-t session:window.pane` targets resolve once, centrally.

## Native terminal stack

The terminal is rendered by Harness's own stack — there is **no Ghostty / libghostty
dependency**. `TerminalHostView` hosts `HarnessTerminalSurfaceView` (a `CAMetalLayer` view)
driving the engine, theme, and renderer modules below.

| Module | Path | Role |
|--------|------|------|
| `HarnessCore` | `Packages/HarnessCore` | Models, IPC, persistence, settings, options, keybindings, command parsing, notifications |
| `HarnessTerminalEngine` | `Packages/HarnessTerminalEngine` | VT100/220/xterm parser (CSI/OSC/SGR + colon subparams), screen model (alt screen, scroll regions, autowrap, UTF-8/wide-char), scrollback, `HarnessGridTerminal` headless `readGrid`, `TerminalEmulator`, `InputEncoder`, image protocols (Sixel / Kitty / iTerm2) |
| `HarnessTheme` | `Packages/HarnessTheme` | `RGBColor`, theme definitions, the 485-theme catalog, and the `.harnesstheme` document format (export / import / install) |
| `HarnessTerminalRenderer` | `Packages/HarnessTerminalRenderer` | ANSI palette + cell-color resolution (pure Swift) and a Metal glyph/draw layer (CoreText atlas, instanced background + glyph + decoration + image passes) |
| `HarnessCopyMode` | `Packages/HarnessCopyMode` | UI-agnostic copy-mode model (state + pure reducer over the engine grid); drives copy mode in both the GUI overlay and the ssh compositor |
| `HarnessTerminalKit` | `Packages/HarnessTerminalKit` | Hosts the surface view, the `attach-window` `GridCompositor`, and wires the engine/renderer/theme into AppKit |
| `HarnessDaemon` | `Packages/HarnessDaemon` | Session-authority server: PTYs, layout, IPC, hooks, options |

The terminal canvas is themed and translucent, while program output keeps untouched ANSI
colors unless `applyThemeToTerminalOutput` is on. Block elements and box-drawing are rendered
**procedurally** (font-independent, seamless). The renderer also implements synchronized
output (DEC 2026), DECSCUSR cursor shapes, OSC 8 hyperlinks + URL auto-detect, dynamic-color
queries, the Kitty keyboard protocol, and inline images.

## Multiplexer & attach

`harness-cli attach-window` renders a tab's full split layout (every pane, borders, status
line, active-pane cursor, copy mode, SGR mouse) into any plain terminal — including over ssh.
`DaemonServer` records each client's requested PTY size per surface and resizes to the
**smallest** (multi-client `window-size smallest`). Control mode (`-CC`) bridges the same
command surface over stdio. See the [multiplexer guide](TMUX_GUIDE.md) for the full surface.

## Migration paths (first-party, opt-in)

- **Themes / config from Ghostty.app** — `TerminalConfigImporter` reads `~/.config/ghostty`
  so migrating users keep their colors, palette, font face, opacity, blur, and padding. Kept
  by product decision; nothing else depends on it. See [MIGRATION.md](MIGRATION.md).
- **tmux muscle memory** — Multiplexer mode exposes a prefix key, status line, copy
  mode, buffers, and `-t` targets, with a `source-file` path for bindings. See
  [MODES.md](MODES.md) and [MIGRATION.md](MIGRATION.md).

## Related docs

- [MODES.md](MODES.md) — experience modes (Plain / Persistent / Multiplexer / Agent) + persistence
- [MIGRATION.md](MIGRATION.md) — migrating from tmux or another terminal
- [TMUX_GUIDE.md](TMUX_GUIDE.md) — multiplexer guide (prefix, panes, sessions, copy mode)
- [RELIABILITY.md](RELIABILITY.md) — reliability & security model
- [COMMANDS.md](COMMANDS.md) / [KEYBINDINGS.md](KEYBINDINGS.md) — command + key reference
