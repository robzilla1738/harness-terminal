import SwiftUI

/// What sets Harness apart, in four rows, before setup begins.
struct DiscoverStepView: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let points: [(symbol: String, title: String, detail: String)] = [
        ("rectangle.stack", "Sessions that outlive the window",
         "Tabs, splits, and scrollback live in a background daemon. Quit, relaunch, and pick up where you left off."),
        ("bell.badge", "Agents that tell you when they need you",
         "Harness spots Claude Code, Codex, Cursor, and more, and notifies you when one wants approval, finishes, or fails."),
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
                bodyText: "Your shells and agents keep going whether or not Harness is open."
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
