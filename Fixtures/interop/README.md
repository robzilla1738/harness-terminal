# Terminal interoperability fixtures

`osc-7501-vectors.json` contains exact base64-encoded UTF-8 wire bytes and expected final records for OSC 7501 revision 0.2. Vectors cover progress, attention, hierarchy/clear, duplicate fields, invalid text, unknown state, prompt lifetime and the non-stored query. See [the public wire handling](../../docs/PROGRAM-STATUS.md).

The Claude, Codex and Cursor `.cast` and equivalent Harness `.jsonl` files are **synthetic representative terminal-UI workloads**, not recorded provider output or a claim that those vendors emit OSC 7501. They exercise alternate screens, cursor movement, line erasure, styled UTF-8 text, permission attention and return to a shell. Status bytes model the Harness observation integration. They contain no account, repository, transcript or credential data. Provider hook/transcript contracts remain independently versioned adapters.

Replay with the existing tool, for example:

```sh
harness-cli replay Fixtures/interop/codex-tui.jsonl
```

The `.cast` versions can be viewed with an asciicast v2 player, including their declared 80×24 geometry. The CLI raw replay writes recorded output without forcing a terminal-window resize.

The existing parser test target consumes these same files, comparing daemon-stream scanning with terminal-emulator records for both complete and byte-split input. This fixture check is part of the existing suite; it adds no CI matrix or recurring validation process.
