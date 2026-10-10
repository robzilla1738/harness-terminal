# Recordings, review and export

Use **Recordings and Export…** in the command palette to record the selected terminal
or open an existing recording. Recording is a passive subscription: it cannot resize
the terminal, send input, or stop its shell. Stop finalizes the archive and opens the
review. Closing the panel also stops its owned recorder without affecting the pane.
Preview panes are not recordable terminal processes.

```sh
harness-cli record --surface UUID --output session.hrec
harness-cli replay session.hrec --speed 2
harness-cli recording review --input session.hrec
harness-cli recording export --input session.hrec --output reviewed.cast --reviewed
```

`record` creates a new file and refuses an existing path. macOS archives use the
signed Harness components' shared Keychain key. Each event and completion marker
is encrypted and authenticated before writing, including identity and exact order.
No adjacent plaintext key or plaintext staging copy is used. An unavailable key
refuses disk recording; the pane and the daemon's bounded memory history continue.
Linux archives are owner-only plaintext and explicitly labelled as such. Reading a
Linux archive on macOS checks framing, but cannot establish cryptographic integrity.

The recorder captures a current screen and actual PTY dimensions, then ordered live
output and resize events. Resizes are tied to the stable terminal byte sequence,
not the recording CLI's local window. A geometry capability is required; an older
host reports an actionable failure and preserves its shells. The stream is bounded;
storage, capacity and connection failures are reported rather than silently dropping
writes. Archives are limited to 128 MiB, 100,000 events and 30 days per recording.
The start clock is monotonic. The recorder captures no keyboard input.

Interrupted archives retain complete verified frames and report an unfinished or
truncated source. Authentication, reordered frames and invalid dimensions fail
explicitly. Legacy JSON Lines files remain readable, with malformed lines reported;
sharing refuses a legacy file with skipped lines. Legacy dimensions may describe
the recorder's terminal and may omit PTY changes; encryption conversion retains that
warning rather than inventing missing geometry.

For an explicit conversion of a selected legacy file:

```sh
harness-cli recording protect --input old-recording.jsonl
```

The conversion encrypts a new stage, verifies every event, and atomically replaces
only the unchanged original. Interrupted conversion retains the original; stages
contain encrypted data. No plaintext migration backup is retained. This does not
securely erase old SSD data.

Review shows candidate credential masks, their times and local context. Candidates
can be toggled by checkbox or the keyboard-accessible toggle button. Additional
literal redactions stay in memory and can be cleared. The complete exported content
is shown with control characters escaped. The .cast is an intentional plaintext
artifact; **Save reviewed .cast…** writes it atomically, and **Share saved .cast…**
opens the system sharing picker for the saved file. Harness does not publish a
recording automatically. Changing masks, adding redactions, or opening another
recording disables sharing until the current review is saved again. A late save
completion cannot re-enable sharing for an older review.

The [asciicast v2 export](https://docs.asciinema.org/manual/asciicast/v2/) retains
relative event times, dimensions and resize records. UTF-8 is carried across output
chunks. Known credential candidates are detected across chunk boundaries and masked
by default. Input is omitted. OSC, DCS, APC, PM, SOS, terminal queries, bell and window
control payloads are stripped while presentation sequences and alternate screens
remain. Invalid UTF-8 is replaced and reported. Export review is limited to 16 MiB of
sanitized output; a larger capture remains available for local replay.

Masking is heuristic. Cursor edits, formatting and unusual secret formats can hide
sensitive text; review the output and add redactions before sharing. CLI literal
additions come from an owner-readable JSON array via `--redactions-file`, avoiding
secrets in command-line arguments. The CLI's `--reviewed` flag explicitly acknowledges
that review; it does not assert that every possible secret was detected.

Focused archive/export and real-socket capture checks pass. The native walkthrough
reviews automatic and added masks, saves a timed/resized export and reaches the
share chooser without sharing. See [native acceptance](NATIVE-ACCEPTANCE.md).
