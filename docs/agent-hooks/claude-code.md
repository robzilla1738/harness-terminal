# Claude Code → Harness

Make Claude Code surface its `Notification` and `Stop` events as Harness pane
notifications (yellow ring + sidebar dot + macOS push), so you can leave a long
edit running and pop back when it's actually waiting on you.

## One-line install

```bash
harness-cli install-hooks claude-code
```

This writes `~/.claude/settings.json` (backing up any existing file as
`settings.json.harness-bak-<timestamp>`).

## What gets written

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Claude Code\" --body \"$HARNESS_NOTIFY_MESSAGE\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Claude Code\" --body \"Done\""
          }
        ]
      }
    ]
  }
}
```

`$HARNESS_SURFACE` is exported by Harness for every pane, so the hook always
notifies the right tab.

## Verifying

1. Open a new Harness pane, run `claude` and start a long task.
2. While it's working, the tab pill's status dot turns Anthropic violet
   (Harness detected `claude` in the process tree).
3. When Claude Code emits a permission request or finishes, you see:
   - macOS notification banner.
   - Harness pane's amber ring.
   - "Claude Code: <message>" in the sidebar card meta line.
4. Press `Cmd+Shift+U` to jump back to the pane.

## Customizing

Edit `~/.claude/settings.json` directly — `install-hooks` only runs once.
You can match specific tools or pre/post events by following the standard
Claude Code hook schema.
