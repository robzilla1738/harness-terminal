# Handoff — Notification system fix (Claude Code + agent hooks + onboarding)

**Branch:** `claude/notification-system-reliability-UNz92`
**Status:** Code complete, committed, and pushed. **Not yet compiled or tested** —
the work was done in a Linux container with no Swift toolchain (this is a
macOS-only project: AppKit / UserNotifications / Metal). You must build and run
the tests on a Mac before merging. See [Build & verify](#build--verify) below.

---

## Why this change

Notifications "weren't working." Root cause: the **Claude Code `Notification`
hook** was installed as

```
harness-cli notify … --body "$HARNESS_NOTIFY_MESSAGE"
```

but `$HARNESS_NOTIFY_MESSAGE` **is never set anywhere**. Claude Code passes the
notification message as **JSON on the hook's stdin**, not via an env var, so the
body always expanded to empty — every Claude Code banner fired blank, which reads
as "broken."

A full audit of the other installable agents found only Claude Code was actually
broken. Pi/Hermes/OpenClaw worked but showed a generic "Agent / Needs attention"
(no `--title`); Codex and Cursor already delivered non-empty bodies.

---

## What changed

### 1. Read the hook message from stdin (the core fix)
- **`Packages/HarnessCore/Sources/HarnessCore/Agents/HookNotificationParser.swift`** *(new)*
  Parses a hook's stdin JSON (`message`, `cwd`) and resolves the final body
  (`message` → `--body` fallback → `"Needs attention"`). Returns `nil` on empty /
  invalid input — never throws or blocks.
- **`Tools/harness/Sources/HarnessCLI/HarnessCLI.swift`** (`case "notify"`)
  New `--from-hook` flag: reads stdin and uses the parsed message. Gated behind an
  explicit flag (same pattern as the existing `set-buffer --stdin`) so an
  interactive `notify` can never hang on `readDataToEndOfFile`.
- **`AgentHookInstaller.swift`** — Claude Code's `Notification` payload now uses
  `notifyFromHookCommand(title:)` → `… --title "Claude Code" --from-hook`.

### 2. Self-healing install (migration for existing users)
- **`AgentHookInstaller.install`** now calls `pruneStaleHarnessHooks(_:for:)`
  before merging. It removes Harness-owned entries (command contains the
  `harness-cli notify` marker) from the events Harness manages
  (`Notification`/`Stop` for Claude, `PermissionRequest`/`Stop` for Codex), then
  re-adds the current canonical payload. Because `JSONMerge.deepMerge` **unions**
  arrays, without this a re-install would append a *second* (duplicate) hook.
  Now re-running `install-hooks` / the Settings "Reinstall hooks" button upgrades
  an existing broken config to exactly one correct hook, while preserving every
  non-Harness key (`model`, `permissions`, `mcp`), other events, and the user's
  own hook entries.

### 3. Agent audit
- Pi / Hermes / OpenClaw payloads now pass `--title "Pi"/"Hermes"/"OpenClaw"` so
  banners identify the agent. Codex / Cursor unchanged (already correct).

### 4. New-user onboarding (auto-detect + offer)
- **`AgentHookInstaller.detectInstalledAgents(homeOverride:table:)`** *(new)* —
  returns installable agents whose CLI is on `$PATH` or whose config dir exists.
- **`OnboardingEnvironment.swift`** *(new, in HarnessOnboarding)* — a small
  injection seam (two closures + an `Agent` value type). The onboarding module is
  **deliberately isolated from HarnessCore** (see the comment on its target in
  `Package.swift`), so instead of adding a core dependency, `HarnessApp` injects
  the real implementations.
- **`Apps/Harness/Sources/HarnessApp/UI/OnboardingController.swift`** —
  `configureEnvironment()` wires the seam to `AgentHookInstaller` before the
  wizard is presented.
- **`SetupStepView.swift`** — the first-run Setup step now shows an "Agent hooks"
  status row and a one-click **"Install hooks for &lt;agents&gt;"** button when
  agents are detected. Hidden entirely when none are found (no nagging).

### 5. Docs
- `docs/agent-hooks/claude-code.md` — corrected command, a note that Claude Code
  delivers the message on stdin, and an updated "Customizing" section noting
  install is now idempotent / self-healing.
- `docs/agent-hooks/{pi,hermes,openclaw}.md` — added `--title`.

### 6. Tests
- `Tests/HarnessCoreTests/HookNotificationParserTests.swift` *(new)* — message
  extraction, empty/invalid/non-object input, and `resolveBody` fallbacks.
- `Tests/HarnessCoreTests/AgentHookInstallerTests.swift` — added: Claude uses
  `--from-hook` (not the env var); **converge from the old broken hook without
  duplicating**; preserve a user's own non-Harness `Notification` entry; idempotent
  reinstall; deterministic `detectInstalledAgents` (custom `AgentTable` so the test
  doesn't depend on what's installed on the host).

---

## Design decisions / rationale (for review)

- **Explicit `--from-hook` flag, not stdin auto-detect (`isatty`).** Auto-reading
  stdin risks blocking an interactive `notify` forever waiting on EOF. The flag
  makes stdin opt-in and matches the existing `set-buffer --stdin` precedent.
- **Prune by the `harness-cli notify` marker, scoped to managed events.** This
  self-heals the current bug *and* any future command drift, and keeps install
  truly idempotent. Trade-off: a user who hand-edited Harness's *own* managed
  entry would have it reset to canonical on reinstall — acceptable, since Harness
  owns those entries, and documented in `claude-code.md`. All other keys, events,
  and the user's non-Harness entries are untouched.
- **`OnboardingEnvironment` static seam instead of a HarnessCore dependency.** The
  onboarding module is intentionally HarnessCore-free and already wraps install
  paths behind its own static helpers (`BinaryInstaller`, `NotificationPermission`).
  The seam keeps that boundary intact with zero duplication. It is `@MainActor`,
  so the closures are only ever touched on the main actor (no data races).
- **Install I/O runs in a main-actor `Task`** in `SetupStepView.installHooks`,
  mirroring the existing `performInstall`. The work is 1–2 small JSON writes per
  detected agent, one-time — not worth extra concurrency machinery.

---

## Build & verify

This was **not compiled** in the container. On a Mac:

```bash
swift build
swift test --filter HookNotificationParserTests
swift test --filter AgentHookInstallerTests
swift test --filter JSONMergeTests        # regression: array-union unchanged
```

Manual CLI smoke (with a daemon running and a real surface id):

```bash
# Real message flows through:
echo '{"message":"Permission needed","cwd":"/tmp/proj"}' \
  | harness-cli notify --surface <id> --title "Claude Code" --from-hook   # body: "Permission needed"

# Empty stdin must NOT hang, falls back:
printf '' | harness-cli notify --surface <id> --title "Claude Code" --from-hook  # body: "Needs attention"
```

Migration smoke:

```bash
# Point HOME at a temp dir holding an OLD broken ~/.claude/settings.json, then:
harness-cli install-hooks claude-code
harness-cli install-hooks claude-code   # run twice
# Inspect ~/.claude/settings.json: exactly ONE Notification hook with --from-hook,
# all other keys intact, plus a settings.json.harness-bak-* backup.
```

End-to-end in the app:
1. New Harness pane → run `claude` → trigger a permission prompt → the macOS
   banner should now show the **actual message** (not blank).
2. First-run onboarding (reset via Help → "Welcome to Harness", or
   `defaults delete <app domain> HarnessOnboardingShown_v1`): the Setup step
   should list detected agents and install their hooks in one click.

---

## Follow-ups / not in scope
- **Cursor** relies on the agent passing the message as positional `$1` (its
  documented contract); unverified here, left as-is.
- **Codex** uses static bodies ("Awaiting input" / "Done"); could later be
  enriched to read its stdin message via `--from-hook` too, but it's not broken.
- Notification *permissions* were already handled well (requested at launch,
  onboarding "Enable notifications" button, Settings status/repair) — untouched.
