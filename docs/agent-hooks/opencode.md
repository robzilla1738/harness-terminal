# OpenCode → Harness

[OpenCode](https://opencode.ai/docs/plugins/) extends itself with JS/TS
**plugins** auto-loaded from `~/.config/opencode/plugins/`. A plugin subscribes
to session events and can run shell commands via Bun's `$` API — that's how
Harness gets notified.

## One-line install

```bash
harness-cli install-hooks opencode
```

Writes `~/.config/opencode/plugins/harness.js`:

```js
// harness-managed — surfaces OpenCode session events in Harness. Safe to delete.
export const HarnessNotify = async ({ $ }) => ({
  "session.idle": async () => {
    await $`PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "${process.env.HARNESS_SURFACE ?? ""}" --title OpenCode --body Done`
  },
  "permission.asked": async () => {
    await $`PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "${process.env.HARNESS_SURFACE ?? ""}" --title OpenCode --body "Awaiting input"`
  },
})
```

- `session.idle` fires when the agent finishes a turn and goes quiet.
- `permission.asked` fires when it needs your approval.

The plugin reads `$HARNESS_SURFACE` (exported by Harness for every pane) so the
notification lands on the right tab. It loads on OpenCode's next session.
Re-running `install-hooks opencode` overwrites this file in place (backing up
the previous copy).

## What you'll see

- The tab pill's dot turns OpenCode teal when an `opencode` process is detected.
- On idle / permission events you get a macOS banner + sidebar entry;
  `Cmd+Shift+U` jumps to the pane.

The dot color for OpenCode panes is `#56b6c2`.
