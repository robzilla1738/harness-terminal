import AppKit

/// Wraps the private CoreGraphics SPI that controls per-window backdrop blur —
/// the same call Alacritty, and iTerm2 use to blur the desktop behind a
/// translucent terminal. Not App-Store-safe, but Harness ships outside the store.
@MainActor
enum WindowBlur {
    static func apply(radius: Int, to window: NSWindow) {
        let wid = window.windowNumber
        guard wid > 0 else { return }
        let clamped = max(0, min(100, radius))
        _ = CGSSetWindowBackgroundBlurRadius(CGSMainConnection(), wid, Int32(clamped))
    }
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnection() -> Int32

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(_ cid: Int32, _ wid: Int, _ radius: Int32) -> Int32

/// Shared window-level transparency for the main window and Quick Terminal.
@MainActor
enum WindowAppearance {
    static func applyTransparency(opacity: Float, blur: Int, opaqueBackground: NSColor, to window: NSWindow) {
        let isOpaque = max(0, min(1, opacity)) >= 0.999
        window.isOpaque = isOpaque
        window.backgroundColor = isOpaque ? opaqueBackground : .clear

        // Drop the window shadow while translucent. macOS computes the drop shadow from the
        // window's content alpha (a rectangle), so on a translucent window it renders as a
        // dark band hugging the rounded frame. With blur high the blurred backdrop hides it;
        // as blur drops it sharpens into the "hard dark edge at the corners that won't go
        // away." A translucent canvas already reads as glass (and the one window-wide blur
        // gives separation), so no shadow is the clean look; opaque windows keep theirs.
        // `invalidateShadow` forces an immediate recompute (toggling blur via the private CGS
        // API doesn't notify AppKit, which is why a stale shadow lingered).
        window.hasShadow = isOpaque
        window.invalidateShadow()

        WindowBlur.apply(radius: isOpaque ? 0 : blur, to: window)
    }
}
