# Harness MCP

Run `harness-cli mcp` as a local stdio server. Stdout carries MCP messages only.
The official Swift SDK 0.12.1 negotiates its supported protocol versions, including
2025-11-25. The integration has no terminal-core SDK dependency.

Approved reads are server version; session list/view; pane capture, process tree,
resources, directory, title, dimensions, program status and view; agent executions
and event pages; usage; digest; and attention. New APIs do not enter this set
implicitly. Each method's generated schema describes arguments and required daemon
capabilities. Older daemons return an actionable capability error while shells remain
running. History has explicit host/run identities and pagination.

`--allow-write` enables exactly `pane.write`, `pane.send_key`, `pane.focus`,
`attention.read`, and `attention.snooze`. This flag is an explicit authorization for
these actions. Canonical resolution rejects every such action targeting the caller's
`HARNESS_SURFACE`, including pane UUIDs, positional targets, labels, and default targets.
Administrative, credential, provider, hook, plugin-trust and kill-tree APIs are never
exposed. Mutation diagnostics contain method, canonical surface and time, never the
arguments or pasted content.

Pane resources use `harness://pane/<surface UUID>/screen`. They read the current
terminal screen without scrollback or input. Requests are cancellable, limited to
eight active integration operations, and bounded by input/output and framing limits.
Cancellation cannot undo a mutation already accepted by the daemon; uncertain input
is never retried automatically.

## Client configuration

```sh
harness-cli mcp-install --client claude
harness-cli mcp-install --client codex
harness-cli mcp-install --client cursor
```

These commands print configuration and perform no writes. Add `--write` to install
with a private backup, or `--path /absolute/config/path` for an explicitly selected
configuration. Add `--allow-write` only when you want the installed server to expose
its fixed write set. Claude and Cursor use JSON; Codex uses TOML. Unrelated entries
are preserved, invalid files are refused, and conflicts with an existing unmanaged
Harness entry require an explicit manual merge of the printed configuration.

For an isolated engineering proof, build then run
`python3 Scripts/prove-session-survival.py --bin-dir .build/out/Products/Debug`.
Its MCP exchange uses the fresh temporary service and never operates on the normal
user service or vendor configuration. SDK and dependency provenance is documented
in [the vendored SDK](../Vendor/swift-sdk/UPSTREAM.md).
