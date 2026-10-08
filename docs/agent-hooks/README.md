# Agent hooks for Harness

Wire your coding agent to surface notifications in Harness.

## Per-agent guides

| Agent | One-line install | Real mechanism | Doc |
| --- | --- | --- | --- |
| Claude Code | `harness-cli install-hooks claude-code` | `~/.claude/settings.json` event hooks | [claude-code.md](claude-code.md) |
| Codex | `harness-cli install-hooks codex` | `~/.codex/hooks.json` event hooks | [codex.md](codex.md) |
| Cursor Agent | `harness-cli install-hooks cursor` | `~/.cursor/hooks.json` `stop` hook | [cursor.md](cursor.md) |
| Grok Build | `harness-cli install-hooks grok` | `~/.grok/hooks/harness.json` | [grok.md](grok.md) |
| OpenCode | `harness-cli install-hooks opencode` | `~/.config/opencode/plugins/harness.js` | [opencode.md](opencode.md) |
| Pi | `harness-cli install-hooks pi` | `~/.pi/agent/extensions/harness.ts` | [pi.md](pi.md) |
| Hermes | `harness-cli install-hooks hermes` | `~/.hermes/config.yaml` (consent) | [hermes.md](hermes.md) |
| OpenClaw | `harness-cli install-hooks openclaw` | `~/.openclaw/openclaw.json` (JSON5) | [openclaw.md](openclaw.md) |

Each command writes the agent's **real** config format (researched per tool),
backs up any existing file first, and is idempotent — re-running it converges to
the current Harness hook instead of duplicating it, and cleans up files an older
Harness wrote at now-wrong paths. Hermes and OpenClaw need a one-time manual step
(consent / merging into an existing `hooks` key) — see their guides.

Harness also recognizes `aider`, `gemini`, and `goose` automatically (app tile
colors per agent), but those tools don't have built-in hook protocols —
use the manual `harness-cli notify` snippet from your shell or a `precmd`
hook to surface their state.

Installed hook commands prepend Harness's app-support `bin` directory to
`PATH`, so notifications still work when an agent subprocess does not load your
interactive shell profile. Each command then prints an OSC 7501 report to the
tty (`; printf "\033]7501;state=…:app=<agent>:msg=<base64>\033\\" >/dev/tty 2>/dev/null || true`);
the per-agent examples leave that tail out for readability.

## Set up via your IDE (copy/paste prompt)

If one-click install can't reach a tool, open **Settings ▸ Agents**, and under
**Setup** click **Copy Prompt** (the "Setup prompt" row), then paste it into any coding agent/IDE
running on the Mac (Claude Code, Cursor, Codex, …). The prompt instructs the agent
to run `harness-cli install-hooks <tool>` (or write the hook config by hand if the
CLI isn't installed) so it wires up its own Harness notifications.

## CLI notification

```bash
harness-cli notify --surface "$HARNESS_SURFACE" --title "Claude" --body "Needs approval to run tests"
```

## OSC sequences (from terminal output)

Harness recognizes the standard notification OSC sequences 9 and 777 emitted by agents and terminals.

`install-hooks` also writes an OSC 7501 report beside `harness-cli notify`, so the pane's program status updates even when the window is not focused. The report is plain text on the tty (`printf` of `OSC 7501`). See [PROGRAM-STATUS.md](../PROGRAM-STATUS.md).

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
        "command": "PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify --surface \"${HARNESS_SURFACE:-default}\" --body \"Agent finished — review output\""
      }]
    }]
  }
}
```
