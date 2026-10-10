# Trusted declarative hook policy

Observation hooks remain quiet, bounded and fail open. Enforcement is a separate explicit opt-in. **Trusted Hook Policy…** in the palette reviews a local JSON file, captures approved literal rules in a private trusted registry, enables/disables them, previews provider configuration, installs/removes only its managed hook entries with atomic backups, and displays redacted evaluated-decision audit. No repository discovery, downloaded plugins or policy code runs during review or evaluation.

A policy uses format/version 1, a UUID, name, exact adapter contract, `enabled` flag and 1–32 unique rules. Each rule names one documented event, 1–4 literal conditions, `deny`/`ask`, and a static reviewed reason. Fields are `tool`, `command`, `path` and `directory`; comparisons are `equals`, `prefix` and `contains`. Conditions within a rule use AND. Any matching deny takes precedence over ask. No match preserves normal processing. Literal checks do not parse shell semantics and are not a complete shell security boundary; aliases, encodings, subprocesses and alternate tools can fall outside a rule.

Provider behavior is explicit:

- Claude `PreToolUse` supports deny/ask. Fail-closed installation verifies Claude Code **2.1.295+**, then configures `onFailure: "block"` and a synchronous bounded command hook. Earlier/unknown versions are refused. See [Claude's failure behavior](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).
- Cursor v1 uses `failClosed: true`. Generic `preToolUse` supports deny; ask rules must use `beforeShellExecution` or `beforeMCPExecution`. A generic ask rule is rejected because the current provider does not enforce it. Cursor requires an explicit normal-processing `permission: "allow"` response when no rule matches. See [Cursor hook responses and failure settings](https://cursor.com/docs/hooks).
- Codex's adapter can produce a documented native deny response, but its current callback failures/timeouts can fail open and `ask` is not enforced. Harness reports fail-closed enforcement **unsupported**, refuses enabled policy/installation for that contract, and keeps observation hooks available. See [Codex hook limitations](https://learn.chatgpt.com/docs/hooks).

Provider trust and managed-policy mechanisms are preserved. The installer prints or displays the proposed Harness-only diff, retains unrelated handlers/settings, checks for concurrent file edits and makes a private backup. It never approves vendor trust automatically. Observation-hook reinstall does not prune enforcement commands. Disabling a trusted policy restores normal hook processing; removal explicitly removes its managed entries. Removing the registry file while leaving an enabled guard installed causes denial rather than silently trusting new configuration.

The helper reads at most 128 KiB of stdin within a short deadline, evaluates only approved local declarations and sends a bounded local audit request without starting a daemon or making network calls. Malformed input, missing trust or unavailable required audit returns a native denial with a fixed safe reason. Output contains JSON only, with no OSC sequences. Vendor failure blocking covers helper crashes/timeouts for supported installations. Disabled policies do not require successful enforcement audit. Guardrails depend on the selected provider honoring its documented contract and trust settings.

Audit contains policy/rule UUIDs, adapter/event, evaluated decision, optional Harness surface UUID, timestamp and failure flag. It contains no command, raw tool input, repository path or secret. An evaluated decision is not proof of delivery, permission approval or actual tool execution; use recorded provider tool events for those observations. Audit payloads use the activity store's encrypted envelopes and bounded unavailable-key memory path, retaining at most 500 entries for 14 days. Audit pages report unavailable history and pagination explicitly.

CLI:

```sh
harness-cli hook-policy review --input policy.json
harness-cli hook-policy trust --input policy.json --approve
harness-cli hook-policy install --id UUID --provider-executable /path/to/claude
harness-cli hook-policy install --id UUID --provider-executable /path/to/claude --write
harness-cli hook-policy disable --id UUID
harness-cli hook-policy uninstall --id UUID --write
harness-cli hook-policy audit --offset 0
```

Install/uninstall print configuration by default; `--dry-run` performs no writes. `--configuration-directory` explicitly selects a custom provider profile directory. Local trust, installation and enablement are not exposed through MCP/mobile/Lua. `policy.audit` is a capability-declared local read API; the helper's raw audit operation is restricted at both forwarding and daemon boundaries.

Focused evidence covers deny precedence, ask support/refusal, native response formats, no raw input/OSC leakage, reviewed version checks, private backups, unrelated settings/handlers, idempotent installation, selective removal and explicit disable. `Scripts/prove-hook-policy.py --cli /absolute/harness-cli` verifies real helper IPC, redacted audit and denial on unavailable audit/malformed input using a disposable socket/home. The native walkthrough verifies the explicit local review/trust controls and truthful enforcement support; no real provider configuration is changed. See [native acceptance](NATIVE-ACCEPTANCE.md).
