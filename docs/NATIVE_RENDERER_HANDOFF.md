# Native terminal renderer — handoff

**STATUS: COMPLETE.** The from-scratch, self-contained terminal stack has fully replaced the
external **libghostty fork**. The fork dependency is **removed** — `swift build` resolves zero
external packages, `grep -rn "import GhosttyTerminal\|import GhosttyTheme"` is empty, and the
GUI/CLI render entirely on `HarnessTerminalEngine` + `HarnessTheme` + `HarnessTerminalRenderer`
via `HarnessTerminalSurfaceView`. Branch: **`claude/macos-terminal-colors-N3rKO`**.

Goal (achieved): Harness is "its own thing" — crisp color (Display-P3 + sRGB), 485-theme
catalog, `.harnesstheme` export/sharing, themed translucent canvas with untouched output,
window padding, cursor styles + blink, text selection + copy, mouse reporting, scrollback,
and IME — with **no Ghostty dependency**.

The only remaining "ghostty" references are the **opt-in config import** (`GhosttyConfigImporter`
reads `~/.config/ghostty` so users migrating from Ghostty.app keep their colors/font — kept by
product decision) and some historical code comments.

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

Live view, built **and now wired in behind the flag**:
- `Packages/HarnessTerminalKit/Sources/HarnessTerminalKit/HarnessTerminalSurfaceView.swift`
  — `CAMetalLayer` `NSView`: drives a `TerminalEmulator`, draws with `TerminalMetalRenderer`,
  `receive(_:)` for PTY bytes, `onInput`/`onResize`/`onTitle`/`onPwd`/`onBell` closures,
  keyboard via `InputEncoder`, live resize, colorspace tagging.
- `TerminalHostView` now branches on `HarnessSettings.useNativeRenderer`: when on it builds
  **only** the native surface (no offscreen Ghostty surface/Metal at all — the Ghostty
  `terminalView`/`controller`/`memorySession` stay nil) and routes daemon PTY output, input,
  resize, theme, settings, focus, and title/cwd/bell through it. Flag default off ⇒ the
  Ghostty path is byte-for-byte unchanged.
- Settings ▸ Color rendering has a **"Native renderer (experimental)"** toggle. Flipping it
  calls `SessionCoordinator.rebuildTerminalHosts()` (drop all hosts → bump `structureRevision`
  → remount) so live panes swap engines without losing the daemon-owned shell/scrollback.

## What's left

### Chunk 4 — go live
Steps 1–3 are **done** (`swift build` + all 271 unit tests green, incl. the `EngineOracleTests`
cutover gate):

1. ✅ `useNativeRenderer: Bool = false` added to `HarnessSettings` (property, memberwise `init`,
   `init(from:)` decoder).
2. ✅ `TerminalHostView` branches on the flag (see "Live view" above). Made the Ghostty
   `terminalView`/`controller`/`memorySession` optional so they're never constructed on the
   native path; added `configureNative(...)` + a `deliverOutput(...)` router; `applyTheme` /
   `applySettings` / `focusTerminal` / `viewDidMoveToWindow` / `layout` all branch.
3. ✅ `onTitle`/`onPwd`/`onBell` added to `HarnessTerminalSurfaceView`, forwarded from
   `emulator.onTitleChange` / `onWorkingDirectoryChange` / `onBell` to `hostDelegate`.
   Plus the Settings toggle + `rebuildTerminalHosts()` live-swap.

   Note: prefix (`Ctrl-A`) still works on the native path — `PrefixKeymap` is a global
   `NSEvent` local monitor that swallows consumed keys before the responder chain, so it
   doesn't depend on which view is first responder.

4. **Still to do — verify by running the app** (`make preview`, toggle on in Settings ▸ Color
   rendering, or pre-seed `.harness-preview/settings.json` with `"useNativeRenderer": true`).
   Iterate on the live visuals; expected first-pixel fixes: cursor style/blink (native draws a
   plain block cursor only), window padding (native ignores `windowPaddingX/Y` today),
   font-size→cell metrics, vertical glyph baseline, selection (not built yet). Compare
   side-by-side with Ghostty (flag off).

### Done since go-live (verified live in `make preview`)
- ✅ **Themed canvas (no seam) + untouched output + translucency/blur.** The native surface's
  canvas (default bg/fg/cursor) now resolves through the SAME `ThemeManager.resolvedCanvas` the
  chrome uses (`TerminalHostView.applyNativeAppearance` → `HarnessTerminalSurfaceView.configureAppearance`),
  so terminal and chrome never seam (this also fixed a "line at the top" that was the
  canvas/chrome color mismatch). Program **output** keeps untouched/default ANSI colors
  (`ThemeManager.defaultBaselinePaletteHex`) unless **`HarnessSettings.applyThemeToTerminalOutput`**
  (Settings ▸ Color rendering toggle, default off) is on, which feeds the theme's 16-color
  palette to the resolver. The canvas is **translucent** when `backgroundOpacity` < 1:
  `FrameBuilder.canvasOpacity` applies alpha to default-bg cells only (glyphs + explicit program
  backgrounds stay opaque), the Metal clear uses the same alpha, and the layer goes non-opaque so
  the window-wide CGS blur shows through — matching the chrome glass. `contentsGravity = .topLeft`
  parks any sub-cell remainder at the bottom-right.
- ✅ **Window padding** — `windowPaddingX/Y` inset the grid (device px); the renderer draws at
  that `origin` offset and the canvas fills the padding region.
- ✅ **Cursor style + blink** — block/bar/underline (`CursorStyle` on `CursorRender`, drawn by
  `TerminalMetalRenderer`); `settings.cursorBlink` drives a 0.53s timer that hides the cursor on
  the off-beat while focused, woken solid by typing/output/focus.
- ✅ **Text selection + copy + copy-on-select** — `TerminalSelection` (normalized linear span)
  highlights via `FrameBuilder`; mouse drag in `HarnessTerminalSurfaceView` builds it (point→cell
  accounts for padding + scale + AppKit's bottom-left origin); ⌘C / Edit▸Copy / copy-on-select
  extract (wide-char aware, trailing-trimmed, `\n`-joined) to `NSPasteboard` + the daemon paste
  buffer. **Verify the highlight with a real mouse drag** — automated drag tests are flaky.

### Done
- ✅ **Mouse reporting** (SGR 1006 + legacy X10) — `InputEncoder.encodeMouse`; surface routes
  down/drag/up/right/middle/wheel to the PTY when tracking is on (Shift forces selection).
- ✅ **Scrollback** — engine history ring on the primary screen; surface scrolls via wheel +
  Shift+PageUp/Down, stays anchored during output, snaps to bottom on typing.
- ✅ **IME / dead keys** — `NSTextInputClient`; plain keys route through `interpretKeyEvents`,
  preedit drawn over the grid, candidate window anchored at the cursor.
- ✅ **Phase 8 — fork removed** — deleted `libghostty-spm-fork` from `Package.swift` /
  `project.yml` (and `Package.resolved` is gone — no external deps); `TerminalHostView` is
  native-only (the Ghostty `terminalView`/controller/session path is deleted); removed the
  `useNativeRenderer` flag + toggle; deleted `TerminalColorPipeline`/`TerminalColorspace` +
  the oracle/export/headless tests; dropped the `GhosttyTerminal` import from `ThemeManager`
  and the libghostty debug block from `AppDelegate`.

- ✅ **Line decorations** — Metal `deco_fragment`: antialiased underline (single/double/dotted/
  dashed) + **undercurl** + strikethrough + overline in the resolved color.
- ✅ **Cursor-text inversion** — glyph under a block cursor draws in the cursor-text color.
- ✅ **Gamma-correct (linear) blending** — `linearBlending` applies a coverage gamma to glyphs.
- ✅ **Ligatures** — CoreText run shaping (`GlyphRasterizer.shape`), grid-snapped to source
  cells; `ligatures` setting (default on) + toggle.
- ✅ **Wide IME preedit** — composing text is wide-char aware (`CharacterWidth`) and underlined.
- ✅ **De-Ghostty** — config import renamed to `TerminalConfigImporter` /
  `ImportedTerminalConfig`; no "Ghostty" in identifiers, UI, or comments. The only residue is
  the filesystem paths the importer reads (`~/.config/ghostty`) so migrating users keep their
  config.

### Remaining polish (optional)
- **Procedural box-drawing/block glyphs** for pixel-perfect alignment, **damage tracking**
  (only redraw dirty rows), **program-driven cursor style** (DECSCUSR), **shaped-run caching**
  (perf: ligature shaping rebuilds CTLines each frame).
- **Theme export/import UI** in `SettingsViewController` (NSSavePanel/NSOpenPanel via
  `ThemeFileService`) + register the `.harnesstheme` doc type in `Info.plist` + handle
  `application(_:open:)` for double-click install.

## Gotchas already hit (so you don't re-learn them)
- **`RGBColor` vs QuickDraw**: any file importing AppKit (or `GhosttyTerminal`, which pulls in
  AppKit) sees Apple's C `struct RGBColor`. Pin with `private typealias RGBColor =
  HarnessTheme.RGBColor` in such files (see `ThemeCatalogExportTests.swift` and now
  `HarnessTerminalSurfaceView.swift`). `TerminalHostView` sidesteps it by passing canvas/palette
  colors as **hex strings** to `configureAppearance` (the surface view does the hex→RGBColor).
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
