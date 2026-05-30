# Codex → Harness

Surface Codex CLI pause / done events as Harness pane notifications.

## One-line install

```bash
harness-cli install-hooks codex
```

Writes `~/.codex/hooks.json` (the event/matcher shape Codex uses — the same as Claude
Code, deep-merged into any existing hooks):

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Awaiting input\"" }] }
    ],
    "Stop": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Codex\" --body \"Done\"" }] }
    ]
  }
}
```

…and enables the hooks feature flag in `~/.codex/config.toml` (Codex won't load
`hooks.json` without it):

```toml
[features]
hooks = true
```

## What you'll see

- The tab pill's dot turns OpenAI green when Codex is the running agent.
- When Codex pauses (waiting on approval, etc.), the pane's status flips to
  `awaiting` and `Cmd+Shift+U` jumps right to it.

If your Codex install uses a different hook config path, copy the JSON above
to the correct location manually.
