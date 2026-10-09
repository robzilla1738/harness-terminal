import CHarnessBase64
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch // DispatchTime: a monotonic clock for command-duration timing (explicit for Linux)

/// A headless terminal emulator: feed it PTY output bytes, query the screen via
/// `readGrid()`. It owns the parser, the primary + alternate screens, terminal modes,
/// and emits host-facing events (title, working directory, bell) and PTY responses
/// (DSR/DA) through closures.
///
/// This is the engine's public driver. The live Metal renderer and the headless
/// `harness attach` compositor both build on it; `HarnessGridTerminal` in
/// HarnessTerminalKit is a thin wrapper that adapts it to the existing call sites.
///
/// PTY spawning, scrollback storage, and process lifecycle are NOT here — they are
/// daemon-owned. The emulator only consumes bytes and renders the viewport.
///
/// **Threading contract:** this type is not thread-safe. `feed`, the screen it mutates, and the
/// `onResponse`/`onBell`/… callbacks must all be driven from a single serialized context — the
/// GUI confines each surface's emulator to one serial queue (`SurfaceEmulatorState` in
/// HarnessTerminalKit). The underlying `VTParser` hands borrowed buffer views to the handler that
/// are only valid within the synchronous `feed` call, so concurrent or reentrant feeds would be a
/// use-after-free; `VTParser` carries a debug-only tripwire that traps on violations.
public final class TerminalEmulator: VTParserHandler {
    private var parser: VTParser!
    private var primary: TerminalScreen
    private var alternate: TerminalScreen
    private var current: TerminalScreen
    private var onAlternateScreen = false

    /// Terminal modes that the host queries to encode input correctly (Phase 6).
    public private(set) var modes = TerminalModes()

    public var cols: Int { current.cols }
    public var rows: Int { current.rows }
    /// Current cursor row (viewport-relative) without snapshotting the grid — cheap enough
    /// for per-batch bookkeeping (e.g. the trigger scanner's completed-line high-water mark).
    public var cursorRow: Int { current.cursorRow }

    // MARK: Host callbacks

    /// Window/tab title (OSC 0 / OSC 2).
    public var onTitleChange: ((String) -> Void)?
    /// Reported working directory (OSC 7).
    public var onWorkingDirectoryChange: ((String) -> Void)?
    /// The working directory last reported (OSC 7 or OSC 1337 `CurrentDir=`).
    public private(set) var workingDirectory: String?
    /// The hostname component of an OSC 7 report, when it CHANGES — `file://host/path`
    /// carries the reporting shell's host, so an ssh session's integration flips it to the
    /// remote and the local shell flips it back on exit (drives per-host profiles). nil = the
    /// report carried no authority, or a full reset dropped the state. Lowercased.
    public var onRemoteHostChange: ((String?) -> Void)?
    /// Last host reported through `onRemoteHostChange` (dedupe: OSC 7 fires on every prompt).
    private var reportedRemoteHost: String?
    private var hasReportedRemoteHost = false
    /// Terminal bell (BEL / `\a`).
    public var onBell: (() -> Void)?
    /// A shell command finished (OSC 133 `D`), with how long it ran (since the `C`/`B` mark) and
    /// its exit code. Drives the "long command finished in an unfocused window" notification.
    public var onCommandFinished: ((_ duration: TimeInterval, _ exitCode: Int?) -> Void)?
    /// Clipboard text set by a program via OSC 52 (already base64-decoded). The
    /// consumer gates this on the `set-clipboard` option before writing the system
    /// pasteboard; the engine only decodes.
    public var onSetClipboard: ((String) -> Void)?
    /// Bytes the terminal must write back to the PTY (DSR cursor report, DA, etc.).
    public var onResponse: ((Data) -> Void)?
    /// Whether Kitty graphics may load images from files (`t=f`, `t=t`). The daemon's own
    /// parser turns this off: it doesn't draw images, and it must not consume a temp file
    /// before the app that does.
    public var readsGraphicsFiles = true
    /// A program asked to read the clipboard (OSC 52 `?`), for the given selection (`c`).
    /// The host answers with `clipboardReply`, or stays silent; unset, nothing answers.
    public var onClipboardRead: ((String) -> Void)?

    /// The OSC 52 answer to a read.
    public static func clipboardReply(selection: String, text: String) -> Data {
        Data("\u{1b}]52;\(selection);\(Data(text.utf8).base64EncodedString())\u{1b}\\".utf8)
    }
    /// True while the host feeds persisted scrollback on (re)attach. Replayed bytes restore
    /// state (grid, title, cwd, user vars) but must not re-fire world-facing effects: query
    /// replies would land on the PTY as junk input long after the program stopped waiting
    /// (#168 — p10k's DECRQM/kitty probes echoing `2026;2$y…1u` at the prompt), and historical
    /// bells / desktop notifications / OSC 52 clipboard writes / command-finished reports
    /// would re-fire on every reopen. A query split across the replay→live boundary still
    /// answers: the parser state carries over and `respond` fires during the live chunk.
    /// Set/cleared by the host around each replay feed, on the emulator's serialized context.
    public var isReplaying = false

    // MARK: Terminal identity (XTVERSION / secondary DA)
    //
    // Capability-detecting tools probe for the terminal's identity. The host sets these from the
    // `terminal-identity` option (HarnessCore `TerminalIdentity`) — the engine is dependency-free,
    // so it carries plain values rather than reaching for the version constant. Mutated only on
    // the emulator's serial queue (host calls go through `emulatorState.sync`).

    /// Name reported in the XTVERSION reply (`DCS > | <name> <version> ST`).
    public var terminalName: String = "Harness"
    /// Version text reported in the XTVERSION reply.
    public var terminalVersion: String = ""
    /// Numeric firmware field of the secondary-DA reply (`CSI > 1 ; n ; 0 c`).
    public var secondaryDAVersion: Int = 0
    /// Title as last set by OSC 0/2 (the value XTWINOPS 22/23 push and pop).
    public private(set) var currentTitle = ""
    /// XTWINOPS title stack (`CSI 22 t` push / `CSI 23 t` pop). Depth-capped like xterm's;
    /// pushes beyond the cap are dropped (a runaway program can't grow it without bound).
    private var titleStack: [String] = []
    private static let titleStackLimit = 10
    /// DECSET 1048 state for DECRPM: xterm tracks save/restore-cursor as a mode bit (set on
    /// `h`, cleared on `l`) even though the observable effect is the save/restore action.
    private var mode1048Saved = false
    /// Resolves the terminal's current colors so the engine can answer OSC 10/11/12/4 *queries*
    /// (e.g. a TUI reading the background to pick a light/dark theme). The host supplies it from
    /// the resolved theme; nil roles get no reply.
    public var colorProvider: ((TerminalColorRole) -> (r: UInt8, g: UInt8, b: UInt8)?)?
    /// Desktop notification requested by a program (OSC 9 = `(nil, body)`; OSC 777 =
    /// `(title, body)`). The host routes it to the system notification path.
    public var onNotification: ((_ title: String?, _ body: String) -> Void)?
    /// ConEmu progress report (OSC 9;4) — `ESC ] 9 ; 4 ; <state> ; <value> ST`. Emitted by
    /// Claude Code 2.0+, amp, zig build, systemd, … while they work. Any
    /// `9;4;…` payload is always a progress report, never a notification (the accepted
    /// iTerm2 OSC 9 collision). The host drives its working indicator from this.
    public var onProgress: ((TerminalProgressReport) -> Void)?
    /// OSC 7501 records changed. The host presents them; the engine only stores the book.
    public var onProgramStatus: ((ProgramStatusBook) -> Void)?
    /// Program-status records for this terminal. RIS clears them. DECSTR does not.
    public private(set) var programStatus = ProgramStatusBook()
    /// Mouse pointer shape requested via OSC 22 (e.g. `text`, `pointer`, `default`); nil clears.
    public var onPointerShapeChange: ((String?) -> Void)?
    /// iTerm2 `OSC 1337 ; SetUserVar=name=<base64>` landed (already decoded + validated).
    /// The host surfaces these to format strings as pane-scoped `@name` user options.
    public var onUserVariableChange: ((_ name: String, _ value: String) -> Void)?
    /// RIS dropped every user variable — hosts that mirrored them (pane-scoped `@` options)
    /// must clear their copies too, or `#{@name}` keeps serving pre-reset values. Fired only
    /// when there was something to clear.
    public var onUserVariablesCleared: (() -> Void)?
    /// User variables set via OSC 1337 `SetUserVar=` (count- and size-capped; RIS clears).
    public private(set) var userVariables: [String: String] = [:]
    private static let maxUserVariables = 64
    /// Last OSC-22 pointer shape (nil = terminal default). Surfaced for hosts that prefer polling.
    public private(set) var pointerShape: String?
    /// When the current command started running (OSC 133 `C`/`B`), for command-duration timing.
    /// A MONOTONIC timestamp, not wall-clock `Date`: command duration is an elapsed interval, and a
    /// wall-clock step (NTP/DST/manual change) between C and D would make it negative (suppressing a
    /// long-command notification) or inflated (firing a spurious one).
    private var commandStartedAt: DispatchTime?

    /// Active character set per designation slot (`ESC ( …` / `ESC ) …`). DEC special graphics
    /// turns letters into line-drawing glyphs; ASCII is the default. `glUsesG1` is toggled by
    /// SO (invoke G1) / SI (invoke G0).
    private enum Charset: String { case ascii, decSpecialGraphics }
    private var g0: Charset = .ascii
    private var g1: Charset = .ascii
    private var glUsesG1 = false

    /// In-flight Kitty graphics chunk reassembly, keyed by image id. The first chunk carries the
    /// control keys (format/dims); later chunks append payload until `m=0`.
    private var kittyPending: [Int: (command: KittyGraphicsCommand, payload: [UInt8])] = [:]
    private let maxKittyPendingBytes = 32 << 20
    /// The per-image byte cap bounds one in-flight transfer, but image ids are free integers —
    /// a hostile stream can open many distinct ids that each send `m=1` and never finish. Cap the
    /// count of concurrently-reassembling images so the dictionary can't grow without bound.
    private let maxKittyPendingImages = 64
    /// The transfer the last first chunk began: later chunks carry only `m` (and `q`) keys.
    private var kittyLoadingKey: Int?
    /// Transmitted images, oldest first, keyed by Kitty image id (`i=`). Populated by `a=t`
    /// (and `a=T`), consumed by `a=p` (place-many) — the transmit-once/place-many model image
    /// plugins use — and animated by `a=f` / `a=a` / `a=c`. Bounded by count + total bytes,
    /// frames included; oldest evicted on overflow.
    private var kittyImages: [KittyImage] = []
    /// Virtual placements (`U=1`) by Kitty image id, drawn wherever placeholder cells name them,
    /// and the cells each spans.
    private var kittyVirtuals: [Int: (cols: Int, rows: Int)] = [:]
    /// Image numbers (`I=`) sent without an id, and the id assigned to each, as Kitty does.
    private var kittyNumbers: [Int: Int] = [:]
    private var nextKittyAssignedID = 1 << 30
    private let maxKittyImages = 64
    private var kittyImageBytes = 0

    public init(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        primary = TerminalScreen(cols: c, rows: r, recordsHistory: true)
        alternate = TerminalScreen(cols: c, rows: r)
        current = primary
        parser = VTParser(handler: self)
    }

    // MARK: - Replacement

    /// A blank emulator with this one's settings but no callbacks. A host rebuilds history
    /// into it off to the side, then swaps it in with `takeOver(from:)`.
    public func makeReplacement(cols: Int, rows: Int) -> TerminalEmulator {
        let replacement = TerminalEmulator(cols: cols, rows: rows)
        replacement.copySettings(from: self)
        return replacement
    }

    /// Become the emulator a host drives in place of `previous`: take its callbacks and
    /// settings, then report the state a replay would have (title, working directory, remote
    /// host, user variables, pointer shape, program status), since none of it fired while this
    /// emulator had no callbacks.
    public func takeOver(from previous: TerminalEmulator) {
        copySettings(from: previous)
        onTitleChange = previous.onTitleChange
        onWorkingDirectoryChange = previous.onWorkingDirectoryChange
        onRemoteHostChange = previous.onRemoteHostChange
        onBell = previous.onBell
        onCommandFinished = previous.onCommandFinished
        onSetClipboard = previous.onSetClipboard
        onResponse = previous.onResponse
        onClipboardRead = previous.onClipboardRead
        onNotification = previous.onNotification
        onProgress = previous.onProgress
        onProgramStatus = previous.onProgramStatus
        onPointerShapeChange = previous.onPointerShapeChange
        onUserVariableChange = previous.onUserVariableChange
        onUserVariablesCleared = previous.onUserVariablesCleared
        if !currentTitle.isEmpty { onTitleChange?(currentTitle) }
        if let workingDirectory { onWorkingDirectoryChange?(workingDirectory) }
        if hasReportedRemoteHost { onRemoteHostChange?(reportedRemoteHost) }
        for (name, value) in userVariables.sorted(by: { $0.key < $1.key }) { onUserVariableChange?(name, value) }
        if pointerShape != nil { onPointerShapeChange?(pointerShape) }
        if !programStatus.records.isEmpty { onProgramStatus?(programStatus) }
    }

    private func copySettings(from other: TerminalEmulator) {
        maxScrollbackLines = other.maxScrollbackLines
        maxDecodedHistoryBytes = other.maxDecodedHistoryBytes
        let cell = other.primary.cellPixelSize
        setCellPixelSize(width: cell.width, height: cell.height)
        readsGraphicsFiles = other.readsGraphicsFiles
        terminalName = other.terminalName
        terminalVersion = other.terminalVersion
        secondaryDAVersion = other.secondaryDAVersion
        colorProvider = other.colorProvider
    }

    /// Scrollback lines available on the current screen (0 on the alternate screen).
    public var historyCount: Int { current.historyCount }

    /// Whether the alternate screen is active (full-screen TUIs like less/vim). The surface
    /// view uses this to synthesize arrow keys for the scroll wheel — the alternate screen
    /// has no scrollback to scroll.
    public var isAlternateScreenActive: Bool { onAlternateScreen }
    /// The scroll region (DECSTBM), 1-based and inclusive.
    public var scrollRegion: (top: Int, bottom: Int) { current.scrollRegionOneBased }
    /// Autowrap (DECAWM).
    public var autowrapEnabled: Bool { current.autowrap }
    /// The attributes the next printed character gets, as a blank cell.
    public var penCell: TerminalGridCell { current.penCell }

    /// Cap on retained primary-screen scrollback. `0` disables the line cap, while the
    /// decoded-byte cap still applies. Negative inputs clamp to `0`.
    public var maxScrollbackLines: Int {
        get { primary.maxHistoryLines }
        set { primary.maxHistoryLines = max(0, newValue) }
    }

    /// A separate decoded-storage ceiling, including stored row widths and cluster storage.
    /// The active screen is preserved even when no history fits. Zero does not disable this limit.
    public var maxDecodedHistoryBytes: Int {
        get { primary.maxHistoryBytes }
        set { primary.maxHistoryBytes = min(512 * 1024 * 1024, max(0, newValue)) }
    }
    public var decodedHistoryBytes: Int { primary.historyBytes }

    /// Read the viewport scrolled `offset` lines up into scrollback (0 = live bottom).
    public func readGrid(scrollbackOffset offset: Int) -> TerminalGridSnapshot {
        withKittyImages(current.snapshot(scrollbackOffset: offset))
    }

    // MARK: - Input

    public func feed(_ data: Data) { parser.feed(data) }
    public func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    public func feed(_ text: String) { parser.feed(Array(text.utf8)) }

    /// Reference seam: feed bytes one at a time through the per-byte scalar path, bypassing the
    /// printable-ASCII run fast path that `feed` uses. Public so the (non-`@testable`) benchmark
    /// target can A/B the run path against the scalar baseline; equivalence tests use it too. Not
    /// part of the normal input API — production code should always use `feed`.
    public func feedScalarwise(_ bytes: [UInt8]) { parser.feedScalarwise(bytes) }

    public func resize(cols: Int, rows: Int) {
        primary.resize(cols: cols, rows: rows)
        alternate.resize(cols: cols, rows: rows)
    }

    /// Reflow the primary screen for a client that does not own the PTY size.
    /// The alternate screen is left untouched: a full-screen program redraws on
    /// the owner's `SIGWINCH`, not on this client's window.
    @discardableResult
    public func resizePrimaryLocally(cols: Int, rows: Int) -> Bool {
        guard !onAlternateScreen else { return false }
        primary.resize(cols: cols, rows: rows)
        return true
    }

    /// Test-only seam: resize routing the primary screen through the general reflow path even when
    /// the width is unchanged, so `ReflowFastPathTests` can A/B the width-unchanged fast path
    /// against the authoritative reflow. Not used in production (`resize` picks the fast path).
    func resizeForcingFullReflow(cols: Int, rows: Int) {
        primary.resize(cols: cols, rows: rows, forceFullReflow: true)
        alternate.resize(cols: cols, rows: rows, forceFullReflow: true)
    }

    /// Cheap, non-mutating preview of the primary-screen viewport after a hypothetical reflow to
    /// `cols × rows` — for live re-wrap during a resize drag while the authoritative history-wide
    /// reflow and PTY `SIGWINCH` are deferred to drag-end. O(visible content), not O(history).
    /// Byte-identical to `resize(...)`'s resulting viewport (proven by `ReflowPreviewTests`).
    /// Returns nil on the alternate screen (full-screen TUIs redraw on `SIGWINCH`; no live reflow).
    public func previewViewportReflow(cols: Int, rows: Int) -> TerminalGridSnapshot? {
        guard !onAlternateScreen else { return nil }
        let preview = primary.previewViewportReflow(toCols: cols, rows: rows)
        return TerminalGridSnapshot(
            cols: max(1, cols), rows: max(1, rows), cells: preview.cells,
            // Honor DECTCEM — a program that hid its cursor must not see it flash
            // back during the drag preview.
            cursor: TerminalCursor(row: preview.cursorRow, col: preview.cursorCol, visible: primary.cursorVisible), clusters: primary.clusters
        )
    }

    public func readGrid() -> TerminalGridSnapshot {
        withKittyImages(current.snapshot())
    }

    /// Points the grid's images at what they show now: a placement of a stored Kitty image draws
    /// the image's current frame, so animation and frame edits reach it, and placeholder cells
    /// draw slices of their virtual placements. Free when no Kitty image is stored.
    private func withKittyImages(_ grid: TerminalGridSnapshot) -> TerminalGridSnapshot {
        guard !kittyImages.isEmpty else { return grid }
        var images = grid.images.map { placement in
            guard let id = current.kittyID(ofPlacement: placement.id), let index = kittyImageIndex(id) else {
                return placement
            }
            var placement = placement
            placement.id = -kittyImages[index].currentFrame.textureID
            return placement
        }
        let virtuals = Dictionary(uniqueKeysWithValues: kittyVirtuals.compactMap { id, size in
            kittyImageIndex(id).map {
                (id, KittyPlaceholders.Virtual(textureID: kittyImages[$0].currentFrame.textureID, cols: size.cols, rows: size.rows))
            }
        })
        images += KittyPlaceholders.placements(in: grid, virtuals: virtuals)
        return TerminalGridSnapshot(cols: grid.cols, rows: grid.rows, cells: grid.cells, cursor: grid.cursor,
                                    images: images, marks: grid.marks, clusters: grid.clusters)
    }

    /// Plays the Kitty animations `grid` draws: each running one whose current frame has shown
    /// for its gap moves on, while images it doesn't draw hold still, as in Kitty. Returns `grid`
    /// showing the frames now current, and when the next one is due in uptime nanoseconds — nil
    /// when nothing it draws animates. A renderer calls this with each grid it builds.
    public func animateImages(in grid: TerminalGridSnapshot, now: UInt64) -> (grid: TerminalGridSnapshot, nextFrameAt: UInt64?) {
        guard !grid.images.isEmpty else { return (grid, nil) }
        var nextFrameAt: UInt64?
        var advanced: [Int: Int] = [:] // the id drawn → the id of the frame now current
        for index in kittyImages.indices where kittyImages[index].isAnimating {
            let drawn = -kittyImages[index].currentFrame.textureID
            guard grid.images.contains(where: { $0.id == drawn }) else { continue }
            if let due = kittyImages[index].advance(now: now) { nextFrameAt = min(nextFrameAt ?? due, due) }
            advanced[drawn] = -kittyImages[index].currentFrame.textureID
        }
        guard !advanced.isEmpty else { return (grid, nil) }
        let images = grid.images.map { placement in
            var placement = placement
            placement.id = advanced[placement.id] ?? placement.id
            return placement
        }
        let animated = TerminalGridSnapshot(cols: grid.cols, rows: grid.rows, cells: grid.cells, cursor: grid.cursor,
                                            images: images, marks: grid.marks, clusters: grid.clusters)
        return (animated, nextFrameAt)
    }

    /// Which viewport rows of the current screen changed since the last call, so a renderer can
    /// rebuild only those rows. Resets the accumulator: each change is reported exactly once.
    /// Reports `full` for screen-wide changes (clear/resize/reset/alternate-screen switch) and
    /// `cursorOnly` when the only change was the cursor moving. Always reflects the *live*
    /// viewport; callers showing scrollback should rebuild fully instead.
    public func consumeDamage() -> TerminalDamage {
        current.consumeDamage()
    }

    /// Total lines addressable by copy-mode / scrollback navigation on the current screen
    /// (retained history + the live viewport rows). 0 history on the alternate screen.
    public var bufferLineCount: Int { current.bufferLineCount }

    /// One line in copy-mode view space (`[history ++ viewport]`, 0 = oldest), padded to
    /// the current width. O(cols) random access — for copy-mode motion/search.
    public func textSnapshot() -> TerminalTextSnapshot { current.textSnapshot() }
    public var clusters: [UInt32: String] { current.clusters }
    public func cluster(for cell: TerminalGridCell) -> String { current.cluster(for: cell) }
    public func bufferLine(_ index: Int) -> [TerminalGridCell] { current.bufferLine(index) }

    /// OSC 133 shell-prompt rows in copy-mode view space (`[history ++ viewport]`), oldest
    /// first — drives jump-to-previous/next-prompt. Empty without shell integration.
    public var promptRows: [Int] { current.promptRows() }

    /// The OSC 133 semantic mark on a copy-mode-space line, or nil.
    public func mark(atBufferLine index: Int) -> SemanticMark? { current.mark(atBufferLine: index) }

    /// The full buffer as plain-text lines for `capture-pane`, or the screen alone without
    /// `history`. `joinWrapped` (tmux `-J`) joins soft-wrapped physical rows into their logical line.
    public func captureLines(joinWrapped: Bool, history: Bool = true) -> [String] {
        current.captureLines(joinWrapped: joinWrapped, history: history)
    }

    /// Cell lines for styled capture (HTML / VT). Same wrap join and `history` as `captureLines`.
    public func captureCellLines(joinWrapped: Bool, history: Bool = true) -> [[TerminalGridCell]] {
        current.captureCellLines(joinWrapped: joinWrapped, history: history)
    }

    /// Whether screen row `row` soft-wraps into the next.
    func screenRowWraps(_ row: Int) -> Bool { current.isLineWrapped(current.historyCount + row) }

    /// Virtual-line span `[first, last]` of the logical (soft-wrapped) line containing virtual
    /// `line` (space: `[history ++ viewport]`, 0 = oldest). Drives triple-click logical-line
    /// selection — a hard-ended line returns just itself.
    public func logicalLineRowSpan(virtualLine line: Int) -> ClosedRange<Int> {
        current.logicalLineSpan(containing: line)
    }

    // MARK: - VTParserHandler

    func parserPrint(_ scalar: UInt32) {
        // Translate through the DEC special-graphics table when that charset is invoked into GL,
        // so `lqqk`-style line drawing renders via the existing procedural box-drawing path.
        let active = glUsesG1 ? g1 : g0
        current.print(active == .decSpecialGraphics ? DECSpecialGraphics.map(scalar) : scalar)
    }

    /// Run-batched printable-ASCII path: route a contiguous ASCII run to the screen's batched
    /// `printASCIIRun` (build the cell template once, fill a row in a tight loop). Only valid when
    /// the active charset is ASCII — under DEC special graphics each byte needs the per-codepoint
    /// translation `parserPrint` does, so we fall back to scalar replay there. Byte-for-byte
    /// equivalent to repeated `parserPrint`, which is what `AsciiFastPathTests` proves.
    func parserPrintRun(_ bytes: UnsafeBufferPointer<UInt8>) {
        let active = glUsesG1 ? g1 : g0
        if active == .decSpecialGraphics {
            for b in bytes { current.print(DECSpecialGraphics.map(UInt32(b))) }
        } else {
            current.printASCIIRun(bytes)
        }
    }

    /// Run-batched printable codepoint path (ASCII + decoded UTF-8): route the run to the screen's
    /// batched `printCodepointRun` (template once, width per scalar, row marked once). Under DEC
    /// special graphics each scalar needs the per-codepoint translation `parserPrint` applies, so
    /// fall back to scalar replay there — byte-for-byte equivalent to repeated `parserPrint`, which
    /// `CodepointRunFastPathTests` proves.
    func parserPrintCodepointRun(_ codepoints: UnsafeBufferPointer<UInt32>) {
        let active = glUsesG1 ? g1 : g0
        if active == .decSpecialGraphics {
            for cp in codepoints { current.print(DECSpecialGraphics.map(cp)) }
        } else {
            current.printCodepointRun(codepoints)
        }
    }

    func parserExecute(_ control: UInt8) {
        switch control {
        case 0x07: if !isReplaying { onBell?() } // BEL — historical bells stay silent on replay
        case 0x08: current.backspace()       // BS
        case 0x09: current.tab()             // HT
        case 0x0A, 0x0B, 0x0C: current.lineFeed() // LF, VT, FF
        case 0x0D: current.carriageReturn()  // CR
        case 0x0E: glUsesG1 = true           // SO / LS1 — invoke G1 into GL
        case 0x0F: glUsesG1 = false          // SI / LS0 — invoke G0 into GL
        default: break
        }
    }

    func parserESC(final: UInt8, intermediates: [UInt8]) {
        // Charset designation: `ESC ( <f>` designates G0, `ESC ) <f>` designates G1. `f` = `0`
        // selects DEC special graphics (line drawing); anything else (incl. `B`) is ASCII.
        if intermediates == [0x28] || intermediates == [0x29] {
            let charset: Charset = (final == 0x30) ? .decSpecialGraphics : .ascii
            if intermediates == [0x28] { g0 = charset } else { g1 = charset }
            return
        }
        // DECALN — `ESC # 8` (intermediate '#'): screen alignment test, fill the screen with 'E'.
        if intermediates == [0x23], final == 0x38 {
            current.screenAlignmentTest()
            return
        }
        // Other intermediate sequences are accepted but not acted on.
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x48: current.setTabStop()      // HTS — set a tab stop at the cursor column
        case 0x44: current.lineFeed()        // IND — Index
        case 0x45: current.carriageReturn(); current.lineFeed() // NEL
        case 0x4D: current.reverseLineFeed() // RI — Reverse Index
        case 0x37: current.saveCursor()      // DECSC
        case 0x38: current.restoreCursor()   // DECRC
        case 0x63: fullReset()               // RIS
        case 0x3D: modes.keypadApplication = true   // DECKPAM
        case 0x3E: modes.keypadApplication = false  // DECKPNM
        default: break
        }
    }

    func parserCSI(final: UInt8, params: CSIParams, intermediates: [UInt8], isPrivate: Bool, privateMarker: UInt8?) {
        // Most control functions use one value per parameter (the first sub-parameter of each
        // group); the `arg`/`argRaw` helpers read those directly off the borrowed view. SGR is the
        // exception — it needs the full groups (for `4:3` underline styles and colon-form colors).
        if isPrivate {
            // Private modes (DECSET/DECRST, Kitty keyboard, XTMODKEYS) are rare and off the
            // throughput hot path; materialize a small flat array just for them so the existing
            // private-mode handlers stay unchanged.
            var flat = [Int]()
            flat.reserveCapacity(params.count)
            for g in 0 ..< params.count { flat.append(params.first(g)) }
            handlePrivateMode(final: final, intermediates: intermediates, params: flat, marker: privateMarker)
            return
        }
        // DECSCUSR — `CSI Ps SP q` (intermediate space) sets the cursor shape/blink.
        if intermediates == [0x20], final == 0x71 {
            current.setCursorStyle(argRaw(params, 0, 0))
            return
        }
        // DECSTR — `CSI ! p` (intermediate '!'): soft terminal reset.
        if intermediates == [0x21], final == 0x70 {
            softReset()
            return
        }
        // DECRQM, ANSI form — `CSI Ps $ p` (no private marker): report a non-private mode's
        // state. The private form (`CSI ? Ps $ p`) routes through `handlePrivateMode`.
        if intermediates == [0x24], final == 0x70 {
            for g in 0 ..< params.count { reportANSIMode(params.first(g)) }
            return
        }
        guard intermediates.isEmpty else { return }
        switch final {
        case 0x41: current.moveCursorRelative(dRow: -arg(params, 0, 1), dCol: 0) // CUU
        case 0x42: current.moveCursorRelative(dRow: arg(params, 0, 1), dCol: 0)  // CUD
        case 0x43: current.moveCursorRelative(dRow: 0, dCol: arg(params, 0, 1))  // CUF
        case 0x44: current.moveCursorRelative(dRow: 0, dCol: -arg(params, 0, 1)) // CUB
        case 0x45: cursorNextLine(arg(params, 0, 1))   // CNL
        case 0x46: cursorPrevLine(arg(params, 0, 1))   // CPL
        case 0x47: current.moveCursorCol(arg(params, 0, 1) - 1) // CHA
        case 0x48, 0x66: // CUP / HVP (origin-mode aware)
            current.cursorPosition(row: arg(params, 0, 1) - 1, col: arg(params, 1, 1) - 1)
        case 0x4A: current.eraseInDisplay(mode: argRaw(params, 0, 0)) // ED
        case 0x4B: current.eraseInLine(mode: argRaw(params, 0, 0))    // EL
        case 0x4C: current.insertLines(arg(params, 0, 1))   // IL
        case 0x4D: current.deleteLines(arg(params, 0, 1))   // DL
        case 0x40: current.insertCharacters(arg(params, 0, 1)) // ICH
        case 0x50: current.deleteCharacters(arg(params, 0, 1)) // DCH
        case 0x58: current.eraseCharacters(arg(params, 0, 1))  // ECH
        case 0x53: current.scrollUp(arg(params, 0, 1))   // SU
        case 0x54: current.scrollDown(arg(params, 0, 1)) // SD
        case 0x64: current.cursorToRow(arg(params, 0, 1) - 1) // VPA (origin-mode aware)
        case 0x62: current.repeatLastGraphicChar(arg(params, 0, 1)) // REP — repeat last graphic char
        case 0x68: setANSIMode(params, true)  // SM — set mode (IRM…)
        case 0x6C: setANSIMode(params, false) // RM — reset mode
        case 0x6D: current.applySGR(params)            // SGR
        case 0x72: setScrollRegion(params)             // DECSTBM
        case 0x73: current.saveCursor()                // ANSI save cursor
        case 0x75: current.restoreCursor()             // ANSI restore cursor
        case 0x6E: deviceStatusReport(argRaw(params, 0, 0)) // DSR
        case 0x63: deviceAttributes()                  // DA
        case 0x67: // TBC — `CSI g` clear tab at cursor; `CSI 3 g` clear all
            argRaw(params, 0, 0) == 3 ? current.clearAllTabStops() : current.clearTabStop()
        case 0x49: current.cursorForwardTabs(arg(params, 0, 1))  // CHT — forward N tab stops
        case 0x5A: current.cursorBackwardTabs(arg(params, 0, 1)) // CBT — back N tab stops
        case 0x74: handleWindowOps(params)             // XTWINOPS (title stack + size reports)
        default: break
        }
    }

    func parserDCS(_ data: [UInt8]) {
        // tmux control-mode passthrough (`DCS tmux; … ST`). Recognized so it is never misread as
        // Sixel; driving the wrapped sequences is out of scope here (tracked separately).
        if data.starts(with: Self.tmuxPassthroughPrefix) { return }
        // Demux the DCS by its header — params (0x30–0x3F), then intermediates (0x20–0x2F), then a
        // final byte (0x40–0x7E), with the device-control data after the final, mirroring CSI. The
        // old `data.contains("q")` test sent every DCS that happened to contain a 'q' (DECRQSS `$q`,
        // XTGETTCAP `+q`, tmux passthrough) into the Sixel decoder, where it decoded as nothing.
        var i = 0
        let n = data.count
        while i < n, (0x30 ... 0x3F).contains(data[i]) { i += 1 } // parameter bytes
        var intermediate: UInt8?
        while i < n, (0x20 ... 0x2F).contains(data[i]) { intermediate = data[i]; i += 1 } // intermediates
        guard i < n else { return } // header with no final byte — malformed, ignore
        let final = data[i]
        let payload = Array(data[(i + 1)...])
        switch (intermediate, final) {
        case (nil, 0x71): // 'q' — Sixel image (no intermediate)
            if let image = SixelDecoder.decode(data) { placeImage(image, z: 0) }
        case (0x24, 0x71): // '$' 'q' — DECRQSS: request the value of a setting
            handleDECRQSS(payload)
        case (0x2B, 0x71): // '+' 'q' — XTGETTCAP: terminfo capability query
            handleXTGETTCAP(payload)
        default:
            break // unrecognized device-control string — ignore rather than misroute
        }
    }

    /// `DCS tmux;` — the tmux control-mode passthrough introducer.
    private static let tmuxPassthroughPrefix = Array("tmux;".utf8)

    /// DECRQSS (`DCS $ q Pt ST`) — report the current value of the setting named by `Pt` (the
    /// intermediate+final of the CSI that sets it). Reply `DCS 1 $ r <value> Pt ST` when we can
    /// answer, or the "invalid request" form `DCS 0 $ r Pt ST` otherwise. We answer for the
    /// settings the engine actually tracks: DECSCUSR (`SP q`) and DECSTBM (`r`).
    private func handleDECRQSS(_ request: [UInt8]) {
        let pt = String(decoding: request, as: UTF8.self)
        switch pt {
        case " q": // DECSCUSR — cursor style
            respond("\u{1b}P1$r\(current.cursorStylePs) q\u{1b}\\")
        case "r": // DECSTBM — scroll region (top;bottom, 1-based)
            let region = current.scrollRegionOneBased
            respond("\u{1b}P1$r\(region.top);\(region.bottom)r\u{1b}\\")
        default:
            respond("\u{1b}P0$r\(pt)\u{1b}\\") // request not recognized
        }
    }

    /// XTGETTCAP (`DCS + q Pt ST`) — answer terminfo/termcap capability queries for the handful of
    /// stable, statically-known capabilities (`TN` terminal name, `Co`/`colors` palette size, `RGB`
    /// truecolor). Names and values are hex-encoded per the protocol; unknown names get the negative
    /// `DCS 0 + r <name> ST` reply so a querier doesn't wait.
    private func handleXTGETTCAP(_ request: [UInt8]) {
        // The request is one or more `;`-separated hex-encoded capability names.
        for nameHex in request.split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let name = Self.decodeHex(Array(nameHex)) else { continue }
            let value: String?
            switch name {
            case "TN": value = terminalName            // terminal name
            case "Co", "colors": value = "256"          // palette size
            case "RGB": value = "8/8/8"                 // 24-bit truecolor (bits per channel)
            case "Pst": value = ProgramStatusRevision.terminfoValue
            default: value = nil
            }
            if let value {
                respond("\u{1b}P1+r\(Self.encodeHex(name))=\(Self.encodeHex(value))\u{1b}\\")
            } else {
                respond("\u{1b}P0+r\(Self.encodeHex(name))\u{1b}\\")
            }
        }
    }

    /// Decode an ASCII hex string (`"5452"` → `"TN"`); nil on odd length or a non-hex digit.
    private static func decodeHex(_ bytes: [UInt8]) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 2)
        var idx = bytes.startIndex
        while idx < bytes.count {
            guard let hi = hexValue(bytes[idx]), let lo = hexValue(bytes[idx + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo))
            idx += 2
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30 ... 0x39: return Int(b - 0x30)
        case 0x41 ... 0x46: return Int(b - 0x41 + 10)
        case 0x61 ... 0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// Hex-encode a string for an XTGETTCAP reply (`"TN"` → `"544e"`).
    private static func encodeHex(_ s: String) -> String {
        s.utf8.map { String(format: "%02x", $0) }.joined()
    }

    func parserAPC(_ data: [UInt8]) {
        // Kitty graphics protocol (`G …`). Reassemble chunks, then decode + place.
        guard let command = KittyGraphicsCommand.parse(data) else { return }
        handleKittyGraphics(command)
    }

    // MARK: - Inline images

    /// Decoded pixels for a placed image (queried by the renderer on the main thread).
    /// Pixels for a placement id: the screen's own, or (negative) a frame of a stored Kitty image.
    public func image(for id: Int) -> DecodedImage? {
        guard id < 0 else { return current.image(for: id) }
        return kittyImages.lazy.compactMap { $0.frames.first { $0.textureID == -id }?.image }.first
    }

    public var cellPixelSize: (width: Int, height: Int) { current.cellPixelSize }

    /// Set by the host so an image's cell footprint + cursor advance match the real cell size.
    public func setCellPixelSize(width: Int, height: Int) {
        for screen in [primary, alternate] {
            screen.cellPixelWidth = max(1, width)
            screen.cellPixelHeight = max(1, height)
        }
    }

    private func placeImage(_ image: DecodedImage, cols: Int = 0, rows: Int = 0, z: Int = 0, kittyID: Int? = nil) {
        current.placeImage(image, cols: cols, rows: rows, z: z, kittyID: kittyID)
    }

    /// Store an image as the newest, replacing any with its id, then evict the oldest past the
    /// count and byte budget.
    private func storeKittyImage(_ image: KittyImage) {
        kittyImages.removeAll { existing in
            if existing.id == image.id { kittyImageBytes -= existing.byteCount; return true }
            return false
        }
        kittyImages.append(image)
        kittyImageBytes += image.byteCount
        while (kittyImages.count > maxKittyImages || kittyImageBytes > ImageLimits.maxBytesPerScreen),
              !kittyImages.isEmpty {
            kittyImageBytes -= kittyImages.removeFirst().byteCount
        }
    }

    private func kittyImageIndex(_ id: Int) -> Int? {
        kittyImages.firstIndex { $0.id == id }
    }

    /// Emit the Kitty graphics ack `APC G <i|I>=<id> ; <message> ST`. Per spec it's sent only when
    /// the client gave an addressable id (`i=`) or number (`I=`), and is suppressed by quietness:
    /// `q=1` silences the OK reply, `q=2` silences errors too.
    private func kittyAck(idKey: String, id: Int, ok: Bool, message: String, quietness: Int) {
        guard id != 0 else { return }
        if ok, quietness >= 1 { return }
        if !ok, quietness >= 2 { return }
        respond("\u{1b}_G\(idKey)=\(id);\(message)\u{1b}\\")
    }

    private func handleKittyGraphics(_ cmd: KittyGraphicsCommand) {
        let continuation = cmd.keys.keys.allSatisfy { $0 == "m" || $0 == "q" }
        let key = continuation ? kittyLoadingKey ?? cmd.imageID : cmd.imageID
        if cmd.moreChunks {
            if var pending = kittyPending[key] {
                // Bound total reassembly memory, but KEEP the entry (with its first chunk's control
                // keys) so the final chunk still resolves the original dims/format. Append only up
                // to the cap and drop the overflow — nilling the entry here would make a later final
                // chunk decode as a fresh, dimensionless image and silently fail to place.
                let remaining = maxKittyPendingBytes - pending.payload.count
                if remaining > 0 {
                    pending.payload.append(contentsOf: cmd.payload.prefix(remaining))
                    kittyPending[key] = pending
                }
            } else {
                // New in-flight image: drop all pending reassembly if we're at the id cap, so a
                // flood of never-finished `m=1` chunks under distinct ids can't grow the map.
                if kittyPending.count >= maxKittyPendingImages { kittyPending.removeAll() }
                kittyPending[key] = (cmd, cmd.payload) // first chunk holds the control keys
                kittyLoadingKey = key
            }
            return
        }
        // Final chunk: combine with any accumulated chunks (whose first command holds the control).
        kittyLoadingKey = nil
        let base: KittyGraphicsCommand
        var payload: [UInt8]
        if let pending = kittyPending.removeValue(forKey: key) {
            base = pending.command
            payload = pending.payload
            payload.append(contentsOf: cmd.payload)
        } else {
            base = cmd
            payload = cmd.payload
        }
        // Echo whichever handle the client used (`i=` preferred, else `I=`) back in the ack.
        let echoKey = base.imageID != 0 ? "i" : "I"
        let echoID = base.imageID != 0 ? base.imageID : base.imageNumber
        let ack = { (error: String?) in
            self.kittyAck(idKey: echoKey, id: echoID, ok: error == nil, message: error ?? "OK", quietness: base.quietness)
        }

        switch base.action {
        case "q":
            // Query (capability/decodability probe): validate without placing or storing. Answering
            // this is what gates detection in `icat`/`timg`/`chafa`, so it must reply.
            let loaded = kittyImage(base, payload: payload)
            ack(loaded.image != nil ? nil : loaded.error)

        case "t", "T":
            // Transmit (`t`) stores for later place-many; transmit+display (`T`) also places now.
            let loaded = kittyImage(base, payload: payload)
            guard let image = loaded.image else { return ack(loaded.error) }
            let id = kittyID(for: base, assigning: true)
            if let id { storeKittyImage(KittyImage(id: id, image: image, textureID: ImageIDs.next())) }
            if base.action == "T" {
                if base.unicodePlaceholder {
                    if let id { placeVirtually(id: id, image: image, command: base) }
                } else {
                    placeImage(image, cols: base.cols, rows: base.rows, z: base.z, kittyID: id)
                }
            }
            ack(nil)

        case "p":
            // Put/place a previously-transmitted image by id (transmit-once / place-many).
            guard let id = kittyID(for: base, assigning: false), let index = kittyImageIndex(id) else {
                return ack("ENOENT:image not found")
            }
            let image = kittyImages[index].currentFrame.image
            if base.unicodePlaceholder {
                placeVirtually(id: id, image: image, command: base)
            } else {
                placeImage(image, cols: base.cols, rows: base.rows, z: base.z, kittyID: id)
            }
            ack(nil)

        case "d":
            deleteKittyImages(base)
            ack(nil)

        case "f":
            // An animation frame, in any format a transmit takes. The image grows by a whole
            // frame, so one that would no longer fit the budget on its own is refused.
            guard let id = kittyID(for: base, assigning: false), let index = kittyImageIndex(id) else {
                return ack("ENOENT:image not found")
            }
            let loaded = kittyImage(base, payload: payload)
            guard let frame = loaded.image else { return ack(loaded.error) }
            var image = kittyImages[index]
            if let error = image.loadFrame(frame, base, textureID: ImageIDs.next()) { return ack(error) }
            guard image.byteCount <= ImageLimits.maxBytesPerScreen else {
                return ack("ENOSPC:too many frames for the image storage quota")
            }
            storeKittyImage(image)
            ack(nil)

        case "a":
            // Animation control answers only errors, as Kitty does.
            guard let id = kittyID(for: base, assigning: false), let index = kittyImageIndex(id) else {
                return ack("ENOENT:image not found")
            }
            kittyImages[index].control(base)

        case "c":
            // Compose: copy a rectangle of one frame onto another.
            guard let id = kittyID(for: base, assigning: false), let index = kittyImageIndex(id) else {
                return ack("ENOENT:image not found")
            }
            ack(kittyImages[index].compose(base, textureID: ImageIDs.next()))

        default:
            break // unknown actions are ignored
        }
    }

    /// The image a transmit or query names: the payload itself (`t=d`), or a file it points at
    /// (`t=f`, `t=t`, honoring `O=` / `S=`). A temp file is deleted once read, but only one in
    /// a temp folder whose name says it's for this protocol, per the spec.
    private func kittyImage(_ command: KittyGraphicsCommand, payload: [UInt8]) -> (image: DecodedImage?, error: String) {
        switch command.medium {
        case "d":
            return (command.decode(base64Payload: payload), "EBADF:could not decode image")
        case "f", "t":
            // One answer for "missing", "unreadable", and "not an image", so a program (perhaps
            // on another machine) can't probe which files exist here.
            let failed = (nil as DecodedImage?, "EBADF:could not load image")
            guard readsGraphicsFiles,
                  let name = Data(base64Encoded: Data(payload), options: [.ignoreUnknownCharacters]).flatMap({ String(data: $0, encoding: .utf8) }),
                  name.hasPrefix("/")
            else { return failed }
            // Resolve `..` and symlinks before reading, and before deciding what may be deleted.
            let url = URL(fileURLWithPath: name).resolvingSymlinksInPath().standardizedFileURL
            // Validate the opened descriptor, not a path that can change between stat and open.
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return failed }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_size >= 0, info.st_size <= ImageLimits.maxBytesPerScreen,
                  command.dataSize <= ImageLimits.maxBytesPerScreen else { return failed }
            do {
                if command.dataOffset > 0 { try handle.seek(toOffset: UInt64(command.dataOffset)) }
            } catch { return failed }
            let limit = command.dataSize > 0 ? command.dataSize : ImageLimits.maxBytesPerScreen + 1
            guard let data = try? handle.read(upToCount: limit), data.count <= ImageLimits.maxBytesPerScreen else { return failed }
            if command.medium == "t", Self.isKittyTempFile(url) {
                // Never unlink a replacement file installed while the read was in progress.
                var current = stat()
                if lstat(url.path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            guard let image = command.decode(raw: data) else { return failed }
            return (image, "")
        case "s":
            return kittySharedMemoryImage(command, payload: payload)
        default:
            return (nil, "EINVAL:transmission medium \(command.medium) is not supported")
        }
    }

    /// A `U=1` placement: nothing is drawn now; placeholder cells naming `id` show it, `c`×`r`
    /// cells big (or the image's own size in cells).
    private func placeVirtually(id: Int, image: DecodedImage, command: KittyGraphicsCommand) {
        let cell = current.cellPixelSize
        let cols = command.cols > 0 ? command.cols : max(1, (image.pixelWidth + cell.width - 1) / cell.width)
        let rows = command.rows > 0 ? command.rows : max(1, (image.pixelHeight + cell.height - 1) / cell.height)
        kittyVirtuals[id] = (cols, rows)
        current.markAllDirty()
    }

    /// The id an image command refers to: its `i=`, else the id assigned to its `I=` number
    /// (a new one when transmitting), else none.
    private func kittyID(for command: KittyGraphicsCommand, assigning: Bool) -> Int? {
        if command.imageID != 0 { return command.imageID }
        guard command.imageNumber != 0 else { return nil }
        if assigning {
            nextKittyAssignedID += 1
            kittyNumbers[command.imageNumber] = nextKittyAssignedID
        }
        return kittyNumbers[command.imageNumber]
    }

    /// `t=s`: the payload names a POSIX shared-memory object; read it (honoring `O=`/`S=`) and
    /// unlink it, as the protocol asks.
    private func kittySharedMemoryImage(_ command: KittyGraphicsCommand, payload: [UInt8]) -> (image: DecodedImage?, error: String) {
        let failed = (nil as DecodedImage?, "EBADF:could not load image")
        guard readsGraphicsFiles,
              let name = Data(base64Encoded: Data(payload), options: [.ignoreUnknownCharacters]).flatMap({ String(data: $0, encoding: .utf8) }),
              !name.isEmpty, !name.contains("\0")
        else { return failed }
        var bytes: UnsafeMutablePointer<UInt8>?
        let count = harness_shm_take(name, command.dataOffset, command.dataSize, ImageLimits.maxBytesPerScreen, &bytes)
        guard count >= 0, let bytes else { return failed }
        defer { free(bytes) }
        guard let image = command.decode(raw: Data(bytes: bytes, count: count)) else { return failed }
        return (image, "")
    }

    /// The spec lets a terminal delete only a temp file in a temp folder whose name carries
    /// this marker. `url` is already resolved.
    static func isKittyTempFile(_ url: URL) -> Bool {
        guard url.lastPathComponent.contains("tty-graphics-protocol") else { return false }
        let folders = [NSTemporaryDirectory(), "/tmp", "/var/tmp", "/dev/shm"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        }
        return folders.contains { url.path.hasPrefix($0) }
    }

    /// `a=d`: lowercase targets remove placements; uppercase also forget the transmitted image.
    /// `a` all, `i` by id, `n` by number, `c` at the cursor, `p`/`q` at a cell, `x` a column,
    /// `y` a row, `z` a z-index, `r` an id range. `f` removes an animation frame instead.
    private func deleteKittyImages(_ command: KittyGraphicsCommand) {
        let target = command.deleteTarget
        if target.lowercased() == "f" {
            // Frame `r` of the image `i=` or `I=` names; its bytes leave the budget with it.
            guard let id = kittyID(for: command, assigning: false), let index = kittyImageIndex(id) else { return }
            kittyImageBytes -= kittyImages[index].byteCount
            kittyImages[index].deleteFrame(command.frameNumber)
            kittyImageBytes += kittyImages[index].byteCount
            return
        }
        let (row, col) = (command.y - 1, command.x - 1)
        // The images a target names by id rather than by where they sit: their virtual placements
        // go too, and uppercase forgets them even when nothing was placed.
        let named: (Int) -> Bool
        switch Character(target.lowercased()) {
        case "a": named = { _ in true }
        case "i": named = { command.imageID != 0 && $0 == command.imageID }
        case "n":
            let id = kittyNumbers[command.imageNumber]
            named = { $0 == id }
        case "r": named = { $0 >= command.x && $0 <= command.y }
        default: named = { _ in false }
        }
        let removed: Set<Int>
        switch Character(target.lowercased()) {
        case "i", "n", "r": removed = current.deleteImages { $0.kittyID.map(named) ?? false }
        case "c": removed = current.deleteImages { $0.covers(row: self.current.cursorRow, col: self.current.cursorCol) }
        case "p": removed = current.deleteImages { $0.covers(row: row, col: col) }
        case "q": removed = current.deleteImages { $0.covers(row: row, col: col) && $0.z == command.z }
        case "x": removed = current.deleteImages { col >= $0.col && col < $0.col + $0.cols }
        case "y": removed = current.deleteImages { row >= $0.row && row < $0.row + $0.rows }
        case "z": removed = current.deleteImages { $0.z == command.z }
        default: removed = current.deleteImages { _ in true }
        }
        let virtualCount = kittyVirtuals.count
        kittyVirtuals = kittyVirtuals.filter { !named($0.key) }
        if kittyVirtuals.count != virtualCount { current.markAllDirty() }
        guard target.isUppercase else { return }
        kittyImages.removeAll { entry in
            guard named(entry.id) || removed.contains(entry.id) else { return false }
            kittyImageBytes -= entry.byteCount
            return true
        }
    }

    /// iTerm2 inline image (`OSC 1337 ; File=…:<base64>`). width/height args may be cells (`N`),
    /// pixels (`Npx`), or percent (`N%`); only plain cell counts are honored here — pixel/percent
    /// fall back to the footprint computed from the image's pixels.
    /// The OSC 1337 family beyond inline images (F20): `CurrentDir=` reports the cwd with
    /// the same trust policy as OSC 7 (absolute paths only — hostile output must not steer
    /// the inherited cwd), and `SetUserVar=name=<base64>` stores a per-surface user variable
    /// (surfaced to format strings by the host as a pane-scoped `@name` option). Anything
    /// else falls through to the image handler, which ignores what it can't parse.
    /// Only ever called with a `CurrentDir=` / `SetUserVar=` payload — `parserOSC` routes the
    /// rest of the 1337 family (inline images) straight to `handleITerm2Image` as raw bytes.
    private func handleITerm2OSC(_ payload: String) {
        if payload.hasPrefix("CurrentDir=") {
            let path = String(payload.dropFirst("CurrentDir=".count))
            guard path.hasPrefix("/") else { return }
            workingDirectory = path
            onWorkingDirectoryChange?(path)
            return
        }
        if payload.hasPrefix("SetUserVar=") {
            let body = String(payload.dropFirst("SetUserVar=".count))
            guard let eq = body.firstIndex(of: "=") else { return }
            let name = String(body[..<eq])
            let encoded = String(body[body.index(after: eq)...])
            // Bound everything a hostile stream controls: name shape + length (ASCII only —
            // Unicode `isLetter`/`isNumber` would admit lookalikes like `½`), the base64 TEXT
            // before decoding (4096 bytes ≈ 5464 base64 chars with padding, so a multi-MiB
            // payload is never decoded), decoded value size + content (no C0/DEL/C1 — values
            // are later format-expanded into status lines and other clients' TTYs, where a
            // control byte is escape injection), and the variable-table population (new names
            // rejected past the cap; existing names stay updatable).
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  encoded.utf8.count <= 5464,
                  let data = Data(base64Encoded: encoded), data.count <= 4096,
                  let value = String(data: data, encoding: .utf8),
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0x80 ... 0x9F).contains($0.value) })
            else { return }
            if userVariables[name] == value { return } // same-value rewrite: no host round trip
            if userVariables[name] == nil, userVariables.count >= Self.maxUserVariables { return }
            userVariables[name] = value
            onUserVariableChange?(name, value)
            return
        }
    }

    private func handleITerm2Image(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let parsed = ITerm2InlineImage.parse(payload) else { return }
        func cells(_ s: String?) -> Int {
            guard let s, !s.hasSuffix("px"), !s.hasSuffix("%"), let n = Int(s) else { return 0 }
            return n
        }
        placeImage(parsed.image, cols: cells(parsed.widthArg), rows: cells(parsed.heightArg), z: 0)
    }

    /// Focused pane got a key. `done` and `error` records have been seen.
    public func noteUserKey() {
        let before = programStatus
        programStatus.acknowledgeVisible()
        if programStatus != before { onProgramStatus?(programStatus) }
    }

    func parserOSC(_ data: UnsafeBufferPointer<UInt8>, sequenceLength: Int) {
        // Route by code BYTEWISE before any String materialization: an OSC 1337 inline image
        // (or OSC 52 clipboard set) carries a multi-megabyte base64 body, and decoding it to
        // a String here — only for the handler to re-encode it back to bytes — costs two full
        // copies plus a UTF-8 validation pass of the whole payload. Bulk codes stay on the
        // borrowed pointer; the small-payload codes materialize a String exactly as before
        // (including the drop-on-invalid-UTF-8 behavior). The pointer dies when this returns.
        guard let semi = data.firstIndex(of: 0x3B) else { return }
        // Codes are short ASCII digit runs ("0"…"1337"). Anything non-digit, empty, or with a
        // leading zero ("08") matched no case in the old string switch — preserve that exactly.
        let codeCount = semi
        guard codeCount > 0, codeCount <= 4,
              !(codeCount > 1 && data[0] == 0x30) else { return }
        var code = 0
        for index in 0 ..< codeCount {
            let byte = data[index]
            guard (0x30 ... 0x39).contains(byte) else { return }
            code = code * 10 + Int(byte - 0x30)
        }
        let body = oscBytes(data, from: semi + 1)
        // Bulk codes first — never built into a String.
        switch code {
        case 52: handleClipboardOSC(body); return          // clipboard set (OSC 52)
        case 1337:                                         // iTerm2 family
            // `CurrentDir=` / `SetUserVar=` are small and string-shaped; everything else falls
            // through to the inline-image parser on the raw bytes (matching handleITerm2OSC's
            // old fall-through).
            if body.starts(with: Self.currentDirPrefix) || body.starts(with: Self.setUserVarPrefix) {
                guard let payload = String(bytes: body, encoding: .utf8) else { return }
                handleITerm2OSC(payload)
            } else {
                handleITerm2Image(body)
            }
            return
        default: break
        }
        guard let payload = String(bytes: body, encoding: .utf8) else { return }
        switch code {
        case 0, 2: // icon+title / title (tracked so XTWINOPS 22/23 can push/pop it)
            currentTitle = payload
            onTitleChange?(payload)
        case 7: handleWorkingDirectoryOSC(payload)         // cwd as file:// URL
        case 8: handleHyperlinkOSC(payload)                // OSC 8 hyperlinks
        case 10: handleColorQuery(code: "10", role: .foreground, payload: payload)
        case 11: handleColorQuery(code: "11", role: .background, payload: payload)
        case 12: handleColorQuery(code: "12", role: .cursor, payload: payload)
        case 4: handlePaletteColorQuery(payload)           // OSC 4 ; index ; ?
        case 9: handleOSC9(payload)                        // notification, or ConEmu progress (9;4)
        case 777: handleNotify777(payload)                 // OSC 777 ; notify ; <title> ; <body>
        case 22: setPointerShape(payload)                  // OSC 22 ; <shape> — mouse cursor shape
        case 133: handleSemanticPrompt(payload)            // OSC 133 ; A/B/C/D — shell integration
        case 7501: handleProgramStatus(payload, sequenceLength: sequenceLength)
        default: break
        }
    }

    private func handleProgramStatus(_ payload: String, sequenceLength: Int) {
        let before = programStatus
        switch programStatus.apply(body: payload, sequenceLength: sequenceLength) {
        case .query:
            if !isReplaying { respond(ProgramStatusRevision.queryReply) }
        case .applied:
            if programStatus != before { onProgramStatus?(programStatus) }
        case .discarded, .ignored:
            break
        }
    }

    private func publishProgramStatus(from before: ProgramStatusBook) {
        if programStatus != before { onProgramStatus?(programStatus) }
    }

    private static let currentDirPrefix = Array("CurrentDir=".utf8)
    private static let setUserVarPrefix = Array("SetUserVar=".utf8)

    /// OSC 9 carries two protocols: `9;4;<state>[;<value>]` is a ConEmu progress report;
    /// anything else is an iTerm2-style desktop notification with the payload as body.
    /// `9;4` always wins the collision (a notification can't start with "4;").
    private func handleOSC9(_ payload: String) {
        guard payload == "4" || payload.hasPrefix("4;") else {
            if !isReplaying { onNotification?(nil, payload) }
            return
        }
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        // parts[0] == "4"; parts[1] = state; parts[2] = optional 0–100 value.
        guard parts.count >= 2, let raw = Int(parts[1]),
              let state = TerminalProgressReport.State(rawValue: raw)
        else { return } // unknown state: ignore (don't fall back to a notification)
        let value = parts.count >= 3 ? Int(parts[2]).map { max(0, min(100, $0)) } : nil
        let report = TerminalProgressReport(state: state, value: value)
        let before = programStatus
        programStatus.applyOSC94(report)
        publishProgramStatus(from: before)
        onProgress?(report)
    }

    /// OSC 133 shell integration. `A` marks a prompt line, `D[;exit]`
    /// reports the finished command's status; `B` (command start) and `C` (output start) are the
    /// input/output delimiters — parsed but not stamped, since the prompt mark + exit status are
    /// what drive jump-to-prompt and the success/failure gutter. Purely informational: nothing is
    /// written back to the PTY, and a program that doesn't emit 133 is unaffected.
    private func handleSemanticPrompt(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first?.first else { return }
        switch kind {
        case "A":
            current.markPromptStart()
            commandStartedAt = nil // new prompt: no command running yet
            let before = programStatus
            programStatus.dropEphemeral()
            publishProgramStatus(from: before)
        case "B", "C":
            // Command execution begins. C (output/exec start) deliberately overwrites B
            // (prompt-end/input start): duration must measure execution (C→D), not the time
            // the user spent typing at the prompt. B alone still covers integrations that
            // never emit C.
            commandStartedAt = .now()
        case "D":
            let exitCode = parts.count >= 2 ? Int(parts[1]) : nil
            current.markCommandFinished(exit: exitCode)
            if let started = commandStartedAt {
                // Monotonic elapsed seconds — never negative or clock-skewed.
                let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds
                if !isReplaying { onCommandFinished?(Double(elapsedNanos) / 1_000_000_000, exitCode) }
                commandStartedAt = nil
            }
        default: break
        }
    }

    /// OSC 777 `notify;<title>;<body>`. Other 777 sub-commands are ignored.
    private func handleNotify777(_ payload: String) {
        let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "notify", parts.count >= 2 else { return }
        let title = parts.count >= 3 ? parts[1] : nil
        let body = parts.count >= 3 ? parts[2] : parts[1]
        if !isReplaying { onNotification?(title, body) }
    }

    private func setPointerShape(_ shape: String) {
        let value = shape.isEmpty ? nil : shape
        guard value != pointerShape else { return }
        pointerShape = value
        onPointerShapeChange?(value)
    }

    /// OSC 10/11/12 `?`: report the current fg/bg/cursor color (8→16-bit, `rgb:RRRR/GGGG/BBBB`).
    /// A non-`?` payload is a *set*, which Harness ignores — the theme owns the canvas colors.
    private func handleColorQuery(code: String, role: TerminalColorRole, payload: String) {
        guard payload.hasPrefix("?"), let rgb = colorProvider?(role) else { return }
        respond("\u{1b}]\(code);\(Self.xtermColor(rgb))\u{1b}\\")
    }

    /// OSC 4 `index ; ?`: report a palette color. A spec instead of `?` is a set (ignored).
    private func handlePaletteColorQuery(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let index = Int(parts[0]), parts[1].hasPrefix("?"),
              let rgb = colorProvider?(.palette(index)) else { return }
        respond("\u{1b}]4;\(index);\(Self.xtermColor(rgb))\u{1b}\\")
    }

    /// xterm color reply form: each 8-bit channel widened to 16-bit (`v * 0x101`).
    private static func xtermColor(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> String {
        func h(_ v: UInt8) -> String { String(format: "%04x", UInt16(v) &* 0x101) }
        return "rgb:\(h(c.r))/\(h(c.g))/\(h(c.b))"
    }

    // OSC 8 hyperlink registry: cell `hyperlinkID` → URL. Global across both screens.
    private struct HyperlinkKey: Hashable, Codable {
        let explicitID: String?
        let uri: String
    }
    private var hyperlinks: [UInt32: String] = [:]
    private var hyperlinkKeys: [HyperlinkKey: UInt32] = [:]
    private var nextHyperlinkID: UInt32 = 1

    /// Resolve a cell's `hyperlinkID` to its URL (nil for 0 / unknown).
    public func hyperlinkURL(id: UInt32) -> String? { id == 0 ? nil : hyperlinks[id] }

    /// OSC 8: `params ; URI` — open a hyperlink over subsequently-printed cells; an empty URI
    /// (`OSC 8 ; ; ST`) ends it. An `id=<name>` param lets split runs of the same link share an
    /// id (so a wrapped URL highlights as one).
    private func handleHyperlinkOSC(_ payload: String) {
        guard let semi = payload.firstIndex(of: ";") else { return }
        let params = payload[payload.startIndex ..< semi]
        let uri = String(payload[payload.index(after: semi)...])
        guard !uri.isEmpty else { current.setHyperlink(0); return }
        let explicitID = params.split(separator: ":").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }
        let key = HyperlinkKey(explicitID: explicitID, uri: uri)
        let id: UInt32
        if let existing = hyperlinkKeys[key] {
            id = existing
        } else {
            // Bound the registry against hostile floods of unique links. The ID counter is NOT
            // reset: cells still carrying pre-purge IDs must resolve to nil (dead link), never
            // alias a fresh URL that happened to land on a recycled ID.
            if hyperlinks.count >= 16_384 { hyperlinks.removeAll(); hyperlinkKeys.removeAll() }
            id = nextHyperlinkID
            nextHyperlinkID &+= 1
            hyperlinks[id] = uri
            hyperlinkKeys[key] = id
        }
        current.setHyperlink(id)
    }

    /// OSC 52: `Pc ; Pd` where `Pd` is base64 text to copy (or `?` to query). We
    /// support *setting* the clipboard; a query is ignored (the engine never blocks
    /// on a pasteboard read). The consumer honors the `set-clipboard` option.
    /// Byte-routed: the base64 body can be megabytes, so it is decoded from the
    /// borrowed pointer and never built into a String first.
    private func handleClipboardOSC(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let semi = payload.firstIndex(of: 0x3B) else { return }
        let encoded = oscBytes(payload, from: semi + 1)
        if encoded.count == 1, encoded[0] == UInt8(ascii: "?") {
            // A read. The host decides whether to answer (`clipboardReply`); a replayed query
            // from history never asks.
            guard !isReplaying else { return }
            let selection = String(decoding: oscBytes(payload, from: 0).prefix(semi), as: UTF8.self)
            onClipboardRead?(selection.isEmpty ? "c" : selection)
            return
        }
        guard encoded.count > 0, let text = Base64Bytes.decodeClipboardText(encoded) else { return }
        if !isReplaying { onSetClipboard?(text) }
    }

    /// Bytes of `data` from `index` to the end. Empty when `index` is past the end.
    /// The result aliases `data` and must not outlive it.
    private func oscBytes(_ data: UnsafeBufferPointer<UInt8>, from index: Int) -> UnsafeBufferPointer<UInt8> {
        guard let base = data.baseAddress, index < data.count else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: base + index, count: data.count - index)
    }

    // MARK: - Helpers

    /// Parameter at `index` (first sub-parameter of group `index`), treating absent/zero as
    /// `defaultValue` (for 1-based counts).
    private func arg(_ params: CSIParams, _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        let v = params.first(index)
        return v == 0 ? defaultValue : v
    }

    /// Parameter at `index` with a literal default (for modes where 0 is meaningful).
    private func argRaw(_ params: CSIParams, _ index: Int, _ defaultValue: Int) -> Int {
        guard index < params.count else { return defaultValue }
        return params.first(index)
    }

    // CNL/CPL are cursor moves, not scrolls: ECMA-48 / xterm clamp them to the page exactly
    // like CUD/CUU (which `moveCursorRelative` already does), so they never scroll the region.
    // The old loop-of-lineFeed form both diverged from that and let `\e[65535E` spin 65k scrolls.
    private func cursorNextLine(_ n: Int) {
        current.moveCursorRelative(dRow: max(1, n), dCol: 0)
        current.carriageReturn()
    }

    private func cursorPrevLine(_ n: Int) {
        current.moveCursorRelative(dRow: -max(1, n), dCol: 0)
        current.carriageReturn()
    }

    private func setScrollRegion(_ params: CSIParams) {
        let top = arg(params, 0, 1) - 1
        // Use the bounds-safe accessor for both branches (no direct indexing).
        let rawBottom = argRaw(params, 1, 0)
        let bottom = rawBottom == 0 ? rows - 1 : rawBottom - 1
        current.setScrollRegion(top: top, bottom: bottom)
    }

    /// ANSI SM/RM (`CSI Ps h` / `CSI Ps l`, no private marker). Only IRM (mode 4) is meaningful;
    /// other ANSI modes (e.g. LNM 20) are not implemented and are ignored.
    private func setANSIMode(_ params: CSIParams, _ set: Bool) {
        for g in 0 ..< params.count where params.first(g) == 4 {
            current.insertMode = set // IRM — insert/replace mode
        }
    }

    /// DECSTR (`CSI ! p`) soft terminal reset: return the active screen's state (cursor visibility,
    /// insert/replace, origin, scroll region, saved cursor, SGR) plus the host-facing keyboard modes
    /// and charset designations to defaults, without clearing the screen or moving the cursor.
    private func softReset() {
        current.softReset()
        modes.cursorKeysApplication = false
        modes.keypadApplication = false
        // The screen's softReset() discards savedCursor — DECRQM ?1048 must not keep
        // reporting "set" for a save that no longer exists.
        mode1048Saved = false
        g0 = .ascii
        g1 = .ascii
        glUsesG1 = false
    }

    private func handlePrivateMode(final: UInt8, intermediates: [UInt8], params: [Int], marker: UInt8?) {
        // Kitty keyboard protocol — `CSI u` with a private introducer (push/pop/set/query).
        if final == 0x75, intermediates.isEmpty {
            handleKittyKeyboard(marker: marker, params: params)
            return
        }
        // modifyOtherKeys (XTMODKEYS) — `CSI > 4 ; n m`.
        if final == 0x6D, marker == 0x3E, params.first == 4 {
            modes.modifyOtherKeys = params.count > 1 ? params[1] : 0
            return
        }
        // XTVERSION — `CSI > q`: reply `DCS > | <name> <version> ST`. Capability-detecting tools
        // (Claude Code) read this to confirm which terminal they're in. Must live here: the
        // private `>` marker means a `q`/`c` final never reaches the main `switch final` (the
        // `isPrivate` early-return in `parserCSI` routes it straight to us).
        if final == 0x71, marker == 0x3E, intermediates.isEmpty {
            // No trailing space when the version is empty — strict DCS parsers choke on it.
            let versionPart = terminalVersion.isEmpty ? "" : " \(terminalVersion)"
            respond("\u{1b}P>|\(terminalName)\(versionPart)\u{1b}\\")
            return
        }
        // Secondary DA — `CSI > c`: reply `CSI > 1 ; <version> ; 0 c` (VT220-class, firmware n).
        if final == 0x63, marker == 0x3E, intermediates.isEmpty {
            respond("\u{1b}[>1;\(secondaryDAVersion);0c")
            return
        }
        // Tertiary DA — `CSI = c`: reply DECRPTUI (`DCS ! | <8-hex-digit unit id> ST`). The
        // all-zero site/serial is what xterm reports; tools only check that a reply arrives.
        if final == 0x63, marker == 0x3D, intermediates.isEmpty {
            respond("\u{1b}P!|00000000\u{1b}\\")
            return
        }
        // DECRQM: `CSI ? Ps $ p` — report a private mode's current state.
        if final == 0x70, intermediates == [0x24] { // '$' then 'p'
            for p in params { reportPrivateMode(p) }
            return
        }
        let set = (final == 0x68) // 'h' set, 'l' reset
        guard final == 0x68 || final == 0x6C else { return }
        for p in params {
            switch p {
            case 5: // DECSCNM reverse video — whole-screen fg/bg swap (resolved at render)
                if modes.reverseVideo != set {
                    modes.reverseVideo = set
                    current.markFullyDirty()
                }
            case 6: current.setOriginMode(set)             // DECOM origin mode
            case 7: current.autowrap = set                 // DECAWM autowrap
            case 12: current.setCursorBlink(set)           // att610 cursor blink
            case 25: current.cursorVisible = set           // DECTCEM cursor visibility
            case 1000: modes.mouseClick = set              // X10/normal mouse
            case 1002: modes.mouseDrag = set               // button-event tracking
            case 1003: modes.mouseAny = set                // any-event tracking
            case 1006: modes.mouseSGR = set                // SGR extended coordinates
            case 1016: modes.mouseSGRPixel = set           // SGR-pixel extended coordinates
            case 1004: modes.focusReporting = set          // focus in/out reporting
            case 1007: modes.alternateScroll = set         // wheel → arrows on alt screen
            case 2004: modes.bracketedPaste = set          // bracketed paste
            case 2026: modes.synchronizedOutput = set      // synchronized output (no tearing)
            case 1: modes.cursorKeysApplication = set      // DECCKM
            case 47, 1047: switchAlternate(set, clearOnEnter: true, saveCursor: false)
            case 1048: // save (h) / restore (l) cursor without the screen switch
                mode1048Saved = set
                set ? current.saveCursor() : current.restoreCursor()
            case 1049: switchAlternate(set, clearOnEnter: true, saveCursor: true)
            default: break
            }
        }
    }

    /// DECRPM reply `CSI ? Ps ; Pm $ y` — Pm: 0 not recognized, 1 set, 2 reset. Lets a program
    /// detect support (e.g. `?2026$p` for synchronized output) before using it.
    private func reportPrivateMode(_ p: Int) {
        let state: Int
        switch p {
        case 5: state = modes.reverseVideo ? 1 : 2
        case 6: state = current.originMode ? 1 : 2
        case 7: state = current.autowrap ? 1 : 2
        case 12: state = current.cursorBlinking == true ? 1 : 2 // nil = user default → "reset"
        case 25: state = current.cursorVisible ? 1 : 2
        case 1000: state = modes.mouseClick ? 1 : 2
        case 1002: state = modes.mouseDrag ? 1 : 2
        case 1003: state = modes.mouseAny ? 1 : 2
        case 1006: state = modes.mouseSGR ? 1 : 2
        case 1016: state = modes.mouseSGRPixel ? 1 : 2
        case 1004: state = modes.focusReporting ? 1 : 2
        case 1007: state = modes.alternateScroll ? 1 : 2
        case 2004: state = modes.bracketedPaste ? 1 : 2
        case 2026: state = modes.synchronizedOutput ? 1 : 2
        case 1: state = modes.cursorKeysApplication ? 1 : 2
        case 47, 1047, 1049: state = onAlternateScreen ? 1 : 2
        case 1048: state = mode1048Saved ? 1 : 2 // xterm tracks save/restore as a mode bit
        default: state = 0 // not recognized
        }
        respond("\u{1b}[?\(p);\(state)$y")
    }

    /// DECRPM reply for the ANSI (non-private) DECRQM form: `CSI Ps ; Pm $ y`. Only IRM
    /// (mode 4) is implemented; every other ANSI mode reports 0 (not recognized) — the
    /// conformance-correct answer, letting programs feature-detect instead of assuming.
    private func reportANSIMode(_ p: Int) {
        let state: Int
        switch p {
        case 4: state = current.insertMode ? 1 : 2
        default: state = 0 // not recognized
        }
        respond("\u{1b}[\(p);\(state)$y")
    }

    /// XTWINOPS (`CSI Ps ; … t`). Implemented: the title stack (22 push / 23 pop) and the
    /// size *reports* (18 chars / 14 pixels). Resize/move/iconify remain deliberate
    /// non-goals — the window belongs to the user — and unknown Ps are ignored.
    private func handleWindowOps(_ params: CSIParams) {
        switch argRaw(params, 0, 0) {
        case 14: // text area size in pixels → CSI 4 ; height ; width t
            // Derived from the cell pixel size the host already supplies for inline images
            // (`setCellPixelSize`, kept current on every font/scale change) — one source of
            // truth, and the same space SGR-pixel (1016) mouse coordinates use. A headless
            // consumer reports the screen's synthetic 8×16 default rather than silence, so
            // a querying program never hangs.
            respond("\u{1b}[4;\(rows * current.cellPixelHeight);\(cols * current.cellPixelWidth)t")
        case 18: // text area size in characters → CSI 8 ; rows ; cols t
            respond("\u{1b}[8;\(rows);\(cols)t")
        case 22: // push title (Ps2 0/1/2 — icon and window title are one value here)
            if titleStack.count < Self.titleStackLimit { titleStack.append(currentTitle) }
        case 23: // pop title — restores (and re-announces) the saved title
            if let restored = titleStack.popLast() {
                currentTitle = restored
                onTitleChange?(restored)
            }
        default: break
        }
    }

    /// Kitty keyboard protocol control, dispatched by the private introducer:
    /// `>` push flags, `<` pop N levels, `=` set flags with a mode, `?` query current flags.
    private func handleKittyKeyboard(marker: UInt8?, params: [Int]) {
        switch marker {
        case 0x3E: // '>' — push flags
            let flags = UInt8(truncatingIfNeeded: params.first ?? 0)
            if modes.kittyKeyboardStack.count < 32 { modes.kittyKeyboardStack.append(flags) }
        case 0x3C: // '<' — pop N levels (default 1)
            let n = max(1, params.first ?? 1)
            modes.kittyKeyboardStack.removeLast(min(n, modes.kittyKeyboardStack.count))
        case 0x3D: // '=' — set flags on the active level; mode 1 replace, 2 set bits, 3 clear bits
            let flags = UInt8(truncatingIfNeeded: params.first ?? 0)
            let mode = params.count > 1 ? params[1] : 1
            let current = modes.kittyKeyboardStack.last ?? 0
            let next: UInt8
            switch mode {
            case 2: next = current | flags
            case 3: next = current & ~flags
            default: next = flags
            }
            if modes.kittyKeyboardStack.isEmpty { modes.kittyKeyboardStack.append(next) }
            else { modes.kittyKeyboardStack[modes.kittyKeyboardStack.count - 1] = next }
        case 0x3F: // '?' — query: reply with the current flags
            respond("\u{1b}[?\(modes.kittyKeyboardFlags)u")
        default:
            break
        }
    }

    private func switchAlternate(_ enable: Bool, clearOnEnter: Bool, saveCursor: Bool) {
        if enable {
            guard !onAlternateScreen else { return }
            if saveCursor { primary.saveCursor() }
            onAlternateScreen = true
            current = alternate
            if clearOnEnter { alternate.clearAll() }
        } else {
            guard onAlternateScreen else { return }
            onAlternateScreen = false
            current = primary
            if saveCursor { primary.restoreCursor() }
        }
        // The visible buffer changed wholesale — the next consumer must repaint everything.
        current.markFullyDirty()
    }

    private func deviceStatusReport(_ code: Int) {
        switch code {
        case 5: respond("\u{1b}[0n")                       // "terminal OK"
        case 6: // cursor position report (1-based)
            let snap = current.snapshot()
            respond("\u{1b}[\(snap.cursor.row + 1);\(snap.cursor.col + 1)R")
        default: break
        }
    }

    private func deviceAttributes() {
        // Identify as a VT220-class terminal (62) with Sixel graphics (4) and ANSI color (22) —
        // the standard VT device class. `parserDCS` decodes Sixel, so tools that gate on
        // the DA1 feature list (img2sixel, chafa, timg) will actually emit it; the 62 class is
        // what makes capability-probing TUIs try VT220-level sequences we do implement (DECRQM,
        // DA3, the title stack) instead of degrading to VT100.
        respond("\u{1b}[?62;4;22c")
    }

    private func respond(_ s: String) {
        guard !isReplaying else { return } // replayed queries have no live reader (#168)
        onResponse?(Data(s.utf8))
    }

    private func handleWorkingDirectoryOSC(_ payload: String) {
        // OSC 7 reports the shell's cwd as a file URL: `file://<host>/<absolute-path>`. Accept only
        // a `file://` URL that resolves to an absolute path; ignore a relative path, a non-`file`
        // scheme, or junk, so hostile output can't steer the cwd inherited by new tabs to an
        // attacker-chosen value. No existence check — the path may live on a remote host (cwd
        // reported over ssh), and the engine is filesystem-agnostic by design.
        let path: String
        let host: String?
        if let url = URL(string: payload), url.isFileURL {
            path = url.path
            // `URL.host` is nil for an empty authority on Darwin but `""` on
            // swift-corelibs-foundation (Linux); normalize so `file:///path` reports nil host
            // identically on both platforms (the authority-less = "locally known" contract).
            host = url.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        } else if payload.hasPrefix("file://") {
            // Fallback: strip scheme + authority manually (URL() rejects some unencoded paths).
            let withoutScheme = String(payload.dropFirst("file://".count))
            guard let slash = withoutScheme.firstIndex(of: "/") else { return }
            path = String(withoutScheme[slash...])
            let authority = String(withoutScheme[..<slash])
            host = authority.isEmpty ? nil : authority.lowercased()
        } else {
            return
        }
        guard path.hasPrefix("/") else { return }
        // DELIBERATELY fires during replay (no `!isReplaying` guard, unlike bells / OSC 9·777
        // notifications / OSC 52 / command-finished / query replies). Host and cwd are pane
        // STATE, not world-facing effects: the daemon PTY is the same process across an app
        // restart, so the replayed final OSC 7 == the current host/cwd, and restoring it is
        // what gives a reopened pane its correct per-host profile immediately (gating it would
        // strand the pane on the global theme until the next live prompt). Do NOT "consistently"
        // add an isReplaying guard here.
        // Emit host on CHANGE only (OSC 7 re-reports every prompt), including the first
        // report — even a nil one, so consumers learn "the shell reports no host" explicitly.
        if !hasReportedRemoteHost || reportedRemoteHost != host {
            hasReportedRemoteHost = true
            reportedRemoteHost = host
            onRemoteHostChange?(host)
        }
        workingDirectory = path
        onWorkingDirectoryChange?(path)
    }

    private func fullReset() {
        primary.fullReset()
        alternate.fullReset()
        if onAlternateScreen {
            onAlternateScreen = false
            current = primary
        }
        modes = TerminalModes()
        g0 = .ascii
        g1 = .ascii
        glUsesG1 = false
        // RIS empties the XTWINOPS title stack (xterm behavior); the title itself persists.
        titleStack.removeAll()
        mode1048Saved = false
        kittyPending.removeAll()
        kittyLoadingKey = nil
        // RIS returns the terminal to its initial state, so the transmitted-image cache
        // (transmit-once / place-many storage, animation frames included) must reset too — same
        // cleanup as `d=a` delete-all — otherwise images survive a full reset and keep occupying
        // the per-screen byte budget.
        kittyImages.removeAll()
        kittyNumbers.removeAll()
        kittyVirtuals.removeAll()
        kittyImageBytes = 0
        pointerShape = nil
        if !userVariables.isEmpty {
            userVariables.removeAll()
            onUserVariablesCleared?()
        }
        // A full reset drops the reported-host state too (a respawned shell re-reports via
        // OSC 7); consumers holding a per-host override hear the nil and revert.
        if hasReportedRemoteHost {
            hasReportedRemoteHost = false
            reportedRemoteHost = nil
            onRemoteHostChange?(nil)
        }
        hyperlinks.removeAll()
        hyperlinkKeys.removeAll()
        nextHyperlinkID = 1
        // A full reset abandons any in-flight command timing — otherwise a 133;D after
        // ESC c reports a spurious command-finished with a pre-reset start time.
        commandStartedAt = nil
        let hadStatus = !programStatus.records.isEmpty || programStatus.acceptedRealReport
        programStatus.reset()
        if hadStatus { onProgramStatus?(programStatus) }
        parser.reset()
    }
}

/// Terminal mode flags that govern how the host encodes keyboard/mouse input. Read by
/// the NSView host's input encoder (Phase 6); set here by DECSET/DECRST.
public struct TerminalModes: Sendable, Equatable, Codable {
    public var cursorKeysApplication = false
    public var keypadApplication = false
    public var bracketedPaste = false
    public var focusReporting = false
    /// DECSET 1007 "alternate scroll": wheel events on the alternate screen become arrow
    /// keys. On by default so less/man/vim scroll out of
    /// the box; programs can opt out with `CSI ? 1007 l`.
    public var alternateScroll = true
    public var mouseClick = false
    public var mouseDrag = false
    public var mouseAny = false
    public var mouseSGR = false
    /// DECSET 1016: SGR-pixel mouse reporting — same `CSI < … M/m` framing as 1006 but with
    /// pixel coordinates. Takes precedence over 1006 when both are set (xterm semantics).
    public var mouseSGRPixel = false
    /// DECSET 5 (DECSCNM): whole-screen reverse video. Resolved at render time (the renderer
    /// swaps default fg/bg), so the engine only tracks the flag and dirties the screen.
    public var reverseVideo = false
    /// DEC private mode 2026 (synchronized output): while set, the program is mid-frame and the
    /// renderer should hold the last presented frame rather than paint partial updates — no
    /// tearing in TUIs (vim, fzf, btop, …). Cleared by the program (or a renderer-side timeout).
    public var synchronizedOutput = false
    /// Kitty keyboard progressive-enhancement flag stack (`CSI > flags u` push / `CSI < u` pop).
    /// Top of stack = active flags; empty = disabled (flags 0). Bits: 1 disambiguate-escape-codes,
    /// 2 report-event-types, 4 report-alternate-keys, 8 report-all-keys-as-escape-codes,
    /// 16 report-associated-text. The input encoder uses CSI-u encoding only when non-zero, so
    /// legacy output is byte-identical until a program opts in.
    public var kittyKeyboardStack: [UInt8] = []
    /// Active Kitty keyboard flags (top of stack, or 0 when none pushed).
    public var kittyKeyboardFlags: UInt8 { kittyKeyboardStack.last ?? 0 }
    /// xterm modifyOtherKeys level (`CSI > 4 ; n m`): 0 off, 1, or 2. Independent of Kitty.
    public var modifyOtherKeys: Int = 0

    public init() {}

    /// Any mouse-tracking mode is active.
    public var mouseTrackingEnabled: Bool { mouseClick || mouseDrag || mouseAny }
}

extension TerminalEmulator {
    private struct PendingImage: Codable { var keys: [String: String]; var payload: Data }
    private struct VirtualImage: Codable { var cols: Int; var rows: Int }
    private struct HyperlinkEntry: Codable { var key: HyperlinkKey; var id: UInt32 }
    private struct CheckpointState: Codable {
        var primary: TerminalScreen.CheckpointState
        var alternate: TerminalScreen.CheckpointState
        var parser: VTParser.CheckpointState
        var onAlternateScreen: Bool
        var modes: TerminalModes
        var workingDirectory: String?
        var reportedRemoteHost: String?
        var hasReportedRemoteHost: Bool
        var terminalName: String
        var terminalVersion: String
        var secondaryDAVersion: Int
        var currentTitle: String
        var titleStack: [String]
        var mode1048Saved: Bool
        var programStatus: ProgramStatusBook
        var userVariables: [String: String]
        var pointerShape: String?
        var commandElapsedNanos: UInt64?
        var g0: String
        var g1: String
        var glUsesG1: Bool
        var kittyPending: [Int: PendingImage]
        var kittyLoadingKey: Int?
        var kittyImages: [KittyImage]
        var kittyVirtuals: [Int: VirtualImage]
        var kittyNumbers: [Int: Int]
        var nextKittyAssignedID: Int
        var hyperlinks: [UInt32: String]
        var hyperlinkKeys: [HyperlinkEntry]
        var nextHyperlinkID: UInt32
    }

    /// Export continuation state at the host's current output sequence. Call on the same
    /// serialized context as feed/resize. No callbacks or older history are serialized.
    public func checkpoint() throws -> TerminalCheckpoint {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = commandStartedAt.map { now >= $0.uptimeNanoseconds ? now - $0.uptimeNanoseconds : 0 }
        let state = CheckpointState(
            primary: primary.checkpointState(),
            alternate: alternate.checkpointState(),
            parser: try parser.checkpointState(),
            onAlternateScreen: onAlternateScreen,
            modes: modes,
            workingDirectory: workingDirectory,
            reportedRemoteHost: reportedRemoteHost,
            hasReportedRemoteHost: hasReportedRemoteHost,
            terminalName: terminalName,
            terminalVersion: terminalVersion,
            secondaryDAVersion: secondaryDAVersion,
            currentTitle: currentTitle,
            titleStack: titleStack,
            mode1048Saved: mode1048Saved,
            programStatus: programStatus,
            userVariables: userVariables,
            pointerShape: pointerShape,
            commandElapsedNanos: elapsed,
            g0: g0.rawValue,
            g1: g1.rawValue,
            glUsesG1: glUsesG1,
            kittyPending: kittyPending.mapValues { PendingImage(keys: $0.command.keys, payload: Data($0.payload)) },
            kittyLoadingKey: kittyLoadingKey,
            kittyImages: kittyImages,
            kittyVirtuals: kittyVirtuals.mapValues { VirtualImage(cols: $0.cols, rows: $0.rows) },
            kittyNumbers: kittyNumbers,
            nextKittyAssignedID: nextKittyAssignedID,
            hyperlinks: hyperlinks,
            hyperlinkKeys: hyperlinkKeys.map { HyperlinkEntry(key: $0.key, id: $0.value) },
            nextHyperlinkID: nextHyperlinkID
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try TerminalCheckpoint(payload: encoder.encode(state))
    }

    /// Restore atomically without firing historical clipboard, query or notification effects.
    /// Settings controlling local file access and existing callbacks remain client-owned.
    public func restore(_ checkpoint: TerminalCheckpoint) throws {
        guard checkpoint.version == TerminalCheckpoint.currentVersion else { throw TerminalCheckpointError.unsupportedVersion }
        guard checkpoint.payload.count <= TerminalCheckpoint.maxPayloadBytes else { throw TerminalCheckpointError.tooLarge }
        let state = try PropertyListDecoder().decode(CheckpointState.self, from: checkpoint.payload)
        guard state.primary.recordsHistory, !state.alternate.recordsHistory,
              state.primary.cols == state.alternate.cols, state.primary.rows == state.alternate.rows,
              let charset0 = Charset(rawValue: state.g0), let charset1 = Charset(rawValue: state.g1),
              state.titleStack.count <= Self.titleStackLimit, state.userVariables.count <= Self.maxUserVariables,
              state.programStatus.records.count <= ProgramStatusRevision.maxRecords,
              state.modes.kittyKeyboardStack.count <= 64, (0...2).contains(state.modes.modifyOtherKeys),
              state.kittyPending.count <= maxKittyPendingImages, state.kittyImages.count <= maxKittyImages,
              state.kittyPending.values.reduce(0, { $0 + $1.payload.count }) <= maxKittyPendingBytes,
              state.kittyVirtuals.count <= 4096, state.kittyNumbers.count <= 4096,
              state.kittyVirtuals.values.allSatisfy({ $0.cols >= 0 && $0.cols <= 100_000 && $0.rows >= 0 && $0.rows <= 100_000 }),
              state.kittyImages.allSatisfy({ image in
                  !image.frames.isEmpty && image.frames.count <= 4096 && image.current >= 0 && image.current < image.frames.count &&
                  image.frames.allSatisfy({ $0.textureID > 0 && $0.gap >= 0 && $0.gap <= Int(Int32.max) }) &&
                  image.maxLoops >= 0 && image.loops >= 0
              }),
              Set(state.kittyImages.map(\.id)).count == state.kittyImages.count,
              state.nextKittyAssignedID > 0 && state.nextKittyAssignedID < Int.max,
              state.hyperlinks.count <= 16_384, state.hyperlinkKeys.count <= 16_384,
              state.hyperlinks.keys.allSatisfy({ $0 > 0 && $0 < state.nextHyperlinkID }),
              state.hyperlinkKeys.allSatisfy({ state.hyperlinks[$0.id] == $0.key.uri }),
              Set(state.hyperlinkKeys.map(\.key)).count == state.hyperlinkKeys.count
        else { throw TerminalCheckpointError.invalidState }
        // Remap host texture IDs into the local allocator so subsequent images cannot reuse an
        // imported ID and display stale cached pixels. Kitty logical protocol IDs stay intact.
        var imageIDs: [Int: Int] = [:]
        func remap(_ id: Int) -> Int {
            if let mapped = imageIDs[id] { return mapped }
            let mapped = ImageIDs.next(); imageIDs[id] = mapped; return mapped
        }
        let restoredPrimary = try TerminalScreen.restored(from: state.primary, remapImage: remap)
        let restoredAlternate = try TerminalScreen.restored(from: state.alternate, remapImage: remap)
        restoredPrimary.maxHistoryLines = primary.maxHistoryLines
        restoredPrimary.maxHistoryBytes = primary.maxHistoryBytes
        let restoredParser = VTParser(handler: self)
        try restoredParser.restore(state.parser)
        var restoredImages = state.kittyImages
        for index in restoredImages.indices {
            restoredImages[index].shownAt = nil // monotonic clocks belong to their process
            for frame in restoredImages[index].frames.indices {
                restoredImages[index].frames[frame].textureID = remap(restoredImages[index].frames[frame].textureID)
            }
        }
        primary = restoredPrimary
        alternate = restoredAlternate
        parser = restoredParser
        current = state.onAlternateScreen ? alternate : primary
        onAlternateScreen = state.onAlternateScreen
        modes = state.modes
        workingDirectory = state.workingDirectory
        reportedRemoteHost = state.reportedRemoteHost
        hasReportedRemoteHost = state.hasReportedRemoteHost
        terminalName = state.terminalName
        terminalVersion = state.terminalVersion
        secondaryDAVersion = state.secondaryDAVersion
        currentTitle = state.currentTitle
        titleStack = state.titleStack
        mode1048Saved = state.mode1048Saved
        programStatus = state.programStatus
        userVariables = state.userVariables
        pointerShape = state.pointerShape
        glUsesG1 = state.glUsesG1
        kittyLoadingKey = state.kittyLoadingKey
        kittyNumbers = state.kittyNumbers
        nextKittyAssignedID = state.nextKittyAssignedID
        hyperlinks = state.hyperlinks
        nextHyperlinkID = state.nextHyperlinkID
        g0 = charset0; g1 = charset1
        kittyImages = restoredImages
        kittyImageBytes = kittyImages.reduce(0) { $0 + $1.byteCount }
        kittyPending = state.kittyPending.mapValues { (KittyGraphicsCommand(keys: $0.keys, payload: []), Array($0.payload)) }
        kittyVirtuals = state.kittyVirtuals.mapValues { ($0.cols, $0.rows) }
        hyperlinkKeys = Dictionary(uniqueKeysWithValues: state.hyperlinkKeys.map { ($0.key, $0.id) })
        let now = DispatchTime.now().uptimeNanoseconds
        commandStartedAt = state.commandElapsedNanos.map { DispatchTime(uptimeNanoseconds: now - min(now, $0)) }
    }
}
