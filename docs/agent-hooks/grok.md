# Grok Build → Harness

[Grok Build](https://x.ai/news/grok-build-cli) (xAI's coding CLI) runs shell
commands at lifecycle events. It merges every `*.json` under `~/.grok/hooks/`,
so Harness writes its **own** file there and never touches yours.

## One-line install

```bash
harness-cli install-hooks grok
```

Writes `~/.grok/hooks/harness.json`:

```json
{
  "on-complete": "PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Grok\" --body \"Done\"",
  "on-error": "PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Grok\" --body \"Error\""
}
```

`$HARNESS_SURFACE` is exported by Harness for every pane, so the hook always
notifies the right tab. Because this is a dedicated Harness file, re-running
`install-hooks grok` simply overwrites it — your other `~/.grok/hooks/*.json`
files are left alone.

## What you'll see

- The tab pill's dot turns Grok blue when a `grok` / `grok-build` process is
  detected in that pane.
- When Grok finishes (or errors), you get a macOS banner + sidebar entry;
  `Cmd+Shift+U` jumps to the pane.

> Grok Build is young and its hook event names are still settling. If
> `on-complete` / `on-error` don't fire in your build, check `grok` docs for the
> current event keys and edit `~/.grok/hooks/harness.json` — the `harness-cli
> notify` command is unchanged. Grok also honors Claude Code / Codex hook
> conventions, so the event/matcher style works too if your build prefers it.

The dot color for Grok panes is `#1d9bf0`.
