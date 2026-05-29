# Native terminal renderer — handoff

Status of the from-scratch, self-contained terminal stack that replaces the external
**libghostty fork** (`robzilla1738/libghostty-spm-fork`, products `GhosttyTerminal` +
`GhosttyTheme`). Branch: **`claude/macos-terminal-colors-N3rKO`**.

Goal: Harness becomes "its own thing" — Ghostty-grade crisp color (Display-P3 + sRGB),
485-theme catalog, `.harnesstheme` export/sharing, full customization, opacity/blur — with
**no Ghostty dependency**. Approach: build a native engine + Metal renderer behind a clean
module boundary, keep the fork as an **A/B test oracle** until the very end (Phase 8).

## How to work this branch

- Build/test on macOS (Xcode 16+, Swift 6): `swift build`, `swift test`.
- Per-suite: `swift test --filter HarnessTerminalEngineTests` / `HarnessThemeTests` /
  `HarnessTerminalRendererTests` / `HarnessTerminalKitTests`.
- The repo was developed largely from a Linux cloud VM (no Swift toolchain there), so each
  step was pushed and verified on the Mac. Continue that loop, or just build locally now.
- Commit messages end with the session link line already used in history.

## Done and verified (all green: 81 unit/offscreen tests + `swift build`)

New packages (all additive, isolated, pure-Swift unless noted):

| Module | Path | What |
|---|---|---|
| `HarnessTerminalEngine` | `Packages/HarnessTerminalEngine` | VT100/220/xterm parser (CSI/OSC/SGR incl. colon subparams), screen model (alt screen, scroll regions, autowrap, UTF-8/wide-char), `HarnessGridTerminal` headless `readGrid`, `TerminalEmulator`, `InputEncoder` (keyboard→bytes), `TerminalModes` |
| `HarnessTheme` | `Packages/HarnessTheme` | `RGBColor`, `HarnessThemeDefinition`, `HarnessThemeCatalog` (9 curated builtins + bundled `Resources/themes.json` = **485 themes**), `ThemeDocument` (`.harnesstheme` format), `ThemeFileService` (export/import/install) |
| `HarnessTerminalRenderer` | `Packages/HarnessTerminalRenderer` | `ANSIPalette` (256), `CellColorResolver` (palette/bold-bright/faint/inverse/conceal → RGB), `FrameBuilder` (snapshot+theme → `TerminalFrame`), `GlyphRasterizer` (CoreText coverage bitmaps), `GlyphAtlas` (R8 texture), `TerminalMetalRenderer` (runtime shaders, instanced bg+glyph passes, offscreen + `present(to:CAMetalDrawable)`) |

Integrated into the app (off the fork already):
- **`harness attach`** runs on the native engine (`GridCompositor` + `WindowAttachClient`
  use `HarnessGridTerminal`). `Tests/HarnessTerminalKitTests/EngineOracleTests.swift` diffs
  the native engine vs Ghostty `GridTerminal` cell-by-cell — **the cutover gate; keep it green.**
- **`ThemeManager` + `HarnessChrome`** read from `HarnessThemeCatalog` (not `GhosttyTheme`).
  No production file imports `GhosttyTheme` anymore — only the test exporter does.

Live view, built but **NOT yet wired in**:
- `Packages/HarnessTerminalKit/Sources/HarnessTerminalKit/HarnessTerminalSurfaceView.swift`
  — `CAMetalLayer` `NSView`: drives a `TerminalEmulator`, draws with `TerminalMetalRenderer`,
  `receive(_:)` for PTY bytes, `onInput`/`onResize` closures, keyboard via `InputEncoder`,
  live resize, colorspace tagging. Compiles; not referenced by the app yet.

## What's left

### Chunk 4 — go live (the immediate next step)
Wire `HarnessTerminalSurfaceView` into `TerminalHostView`
(`Packages/HarnessTerminalKit/Sources/HarnessTerminalKit/TerminalHostView.swift`) **behind a
`useNativeRenderer` flag** so the Ghostty path is untouched when off (safe A/B).

1. Add `useNativeRenderer: Bool = false` to `HarnessSettings`
   (`Packages/HarnessCore/.../Settings/HarnessSettings.swift`): the memberwise `init` (line ~62),
   the `init(from:)` decoder (line ~182, `decodeIfPresent ... ?? fallback`), and the property
   list (~line 60). CodingKeys are auto-synthesized.
2. In `TerminalHostView`, when the flag is on: create a `HarnessTerminalSurfaceView` instead of
   Ghostty's `terminalView`, add it as the filling subview, and wire:
   - `nativeView.onInput = { inputGate.route($0) }` (to the PTY)
   - `nativeView.onResize = { cols, rows in io.resize(rows: UInt16(rows), cols: UInt16(cols)) }`
   - daemon output subscription + `replayScrollback` → `nativeView.receive(...)` (instead of
     `memorySession.receive`)
   - first responder, `applyTheme`/`applySettings`, `focusTerminal` → native view
3. Surface title/cwd/bell from the native view to `hostDelegate`: add `onTitle`/`onPwd`/`onBell`
   closures to `HarnessTerminalSurfaceView` that forward `emulator.onTitleChange` /
   `onWorkingDirectoryChange` / `onBell` (the emulator already exposes these).
4. **Verify by running the app** (`make build` / Xcode), flip the toggle, and iterate on the
   live visuals. Expect first-pixel fixes: cursor style/blink, window padding (apply
   `windowPaddingX/Y`), font-size→cell metrics, vertical glyph baseline, selection (not built
   yet). Compare side-by-side with Ghostty (flag off).

### Follow-ups (after it renders live)
- **Mouse reporting** (SGR 1006), **text selection + copy/copy-on-select**, **scrollback view**
  (engine renders the viewport; daemon owns history — decide how to scroll back), **IME / dead
  keys** (call `interpretKeyEvents` / adopt `NSTextInputClient`), **ligatures**, **procedural
  box-drawing/block glyphs** for pixel alignment, **damage tracking** (only redraw dirty rows),
  **window padding + opacity/blur** parity (keep CGS `WindowBlur` + `MainWindowController`).
- **Theme export/import UI** in `SettingsViewController` (NSSavePanel/NSOpenPanel via
  `ThemeFileService`) + register the `.harnesstheme` doc type in `Info.plist` + handle
  `application(_:open:)` for double-click install.
- **"Apply theme to terminal output" toggle** (sync the 16-color palette into the terminal vs
  keep it standalone) — `HarnessSettings` bool plumbed to the surface's `FrameBuilder`/resolver.
- **Phase 8 — remove the fork**: once the native view is the only renderer, delete
  `libghostty-spm-fork` from `Package.swift` / `project.yml` / `Package.resolved`, delete
  `EngineOracleTests` + `ThemeCatalogExportTests` (their only reason is the oracle/port), drop
  the residual `GhosttyTerminal` import in `ThemeManager` (the no-op `configureBuilder` +
  `TerminalColorPipeline`), and `grep -ri ghostty` to confirm zero references.

## Gotchas already hit (so you don't re-learn them)
- **`RGBColor` vs QuickDraw**: any file importing AppKit (or `GhosttyTerminal`, which pulls in
  AppKit) sees Apple's C `struct RGBColor`. Pin with `private typealias RGBColor =
  HarnessTheme.RGBColor` in such files (see `ThemeCatalogExportTests.swift`). The surface view
  avoids it by never naming `RGBColor`.
- **`MTLRenderPipelineColorAttachmentDescriptorArray[0]` is optional** in this SDK — force-unwrap.
- **Atlas/texture storage mode**: `.shared` on unified memory (Apple Silicon), `.managed` on
  discrete GPUs (`device.hasUnifiedMemory`).
- **The fork's catalog**: `GhosttyThemeCatalog.search("")` returns empty; use `.allThemes`.
  Width type is `TerminalGridCellWidth` (ours is `TerminalCellWidth`).
- **Regenerate `themes.json`**: `EXPORT_THEMES=1 swift test --filter ThemeCatalogExportTests`.

## Verification checklist
- `swift test` (all suites green, incl. `EngineOracleTests`).
- `swift build` (whole app compiles).
- After chunk 4: run app, toggle `useNativeRenderer`, confirm typing/vim/ls colors render and
  match Ghostty; check `harness attach` still works.
