# Agent hooks for Harness

Wire your coding agent to surface notifications in Harness.

## Per-agent guides

| Agent | One-line install | Doc |
| --- | --- | --- |
| Claude Code | `harness-cli install-hooks claude-code` | [claude-code.md](claude-code.md) |
| Codex | `harness-cli install-hooks codex` | [codex.md](codex.md) |
| Cursor Agent | `harness-cli install-hooks cursor` | [cursor.md](cursor.md) |
| Pi | `harness-cli install-hooks pi` | [pi.md](pi.md) |
| Hermes | `harness-cli install-hooks hermes` | [hermes.md](hermes.md) |
| OpenClaw | `harness-cli install-hooks openclaw` | [openclaw.md](openclaw.md) |

Harness also recognizes `aider`, `gemini`, and `goose` automatically (status
dot colors per agent), but those tools don't have built-in hook protocols —
use the manual `harness-cli notify` snippet from your shell or a `precmd`
hook to surface their state.

## CLI notification

```bash
harness-cli notify --surface "$HARNESS_SURFACE" --title "Claude" --body "Needs approval to run tests"
```

## OSC sequences (from terminal output)

Harness recognizes standard notification OSC sequences (9, 99, 777) emitted by agents and terminals.

## Jump to waiting agent

Press `Cmd+Shift+U` in Harness, or run:

```bash
# Use the command palette (Cmd+K) → jump-notification
```

## Example Claude Code hook

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "harness-cli notify --surface \"${HARNESS_SURFACE:-default}\" --body \"Agent finished — review output\""
      }]
    }]
  }
}
```
