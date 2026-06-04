import AppKit
import HarnessCore
import SwiftUI

struct AgentNotchRootView: View {
    @ObservedObject var model: AgentNotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            shell
                .frame(width: currentWidth, height: currentHeight, alignment: .top)
                .background(Color.black)
                .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.black)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                .shadow(color: shadowColor, radius: isExpanded ? 12 : 0, y: isExpanded ? 8 : 0)
                // Closed state: only the inner ~3/4 of the pill is hover/click-sensitive, so
                // a fly-by across the menu bar (or a fling to the top edge) never triggers
                // the HUD. Peek/open keep the whole card interactive.
                .contentShape(HorizontalInsetRect(inset: hotZoneInset))
                .onHover { model.handleHover($0) }
                .onTapGesture {
                    if !model.isOpen { model.open() }
                }
                .animation(contentAnimation, value: model.openContentHeight)
                .animation(contentAnimation, value: model.waitingCount)
                .accessibilityElement(children: .contain)
        }
        .frame(
            width: CGFloat(model.geometry.panelFrame.width),
            height: CGFloat(model.geometry.panelFrame.height),
            alignment: .top
        )
    }

    /// Presentation switch with staggered transitions: the shape (frame/radii, animated by
    /// the model's springs) leads; incoming content fades and settles in just after, and
    /// outgoing content drops away fast — no hard swap.
    @ViewBuilder
    private var shell: some View {
        switch model.presentation {
        case .closed:
            closedView
                .transition(closedTransition)
        case let .peek(event):
            peekView(event)
                .transition(expandedContentTransition)
        case .open:
            openView
                .transition(expandedContentTransition)
        }
    }

    // MARK: - Closed

    private var closedView: some View {
        HStack(spacing: 7) {
            Image(systemName: model.waitingCount > 0 ? "sparkles" : "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.waitingCount > 0 ? Color.orange : Color.white.opacity(0.72))
            agentDots(limit: 4)
            if model.waitingCount > 0 {
                Text("\(model.waitingCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.88), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(closedAccessibilityLabel)
    }

    // MARK: - Peek

    /// Transient one-row live activity: dot + agent + one-line reason. Clicking jumps to
    /// the tab; hovering holds it (and promotes to the full HUD after the dwell).
    private func peekView(_ event: AgentNotchPeekEvent) -> some View {
        Button {
            model.openRow(event.row)
        } label: {
            HStack(spacing: 8) {
                statusDot(
                    kind: event.row.agentKind,
                    waiting: event.reason == .needsInput,
                    working: event.row.agentActivity == .working
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(peekTitle(event))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(peekReason(event))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(peekReasonColor(event.reason))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, CGFloat(model.geometry.hasPhysicalNotch ? model.geometry.closedHeight - 22 : 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(peekTitle(event)), \(peekReason(event))")
    }

    private func peekTitle(_ event: AgentNotchPeekEvent) -> String {
        event.row.agentKind?.displayName ?? event.row.title
    }

    private func peekReason(_ event: AgentNotchPeekEvent) -> String {
        switch event.reason {
        case .needsInput:
            return event.row.notificationText ?? "needs your input"
        case .errored:
            return "hit an error"
        case .finished:
            return "finished"
        }
    }

    private func peekReasonColor(_ reason: AgentNotchPeekEvent.Reason) -> Color {
        switch reason {
        case .needsInput: return .orange
        case .errored: return Color(red: 1.0, green: 0.42, blue: 0.40)
        case .finished: return Color(red: 0.42, green: 0.85, blue: 0.50)
        }
    }

    // MARK: - Open

    private var openView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.visibleRows.isEmpty {
                emptyState
            } else {
                rowList
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Harness Agent Notch")
    }

    private var rowList: some View {
        // Periodic tick only while open, so the relative timestamps ("2m") stay honest
        // without any timer running while the notch is closed.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.visibleRows) { row in
                        NotchOverviewRow(
                            row: row,
                            progressPercent: model.rowProgress[row.id],
                            now: context.date,
                            dot: AnyView(statusDot(
                                kind: row.agentKind,
                                waiting: row.waitingCount > 0,
                                working: row.agentActivity == .working
                            )),
                            reduceTransparency: reduceTransparency
                        ) {
                            model.openRow(row)
                        }
                    }
                    if model.hasOverflowRows {
                        Text("More sessions available in the main window")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.44))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 1)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 3) {
            Text("No active sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text("Agents and sessions appear here as they run")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Harness Agents")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(model.headerSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            if model.waitingCount > 0 {
                chip("\(model.waitingCount) waiting", color: .orange)
            }
            if model.workingCount > 0 {
                chip("\(model.workingCount) working", color: .green)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.32), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func agentDots(limit: Int) -> some View {
        HStack(spacing: -3) {
            ForEach(Array(model.agents.prefix(limit).enumerated()), id: \.element.id) { _, agent in
                statusDot(kind: agent.kind, waiting: agent.waiting, working: agent.activity == .working)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }

    private func statusDot(kind: AgentKind?, waiting: Bool, working: Bool) -> some View {
        NotchStatusDot(
            color: dotColor(kind: kind, waiting: waiting),
            working: working,
            waiting: waiting,
            reduceMotion: reduceMotion
        )
    }

    private func dotColor(kind: AgentKind?, waiting: Bool) -> Color {
        if waiting { return .orange }
        guard let kind else { return Color.white.opacity(0.36) }
        let hex = SessionCoordinator.shared.settings.agentColorHex(for: kind)
        return Color(nsColor: NSColor.fromHex(hex) ?? .secondaryLabelColor)
    }

    // MARK: - Geometry

    private var currentWidth: CGFloat {
        switch model.presentation {
        case .closed:
            return CGFloat(model.geometry.closedWidth)
        case .peek:
            return CGFloat(model.geometry.peekWidth)
        case .open:
            return CGFloat(model.geometry.openWidth)
        }
    }

    private var currentHeight: CGFloat {
        switch model.presentation {
        case .closed:
            return CGFloat(model.geometry.closedHeight)
        case .peek:
            return CGFloat(model.geometry.peekHeight)
        case .open:
            return model.openContentHeight
        }
    }

    private var isExpanded: Bool {
        switch model.presentation {
        case .closed: return false
        case .peek, .open: return true
        }
    }

    private var topRadius: CGFloat {
        model.geometry.hasPhysicalNotch ? 2 : 9
    }

    private var bottomRadius: CGFloat {
        switch model.presentation {
        case .closed:
            return model.geometry.hasPhysicalNotch ? 14 : 15
        case .peek:
            return 18
        case .open:
            return 22
        }
    }

    /// Closed-state hover/click hot zone shrinks 24 pt per side (accidental-trigger fix);
    /// peek/open stay fully interactive.
    private var hotZoneInset: CGFloat {
        if case .closed = model.presentation { return 24 }
        return 0
    }

    private var shadowColor: Color {
        reduceTransparency ? .clear : .black.opacity(0.52)
    }

    /// In-place value changes while open (row count, badges) — presentation changes are
    /// animated by the model's asymmetric springs instead.
    private var contentAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.30, dampingFraction: 0.88)
    }

    private var closedTransition: AnyTransition {
        .opacity.animation(.easeOut(duration: reduceMotion ? 0.08 : 0.14))
    }

    /// Incoming expanded content fades in and settles upward just after the shape starts
    /// growing (skill: shape leads by 40–90 ms); outgoing content drops away fast.
    private var expandedContentTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeOut(duration: 0.10))
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8))
                .animation(.easeOut(duration: 0.20).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.10))
        )
    }

    private var closedAccessibilityLabel: String {
        if model.waitingCount > 0 {
            return "Harness Agent Notch, \(model.waitingCount) agents waiting"
        }
        return "Harness Agent Notch, \(model.agents.count) agents"
    }
}

/// Hit-test shape for the notch shell: the full rect inset horizontally. Used to shrink the
/// closed pill's hover/click target without changing its visual size.
private struct HorizontalInsetRect: Shape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: inset, dy: 0))
    }
}

/// One open-state row: dot · title + subtitle · progress/badge · relative time. Hover
/// brightens, press compresses — the row should feel like a control, not a label.
private struct NotchOverviewRow: View {
    let row: AgentNotchRowSummary
    let progressPercent: Int?
    let now: Date
    let dot: AnyView
    let reduceTransparency: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                dot
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "Terminal" : title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let relative = relativeTime {
                    Text(relative)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                }
                if let badge {
                    Text(badge.text)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.16), in: Capsule())
                }
            }
            .frame(height: 38)
            .padding(.horizontal, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(alignment: .bottomLeading) { progressUnderline }
        }
        .buttonStyle(NotchRowButtonStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private var title: String {
        row.agentKind?.displayName ?? row.title
    }

    private var subtitle: String {
        // A blocked agent's notification body is the densest thing we can show.
        if row.waitingCount > 0, let text = row.notificationText, !text.isEmpty {
            return text
        }
        return row.detail
    }

    private var subtitleColor: Color {
        row.waitingCount > 0 && row.notificationText != nil
            ? Color.orange.opacity(0.92)
            : Color.white.opacity(0.54)
    }

    private var relativeTime: String? {
        guard let date = row.lastActivityAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    private var badge: (text: String, color: Color)? {
        if row.waitingCount > 0 {
            return (row.waitingCount == 1 ? "needs input" : "\(row.waitingCount) need input", .orange)
        }
        if row.agentActivity == .errored {
            return ("error", Color(red: 1.0, green: 0.45, blue: 0.42))
        }
        if row.agentActivity == .working {
            if let percent = progressPercent {
                return ("\(percent)%", Color(red: 0.42, green: 0.85, blue: 0.50))
            }
            return ("working", Color(red: 0.42, green: 0.85, blue: 0.50))
        }
        if row.rowKind == .session, row.tabCount > 1 {
            return ("\(row.tabCount) tabs", .white.opacity(0.7))
        }
        return nil
    }

    /// 2 pt determinate progress bar pinned to the row's bottom edge (OSC 9;4 `set`).
    @ViewBuilder
    private var progressUnderline: some View {
        if let percent = progressPercent, row.agentActivity == .working {
            GeometryReader { proxy in
                Capsule()
                    .fill(Color(red: 0.42, green: 0.85, blue: 0.50).opacity(0.85))
                    .frame(width: max(6, proxy.size.width * CGFloat(percent) / 100), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 2)
            }
            .padding(.horizontal, 10)
            .allowsHitTesting(false)
        }
    }

    private var background: Color {
        let base = reduceTransparency ? 0.13 : 0.08
        return Color.white.opacity(hovering ? base + 0.06 : base)
    }
}

/// Press feedback: gentle compression, no color flash.
private struct NotchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A notch status dot that gently breathes while its agent is working (honoring Reduce Motion),
/// and is a calm static dot otherwise. The breathing is the closed-view "agent is still working"
/// signal that pairs with the red waiting badge.
private struct NotchStatusDot: View {
    let color: Color
    let working: Bool
    let waiting: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    private var animates: Bool { working && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .scaleEffect(animates && pulse ? 1.18 : 1.0)
            .opacity(animates && pulse ? 0.62 : 1.0)
            .shadow(color: color.opacity(waiting ? 0.6 : 0.25), radius: waiting ? 5 : 2)
            .onAppear { syncPulse() }
            .onChange(of: working) { _, _ in syncPulse() }
            .onChange(of: reduceMotion) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        if animates {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }
}
