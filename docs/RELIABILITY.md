# Reliability, recovery, and security

Harness is built around one rule: **the daemon owns session truth, and clients are
disposable.** Harness.app, `harness-cli attach`, and a terminal `attach-window` are all just
clients. Any of them can quit or crash without taking your sessions with it.

## Daemon lifecycle

`HarnessDaemon` runs under a launchd user agent
(`~/Library/LaunchAgents/com.robert.harness.daemon.plist`) with `KeepAlive` set to respawn on
crash and at login. The GUI never starts or stops it on quit (`DaemonLauncher` only installs/
launches it if launchd is unavailable).

```bash
# Inspect / restart
launchctl print gui/$(id -u)/com.robert.harness.daemon
launchctl kickstart -k gui/$(id -u)/com.robert.harness.daemon
```

## Crash and restart behavior

| Event | Sessions | Scrollback | Notes |
|-------|----------|-----------|-------|
| **GUI quit (clean)** | Survive (ephemeral ones reaped — see [MODES.md](MODES.md)) | Survive | Daemon keeps running; relaunch reattaches and replays scrollback. |
| **GUI crash / force-quit** | All survive | Survive | Daemon untouched; the next *clean* quit reaps any ephemeral orphans. |
| **Daemon crash** | Recreated from `layout.json` on respawn (same surface IDs, cwd, shell) | In-memory scrollback is lost (ring buffer) | launchd respawns within ~5s (`ThrottleInterval`). |
| **Reboot / re-login** | Recreated from `layout.json` | Lost | `RunAtLoad` brings the daemon back. |

The session snapshot (`sessions/layout.json`) is written atomically and debounced (~0.5s).
On startup the daemon loads it and `ensureAllSnapshotSurfaces()` respawns a PTY for every
surface in the layout, so a relaunched daemon converges to the persisted topology.

## Corrupted-state recovery

A present-but-unparseable state file is **renamed `.corrupt`** rather than silently reset, so
nothing is lost and the daemon still starts:

- `layout.json` — backed up; the daemon seeds a fresh default workspace.
- `options.json` — backed up; defaults are used.
- `hooks.json` — backed up; hooks start empty.

Absent files are the normal first-run case and start from defaults silently (no `.corrupt`
artifact).

## Security model

- **Control socket** (`harness.sock`) is created `0o600` and `accept()` verifies the peer's
  euid via `getpeereid`, so only the owning user can drive the daemon (spawn PTYs, read pane
  output, run hook shell commands). The Harness home and its subdirectories are `0o700`; an
  older loose (`0o755`) home is tightened on the next launch.
- **IPC framing** is length-prefixed and bounded by `IPCCodec.maxPayloadLength` (16 MiB). An
  over-cap declared length throws so the reader drops the unrecoverable connection instead of
  mis-framing.
- **Escape-sequence parsing** caps OSC (1 MiB), CSI parameters (32), and intermediates (8) so
  hostile/buggy output can't grow parser memory without bound; the parser always recovers to
  ground (covered by `ParserRobustnessTests`).
- **No command injection from data.** The only shell execution is user-authored hook commands
  and `pipe-pane`, run via `/bin/sh -c <command>` with **no interpolation of terminal data** —
  the command string is the user's own config, never assembled from PTY bytes.
- **No secret logging.** `daemon.log` records only lifecycle events; PTY bytes, command lines,
  and pasted content are never logged. `pipe-pane` failures log the surface id, not the command.
- **Clipboard.** Program clipboard writes (OSC 52) are gated by the `set-clipboard` option.

## Benchmarks

Performance baselines for the hot paths (VT parse throughput, `readGrid` snapshot, scrollback
append/replay, IPC codec round-trip, compositor frame build) live in the `HarnessBenchmarks`
target. They're opt-in so a normal `swift test` stays fast:

```bash
HARNESS_BENCHMARKS=1 swift test --filter HarnessBenchmarks
```

Run under `xcrun xctest` (or Xcode) to track each `measure {}` against a stored baseline and
fail on regression.

## Malformed input

Beyond escape sequences and IPC framing, the deterministic suites cover malformed/edge input:
corrupt config recovery (`HookRegistryTests`, `OptionStore`), oversized IPC frames
(`IPCCodecTests`), empty/zero-workspace snapshots (`SessionSnapshot` repair), and key-token
parsing (`KeyTokenParserTests`).
