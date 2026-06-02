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
                .contentShape(Rectangle())
                .onHover { model.handleHover($0) }
                .onTapGesture {
                    if !model.isOpen { model.open() }
                }
                .animation(animation, value: model.presentation)
                .animation(animation, value: model.openContentHeight)
                .animation(animation, value: model.waitingCount)
                .accessibilityElement(children: .contain)
        }
        .frame(
            width: CGFloat(model.geometry.panelFrame.width),
            height: CGFloat(model.geometry.panelFrame.height),
            alignment: .top
        )
    }

    @ViewBuilder
    private var shell: some View {
        switch model.presentation {
        case .closed:
            closedView
        case .open:
            openView
        }
    }

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

    private var openView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.visibleRows) { row in
                        overviewRow(row)
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
        .padding(.horizontal, 13)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Harness Agent Notch")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Harness Agents")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(model.agentCount) agents / \(model.sessionCount) sessions")
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

    private func overviewRow(_ row: AgentNotchRowSummary) -> some View {
        Button {
            model.openRow(row)
        } label: {
            rowShell(
                dot: statusDot(kind: row.agentKind, waiting: row.waitingCount > 0),
                title: rowTitle(row),
                subtitle: rowSubtitle(row),
                badge: rowBadge(row)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rowTitle(row)), \(rowSubtitle(row))")
    }

    private func rowShell(dot: some View, title: String, subtitle: String, badge: String?) -> some View {
        HStack(spacing: 8) {
            dot
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "Terminal" : title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                statusDot(kind: agent.kind, waiting: agent.waiting)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }

    private func statusDot(kind: AgentKind?, waiting: Bool) -> some View {
        Circle()
            .fill(dotColor(kind: kind, waiting: waiting))
            .frame(width: 9, height: 9)
            .shadow(color: dotColor(kind: kind, waiting: waiting).opacity(waiting ? 0.6 : 0.25), radius: waiting ? 5 : 2)
    }

    private func dotColor(kind: AgentKind?, waiting: Bool) -> Color {
        if waiting { return .orange }
        guard let kind else { return Color.white.opacity(0.36) }
        let hex = SessionCoordinator.shared.settings.agentColorHex(for: kind)
        return Color(nsColor: NSColor.fromHex(hex) ?? .secondaryLabelColor)
    }

    private var currentWidth: CGFloat {
        switch model.presentation {
        case .closed:
            return CGFloat(model.geometry.closedWidth)
        case .open:
            return CGFloat(model.geometry.openWidth)
        }
    }

    private var currentHeight: CGFloat {
        switch model.presentation {
        case .closed:
            return CGFloat(model.geometry.closedHeight)
        case .open:
            return model.openContentHeight
        }
    }

    private var isExpanded: Bool {
        switch model.presentation {
        case .closed: return false
        case .open: return true
        }
    }

    private var topRadius: CGFloat {
        model.geometry.hasPhysicalNotch ? 2 : 9
    }

    private var bottomRadius: CGFloat {
        switch model.presentation {
        case .closed:
            return model.geometry.hasPhysicalNotch ? 14 : 15
        case .open:
            return 22
        }
    }

    private var rowBackground: Color {
        reduceTransparency ? Color.white.opacity(0.13) : Color.white.opacity(0.08)
    }

    private var shadowColor: Color {
        reduceTransparency ? .clear : .black.opacity(0.52)
    }

    private var animation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .interactiveSpring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.06)
    }

    private var closedAccessibilityLabel: String {
        if model.waitingCount > 0 {
            return "Harness Agent Notch, \(model.waitingCount) agents waiting"
        }
        return "Harness Agent Notch, \(model.agents.count) agents"
    }

    private func rowTitle(_ row: AgentNotchRowSummary) -> String {
        if let kind = row.agentKind {
            return kind.displayName
        }
        return row.title
    }

    private func rowSubtitle(_ row: AgentNotchRowSummary) -> String {
        row.detail
    }

    private func rowBadge(_ row: AgentNotchRowSummary) -> String? {
        if row.waitingCount > 0 { return row.waitingCount == 1 ? "waiting" : "\(row.waitingCount) waiting" }
        if row.agentActivity == .working { return "working" }
        if row.rowKind == .session, row.tabCount > 1 { return "\(row.tabCount) tabs" }
        return nil
    }
}
