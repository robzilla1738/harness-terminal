# Import previews

Importing never attaches existing tmux PTYs. **Import tmux Layout…** in the palette reads a local server with bounded `list-panes`/`display-message` requests or opens an owner-readable snapshot. Select a session, inspect its nested layout, directories, warnings and unchecked startup suggestions, then save it to the selected host's Saved Setups. Saving runs no commands. Opening the setup later creates new Harness shells. Remote-host imports use a snapshot captured on that host; recorded directories must exist there.

The CLI defaults to a JSON preview:

```sh
harness-cli import tmux --socket /absolute/server.sock --snapshot-output /tmp/tmux-snapshot.json
harness-cli import tmux --input /tmp/tmux-snapshot.json --session '$0' --reviewed --write
harness-cli import iterm-colors --input /path/Preset.itermcolors --variant dark
harness-cli import iterm-colors --input /path/Preset.itermcolors --variant dark --reviewed --write
harness-cli import ghostty --input /path/config
harness-cli import ghostty --input /path/config --select paletteShortcuts --reviewed --write
```

`--dry-run` performs no writes, including when combined with `--write` or `--snapshot-output`. tmux write mode requires a previously captured snapshot and explicit session selection; it does not capture and silently save a live layout. The parser supports checksummed v1 layouts and v2 JSON using stable session/window/pane IDs, validates contiguous nested geometry and detects changes during capture. Floating panes and unknown layout versions fail explicitly. Harness's 10% minimum split fraction is reported when a smaller source split is clamped. Tabs, newlines, quotes and backslashes in captured field values remain data because each text field is queried separately. The implementation follows the [tmux layout contract](https://github.com/tmux/tmux/blob/master/layout-custom.c) and [format fields](https://github.com/tmux/tmux/wiki/Formats).

**Import iTerm2 Colors…** previews the base/dark/light variant, foreground/background sample and all 16 ANSI swatches, with accessible color descriptions. Install adds an existing-model `.harnesstheme`; Install and Apply also changes settings. XML and binary property lists work. Explicit Display P3 values are converted to sRGB; gamut clipping and 8-bit quantization are reported. Undeclared legacy components are labeled as interpreted sRGB; unsupported declared spaces fail instead of pretending to convert them. Other profile fields and variants are reported as unapplied. The format follows [iTerm2's color definitions](https://iterm2.com/python-api/color.html) and the conversion uses [CSS Color 4 matrices](https://www.w3.org/TR/css-color-4/).

Ghostty import retains its native preview and customized-value opt-in. Supported command shortcuts map to palette actions; unsupported/global/sequence bindings are reported, duplicate chords reflect later reassignment, and additional chords that cannot fit the one-chord action model are reported. Native conflict reporting also checks existing palette actions, prefix/root bindings and menus; the headless CLI can report persisted palette conflicts. Font size remains unchanged. CLI `--select` names the fields from the preview and requires `--reviewed --write`.

Changed files are staged, verified and atomically renamed with owner-only backups. Selected Ghostty fields preserve unknown JSON and daemon-owned settings; a file changed since preview aborts the write. Native Undo Last Settings Import restores imported values only if they have not since been edited. iTerm/theme installation failure is visible and cannot silently apply a supposedly installed theme. Preview reads are bounded and perform no settings writes.

Focused evidence covers v1/v2 nested layouts, stable-ID mismatches, checksum and geometry failures, escaped fields in a disposable real tmux server, unchanged pane/process identities, color variants/P3/invalid channels, verified theme backups, read-only settings previews, preservation of unknown fields and concurrent-edit refusal. The native tmux preview saves a setup with unchecked startup suggestions and unchanged PTY count. Color/keybinding correctness and atomic settings behavior are covered by the focused importer checks. See [native acceptance](NATIVE-ACCEPTANCE.md).
