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
