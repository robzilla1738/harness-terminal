import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class SettingsWindowCloseProxyTests: XCTestCase {
    /// The persist safety net (#89) depends on the window delegate firing on close. A continuous
    /// slider drag applies live every tick but only persists in `HarnessSlider.mouseUp → onCommit`;
    /// if the window is closed mid-drag, `windowWillClose` is the backstop that saves the
    /// already-applied value. This proves the proxy invokes its closure on that notification.
    func testWindowWillCloseFiresPersistClosure() {
        var fired = 0
        let proxy = SettingsWindowCloseProxy { fired += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.delegate = proxy

        XCTAssertEqual(fired, 0, "closure must not fire before close")
        // Drive the same notification AppKit posts when the window closes.
        proxy.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertEqual(fired, 1, "windowWillClose must flush pending settings exactly once")
    }

    /// The proxy is retained by `SettingsWindowController` (NSWindow holds delegates weakly); confirm
    /// it actually serves as the window's delegate so a real close routes through it.
    func testProxyIsRetainedAsWindowDelegate() {
        let proxy = SettingsWindowCloseProxy {}
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.delegate = proxy
        XCTAssertTrue(window.delegate === proxy)
    }
}
