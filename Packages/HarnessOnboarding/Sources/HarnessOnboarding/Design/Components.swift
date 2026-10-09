import SwiftUI
import AppKit

/// Shared monochrome components for the immersive onboarding wizard.
/// One calm glass plane over black, off-white text, one white primary action per step.

enum Motion {
    @MainActor static var reduce: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor static var spring: Animation {
        reduce
            ? .easeOut(duration: ImmersivePalette.Motion.fast)
            : .spring(response: ImmersivePalette.Motion.springResponse,
                      dampingFraction: ImmersivePalette.Motion.springDamping)
    }
}

/// Eyebrow, title, and one or two sentences of body — the top of every step but Welcome.
struct StepIntro: View {
    let eyebrow: String
    let title: String
    let bodyText: String

    var body: some View {
        VStack(spacing: 0) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .textCase(.uppercase)
                .foregroundStyle(ImmersivePalette.SUI.textTertiary)
                .padding(.bottom, 12)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(ImmersivePalette.SUI.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)

            Text(bodyText)
                .font(.system(size: 14))
                .foregroundStyle(ImmersivePalette.SUI.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 540)
    }
}

/// A list row: a symbol tile, a title with a line of detail, and an optional trailing status.
struct IconRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ImmersivePalette.SUI.textPrimary.opacity(0.86))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ImmersivePalette.SUI.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(ImmersivePalette.SUI.textSecondary.opacity(0.85))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

extension IconRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// Rows separated by hairlines, at the width every step's list shares.
struct RowList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle().fill(ImmersivePalette.SUI.border).frame(height: 1).padding(.leading, 48)
                    }
                    row.padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: 500)
    }
}

/// One line of feedback under a step's list: what just happened, or what went wrong and why.
struct StatusNote: View {
    let text: Text
    var tone: StatusPill.Tone = .neutral

    var body: some View {
        text
            .font(.system(size: 12))
            .foregroundStyle(tone == .danger ? ImmersivePalette.SUI.danger : ImmersivePalette.SUI.textTertiary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 480)
            .transition(.opacity)
    }
}

struct StatusPill: View {
    enum Tone { case neutral, success, danger }
    let text: String
    var tone: Tone = .neutral

    private var color: Color {
        switch tone {
        case .neutral: ImmersivePalette.SUI.textSecondary
        case .success: ImmersivePalette.SUI.success
        case .danger:  ImmersivePalette.SUI.danger
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if tone == .success {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
            }
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.12)))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A shortcut drawn as keycaps, e.g. `KeyCaps(["⇧", "⌘", "U"])`.
struct KeyCaps: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ImmersivePalette.SUI.textPrimary)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, key.count > 1 ? 6 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct GlassPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.92))
            .frame(minWidth: 104, minHeight: 20)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.80 : 0.95))
                    .shadow(color: .white.opacity(0.10), radius: 18)
            )
            .contentShape(.focusEffect, Capsule())
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Text-only button for everything but the primary action (Back, Not Now, Skip Setup).
struct GlassTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ImmersivePalette.SUI.textSecondary.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .contentShape(.focusEffect, Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A small dark arc that turns while the primary button works. AppKit's spinner draws light on
/// this always-dark panel and all but vanishes on the white button.
struct Spinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.88)
            .stroke(Color.black.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityHidden(true)
    }
}
