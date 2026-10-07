# Program status (OSC 7501)

Harness reads [OSC 7501 revision 0.2](https://www.superlogical.com/rex/docs/build/program-status). A program reports what it is doing. The terminal keeps one record per id and shows that state on the tab, the session row, the notch, and the waiting list (⌘⇧U).

## Report

A report is `OSC 7501 ;` pairs `ST`. Pairs are `key=value`, separated by `:`. Whitespace around the body is ignored. A pair with no `=`, an empty key, or a value byte outside the value set is skipped. Unknown keys are ignored. The last copy of a repeated key wins.

`state` is required. The stored states are `idle`, `working`, `done`, `blocked`, and `error`. `clear` is not stored: it removes the addressed record and every record under it. With no id, `clear` removes every record. An unknown state discards the whole report. It is not stored as `idle`.

`kind` is kept only when `state` is `blocked`, and only for `permission`, `question`, or `auth`. Anything else is treated as absent.

`progress` is an integer from 0 to 100, and only while `state` is `working` or `blocked`. Any other progress value is absent.

`title` and `msg` are standard base64 of UTF-8. Padding is optional. If the base64 does not decode, or the decoded text contains a control character (U+0000–U+001F, U+007F, U+0080–U+009F), the whole report is discarded. Decoded text is plain text. It is never parsed as markup. When that text is drawn outside the grid, bidi overrides are stripped (U+202A–U+202E, U+2066–U+2069, and U+200E, U+200F, U+061C).

`app` is a token of 1–32 characters from `[A-Za-z0-9_.+-]`. A longer `app` discards the report. A token that fails the character set is treated as absent.

`id` is `segment` or `segment/segment…`. A segment is 1–32 characters from `[A-Za-z0-9_.+-]`. A missing id addresses the root record. A bad id is ignored, and the report does not fall back to the root. `/` is parent and child for `clear` and for `app` inheritance only. A record with no `app` takes it from the nearest ancestor that has one, including the root. The parent does not have to exist. Root and children coexist. Each report replaces that one record.

## Limits

The whole sequence, OSC through ST, is at most 4096 bytes. A key longer than 16 characters, a message longer than 2732 encoded bytes or 2048 decoded bytes, a title longer than 256 encoded or 192 decoded, an `app` longer than 32, an id longer than 128 or eight segments, or a 33rd character in a segment discards the whole report. The terminal keeps 256 records and evicts the least recently updated. It always retains at least 64.

These checks run before any stored record changes. A discarded report leaves the previous records as they were.

## Lifetimes

There is no heartbeat. The process exiting, or OSC 133 `A` (a shell prompt), drops `working` and `blocked`. `idle` stays. `done` and `error` stay until that pane is focused and a key is typed.

RIS (`ESC c`) removes every record. DECSTR does not. The alternate screen does not. Records belong to the terminal, not to a screen.

## Query

`OSC 7501 ; ? ST` is answered with the same body, `?`. The body after trimming must be exactly `?`. `?something` is not a query. The reply is not a stored record, and records are not echoed back.

The bundled terminfo source is `term/harness.ti`:

```
Pst=\E]7501;%p1%s\E\\
```

## OSC 9;4

ConEmu progress (OSC 9;4) may fill the root record only until the first real 7501 report is accepted. It then stops, until RIS. A real 7501 record beats the agent detector. When OSC 9;4, the detector, and a 7501 report all describe one pane, the user is notified once. Bells and banners are rate-limited and name the source pane.

## Who reads it

The daemon scans the byte stream with no window open. The GUI parser, given the same bytes, produces the same records. One presenter feeds the tab, the session row, the notch, and the waiting queue. `working` uses the working dot. `blocked` joins the waiting queue, `kind` picks the glyph, and `msg` is shortened plain text. `done` and `error` mark the session row until focus plus a key. The tab chip shows the agent color and, when set, the `app` label.

`harness-cli events --follow` emits `program_status_changed` as soon as a real report is accepted, and `program_status_removed` when a real report clears the records. `harness-cli api call pane.program_status` returns the records for one pane.
