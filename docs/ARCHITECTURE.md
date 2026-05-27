# Harness Architecture

## Processes

- **Harness.app** — AppKit GUI: workspace sidebar, session sidebar, per-session tab bar, libghostty surfaces
- **HarnessDaemon** — Single source of truth for `layout.json` and IPC
- **harness-cli** — CLI client over `~/Library/Application Support/Harness/harness.sock`

## Session authority

All layout mutations (workspace/session/tab/split/select/notify) go through **HarnessDaemon**. The app calls `DaemonSessionService` and syncs snapshot on `NotificationBus.snapshotChanged`.

GUI terminals use libghostty `.exec` locally. Surface identity is unified via `HARNESS_SURFACE=<uuid>` in the shell environment.

## Packages

| Package | Role |
|---------|------|
| HarnessCore | Models, IPC, persistence, settings, notifications |
| HarnessTerminalKit | libghostty wrapper with delegates |
| HarnessDaemon | Session authority server |
| HarnessApp | macOS UI |

## v1.1 backlog

- Real PTY in daemon (C helper + host-managed libghostty)
- `harness-cli attach` for detach/reattach
- SSH workspaces, embedded browser, Sparkle updates
