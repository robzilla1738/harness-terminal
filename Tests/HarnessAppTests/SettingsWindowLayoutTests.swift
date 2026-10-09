import AppKit
import XCTest
@testable import HarnessApp
import HarnessCore

/// Every Settings pane lays out cleanly at the window's default and minimum sizes, in the dark
/// default and in light mode: no ambiguous layout, nothing past the page edge, no wrapped label
/// cut short.
@MainActor
final class SettingsWindowLayoutTests: XCTestCase {
    func testThemeSearchPanelAcceptsKeyboardFocus() async throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        var picked: String?
        let popover = HarnessSelectPopover(items: ["Harness Default", "Harness Deep Sea"],
                                          selected: nil, placeholder: "Search themes", featuredCount: 2) { picked = $0 }
        defer { popover.dismiss(); parent.orderOut(nil) }
        popover.present(anchor: parent.frame, width: 280, relativeTo: parent)
        let panel = try XCTUnwrap(parent.childWindows?.first)
        XCTAssertTrue(panel.canBecomeKey, "A borderless theme picker must accept search input")
        let focused = expectation(description: "Theme search receives focus")
        DispatchQueue.main.async {
            XCTAssertTrue(panel.firstResponder is NSTextView, "The search field editor should own typing")
            focused.fulfill()
        }
        await fulfillment(of: [focused], timeout: 2)
        let content = try XCTUnwrap(panel.contentView)
        let row = try XCTUnwrap(descendants(of: content).first { $0.accessibilityLabel() == "Harness Deep Sea" })
        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(picked, "Harness Deep Sea")
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }

    override class func setUp() {
        super.setUp()
        // Settings reads and writes the shared coordinator's store. Point it at a scratch home
        // (short, so the socket path fits) before anything touches it, and leave it there: a
        // later save must never land in the real settings file.
        setenv("HARNESS_HOME", "/tmp/hst-\(UUID().uuidString.prefix(6))", 1)
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    func testEveryPaneLaysOutCleanly() {
        for mode in [HarnessAppearanceMode.theme, .light] {
            var settings = HarnessSettings()
            settings.appearanceMode = mode
            SessionCoordinator.shared.settings = settings
            SessionCoordinator.shared.applySettingsToHosts()
            XCTAssertEqual(HarnessChrome.current.isDark, mode == .theme)
            for size in [NSSize(width: 940, height: 680), NSSize(width: 840, height: 600)] {
                let controller = SettingsViewController()
                let window = NSWindow(contentViewController: controller)
                window.setContentSize(size)
                for pane in SettingsPane.allCases {
                    controller.showPage(pane)
                    window.layoutIfNeeded()
                    for problem in layoutProblems(in: controller.view) {
                        XCTFail("\(pane.title) at \(Int(size.width))×\(Int(size.height)), \(mode): \(problem)")
                    }
                }
                window.close()
            }
        }
    }

    func testLiveLightThemeRefreshesSidebarBackground() throws {
        var settings = HarnessSettings()
        settings.appearanceMode = .theme
        SessionCoordinator.shared.settings = settings
        SessionCoordinator.shared.applySettingsToHosts()
        let controller = SettingsViewController()
        let root = controller.view
        let backdrop = try XCTUnwrap(root.subviews.flatMap(\.subviews).first { $0 is ChromeBackdrop })
        let tint = try XCTUnwrap(backdrop.subviews.last)
        let darkColor = try XCTUnwrap(tint.layer?.backgroundColor)
        settings.appearanceMode = .light
        SessionCoordinator.shared.settings = settings
        SessionCoordinator.shared.applySettingsToHosts()
        NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged,
                                        object: nil, userInfo: ["chromeChanged": true])
        let lightColor = try XCTUnwrap(tint.layer?.backgroundColor)
        XCTAssertNotEqual(darkColor, lightColor, "sidebar background must follow its label colors")
        let color = try XCTUnwrap(NSColor(cgColor: lightColor)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
    }

    func testToggleAndSegmentAnswerTheKeyboardAndVoiceOver() {
        let target = ActionCounter()
        let toggle = HarnessToggle(frame: .zero)
        toggle.target = target
        toggle.action = #selector(ActionCounter.fire)
        XCTAssertTrue(toggle.accessibilityPerformPress())
        XCTAssertEqual(toggle.state, .on)
        toggle.keyDown(with: key(" ", code: 49))
        XCTAssertEqual(toggle.state, .off)

        let segment = HarnessSegmented(frame: .zero)
        segment.setSegments(["Block", "Beam", "Underline"])
        segment.target = target
        segment.action = #selector(ActionCounter.fire)
        segment.keyDown(with: key("", code: 124))
        XCTAssertEqual(segment.titleOfSelectedItem, "Beam")
        XCTAssertTrue(segment.accessibilityPerformDecrement())
        XCTAssertEqual(segment.titleOfSelectedItem, "Block")
        _ = segment.accessibilityPerformDecrement() // already first: stays, sends nothing
        XCTAssertEqual(segment.titleOfSelectedItem, "Block")
        XCTAssertEqual(target.count, 4)
    }

    func testSegmentsAreWideEnoughForTheirTitles() {
        let segment = HarnessSegmented(frame: .zero)
        segment.setSegments(["Comfortable", "Compact"])
        let label = NSTextField(labelWithString: "Comfortable")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        XCTAssertGreaterThanOrEqual(segment.intrinsicContentSize.width / 2, label.intrinsicContentSize.width + 8)
    }

    private func layoutProblems(in root: NSView) -> [String] {
        guard let doc = descendants(of: root).compactMap({ $0 as? NSScrollView }).first?.documentView else {
            return ["no page"]
        }
        var problems: [String] = []
        for view in descendants(of: doc) where !view.isHiddenOrHasHiddenAncestor {
            let frame = view.convert(view.bounds, to: doc)
            if frame.maxX > doc.bounds.maxX + 0.5 || frame.minX < -0.5 {
                problems.append("\(type(of: view)) runs past the page edge (\(frame))")
            }
            if view.hasAmbiguousLayout {
                problems.append("\(type(of: view)) has an ambiguous layout")
            }
            if let label = view as? NSTextField, !label.isEditable, label.cell?.wraps == true,
               label.intrinsicContentSize.height > label.bounds.height + 1 {
                problems.append("“\(label.stringValue.prefix(40))” is clipped")
            }
        }
        return problems
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
    }
}

@MainActor
private final class ActionCounter: NSObject {
    var count = 0
    @objc func fire() { count += 1 }
}
