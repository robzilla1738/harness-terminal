import SwiftUI

/// Final step: the four shortcuts worth learning first. The wizard's footer closes it.
struct CompleteStepView: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shortcuts: [(keys: [String], title: String, detail: String)] = [
        (["⌘", "K"], "Command palette", "Every command and setting, by name"),
        (["⇧", "⌘", "U"], "Jump to agent", "Go straight to whoever needs you"),
        (["⇧", "⌘", "O"], "Workspace Overview", "Every tab as a live tile"),
        (["⌘", "N"], "New window", "Another session, side by side"),
    ]

    var body: some View {
        VStack(spacing: 28) {
            StepIntro(
                eyebrow: "Ready",
                title: "You're all set.",
                bodyText: "Four shortcuts to start with. Press ⌘/ for the rest."
            )

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { column in
                            tile(shortcuts[row * 2 + column], index: row * 2 + column)
                        }
                    }
                }
            }
            .frame(maxWidth: 540)
        }
        .onAppear { appeared = true }
    }

    private func tile(_ shortcut: (keys: [String], title: String, detail: String), index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyCaps(shortcut.keys)
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ImmersivePalette.SUI.textPrimary)
                Text(shortcut.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ImmersivePalette.SUI.textSecondary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.04))
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortcut.title), \(shortcut.keys.joined()). \(shortcut.detail)")
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .animation(reduceMotion ? .easeOut(duration: 0.18)
                   : .spring(response: 0.5, dampingFraction: 0.86).delay(0.08 + Double(index) * 0.05),
                   value: appeared)
    }
}
