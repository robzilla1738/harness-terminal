# Harness — Full Audit & Parity Roadmap

> **Status:** ✅ **PR-1 → PR-21 are all merged & shipped to `main`** (PRs #115–#138; per-PR markers below) — bundled into the **v1.9.0** release. The **P5 tail (PR-22 / PR-23 / PR-24)** is **superseded by [docs/V1_10_ROADMAP.md](V1_10_ROADMAP.md)** (as PR-30/31/32, PR-29, and PR-36 respectively) — execute it there, not here. Originally generated 2026-06-08 from an exhaustive read-only audit; shipped state reconciled 2026-06-09.
> Execute remaining PRs in priority order, one focused themed PR at a time (impl + tests + green CI, merged on review). Finding IDs in `[...]` map to the appendix table at the bottom.

## Context

Harness is a native macOS terminal (~171K LOC Swift, 9 packages, 1489 tests) built to be **ghostty + tmux + cmux in one app**, with zero tech debt. This roadmap is the result of a *complete analysis*: find inefficiencies, close remaining gaps to ghostty/tmux parity, eliminate tech debt.

It was produced by a **42-agent audit workflow** (12 parallel finders across emulation, rendering, multiplexing, performance, concurrency/safety, tech-debt, and tests → adversarial verification of every falsifiable claim → synthesis → completeness critic), cross-checked by **independent hand-reads** of the highest-impact files. **101 findings, 28 adversarially verified (0 refuted).** The two confirmed shipping bugs and the five highest-severity items were independently re-verified against source with line numbers.

**Headline:** Harness is genuinely mature and low-debt — at/near parity on the common interactive surface (VT core 90%, input protocols 92%, font/glyph/cursor 93%). The real gaps are **narrow and cluster**: two shipping bugs, a cluster of standard-but-absent VT control functions, a few self-inflicted "silent failure" spots in the option/format layer, and a **missing macOS-native + security axis** (VoiceOver, secure keyboard entry, escape-sequence input validation) surfaced only by the completeness critic.

**Priorities applied here:** all findings documented in detail; **VoiceOver accessibility and secure keyboard entry elevated to top-tier**; delivered as **incremental themed PRs**.

---

## Parity scorecard (verified)

| Area | vs | % | Verdict |
|---|---|---|---|
| VT / CSI / SGR core | ghostty | 90 | At parity on the common surface; gap = a cluster of standard control functions with **no handler at all** (DECSTR, REP, IRM, DECOM, CSI t title stack) — IRM/REP/DECSTR/DECOM are real correctness gaps. |
| OSC / DCS dispatch | ghostty | 80 | OSC broad & well-bounded. Structural gap: DCS `data.contains('q')` misroutes DECRQSS/XTGETTCAP/tmux-passthrough into the Sixel decoder; DA1 doesn't advertise Sixel `;4`. |
| Keyboard / mouse / focus | ghostty | 92 | Kitty keyboard fully implemented; SGR/normal/button mouse + focus + alt-scroll all wired. Gaps: DECSET 1003 motion never reported, 1016 pixel mouse absent, **paste-injection bug**. |
| Inline images (Kitty/Sixel/iTerm2) | ghostty | 65 | Decode/display/eviction/reflow solid, but Kitty protocol is **display-only**: no ack, no `a=q` query, no `a=d` delete, `i=` client-id ignored. |
| Font / glyph / cursor / decorations | ghostty | 93 | Procedural box+block, ligatures, bold-bright, min-contrast, DECSCUSR+blink, hollow cursor, Nerd Font fallback all present & rendered. Gaps are polish + known-backlog (SGR blink, double-line box, sextants/Braille, font-feature). |
| tmux commands + option model | tmux | 85 | Broad verbs, STRICT `-t` targeting, correct scope-fallback. Gaps: **set-option has no key validation**, **@user-options unsupported**, display-message `-p` missing, status-position dead toggle. |
| Copy-mode motions / actions | tmux | 70 | Clean shared reducer (char/line/rect, word, page, regex search, copy-pipe). But f/F/t/T, H/M/L, e/E, W/B/E, other-end, goto-line missing — and **three aliases are semantically wrong today**. |
| Format string engine | tmux | 72 | ~73 tokens + ternary + truncation + time/==/m/s///. But **conditionals can't nest operators in the test** (`#{?#{==:a,b},x,y}` silently empty); `!=`/`\|\|`/`&&`/`n:`/`T:`/`a:`/`p<N>:` + loop modifiers absent. |
| Hooks / lifecycle events | tmux | 80 | 24 events incl. alert-bell/activity/silence, persisted w/ corrupt-file backup. Missing: command-error, client-session-changed, pane-focus-in/out, window-pane-changed. |
| Status line / window-list | tmux | 70 | status-left/right + `#[...]` + multi-row + display-message override work. Missing: status-position honored, status-justify/centre list, status-interval. (Native GUI tab bar legitimately substitutes for much of the window-status family.) |
| Daemon / IPC / PTY perf | tmux | 75 | PTY read reuses a 64KiB buffer; recordActivity throttled. But **layout.json written synchronously under the lock on every mutation** (debounced async save exists, unused); process tree scanned redundantly per tick. |
| Architecture health / tech debt | both | 85 | Genuinely low debt: strict layering, warnings-as-errors on Foundation layers, no rot markers. Real debt is concentrated: a few oversized files + one duplicated, mode-unaware special-key encoder. |
| Test coverage | both | 80 | Strong in hot paths (reflow corpus, damage, concurrency, transport framing, corrupt-file recovery). Holes: IPC round-trip covers ~25 of 124 cases, OptionStore scope-fallback untested, capture-pane `-e/-S/-E` untested. |
| **macOS-native + security** | both | **40** | *(critic-added axis)* Terminal grid is **invisible to VoiceOver** (0 NSAccessibility refs); **no secure keyboard entry** (passphrases keyloggable); OSC 7/8 inputs trusted without validation; unsandboxed + Sparkle + Services posture unaudited. |

**Confirmed strengths (don't touch — verified healthy):** Williams VT500 parser with colon sub-params + DoS bounds + CAN/SUB abort; full cursor/erase/edit/scroll-region/tab vocabulary (BCE, region-clamped scroll, poison-safe params); SGR styled/colored underlines + overline + strikethrough + faint + 256/truecolor in both colon and semicolon forms, **actually rendered**; Kitty keyboard 5-bit flag stack + all five progressive bits + key-up + modifyOtherKeys; reflow golden corpus + damage tracking; daemon single-lock serialization (a documented correctness invariant — do **not** redesign it); socket security is **0o600 + peer-UID check**; OSC 52 clipboard **read is safely refused** (exfil closed).

---

## Roadmap — incremental themed PRs

Effort: **S** < ~1 day · **M** a few days · **L** larger.

### P0 — Ship-blockers & top-tier (do first)

**PR-1 · Paste & escape-injection hardening** · safety · S · `[F21 + critic OSC 7/8]` · ✅ **Shipped (#115)**
- *Why:* A clipboard payload containing `ESC[201~` terminates bracketed paste early; everything after is delivered as typed input → command execution on paste, the exact attack bracketed paste exists to prevent. ghostty/kitty/foot all neutralize it. **Verified:** `encodePaste` (`InputEncoder.swift:244-247`) does zero stripping. Same threat class: OSC 7 cwd (`TerminalEmulator.swift:735-746`) feeds any `file://` path straight through with no validation, and OSC 8 hyperlink URIs aren't scheme-checked before the GUI opens them.
- *Approach:* In `encodePaste`, before wrapping, strip every `ESC[201~` (6-byte) and the 8-bit C1 ST `0x9C` from the body (delete, like kitty). Validate OSC 7 (`handleWorkingDirectoryOSC`) — require `file://`, reject non-absolute/non-existent paths before emitting `onWorkingDirectoryChange`. Scheme-allowlist OSC 8 / clicked-URL open paths (`http/https/file/mailto/ssh`; never `javascript:`/`data:`), confirm-before-open for unusual schemes.
- *Files:* `InputEncoder.swift`, `TerminalEmulator.swift`, `URLDetection.swift`, `HarnessTerminalSurfaceView.swift`. *Tests:* paste `a\e[201~b` → marker gone from inner payload; OSC 7 with a bogus/relative/`http` path → rejected; OSC 8 `javascript:` → not opened.

**PR-2 · Move layout.json off the synchronous critical path** · performance · M · `[F79]` · ✅ **Shipped (#116)**
- *Why:* `commit()` (`SurfaceRegistry.swift:1302-1305`) calls `store.saveImmediately()` — full-snapshot **prettyPrinted** JSON encode + synchronous atomic disk write — **under the registry lock on every mutation**, on the input-latency path, multiple times/sec under agent activity (`commit()` fires on agent-activity transitions, `:1047`). **Verified:** `SessionStore` already has a 0.5s-debounced `save()` confined to its own queue (`SessionStore.swift:37-56`) that `commit()` simply doesn't use, and a shutdown flush path already exists (`:1691`).
- *Approach:* Keep the revision bump + NotificationBus post under the lock; switch `commit()` from `saveImmediately()` to the existing debounced `save()`. Ensure the daemon-teardown / SIGTERM flush calls `saveImmediately`. Drop `.prettyPrinted` from the on-disk encoder (keep `.sortedKeys` for determinism). **Reuse the existing queue-confined debounce — no new infrastructure** (see Non-goals).
- *Files:* `SurfaceRegistry.swift`, `SessionStore.swift`. *Tests:* N rapid mutations → one debounced write; teardown flushes last state; round-trip after compacted encode.

**PR-3 · Secure keyboard entry** · security · S–M · `[critic HIGH]` · ✅ **Shipped (#117)**
- *Why:* **Verified absent everywhere** in Packages+Apps (0 refs). Without `EnableSecureEventInput`, any local process can keylog keystrokes typed at sudo/ssh-passphrase prompts inside Harness. Terminal.app and iTerm2 both ship this. Amplified by the app being unsandboxed.
- *Approach:* Add a "Secure Keyboard Entry" setting + menu toggle. Call `EnableSecureEventInput()`/`DisableSecureEventInput()` paired with window key/active state (must be balanced — disable on resign-active/terminate to avoid leaking the global lock). Persist the toggle in `HarnessSettings`.
- *Files:* `HarnessApp` (app delegate / window controller), `HarnessSettings.swift`, menu. *Tests:* unit-test the enable/disable balance accounting; manual verify via Activity Monitor / a keylogger probe.

**PR-4 · VoiceOver accessibility for the terminal grid** · accessibility · L · `[critic HIGH]` · ✅ **Shipped (#118)**
- *Why:* **Verified:** `HarnessTerminalSurfaceView.swift` (3946 lines) has **zero** accessibility API (no `isAccessibilityElement`, `accessibilityValue`, AXTextArea role, line/char navigation). VoiceOver users cannot read terminal output at all — a categorical exclusion from the product's core surface. Terminal.app and iTerm2 implement the NSAccessibility text protocols.
- *Approach:* Conform the surface view to `NSAccessibilityNavigableStaticText` / text-area semantics: expose `accessibilityRole = .textArea`, `accessibilityValue` = visible (or full scrollback) text, line-for-index / range-for-line / string-for-range, and cursor as the insertion point / selected range. Drive announcements off the existing damage stream. Map copy-mode selection to `accessibilitySelectedText`. Build incrementally: read-only value + line nav → cursor + selection → live-output announcements.
- *Files:* new `HarnessTerminalSurfaceView+Accessibility.swift`, engine `captureLines` (exists). *Tests:* unit-test the text-protocol math against a known grid; manual VoiceOver pass.

### P1 — Genuine correctness gaps (parity that's actually wrong/missing today)

**PR-5 · VT correctness cluster: DECSTR, REP, IRM, DECOM, DECALN** · ghostty-parity · L · `[F0,F1,F2,F3,F5,F94,F95]` · ✅ **Shipped (#120)**
- *Why:* Standard control functions with **no handler routed at all** (verified at `TerminalEmulator.swift:294-322` / `:630-644`). REP (`CSI b`) — ncurses `rep`/output optimizers → missing character runs. IRM (`CSI 4h`) insert mode → overwrite-on-type corruption in line editors. DECOM (mode 6) → region-relative addressing wrong, cursor escapes region. DECSTR (`CSI ! p`) → TUI cleanup soft-reset is a no-op (stale modes/margins leak). DECALN (`ESC # 8`) → vttest alignment blank.
- *Approach:* Add a **non-private** `CSI h/l` path (`setANSIMode`) for IRM (insert shifts line right) + LNM. Track last-printed scalar → REP repeats through the normal print path honoring wrap. Add `originMode` flag (DECSET 6): offset CUP/HVP/VPA by `scrollTop`, clamp to region, home on set/reset; a valid DECSTBM homes the cursor. Add `softReset()` (DECSTR: home, default pen, DECAWM on, DECTCEM on, origin off, IRM off, full region, ASCII charset — **not** clearing cells/history) on `intermediates==[0x21] && final=='p'`. Add `screenAlignmentTest()` for `ESC # 8`.
- *Files:* `TerminalEmulator.swift`, `TerminalScreen.swift`. *Tests:* one `EngineConformanceTests` golden each (esctest-derived where possible).

**PR-6 · DCS demux + DA1 Sixel advertisement** · ghostty-parity · M · `[F15,F16]` · ✅ **Shipped (#121)**
- *Why:* **Verified:** `parserDCS` (`TerminalEmulator.swift:329`) does `guard data.contains(0x71)` — everything containing `q` (incl. DECRQSS, whose `$q` payload literally contains `q`) is misrouted into Sixel decode and dropped. vim/neovim/tmux probe DECRQSS for SGR/DECSTBM/DECSCUSR; no reply → conservative/wrong fallbacks. DA1 doesn't advertise `;4`, so the **working** Sixel decoder is unreachable to capability-gating tools (img2sixel/lsix).
- *Approach:* Branch in `parserDCS` **before** Sixel: leading `$q` → DECRQSS (reply `DCS 1$r<data>ST` for DECSCUSR/SGR/DECSTBM, `DCS 0$r ST` on failure); leading `+q` → XTGETTCAP (reply Co/RGB/Tc); `tmux;` → unescape + re-feed. Gate the Sixel branch on a real introducer (optional `P1;P2;P3` then `q` at the **start**), not `q` anywhere. Add `;4` to DA1 when Sixel is enabled; add a minimal XTSMGRAPHICS responder.
- *Files:* `TerminalEmulator.swift`. *Tests:* DECRQSS round-trips for DECSCUSR/SGR; `tmux;` passthrough re-feeds; Sixel still decodes; DA1 advertises `;4`.

**PR-7 · Format engine: nest operators in conditional test + delete dead `wrapInline`** · tmux-parity · S · `[F66,F76]` · ✅ **Shipped (#119)**
- *Why:* `.tmux.conf` routinely writes `#{?#{==:#{pane_current_command},vim},...,...}`. **Verified:** `evaluateConditional` resolves the test via `resolve(token:)` (bare-token switch, `FormatString.swift:242`) → any operator/comparison test is "unknown" and always falsy; the else-branch always wins. The then/else branches already evaluate operators. `wrapInline` (`:249-254`) is a literal identical-branch no-op (`part.contains("#{") ? part : part`).
- *Approach:* Evaluate the test as a full expression (through `evaluate`/`evaluateToken`, not `resolve(token:)`). Delete `wrapInline`; use `parts[i]` at the two call sites.
- *Files:* `FormatString.swift`. *Tests:* `#{?#{==:a,a},Y,N}` → `Y`; `#{?#{m:foo,foobar},Y,N}` → `Y`.

**PR-8 · Copy-mode: correct the three wrong tmux action aliases** · tmux-parity · M · `[F62,F63]` · ✅ **Shipped (#122)**
- *Why:* Correctness bugs shipping today (verified in `CopyModeAction.swift`): `next-word-end` aliased to `.nextWord` (lands on word **start**), `top-line`/`bottom-line` aliased to history-top/bottom (jumps to scrollback **extent**, not the visible row), `back-to-indentation` aliased to `.startOfLine` (col 0, ignoring indent). Any vi user binding `e`/`H`/`L`/`^` gets wrong behavior. **Caveat: diff the intended `back-to-indentation`/`top/bottom-line` semantics against tmux source before shipping the behavior change.**
- *Approach:* Add distinct reducer cases `nextWordEnd`, `topLine`/`middleLine`/`bottomLine` (cursor = viewTop / viewTop+rows/2 / viewTop+rows-1), `backToIndentation` (first non-blank col). Unalias in `CopyModeAction`. Bind `e`, `H`/`M`/`L`, `^`.
- *Files:* `CopyModeAction.swift`, `CopyModeReducer.swift`. *Tests:* per-motion reducer tests incl. wide-char columns.

**PR-9 · set-option key validation + @user-options** · tmux-parity · M · `[F50,F51]` · ✅ **Shipped (#123)**
- *Why:* Directly violates the project's own STRICT no-silent-failure invariant. **Verified:** `setOption` checks scope + colon-safety but **not** the key name, so `set -g moused on` is silently persisted and never read. Separately, `@`-prefixed user-options (heavily used by theme/statusline `.tmux.conf` plugins) are accepted but `#{@foo}` always reads empty.
- *Approach:* Build a known-option vocabulary from `OptionStore.builtinDefaults` keys + the documented set; reject unknown keys in the IPC `setOption` handler with `.error("unknown option: <key>")` so every front-end inherits the loud failure — but **always accept** `@`-prefixed keys. Give `FormatContext` access to `OptionStore`; add a `#{@name}` branch reading via the scope chain.
- *Files:* `SurfaceRegistry.swift`, `OptionStore.swift`, `FormatString.swift`, `HarnessCLI.swift`. *Tests:* unknown key → error in CLI + `:` + source-file; `@foo` set then `#{@foo}` renders.

**PR-10 · status-position: honor the option or remove the dead toggle** · tmux-parity · M · `[F53,F69]` · ✅ **Shipped (#125)**
- *Why:* **Verified:** `status-position` is in `OptionStore` defaults and a Settings segment (bottom/top), but nothing in the layout (MainSplitViewController/StatusLineView/compositor) reads it. Toggling it does nothing — a present-but-ignored option is worse than absent.
- *Approach:* Anchor top vs bottom from `options.get("status-position")` in the GUI split controller (re-layout on the option-change snapshot nudge the registry already pushes) and mirror in the compositor's `PaneRectSolver` + `GridCompositor`. If top is out of scope, **remove** it from Settings and document the divergence in `TMUX_PARITY.md` — don't ship a dead toggle.
- *Files:* `MainSplitViewController.swift`, `StatusLineView.swift`, `WindowAttachClient.swift`, `GridCompositor.swift`.

### P2 — Test hardening & performance

**PR-11 · Wire-protocol + option-resolution + capture-pane tests** · tests · M · `[F90,F91,F92,F87]` · ✅ **Shipped (#126)**
- *Why:* **Verified** 124 IPC cases but the round-trip test covers ~25 requests / ~15 responses — the entire targeting/options/hooks/layout/grouped-session surface never round-trips (memory notes prior IPC version-skew breakage). `OptionStore`'s scope-fallback (the heart of tmux option semantics) and `capture-pane -e/-S/-E` (hand-rolled `stripANSI`) have no direct test. The 64-property hand-written `HarnessSettings` decoder silently drops a new setting whose decode line is missing.
- *Approach:* Drive the existing round-trip loop from a static `allCases`-style `[IPCRequest]/[IPCResponse]` fixture so a new enum case forces a sample (encode→decode→re-encode byte-stability). Add `OptionStoreTests` (per-scope set + most-specific get, top-down unset fallthrough, set/save/reload, builtinDefaults, keyAliases). Add `RealPty` tests for `stripANSI` (SGR/OSC-BEL/OSC-ST/truncated-CSI-at-EOF/DCS blob) and `captureRange`. Add a settings-decoder guard test: every-key-absent fixture → all defaults apply.
- *Files:* `IPCCodecTests.swift`, `OptionStoreTests.swift`, `RealPtyCaptureTests.swift`, settings guard test.

**PR-12 · Daemon perf: single per-tick process-tree snapshot** · performance · M · `[F80,F81]` · ✅ **Shipped (#127)**
- *Why:* The system-wide PID enumeration is invariant within a tick but recomputed for each surface (cwd walks + agent walks), scaling O(surfaces × system_processes); the GUI `SurfaceShellTracker` runs another full scan every 500ms for the same map. tmux/iTerm2 build a `pid→ppid` map once per refresh and reuse it. **Caveat: the "3× per tick" multiplier is unverified — re-measure (counter/Instruments) before committing; the direction is sound regardless.**
- *Approach:* Build the `pid→ppid` table once per tick in the daemon, thread it into both the cwd and agent walks (collapse 2N scans → 1). In the GUI, consume cwd from the daemon snapshot (daemon owns session truth) and retire the `SurfaceShellTracker` poll — or, if a transitional poll stays, slow it to 1.5s and drop the per-descendant `KERN_PROCARGS2` env read.
- *Files:* `SurfaceRegistry.swift`, `RealPty.swift`, `AgentDetector.swift`, `SurfaceShellTracker.swift`.

**PR-13 · Unify special-key encoding (mode-aware send-keys)** · tech-debt+correctness · M · `[F84]` · ✅ **Shipped (#128)**
- *Why:* Two independent escape-sequence encoders for the same domain (arrows, F-keys, Home/End, PgUp/Dn) hand-kept in agreement — and the keybinding/send-keys path uses the **mode-unaware** one. A key injected into a full-screen app that enabled DECCKM (vim/less) or Kitty mode gets the wrong bytes — a real correctness gap. tmux `send-keys` consults the target pane's cursor-key mode.
- *Approach:* Make `KeyTokenParser` parse tokens into the engine's `SpecialKey`/`KeyModifiers` vocabulary and delegate byte encoding to `InputEncoder`, threaded with the target surface's current `TerminalModes` (the daemon already owns the per-surface emulator). Collapses two encoders into one; pairs with PR-17's bindable send-keys.
- *Files:* `KeyTokenParser.swift`, `InputEncoder.swift`, `SurfaceRegistry.swift`, `HarnessCLI.swift`.

### P3 — Parity completion (features)

**PR-14 · Kitty graphics: ack, query (`a=q`), delete (`a=d`), transmit-once/place-many (`i=`)** · ghostty-parity · L · `[F23,F24,F25]` (+ `[F28]` iTerm2 px/% sizing) · ✅ **Shipped (#129)**
- *Why:* The decoder is solid but the protocol is display-only. No ack → probing tools (kitty icat, timg, chafa) hang or retransmit; `a=q` capability detection fails; no `a=d` → TUIs that redraw images leave stale ones; ignoring `i=` makes the idiomatic transmit-once/place-many model (basis of the unicode-placeholder protocol tmux/neovim image plugins use) impossible.
- *Approach:* (a) emit `ESC_Gi=<id>;OK ST` (or error) via `respond()` for any command not `q=2` — answer `a=q` first since detection gates everything; (b) maintain a transmitted-image table keyed by `i=`/`I=`, handle `a=t` (store w/o placing) and `a=p` (look up + place), keeping internal placement id separate; (c) add a delete path parsing `d=` (`d=a` all, `d=i` by id). **Animation (`a=a`) stays deferred** (`[F29]`).
- *Files:* `TerminalEmulator.swift`, `TerminalScreen.swift`, `Images/KittyGraphicsProtocol.swift`.

**PR-15 · Copy-mode motions: jump-to-char family, word-end, big-WORD, other-end, goto-line** · tmux-parity · M · `[F61,F64,F65,F93]` · ✅ **Shipped (#130)**
- *Why:* None of tmux's six jump commands (f/F/t/T + `;`/`,`) exist — a bound `jump-forward` is a parse-time failure. Plus big-WORD (W/B/E), `other-end` (`o`), and goto-line. Builds on PR-8's alias fixes.
- *Approach:* Add `jumpForward/Backward/ToForward/ToBackward` (+jump-again/reverse) carrying the pending target char (front-end captures the next keystroke like search entry); single-line char search in the reducer. Add whitespace-delimited W/B/E + `nextWordEnd`. Add `otherEnd` (swap anchor/cursor) and `gotoLine(Int)`. Wire `tmuxName` + init aliases + the `copy-mode-vi` key table.
- *Files:* `CopyModeAction.swift`, `CopyModeReducer.swift`. *Tests:* per-motion.

**PR-16 · Format engine operators: `!=`, `\|\|`, `&&`, `n:` then `T:`/`a:`/`p<N>:`** · tmux-parity · M · `[F67,F77]` · ✅ **Shipped (#131)**
- *Why:* After PR-7's nested-condition fix, these are the remaining high-frequency operators in real `.tmux.conf`. Each is a small dispatch branch; `n:` reuses `DisplayWidth`.
- *Approach:* Prioritize `!=:`, `||:`, `&&:`, `n:` (length); then `T:` (expand twice), `a:` (char from code), `p<N>:` (padding), `f[N]` float precision. *(Loop modifiers `#{W:/P:/S:}` `[F68]` + centre window-list `[F70]` are larger/lower priority given the native GUI tab bar — see Long-tail.)*
- *Files:* `FormatString.swift`. *Tests:* per-operator.

**PR-17 · Bindable send-keys `-l`/`-H`, display-message `-p`, missing hooks + lifecycle hook tests** · tmux-parity · M · `[F55,F52,F71,F98]` · ✅ **Shipped (#132)**
- *Why:* `send-keys -l/-H` work from the CLI but are silently dropped from bind/`:`/hooks/source-file. `display-message -p` (print rendered format to stdout) is the dominant scripted use and is impossible. `pane-focus-in/out` hooks can wire off the existing focus-reporting path; `command-error` fires from the executor's error path. Hook firing is fragile (memory notes a deeper-than-reported context bug) and several events lack a firing test.
- *Approach:* Carry literal/hex mode on `Command.sendKeys` (enum), parse `-l/-H` in the bindable parser routing to the existing `sendData` byte path (unifies the two send-keys paths — pairs with PR-13). Add `-p` to `display-message`. Add `pane-focus-in/out`, `command-error`, `window-pane-changed` to `HookRegistry`. Extend `HookFiringTests` with one firing assertion per remaining event, driven from a list so new events force a test.
- *Files:* `CommandParser.swift`, `HarnessCLI.swift`, `HookRegistry.swift`, `HookFiringTests.swift`.

**PR-18 · clear-history (off the deferred ledger) + status-interval** · tmux-parity · S–M · `[F59,F73]` · ✅ **Shipped (#133)**
- *Why:* `clear-history` is one-keystroke muscle memory (`bind C-k clear-history`) and Harness can currently **only** clear by respawning the shell (kills the process). The file-clear primitive (`ScrollbackFile.clear`) already exists; the missing piece is a non-respawn path + verb. `status-interval` (a repeating status-refresh timer) is a cheap bundled add.
- *Approach:* Add a `clear-history` verb routing to `ScrollbackFile.clear` + an emulator scrollback reset **without** respawning (distinct from `respawn-pane -k`); wire through `CommandParser` + IPC + CLI. Add a `status-interval`-gated repeating timer in `WindowAttachClient` + the GUI status strip. Update `TMUX_PARITY.md`. Keep `resize-window`/`window-size`/`list -F` deferred; re-confirm the ledger.
- *Files:* `SurfaceRegistry.swift`, `RealPty.swift`, `CommandParser.swift`, `WindowAttachClient.swift`, `docs/TMUX_PARITY.md`.

### P4 — UX backlog (ghostty + CLAUDE.md)

**PR-19 · Audible + visual bell** · ux · M · `[F34,F41,F74]` · ✅ **Shipped (#136)**
- *Why:* A focused-window `\a` produces **no** feedback today — only a tmux window-flag + background notification. The plumbing exists end-to-end (`onBell` → host delegate → coordinator); only the focused-path action is missing. Baseline terminal expectation + explicit CLAUDE.md backlog.
- *Approach:* Add a bell setting (off/audible/visual/both) honored on every BEL regardless of `NSApp.isActive`: audible = `NSSound.beep()`; visual = a one-shot inverse/flash overlay on the ringing surface. Keep the unfocused-notification path. Also wire the tmux `visual-bell`/`visual-activity`/`visual-silence` + `*-action` knobs through the existing alert path.
- *Files:* `SessionCoordinator.swift`, `HarnessTerminalSurfaceView.swift`, `HarnessSettings.swift`.

**PR-20 · Ghostty UX quick wins: scroll-multiplier, mouse-hide-while-typing, config reload-on-save, triple-click logical line** · ux · M · `[F45,F46,F42,F47]` · ✅ **Shipped (#135)**
- *Why:* Four small, self-contained, high-recognition ghostty features on the backlog. Scroll speed is a fixed 3-lines/tick constant; the cursor never hides on type; `settings.json` isn't watched; triple-click selects only the display row, not the soft-wrapped logical line (the wrap model already exists for reflow + `capture-pane -J`).
- *Approach:* `scrollMultiplier: Double` multiplied into `consumeWheelLines`/`continuousWheelLines`. `mouseHideWhileTyping`: `NSCursor.setHiddenUntilMouseMoves(true)` in `keyDown` gated on a setting. Config reload: `DispatchSource.makeFileSystemObjectSource` on settings/keybindings → debounce → existing `applySettings`. Triple-click: walk the existing `rowWrapped` flags up/down from the clicked row.
- *Files:* `HarnessTerminalSurfaceView.swift`, `HarnessSettings.swift`, `HarnessApp`.

**PR-21 · Quick terminal (global-hotkey dropdown), find-bar regex, unlimited scrollback** · ux · M–L · `[F40,F48,F49]` · ✅ **Shipped (#138)**
- *Why:* Quick terminal (Quake dropdown) is an explicit backlog item (medium). Find bar is substring-only (no regex/case toggle). Scrollback is a fixed bounded count with no unlimited option.
- *Approach:* Quick terminal: an `NSPanel` (`.nonactivatingPanel`, `canJoinAllSpaces`, `.floating`) hosting a dedicated daemon-backed surface, summoned by a global hotkey (`RegisterEventHotKey`/CGEvent monitor), behind a setting. Find: optional `NSRegularExpression` mode + case toggle in `TerminalBufferSearch` + two `TerminalFindBar` buttons. Scrollback: treat `scrollbackLines == 0` as unbounded in `OptionStore` + `ScrollbackFile` (verify the file can grow safely / byte-cap).
- *Files:* `HarnessApp` (panel), `TerminalBufferSearch.swift`, `TerminalFindBar.swift`, `HarnessSettings.swift`, `ScrollbackFile.swift`.

### P5 — Tech debt & polish

**PR-22 · Decompose oversized files (mechanical, zero behavior change)** · tech-debt · L · `[F85,F86,F87,F88,F89]` · ➡️ **Superseded by [V1_10_ROADMAP.md](V1_10_ROADMAP.md) PR-30/PR-31/PR-32**
- *Why:* The only structural debt in an otherwise healthy codebase. The 3946-line `HarnessTerminalSurfaceView` mixes 8+ responsibilities; the 1776-line `SurfaceRegistry` is a God object (124-case switch + PTY lifecycle + monitoring + hooks + banner); the 64-property hand-written `HarnessSettings` decoder is a forward-compat hazard. These are merge-conflict magnets.
- *Approach:* Split the surface view along existing `MARK` seams into **same-class extension files** (`+Selection/+Find/+CopyMode/+Input/+IME/+LinkHover`) — zero behavior change. Extract `SurfaceMonitor` + the version-banner one-shot out of `SurfaceRegistry` **behind the same lock seam** (the single-lock serialization is a documented correctness invariant — **do not redesign it**). Replace the hand-written settings decoder with a default-instance-driven decode helper (or, cheapest, the guard test from PR-11). Add a `TerminalRenderInstances.swift` extraction; extract `SessionEditor` split-tree algebra into `+SplitTree.swift`. **Strictly mechanical.**
- *Files:* `HarnessTerminalSurfaceView.swift`, `SurfaceRegistry.swift`, `HarnessSettings.swift`, `TerminalMetalRenderer.swift`, `SessionEditor.swift`.

**PR-23 · VT polish + safety hardening cluster** · ghostty-parity+safety · M · `[F8,F9,F10,F12,F14,F33,F82,F83,F4,F100,F22,F36,F6]` · ➡️ **Superseded by [V1_10_ROADMAP.md](V1_10_ROADMAP.md) PR-29**
- *Why:* A tail of small correctness/polish items worth batching: richer DA1 (`?62;22c`), DA3 reply, non-private DECRQM, mode 1048 save/restore cursor, att610 cursor-blink (mode 12), CSI t title-stack push/pop (22/23) + size reports (18/14), underline-pattern continuous phase, DECSET 1003 any-event motion, SGR blink rendering (off-phase dim via the existing cursor-blink timer), DECSCNM reverse-video (mode 5), `HistoryRingBuffer`'s release-shipping `precondition` that defeats its own graceful-degradation intent, and a per-connection partial-frame cap in `DaemonServer`.
- *Approach:* Batch the trivial emulator replies; phase underline decorations on absolute grid X + widen undercurl period; report 1003 motion in `mouseMoved` when `mouseAny` set; fold a blink-phase bit into the row content key so only blink rows re-encode; add `reverseScreen` swap in `CellColorResolver`; drop the release-shipping `precondition` in `HistoryRingBuffer` subscript (keep the assert); add the partial-buffer ceiling. Add the DECRQM-unrecognized-mode (state 0) conformance test.
- *Files:* `TerminalEmulator.swift`, `TerminalMetalRenderer.swift`, `CellColorResolver.swift`, `HistoryRingBuffer.swift`, `DaemonServer.swift`.

**PR-24 · Security posture review (investigation + decisions, not a feature)** · security · S–M · `[critic MED/LOW]` · ➡️ **Superseded by [V1_10_ROADMAP.md](V1_10_ROADMAP.md) PR-36**
- *Why:* Named in the brief ("packaging/update path") but unaudited: app ships `app-sandbox=false` + Sparkle auto-update + a Services provider; hardened-runtime/library-validation/notarization posture never assessed. Scrollback persists raw PTY output (echoed secrets, `env` dumps, key material) to disk — owner-only `0o700` (good) but **no do-not-persist/redaction** per sensitive surface. IME depth (dead keys, CJK candidate commit timing, wide marked-text width) never systematically audited beyond the preedit overlay.
- *Approach:* Audit `Harness.entitlements` + hardened-runtime flags; document the rationale for no-sandbox and confirm notarization/library-validation. Add a per-surface "don't persist scrollback" option (and document the secrets-at-rest decision even if "won't redact"). Run a focused IME pass (dead-key compose, CJK candidate commit, wide marked-text width). Output: a short security/posture doc + any small fixes that fall out.
- *Files:* `Harness.entitlements`, `ScrollbackFile.swift`, `HarnessSettings.swift`, IME path in `HarnessTerminalSurfaceView.swift`.

### Long-tail (batched, low priority — track, don't rush)

Fold into the nearest themed PR or a dedicated cleanup PR.
- **`[F18]`** OSC 17/19 selection/highlight color set/query — fold into any future color-override layer.
- **`[F20]`** OSC 1337 `CurrentDir=` (→ `onWorkingDirectoryChange`) + `SetUserVar=` (→ per-surface user-var dict feeding format tokens). *(Pairs with PR-9 `@user-options`.)*
- **`[F26]`** SGR-pixel mouse (1016) — add once 1006 plumbing carries pixel offsets. *(Bundle with PR-23's 1003 work.)*
- **`[F30]`** DECKPAM/DECKPNM — mode flag exists; add keypad `SpecialKey` SS3 emission. *(Bundle with PR-13/PR-17 encoder work.)*
- **`[F54]`** display-panes honors `display-panes-time`/`-colour` + `pane-base-index`.
- **`[F56]`** new-window/new-tab `-d` (detached) + `-a/-b` insertion position.
- **`[F57]`** show-options single-key query (`show-options -g status`) + `-v`.
- **`[F60]`** set `-F` (format expansion at set time) — relevant once `@user-options` land.
- **`[F68]`** format loop modifiers `#{W:/P:/S:}` (iterate windows/panes/sessions) — larger; pairs with F70.
- **`[F70]`** status-justify + centre window-list (depends on F68). *(Native GUI tab bar substitutes; document in ledger.)*
- **`[F58]`** map the **safe** status styles (`status-style`/`message-style`/`mode-style`, length caps); reject/ledger the window-status-format family.
- **`[F72]`** copy-mode `wrap-search` + `word-separators` options (deferred ledger).
- **`[F75]`** command-prompt input history (deferred ledger).
- **`[F78]`** FrameBuilder `RenderCell` pool + ligature-scratch reuse + per-page atlas LRU.
- **`[F27]`** iTerm2 multipart inline-image upload (niche).
- **`[F32,F99]`** legacy X10 mouse >col-223 — suppress vs clamp; add the >223 test.
- **`[F96,F97]`** add tests: custom tab-stops surviving resize; underline-style propagation into the render frame.
- **`[F11]`** SGR superscript/subscript (73/74/75) optional; explicitly ignore framed/encircled (51/52) — ledger note.
- **`[F39]`** font-feature setting (OpenType feature dict via CTFontDescriptor) — lower priority than rendering parity.
- **`[F37]`** double-line box-drawing (U+2550–256C) procedural. **`[F38]`** sextants/octants/Braille (U+1FB00+, U+2800+) procedural.

---

## Deliberate non-goals (found, but should NOT be built)

Document each in `TMUX_PARITY.md`/handbook so they aren't re-flagged.
- **DECCOLM 132-col resize + xterm window resize/move (CSI t 4/8) `[F7, part F4]`** — wrong for a windowed/tiling terminal; at most honor the clear-and-home side effect.
- **SGR framed/encircled 51/52 `[F11]`** — ghostty itself doesn't render them; explicitly ignore.
- **OSC 52 clipboard-read default-allow `[F19,F43]`** — current silent-deny is the **safe** default. If ever added, it must be a separate **default-deny** `clipboard-read=ask` option with a prompt; **never weaken** to default-allow.
- **Dynamic OSC 4/10/11/12 color SET as from-scratch palette mutation `[F17,F31,F35,F44]`** — these are **one** backlog item, not four; design is "theme owns the canvas." If pursued, do **only** a per-surface override layer over the theme (cursor color OSC 12 first, lowest blast radius); **never** let programs corrupt persisted theme state.
- **Legacy mouse modes X10 (9), urxvt 1015, UTF-8 1005, grapheme 2027, DECSDM 80 `[F13,F32,F99]`** — SGR 1006 covers essentially all real usage; treat as deferred (1016 is the only one worth doing, in PR-23).
- **Kitty graphics animation (`a=a`) `[F29]`** + **iTerm2 multipart upload `[F27]`** — niche; defer behind PR-14's core transmit-once/delete/ack.
- **Full tmux status window-list port (window-status-format/status-justify/centre) `[F58,F68,F70]`** — Harness renders windows as a **native GUI tab bar**, a legitimate adaptation; map only safe base styles; document the substitution.
- **A retries/session-manager/daemon-supervisor abstraction for the perf fixes `[F79,F80,F81]`** — reuse the **existing** debounced `SessionStore.save()` and thread a single `pid→ppid` snapshot; introduce **no new infrastructure**.
- **Redesigning `SurfaceRegistry`'s single-lock serialization seam (during PR-22)** — it's a documented correctness invariant; decomposition stays strictly mechanical.

---

## Critic caveats — verify before acting

- **OSC 52 read is already safely refused** — the dangerous half (clipboard exfil) is closed (`TerminalEmulator.swift:546-557`). Credit it; don't "fix" it into default-allow.
- **"3× per-tick process scan" (PR-12) is unverified** — re-measure before committing the M-effort change. Direction is sound; the multiplier is an estimate.
- **Copy-mode "wrong aliases" (PR-8)** — diff `back-to-indentation`/`top-line`/`bottom-line` against tmux source before shipping; users may have adapted to current behavior.
- **"No dead code" is slightly overstated** — `wrapInline` is provably dead (PR-7 removes it); the sweep wasn't exhaustive.

---

## Verification & delivery

**Per PR:** smallest correct diff; `swift test` green (+ `HARNESS_LIVE_DAEMON_TESTS=1` where the change touches daemon/PTY); `xcodebuild ... build test` on macOS; CI green on both macOS and Linux-headless before merge. Match repo conventions: `@MainActor` for AppKit, no off-main NSView mutation, comments only for non-obvious invariants.

**Conformance:** VT changes (PR-5/6/23) get `EngineConformanceTests` goldens derived from esctest/vttest expectations where available; assert against **expected behavior**, not just path-agreement.

**Live checks:** drive the preview app (`make preview`) for GUI-facing PRs (bell, quick terminal, secure-input toggle, a11y) and verify with VoiceOver / a keylogger probe / paste of a hostile clipboard payload as appropriate.

**Cadence:** themed PRs merged in priority order; cut release trains (`make release-notes` → `gh workflow run release.yml`) at natural milestones (e.g. after P0 = a security/correctness release, after P1, …). Update `CHANGELOG.md` + `TMUX_PARITY.md` per PR that changes user-facing behavior or the ledger.

**Sequencing:** PR-13 (encoder unify) before PR-17 (shared files); PR-8 before PR-15 (motions build on alias fixes); PR-7 before PR-16 (operators build on the nested-conditional fix).

---

## Appendix — finding-ID index (selected)

| ID | Area | Sev | PR |
|---|---|---|---|
| F21 | bracketed-paste injection | high | PR-1 |
| F79 | layout.json sync write on critical path | high | PR-2 |
| F0,F1,F2,F3,F5,F94,F95 | DECSTR/REP/IRM/DECOM/DECALN cluster | med | PR-5 |
| F15,F16 | DCS demux + DA1 Sixel | med | PR-6 |
| F66,F76 | format nested conditional + dead wrapInline | med | PR-7 |
| F62,F63 | copy-mode wrong aliases | med | PR-8 |
| F50,F51 | set-option validation + @user-options | med | PR-9 |
| F53,F69 | status-position dead toggle | med | PR-10 |
| F90,F91,F92,F87 | IPC/option/capture-pane/settings tests | high/med | PR-11 |
| F80,F81 | daemon process-scan dedup | med | PR-12 |
| F84 | duplicated mode-unaware key encoder | med | PR-13 |
| F23,F24,F25 | Kitty graphics ack/query/delete/i= | med | PR-14 |
| F61,F64,F65,F93 | copy-mode jump/word-end/big-WORD/other-end | low | PR-15 |
| F67,F77 | format operators !=/\|\|/&&/n:/T:/a:/p | low | PR-16 |
| F55,F52,F71,F98 | bindable send-keys/display-message/hooks | low | PR-17 |
| F59,F73 | clear-history + status-interval | low | PR-18 |
| F34,F41,F74 | audible/visual bell | low | PR-19 |
| F45,F46,F42,F47 | scroll-mult / mouse-hide / config-reload / triple-click | low | PR-20 |
| F40,F48,F49 | quick terminal / find regex / unlimited scrollback | med/low | PR-21 |
| F85,F86,F87,F88,F89 | oversized-file decomposition | low | PR-22 |
| F8,F9,F10,F12,F14,F33,F82,F83,F4,F100,F22,F36,F6 | VT polish + safety cluster | low | PR-23 |
| (critic) | secure keyboard entry · VoiceOver a11y · OSC 7/8 validation · posture | high/med | PR-3, PR-4, PR-1, PR-24 |

*Full 101-finding detail (evidence, file:line, reference behavior) is in the audit run; this index lists the ones routed to PRs. Low-priority orphans are in the Long-tail and Non-goals sections above.*
