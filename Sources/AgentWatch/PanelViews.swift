import AgentWatchCore
import SwiftUI

extension SessionState {
    var color: Color {
        switch self {
        case .needsInput: .orange
        case .running: .green
        case .stale: .yellow
        case .idle: Color(nsColor: .tertiaryLabelColor)
        case .unknown: .purple.opacity(0.7)
        case .ended: Color(nsColor: .quaternaryLabelColor)
        }
    }
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.30, green: 0.56, blue: 0.98)
        }
    }
}

struct PanelRootView: View {
    let model: AppModel
    var controller: PanelController? = nil

    var body: some View {
        Group {
            if model.settings.collapsed {
                PillView(model: model, controller: controller)
            } else {
                ExpandedView(model: model, controller: controller)
            }
        }
        .padding(8) // room for the attention glow
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { controller?.applyOpacity(hovering: $0) }
        // Drag from anywhere moves the window; rows ignore the click that ends a drag.
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in controller?.dragChanged() }
                .onEnded { _ in controller?.dragEnded() }
        )
    }
}

// MARK: - Pulse

private struct AttentionGlow: ViewModifier {
    let active: Bool
    let pulse: Bool
    let shape: AnyShape
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            // Glow lives on the border stroke only; a shadow on the content would tint the translucent material.
            .overlay(
                shape.stroke(Color.orange.opacity(active ? (phase ? 1 : 0.45) : 0), lineWidth: 1.5)
                    .shadow(color: .orange.opacity(active ? (phase ? 0.8 : 0.25) : 0), radius: active ? 6 : 0)
                    .allowsHitTesting(false)
            )
            .onAppear { restart() }
            .onChange(of: active) { restart() }
            .onChange(of: pulse) { restart() }
    }

    private func restart() {
        phase = false
        guard active, pulse else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
    }
}

extension View {
    func attentionGlow(_ active: Bool, pulse: Bool, shape: some Shape) -> some View {
        modifier(AttentionGlow(active: active, pulse: pulse, shape: AnyShape(shape)))
    }
}

// MARK: - Collapsed

struct PillView: View {
    let model: AppModel
    var controller: PanelController? = nil

    var body: some View {
        let c = model.counts
        HStack(spacing: 10) {
            count(c.attention, .orange)
            count(c.running, .green)
            count(c.idle, Color(nsColor: .tertiaryLabelColor))
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .background(c.attention > 0 ? Color.orange.opacity(0.18) : .clear, in: Capsule())
        .attentionGlow(c.attention > 0, pulse: model.settings.pulse, shape: Capsule())
        .fixedSize()
        .contentShape(Capsule())
        .onTapGesture { if controller?.didDrag != true { model.settings.collapsed = false } }
        .help("Click to expand · drag to move")
    }

    private func count(_ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(n)").foregroundStyle(n == 0 ? .secondary : .primary)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    let model: AppModel
    var controller: PanelController? = nil
    /// ImageRenderer can't draw ScrollView or AppKit views, so snapshots use a plain stack.
    var forSnapshot = false
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let rows = model.rows
        let attention = model.counts.attention > 0
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if forSnapshot {
                list(rows)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) { list(rows) }.scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: shape)
        .overlay(alignment: .bottomTrailing) {
            if !forSnapshot { ResizeGrip(controller: controller).frame(width: 16, height: 16).padding(2) }
        }
        .clipShape(shape)
        .attentionGlow(attention, pulse: model.settings.pulse, shape: shape)
    }

    @ViewBuilder
    private func list(_ rows: [Session]) -> some View {
        if rows.isEmpty {
            Text("No agent sessions")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { s in
                    SessionRowView(model: model, controller: controller, session: s)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var header: some View {
        let c = model.counts
        return HStack(spacing: 8) {
            Text("AgentWatch").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 7) {
                miniCount(c.attention, .orange)
                miniCount(c.running, .green)
                miniCount(c.idle, Color(nsColor: .tertiaryLabelColor))
            }
            .allowsHitTesting(false)
            Button { model.settings.collapsed = true } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse to pill")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func miniCount(_ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(n)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct SessionRowView: View {
    let model: AppModel
    var controller: PanelController? = nil
    let session: Session
    @State private var hovering = false

    var body: some View {
        let state = model.displayState(session)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(state.color).frame(width: 8, height: 8)
                Text(session.agent.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(session.agent.tint)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(session.agent.tint.opacity(0.16), in: Capsule())
                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(state.verb) \(shortDuration(model.now.timeIntervalSince(model.since(session))))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(state == .needsInput ? Color.orange : .secondary)
            }
            if let sub = subtitle(state) {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundStyle(session.error != nil && state == .idle ? Color.red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 14)
            }
            ForEach(session.sortedSubagents) { sub in
                HStack(spacing: 5) {
                    Text("↳").foregroundStyle(.tertiary)
                    Circle().fill(sub.running ? Color.green : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 6, height: 6)
                    Text(sub.type).lineLimit(1)
                    Spacer()
                    Text(sub.running ? "running \(shortDuration(model.now.timeIntervalSince(sub.since)))" : "done")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
                .padding(.leading, 14)
            }
        }
        .opacity(state == .ended ? 0.5 : 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if controller?.didDrag != true { Focuser.focus(session) } }
        .contextMenu {
            Button("Bring to Front") { Focuser.focus(session) }
            Button("Open Folder in Finder") { Focuser.openFolder(session) }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionId, forType: .string)
            }
            Divider()
            Button("Dismiss") { model.dismiss(session) }
        }
        .help(tooltip)
    }

    private func subtitle(_ state: SessionState) -> String? {
        switch state {
        case .needsInput:
            guard let p = session.primaryPending else { return nil }
            return [p.reason, p.detail].compactMap { $0 }.joined(separator: " · ")
        case .running:
            return nonEmpty(session.currentDetail) ?? session.lastPrompt
        case .stale:
            return "no activity since \(session.lastActivityEvent ?? "start")"
        case .idle:
            return session.error ?? session.lastMessage ?? session.lastPrompt
        case .unknown:
            return "no hook events yet" + (session.pid.map { " · pid \($0)" } ?? "")
        case .ended:
            return nil
        }
    }

    private var tooltip: String {
        var parts = [session.cwd ?? "?"]
        if let host = session.hostKind { parts.append("in \(host)") }
        if let pid = session.pid { parts.append("pid \(pid)") }
        if !session.hasHooks { parts.append("(inferred, no hooks)") }
        return parts.joined(separator: "  ")
    }

    private func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}
