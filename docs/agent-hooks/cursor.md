# Cursor Agent → Harness

Make Cursor's agent (`cursor-agent`) ping Harness when a turn finishes.

## One-line install

```bash
harness-cli install-hooks cursor
```

Writes `~/.cursor/hooks.json` using Cursor's real [hooks
schema](https://cursor.com/docs/hooks) (introduced in Cursor 1.7) — deep-merged
into any existing hooks, so your own entries are preserved:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      { "command": "PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"Done\"" }
    ]
  }
}
```

The `stop` hook fires when the agent loop terminates. Cursor passes
`{"status":...,"loop_count":...}` on the hook's stdin; we don't need it, so the
command just notifies Harness. (Re-running `install-hooks cursor` replaces the
Harness `stop` entry in place and leaves everything else untouched.)

> **Caveat — IDE vs CLI:** Cursor's hooks were designed for the desktop app /
> Agent Chat. As of this writing the `cursor-agent` **CLI** may not fire the
> `stop` hook. Harness installs the correct, documented format regardless;
> process-tree detection still lights up the Cursor status dot either way. If
> the hook doesn't fire in your CLI build, use the manual fallback below.

## What you'll see

- The tab pill's dot turns Cursor cyan whenever a `cursor-agent` process is
  detected in that pane.
- When the agent stops, notifications surface in macOS Notification Center plus
  the Harness sidebar; `Cmd+Shift+U` jumps to the pane.

## Manual fallback

If your build doesn't fire the hook, drop this in your shell config and call it
from inside Cursor's terminal session at the moments you care about:

```bash
cursor_notify() { PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "$HARNESS_SURFACE" --title "Cursor" --body "$1"; }
```
