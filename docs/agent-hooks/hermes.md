# Hermes → Harness

[Hermes Agent](https://github.com/nousresearch/hermes-agent) declares
shell-script hooks in `~/.hermes/config.yaml`, gated behind a one-time consent
allowlist (`~/.hermes/shell-hooks-allowlist.json`, managed by `hermes hooks`).

## One-line install

```bash
harness-cli install-hooks hermes
```

Appends a Harness-managed region to `~/.hermes/config.yaml` (backing the file up
first; the region is replaced in place on re-install, never duplicated):

```yaml
# >>> harness-managed (do not edit) >>>
hooks:
  - event: stop
    command: 'PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "$HARNESS_SURFACE" --title "Hermes" --body "Done"'
# <<< harness-managed <<<
```

## Required: approve the hook

Hermes will not run a shell hook until you approve it:

```bash
hermes hooks            # review configured hooks
# approve the Harness 'stop' hook when prompted
```

Until then the hook is inert (Hermes refuses to run un-allowlisted shell
commands by design). You can verify with `hermes hooks doctor`.

> If your `config.yaml` already has a top-level `hooks:` key, merge the Harness
> entry into it by hand — YAML allows only one `hooks:` mapping per document.

The dot color for Hermes panes is `#ff7e6b`.
