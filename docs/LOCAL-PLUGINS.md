# Trusted local Lua actions

Use **Review and trust local Lua plugin…** in the command palette to choose a
local manifest. The review displays each Lua entry and, when replacing an approval,
the previous entries. Approval stores the reviewed entry code in the local,
owner-only trusted-plugin registry. Palette discovery reads declarations and does
not execute plugin code. Invoking a declared action runs its approved entry through
the existing Lua CLI and the Lua API exposure checks.

Lua has your user privileges, including filesystem and process access. This is a
trust decision, not a sandbox. Modules, programs and files called by an entry are
also within that trust decision. Original entry edits are not loaded automatically;
review and approve again to use them. Harness does not discover executable plugins
in repositories, download plugins, or update them automatically.

Example `plugin.json`:

```json
{
  "format": 1,
  "id": "local-tools",
  "title": "Local tools",
  "actions": [
    { "id": "split", "title": "Split vertically", "file": "split.lua" }
  ]
}
```

`split.lua` can contain `harness.queue("split-window -h")`. An entry executes when
its action is invoked; it can also use generated Lua APIs and `harness.args`.
Persistent event handlers remain the explicit script flow. A plugin can declare up
to 32 actions with safe unique IDs, owned relative Lua paths, 256 KiB per entry and
1 MiB of entry code per plugin. Symlinked entry paths are refused. The local registry
holds up to 64 plugins and has a 4 MiB file limit. Errors are shown instead of
loading a partial or untrusted registry.

CLI review makes no writes. `--approve` is the explicit trust action:

```sh
harness-cli plugin review --manifest /absolute/plugin.json
harness-cli plugin trust --manifest /absolute/plugin.json --approve
harness-cli plugin list
harness-cli plugin run --id local-tools --action split
harness-cli plugin revoke --id local-tools
```

The palette provides a revoke action for each approved plugin. Revocation stops
future invocations; it does not interrupt an already running invocation. Registry
edits are atomic, check the expected prior file, and make owner-only backups.
Trust and execution are local; mobile/MCP/remote clients cannot approve plugins.
