import Foundation

/// Decides *when* the terminal surface should present a frame, separating the three concerns the
/// view used to entangle in `scheduleRender()`:
///
///   1. marking the surface dirty (`markDirty`) — cheap, no dispatch, called from every code path
///      that changes what's on screen (PTY output, cursor blink, focus, selection, copy mode, …);
///   2. deciding when to render (`tick`) — driven at display cadence by the view's `CADisplayLink`,
///      it presents at most one frame per tick and only when there's pending work;
///   3. forcing an immediate render (`forceRender`) — for first paint, flicker-free resize, and the
///      DEC 2026 synchronized-output timeout safety valve, which must bypass coalescing.
///
/// Pure Foundation and isolated from AppKit/Metal so the coalescing/hold/force logic is unit-tested
/// without a window or GPU. The view owns one of these and supplies `render` = its `renderNow`.
///
/// Not thread-safe by design: the surface drives it entirely on the main thread (PTY callbacks,
/// the display link, and AppKit lifecycle all land there), matching the old `scheduleRender` path.
final class RenderScheduler {
    /// Presents one frame. Set by the owner to its `renderNow`. The scheduler decides *whether* and
    /// *when* to call it; it never inspects what gets drawn. May present asynchronously (the off-main
    /// pipeline builds the frame on a worker and presents on the next main hop).
    private let render: () -> Void
    /// Presents one frame *synchronously* this turn (used only by `forceRender`). On the off-main
    /// pipeline `render` returns before the frame reaches the screen, which is fine for coalesced
    /// ticks but wrong for resize/first-paint inside a `CATransaction` — an async hop there shows the
    /// old grid stretched to the new bounds (the resize flicker). This closure builds + presents
    /// inline so the forced frame is on screen before the transaction commits. Defaults to `render`
    /// for owners (and tests) that don't distinguish the two.
    private let renderSynchronously: () -> Void

    /// Pending paint requested since the last present. Coalesces a burst of `markDirty` into one
    /// render at the next `tick`.
    private(set) var needsRender = false
    /// Whether this display interval has already presented (via `presentNow`, `tick`, or
    /// `forceRender`). Gates `presentNow` so the *first* paint after idle flushes immediately
    /// (low-latency echo) while a sustained burst still coalesces to one present per `tick`. Reset
    /// only by an *idle* `tick` (one that found nothing to draw), which marks the start of a fresh
    /// interval — during a burst every tick has work, so it stays set and immediate presents stay
    /// suppressed until the burst drains.
    private(set) var presentedThisInterval = false
    /// DEC 2026 synchronized output: while true, `tick` holds (no partial frame). `forceRender`
    /// still presents (the timeout safety valve and an explicit force ignore the hold).
    private(set) var synchronized = false
    /// Whether the display-cadence loop is live (the view is in a window). `tick` is inert when
    /// stopped, so a detached view never presents.
    private(set) var isRunning = false
    /// The hosting window is occluded (fully covered / minimized): nothing presented can be seen,
    /// and acquiring drawables for an invisible window wastes CPU and can stall the shared pool
    /// (Apple guidance: don't `nextDrawable()` for occluded windows). `tick`/`presentNow` hold
    /// while set; dirty marks keep accumulating so visibility returning presents promptly. The
    /// view owns the state (it observes `NSWindow.didChangeOcclusionStateNotification`) and wakes
    /// the loop itself on un-occlusion. `forceRender` stays ungated (resize/first-paint forces
    /// while occluded are rare and harmless).
    private(set) var isOccluded = false

    init(render: @escaping () -> Void, renderSynchronously: (() -> Void)? = nil) {
        self.render = render
        self.renderSynchronously = renderSynchronously ?? render
    }

    /// There is a frame to present and nothing is holding it — the view uses this to keep its
    /// display link running only while needed (and pause it when idle, so a quiet terminal doesn't
    /// wake the CPU every display tick). An occluded window holds too: its link pauses even with
    /// output flooding in, so a covered pane running a build costs no presents at all.
    var hasPendingWork: Bool { isRunning && needsRender && !synchronized && !isOccluded }

    /// Window visibility changed (see `isOccluded`). Un-occlusion does not present by itself —
    /// the caller re-arms via its normal scheduling so any marks accumulated while covered land
    /// on the next tick.
    func setOccluded(_ occluded: Bool) { isOccluded = occluded }

    /// Begin display-cadence scheduling (called when the view enters a window).
    func start() { isRunning = true }

    /// Stop scheduling and drop any pending work / hold (called when the view leaves its window).
    /// A later `tick` is a no-op until `start()` runs again. Occlusion resets too — it described
    /// the departed window; re-hosting seeds it from the new window's state.
    func stop() {
        isRunning = false
        needsRender = false
        synchronized = false
        presentedThisInterval = false
        isOccluded = false
    }

    /// Request a present at the next display tick. Cheap and idempotent — many marks before a tick
    /// still yield a single render.
    func markDirty() { needsRender = true }

    /// Present immediately *this* runloop turn if there's pending paint, nothing is holding it, and
    /// this interval hasn't already presented — so a keystroke echo paints now instead of waiting up
    /// to a full display interval for the next `tick`. The caller marks dirty (e.g. via
    /// `scheduleRender`) before calling this. During a burst the `presentedThisInterval` gate makes
    /// this a no-op after the first paint, so the flood still coalesces at `tick` cadence (no
    /// per-chunk present). Returns whether it actually rendered.
    @discardableResult
    func presentNow() -> Bool {
        guard isRunning, needsRender, !synchronized, !isOccluded, !presentedThisInterval else { return false }
        needsRender = false
        presentedThisInterval = true
        render()
        return true
    }

    /// The display link paused (the view found nothing left to draw and stopped the link). That ends
    /// the current interval, so reopen the immediate-present path — the next arrival after the idle
    /// gap flushes right away instead of waiting for the link to wake and tick. Without this, a burst
    /// that ended on a *presenting* tick would leave the gate closed and delay the next keystroke by
    /// a frame.
    func linkDidPause() { presentedThisInterval = false }

    /// Set DEC 2026 synchronized-output state. Entering the hold suppresses ticks; leaving it marks
    /// the surface dirty so the batched frame presents at the next tick (matching the old behavior
    /// where the chunk that clears 2026 triggers the atomic present).
    func setSynchronized(_ on: Bool) {
        synchronized = on
        if !on { needsRender = true }
    }

    /// Display-cadence callback. Presents one frame iff running, dirty, and not synchronized; clears
    /// the dirty flag. Returns whether it actually rendered (for tests / display-link pausing).
    @discardableResult
    func tick() -> Bool {
        guard hasPendingWork else {
            // Idle tick: nothing to draw. This ends the current interval, so reopen the
            // immediate-present path for the next arrival after a quiet gap.
            presentedThisInterval = false
            return false
        }
        needsRender = false
        // The tick is this interval's present; keep `presentedThisInterval` set so a chunk arriving
        // right after it coalesces into the *next* tick rather than triggering a second present.
        presentedThisInterval = true
        render()
        return true
    }

    /// Present immediately, bypassing both coalescing and the synchronized-output hold. Clears the
    /// dirty flag so no duplicate render follows at the next tick. Used for first paint, resize
    /// (drawn synchronously to stay flicker-free), and the 2026 timeout safety valve.
    func forceRender() {
        needsRender = false
        presentedThisInterval = true // this counts as the interval's present (no immediate double-paint)
        renderSynchronously()
    }
}
