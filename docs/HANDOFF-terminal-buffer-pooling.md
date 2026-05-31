# Handoff: Pooled Metal instance buffers in the terminal renderer

Branch: `claude/terminal-buffer-pooling-ic1ll` · Base: `main`

## Why

`TerminalMetalRenderer.encode(...)` rebuilds three instance arrays every frame
(`backgrounds`, `glyphs`, `decorations`) and previously created a **brand-new Metal buffer per
array per frame** via `device.makeBuffer(bytes:length:options:)`. At terminal refresh rates
that allocates and frees three GPU buffers on every redraw, adding allocation and copy pressure
to the hot render path.

## What changed

Instance data is now copied into a small pool of reusable, growable Metal buffers instead of
allocating fresh ones each frame. In steady state (a stable grid size) the render path performs
only a `memcpy` — no Metal allocation.

### New file: `DynamicInstanceBuffer.swift`
`Packages/HarnessTerminalRenderer/Sources/HarnessTerminalRenderer/DynamicInstanceBuffer.swift`

A triple-buffered ring of CPU-writable (`.storageModeShared`) Metal buffers.

- `upload<T>(_ instances: [T], slot: Int) -> MTLBuffer?`
  - Returns `nil` for an empty array, so callers skip the pass — preserving the renderer's prior
    "never create or bind a zero-length buffer" behavior.
  - Grows the slot's buffer on demand with doubling headroom
    (`max(needed, capacity * 2)`) via `makeBuffer(length:options:)` — the only allocation,
    on first use or growth, never in steady state.
  - Copies with `withUnsafeBytes` + `memcpy` into `buffer.contents()`.

**Why a ring (the key invariant):** the live-view `present(_:to:…)` path commits its command
buffer *without* waiting for the GPU, so the GPU may still be reading frame N's instance buffer
while the CPU builds frame N+1. Reusing one buffer would corrupt the in-flight frame. Cycling
through `ringSize` (= 3) buffers, paired with an in-flight semaphore that caps queued frames at
3, guarantees the slot the CPU writes was last used 3 frames ago and is no longer GPU-referenced.

### `TerminalMetalRenderer.swift`
- Added three `DynamicInstanceBuffer` rings (bg / glyph / deco), a
  `DispatchSemaphore(value: maxFramesInFlight)` (`maxFramesInFlight = 3`), and a `frameSlot`.
- `encode(...)` now: `inFlightSemaphore.wait()` → advance `frameSlot` → create the command
  buffer (signalling and returning `nil` if creation fails, so no slot leaks) → register
  `addCompletedHandler` that signals the semaphore (captures the semaphore, not `self`).
- The three `device.makeBuffer(bytes:...)` call sites are replaced with `…InstanceBuffer.upload(…)`.
  Pipeline binds, vertex/fragment bytes, gamma/texture/sampler, and `drawPrimitives` are
  unchanged.

### Unchanged on purpose
- Draw ordering: background → negative-z images → glyph → decoration → non-negative-z images.
- Image rendering (`drawImages`, per-image `setVertexBytes`).
- Storage mode (`.storageModeShared`).

## Tests

`Tests/HarnessTerminalRendererTests/MetalRendererTests.swift` gains
`testRepeatedRendersReuseInstanceBuffersWithoutCorruption`: renders the same frame 6 times
(past the ring depth so slots wrap) and asserts stable pixels, proving reused slots don't
corrupt output. The existing golden-image tests remain the primary "no visual change" guard.

## Verification status — action needed by reviewer

This was developed in a Linux container with **no Swift toolchain**, and the renderer is
Metal/QuartzCore (Apple-only), so it could **not be compiled or tested here**. Verified by
review + grep only (the sole remaining `makeBuffer(bytes:` is a comment; the only allocating
call is the helper's growth path).

**Please run on an Apple machine before merge:**

```sh
swift build
swift test --package-path Packages/HarnessTerminalRenderer
```

Metal tests self-skip when no GPU is present (e.g. headless CI).

## Risk / threading note

The shared `frameSlot` and ring buffers assume `encode` is submitted serially from one thread.
This invariant already held (the renderer shares mutable `imageCache`, `atlas`, and pipelines),
so no new threading hazard is introduced — but keep submission single-threaded.
