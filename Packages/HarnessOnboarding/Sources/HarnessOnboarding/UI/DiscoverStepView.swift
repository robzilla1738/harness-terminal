import SwiftUI

/// What sets Harness apart, in four rows, before setup begins.
struct DiscoverStepView: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let points: [(symbol: String, title: String, detail: String)] = [
        ("rectangle.stack", "Sessions that outlive the window",
         "Session persistence is on by default. Quit and reopen Harness while your Mac stays running; change this behavior in Settings."),
        ("bell.badge", "Agents that tell you when they need you",
         "See agent activity alongside your shells. Optional hooks report supported events; choose banners and sounds in Settings."),
        ("macwindow.on.rectangle", "Every window, every machine",
         "Open as many windows as you like, and connect to other Macs or Linux boxes over SSH, all live side by side."),
        ("chevron.left.forwardslash.chevron.right", "Scriptable to the core",
         "harness-cli, a JSON API, and Lua config drive the same sessions, tabs, and panes you see."),
    ]

    var body: some View {
        VStack(spacing: 28) {
            StepIntro(
                eyebrow: "Overview",
                title: "A terminal built for long-running work.",
                bodyText: "Start with your usual shell. Add workspaces, remote hosts, and automation when you need them."
            )

            RowList {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    IconRow(symbol: point.symbol, title: point.title, detail: point.detail)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 8)
                        .animation(reduceMotion ? .easeOut(duration: 0.18)
                                   : .spring(response: 0.5, dampingFraction: 0.88).delay(0.08 + Double(index) * 0.05),
                                   value: appeared)
                }
            }
        }
        .onAppear { appeared = true }
    }
}
