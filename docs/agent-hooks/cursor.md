# Cursor Agent → Harness

Make Cursor's terminal agents (`cursor-agent`) ping Harness when they need
input or finish a turn.

## One-line install

```bash
harness-cli install-hooks cursor
```

Writes `~/.cursor/agent-hooks.json` with:

```json
{
  "version": 1,
  "agent_notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"$1\""
}
```

If your Cursor build doesn't read this file, you can wire the same command
into your shell prompt or a `precmd` hook — the only env var Harness needs
is `$HARNESS_SURFACE`.

## What you'll see

- The tab pill's dot turns Cursor cyan whenever a Cursor agent process is
  detected in that pane.
- Notifications surface in macOS Notification Center plus the sidebar.

## Manual fallback

If you can't use the hook file, drop this in your shell config:

```bash
cursor_notify() { harness-cli notify --surface "$HARNESS_SURFACE" --title "Cursor" --body "$1"; }
```

Then call `cursor_notify "Done"` from inside Cursor's terminal session at the
moments you care about.
