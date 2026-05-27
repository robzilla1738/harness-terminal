# Pi → Harness

```bash
harness-cli install-hooks pi
```

Writes `~/.pi/hooks.json`:

```json
{
  "notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""
}
```

If your Pi build uses a different hook config path, copy the same JSON to
the correct location manually.

The dot color for Pi panes is `#b48cff`.
