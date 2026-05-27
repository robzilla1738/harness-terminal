# Codex → Harness

Surface Codex CLI pause / done events as Harness pane notifications.

## One-line install

```bash
harness-cli install-hooks codex
```

Writes `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "on_pause": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Awaiting input\"",
    "on_done":  "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Done\""
  }
}
```

## What you'll see

- The tab pill's dot turns OpenAI green when Codex is the running agent.
- When Codex pauses (waiting on approval, etc.), the pane's status flips to
  `awaiting` and `Cmd+Shift+U` jumps right to it.

If your Codex install uses a different hook config path, copy the JSON above
to the correct location manually.
