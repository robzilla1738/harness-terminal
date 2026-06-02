# Pi → Harness

Pi (the [pi coding agent](https://pi.dev)) extends itself with TypeScript
**extensions** auto-discovered from `~/.pi/agent/extensions/*.ts` — there's no
config file to edit; dropping a file is enough, and it loads on the next session.

## One-line install

```bash
harness-cli install-hooks pi
```

Writes `~/.pi/agent/extensions/harness.ts`:

```ts
// harness-managed — surfaces Pi session events in Harness. Safe to delete.
import { execSync } from "node:child_process"

export function activate(api: any) {
  const notify = (body: string) =>
    execSync(
      `PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "${process.env.HARNESS_SURFACE ?? ""}" --title "Pi" --body "${body}"`,
      { stdio: "ignore" }
    )
  api.on?.("session_end", () => notify("Done"))
  api.on?.("stop", () => notify("Done"))
}
```

The extension reads `$HARNESS_SURFACE` (exported by Harness for every pane) so
the notification lands on the right tab. Re-running `install-hooks pi`
overwrites this file in place (backing up the previous copy).

> The exact Pi `ExtensionAPI` event names can vary by version. If notifications
> don't fire, check `~/.pi/agent/extensions/` against your Pi release's hooks
> reference and adjust the event names — the `harness-cli notify` command itself
> is unchanged.

The dot color for Pi panes is `#b48cff`.
