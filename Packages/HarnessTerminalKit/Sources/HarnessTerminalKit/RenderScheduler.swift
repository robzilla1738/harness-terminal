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
    /// *when* to call it; it never inspects what gets drawn.
    private let render: () -> Void

    /// Pending paint requested since the last present. Coalesces a burst of `markDirty` into one
    /// render at the next `tick`.
    private(set) var needsRender = false
    /// DEC 2026 synchronized output: while true, `tick` holds (no partial frame). `forceRender`
    /// still presents (the timeout safety valve and an explicit force ignore the hold).
    private(set) var synchronized = false
    /// Whether the display-cadence loop is live (the view is in a window). `tick` is inert when
    /// stopped, so a detached view never presents.
    private(set) var isRunning = false

    init(render: @escaping () -> Void) {
        self.render = render
    }

    /// There is a frame to present and nothing is holding it — the view uses this to keep its
    /// display link running only while needed (and pause it when idle, so a quiet terminal doesn't
    /// wake the CPU every display tick).
    var hasPendingWork: Bool { isRunning && needsRender && !synchronized }

    /// Begin display-cadence scheduling (called when the view enters a window).
    func start() { isRunning = true }

    /// Stop scheduling and drop any pending work / hold (called when the view leaves its window).
    /// A later `tick` is a no-op until `start()` runs again.
    func stop() {
        isRunning = false
        needsRender = false
        synchronized = false
    }

    /// Request a present at the next display tick. Cheap and idempotent — many marks before a tick
    /// still yield a single render.
    func markDirty() { needsRender = true }

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
        guard hasPendingWork else { return false }
        needsRender = false
        render()
        return true
    }

    /// Present immediately, bypassing both coalescing and the synchronized-output hold. Clears the
    /// dirty flag so no duplicate render follows at the next tick. Used for first paint, resize
    /// (drawn synchronously to stay flicker-free), and the 2026 timeout safety valve.
    func forceRender() {
        needsRender = false
        render()
    }
}
