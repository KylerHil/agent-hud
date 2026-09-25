import AgentHUDCore
import SwiftUI

extension SessionState {
    var nsColor: NSColor {
        switch self {
        case .needsInput: .systemOrange
        case .running: .systemGreen
        case .stale: .systemYellow
        case .idle: .tertiaryLabelColor
        case .unknown: .systemPurple.withAlphaComponent(0.7)
        case .ended: .quaternaryLabelColor
        }
    }

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
        case .chatgpt: Color.primary.opacity(0.75)
        }
    }
}

/// Buttons in the panel that open other windows; wired by the app delegate.
@MainActor
struct PanelActions {
    var openDashboard: () -> Void = {}
    /// Makes the panel take keystrokes, for the search field.
    var focusPanel: () -> Void = {}
}

// MARK: - Small pieces

struct StateDot: View {
    let state: SessionState
    var size: CGFloat = 8
    var halo = false

    var body: some View {
        Circle().fill(state.color)
            .frame(width: size, height: size)
            .background(Circle().fill(state.color.opacity(halo && state != .idle ? 0.22 : 0)).padding(-3))
    }
}

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(agent.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(agent.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize() // never squeezed into a column by a long project name
    }
}

struct SourceChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            .fixedSize()
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.16)))
            .fixedSize()
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Root

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
        HStack(spacing: 9) {
            if let s = model.nextWaiting {
                // Name the session that has waited longest, so the pill says who needs you.
                StateDot(state: .needsInput)
                Text(s.projectName).fontWeight(.bold).lineLimit(1)
                if let reason = s.primaryPending?.reason {
                    Text(reason).foregroundStyle(.orange).lineLimit(1)
                }
                if c.attention > 1 {
                    Text("+\(c.attention - 1)")
                        .fontWeight(.bold)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                }
            } else {
                count(c.running, .green)
                count(c.idle, Color(nsColor: .tertiaryLabelColor))
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .frame(maxWidth: 320)
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
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        let attention = model.counts.attention > 0
        VStack(spacing: 0) {
            if model.mode == .dashboard {
                DashboardView(model: model, forSnapshot: forSnapshot)
            } else if model.mode == .settings {
                PanelSettingsView(model: model)
            } else if let id = model.detailID, let s = model.store.sessions[id] {
                SessionDetailView(model: model, session: s, forSnapshot: forSnapshot)
            } else {
                header
                if model.searching {
                    SearchField(model: model)
                } else {
                    tabs
                }
                if model.legacyHooks && !model.searching { legacyBanner }
                if let r = model.updater.available, !model.searching { updateBanner(r) }
                if forSnapshot {
                    list
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical) { list }.scrollIndicators(.automatic)
                }
                footer
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("Agent HUD").font(.system(size: 12, weight: .semibold))
            Spacer()
            IconButton(symbol: "magnifyingglass", help: "Find a session (\(model.settings.findShortcut.display))") {
                if model.searching { model.endSearch() } else { model.beginSearch(); model.actions.focusPanel() }
            }
            IconButton(symbol: "chart.bar.xaxis", help: "Dashboard") { model.actions.openDashboard() }
            if model.canSyncDotOrder {
                IconButton(symbol: "rectangle.split.3x1", help: "Order menu bar dots like your AeroSpace windows") {
                    model.syncDotOrder()
                }
            }
            IconButton(symbol: "gearshape", help: "Settings") { model.openSettings() }
            IconButton(symbol: "chevron.up", help: "Collapse to pill") { model.settings.collapsed = true }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
    }

    private var tabs: some View {
        let units = model.units
        let current = model.filter
        return HStack(spacing: 2) {
            ForEach(PanelFilter.allCases, id: \.self) { f in
                let n = units.filter { f.includes(model.state($0)) }.count
                Button { model.filter = f } label: {
                    HStack(spacing: 4) {
                        if f != .all {
                            Circle().fill(dotColor(f)).frame(width: 6, height: 6)
                        }
                        Text(f.title).fontWeight(.semibold)
                        Text("\(n)").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .background(current == f ? Color.primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(current == f ? .primary : .secondary)
                .accessibilityAddTraits(current == f ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func dotColor(_ f: PanelFilter) -> Color {
        switch f {
        case .needs: .orange
        case .working: .green
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var legacyBanner: some View {
        Button { model.openSettings(.hooks) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                Text("Hooks still use the old AgentWatch reporter.").foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("Update…").fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Shown when an update is waiting (auto-install is off, or waits until nothing needs you).
    private func updateBanner(_ r: UpdateCheck.Release) -> some View {
        Button { model.updater.install() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("Agent HUD \(r.version) is available.").foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(model.updater.status == .installing ? "Updating…" : "Update").fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var list: some View {
        if model.searching {
            searchList
        } else {
            groupedList
        }
    }

    /// While searching: one flat list, the selected row highlighted, numbered for ⌘1–9.
    @ViewBuilder
    private var searchList: some View {
        let rows = model.searchResults
        if rows.isEmpty {
            Text(model.query.isEmpty ? "No agent sessions" : "No matches")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                    SessionRowView(model: model, controller: controller, session: s,
                                   selected: i == min(model.searchSelection, rows.count - 1))
                }
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        let groups = model.groups
        if groups.isEmpty {
            Text(model.rows.isEmpty ? "No agent sessions" : "Nothing here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(g.title.uppercased()).fontWeight(.bold)
                            Text("\(g.units.count)")
                        }
                        .font(.system(size: 9.5))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 1)
                        ForEach(g.units) { u in
                            if u.isProject {
                                SessionRowView(model: model, controller: controller, session: u.primary, unit: u)
                            } else {
                                SessionRowView(model: model, controller: controller, session: u.primary)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var footer: some View {
        let t = model.today()
        let text = t.working + t.waiting < 60 ? "No agent time yet today"
            : "\(shortDuration(t.working)) agent time · \(shortDuration(t.waiting)) waiting on you"
        return HStack(spacing: 6) {
            Button { model.actions.openDashboard() } label: { Text(text).lineLimit(1) }
                .buttonStyle(.plain)
                .help("Open the dashboard")
            Spacer(minLength: 4)
            if model.settings.hotkeysEnabled {
                Keycap(text: model.settings.findShortcut.display)
                Text("jump")
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 22) // clear of the resize grip
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

// MARK: - Row

struct SessionRowView: View {
    let model: AppModel
    var controller: PanelController? = nil
    let session: Session
    var selected = false
    /// Set when this row stands for a whole project (several sessions).
    var unit: AppModel.Unit? = nil
    @State private var hovering = false

    private var expanded: Bool { unit.map { model.expandedProjects.contains($0.id) } ?? false }

    var body: some View {
        let state = model.displayState(session)
        let waiting = state == .needsInput
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let unit {
                    Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(unit) } } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(expanded ? "Hide this project's sessions" : "Show all \(unit.sessions.count) sessions")
                    .accessibilityLabel(expanded ? "Collapse \(session.projectName)" : "Show sessions in \(session.projectName)")
                }
                StateDot(state: state, halo: true)
                ForEach(agents, id: \.self) { AgentBadge(agent: $0) }
                Text(session.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let sub = session.subpath {
                    // Gives way first: the project name matters more than where inside it the agent is.
                    Text("› " + sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
                if let unit { SessionDots(states: unit.sessions.map(model.displayState)) }
                if let host = hostsLabel { SourceChip(label: host) }
                if model.isMuted(session) {
                    Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if hovering {
                    Button { model.detailID = session.id } label: {
                        Image(systemName: "info.circle").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show details")
                    .accessibilityLabel("Show details")
                } else {
                    Text(timeLabel(state))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(waiting ? Color.orange : state == .stale ? Color.yellow : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            subtitle(state)
                .padding(.leading, 14)
            if let unit, expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(unit.sessions) { s in ProjectSessionRow(model: model, controller: controller, session: s) }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).padding(.leading, 8)
                }
            } else if unit == nil {
            ForEach(session.sortedSubagents) { sub in
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Circle().fill(sub.running ? Color.green : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 6, height: 6)
                    Text(sub.type).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(sub.running ? shortDuration(model.now.timeIntervalSince(sub.since)) : "done")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
                .padding(.leading, 14)
            }
            }
        }
        .opacity(state == .ended ? 0.5 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(background(waiting), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : waiting ? Color.orange.opacity(0.35) : .clear,
                          lineWidth: selected ? 1.5 : 1))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if controller?.didDrag != true {
                model.endSearch()
                Focuser.focus(session)
            }
        }
        .contextMenu { SessionMenu(model: model, session: session) }
        .help(tooltip)
    }

    /// A project row lists each agent once, and each app once ("Claude app · VS Code").
    private var agents: [AgentKind] {
        guard let unit else { return [session.agent] }
        var seen: [AgentKind] = []
        for s in unit.sessions where !seen.contains(s.agent) { seen.append(s.agent) }
        return seen
    }

    private var hostsLabel: String? {
        guard let unit else { return session.hostLabel }
        var seen: [String] = []
        for s in unit.sessions { if let h = s.hostLabel, !seen.contains(h) { seen.append(h) } }
        return seen.isEmpty ? nil : seen.joined(separator: " · ")
    }

    private func background(_ waiting: Bool) -> Color {
        if waiting { return Color.orange.opacity(hovering ? 0.16 : 0.10) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }

    private func timeLabel(_ state: SessionState) -> String {
        let d = shortDuration(model.now.timeIntervalSince(model.since(session)))
        switch state {
        case .needsInput: return "waiting \(d)"
        case .running: return d
        case .stale: return "quiet \(d)"
        default: return "\(state.verb) \(d)"
        }
    }

    /// Two short lines: what the state is about (bold), then its detail.
    @ViewBuilder
    private func subtitle(_ state: SessionState) -> some View {
        let (head, detail, mono) = lines(state)
        VStack(alignment: .leading, spacing: 1) {
            if let head {
                Text(head)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(headColor(state))
                    .lineLimit(1)
            }
            if let detail {
                Text(detail)
                    .font(mono ? .system(size: 10, design: .monospaced) : .system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func headColor(_ state: SessionState) -> Color {
        switch state {
        case .needsInput: .orange
        case .stale: .yellow
        case .idle where session.error != nil: .red
        default: .primary.opacity(0.85)
        }
    }

    private func lines(_ state: SessionState) -> (String?, String?, Bool) {
        switch state {
        case .needsInput:
            guard let p = session.primaryPending else { return ("Needs input", nil, false) }
            return (p.reason, p.detail, p.reason.hasPrefix("Permission"))
        case .running:
            if let d = nonEmpty(session.currentDetail) {
                let parts = d.components(separatedBy: " · ")
                return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil, true)
            }
            if session.isChat { return ("Responding…", nil, false) }
            return (nil, session.lastPrompt ?? session.title, false)
        case .stale:
            return ("No output for \(shortDuration(model.now.timeIntervalSince(model.since(session))))",
                    nonEmpty(session.currentDetail) ?? session.lastActivityEvent, true)
        case .idle:
            if let e = session.error { return ("Failed", e, false) }
            if session.isChat { return ("Reply ready", nil, false) }
            return (nil, session.lastMessage ?? session.title ?? session.lastPrompt, false)
        case .unknown:
            return (nil, "No hook events: started before hooks were installed?" + (session.pid.map { " · pid \($0)" } ?? ""), false)
        case .ended:
            return (nil, nil, false)
        }
    }

    private var tooltip: String {
        var parts = [session.title, session.cwd].compactMap { $0 }
        if let host = session.hostLabel { parts.append("in \(host)") }
        if let pid = session.pid { parts.append("pid \(pid)") }
        if !session.hasHooks { parts.append("(inferred, no hooks)") }
        return parts.joined(separator: "  ")
    }

    private func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
}

/// Right-click menu, shared by rows and the detail view.
struct SessionMenu: View {
    let model: AppModel
    let session: Session

    var body: some View {
        Button("Show Details") { model.detailID = session.id }
        Button("Bring to Front") { Focuser.focus(session) }
        Button("Open Folder in Finder") { Focuser.openFolder(session) }
        Divider()
        if let cmd = session.resumeCommand {
            Button("Copy Resume Command") { copy(cmd) }
        }
        Button("Copy Session ID") { copy(session.sessionId) }
        Divider()
        Button(model.isMuted(session) ? "Unmute Notifications" : "Mute Notifications") { model.toggleMute(session) }
        Button("Dismiss") { model.dismiss(session) }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Detail

struct SessionDetailView: View {
    let model: AppModel
    let session: Session
    var forSnapshot = false

    var body: some View {
        let state = model.displayState(session)
        VStack(alignment: .leading, spacing: 0) {
            header(state)
            Divider().opacity(0.5)
            if forSnapshot {
                content
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) { content }.scrollIndicators(.automatic)
            }
            Divider().opacity(0.5)
            actions
        }
        .onAppear { model.refreshContext(session) }
    }

    private func header(_ state: SessionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button { model.detailID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Back to all sessions")
                .accessibilityLabel("Back")
                StateDot(state: state, size: 9, halo: true)
                Text(session.projectName).font(.system(size: 14, weight: .bold))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let sub = session.subpath {
                    Text("› " + sub).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head).layoutPriority(-1)
                }
                AgentBadge(agent: session.agent)
                Spacer(minLength: 4)
                Text("\(state.verb) \(longDuration(model.now.timeIntervalSince(model.since(session))))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state == .idle || state == .ended ? .secondary : state.color)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(locationLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 29)
            if let prompt = session.lastPrompt ?? session.title {
                Text(prompt)
                    .font(.system(size: 11.5))
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 29)
            }
            if state == .needsInput, let p = session.primaryPending {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.reason).font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                    if let d = p.detail { Text(d).font(.system(size: 10.5, design: .monospaced)).lineLimit(3) }
                    Text("Answer it in \(session.hostLabel ?? "the agent").")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.leading, 29)
            }
        }
        .padding(12)
    }

    private var locationLine: String {
        var parts: [String] = []
        if let dir = session.root ?? session.cwd { parts.append((dir as NSString).abbreviatingWithTildeInPath) }
        if let host = session.hostLabel { parts.append(host) }
        if let pid = session.pid { parts.append("pid \(pid)") }
        if !session.hasHooks { parts.append("no hooks") }
        return parts.joined(separator: " · ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            stats
            if !session.subagents.isEmpty {
                section("Subagents") {
                    ForEach(session.sortedSubagents) { sub in
                        HStack(spacing: 7) {
                            Circle().fill(sub.running ? Color.green : Color(nsColor: .tertiaryLabelColor))
                                .frame(width: 7, height: 7)
                            Text(sub.type).font(.system(size: 11.5, weight: .semibold))
                            Spacer()
                            Text(sub.running ? longDuration(model.now.timeIntervalSince(sub.since)) : "done")
                                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !session.filesChanged.isEmpty {
                section("Files changed") {
                    ForEach(session.filesChanged.suffix(8), id: \.self) { f in
                        Text(relative(f))
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                    }
                    if session.filesChanged.count > 8 {
                        Text("and \(session.filesChanged.count - 8) more").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            section("Timeline") {
                if session.timeline.isEmpty {
                    Text(session.hasHooks ? "Nothing yet." : "No hook events for this session, so only its state is known.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                ForEach(Array(session.timeline.suffix(forSnapshot ? 8 : 30).reversed().enumerated()), id: \.offset) { _, entry in
                    TimelineRow(entry: entry)
                }
            }
        }
        .padding(12)
    }

    private var stats: some View {
        let ctx = model.context[session.id]
        return HStack(spacing: 6) {
            stat("Tool calls", "\(session.toolCalls)")
            stat("Files", "\(session.filesChanged.count)")
            stat("Waited", shortDuration(waited))
            stat("Context", ctx.map { u in u.fraction.map { "\(Int($0 * 100))%" } ?? tokens(u.tokens) } ?? "—",
                 help: ctx.map { "\($0.tokens.formatted()) tokens" + ($0.window.map { " of \($0.formatted())" } ?? "") })
        }
    }

    /// Past waits plus the one in progress.
    private var waited: TimeInterval {
        session.waitedTotal + (session.state == .needsInput ? model.now.timeIntervalSince(session.stateSince) : 0)
    }

    private func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : "\(n / 1000)k"
    }

    private func stat(_ label: String, _ value: String, help: String? = nil) -> some View {
        // Labels are one short word so four fit side by side even in a narrow panel.
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 14, weight: .bold).monospacedDigit()).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .help(help ?? "")
    }

    private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            body()
        }
    }

    private func relative(_ path: String) -> String {
        guard let cwd = session.root ?? session.cwd, path.hasPrefix(cwd + "/") else { return (path as NSString).abbreviatingWithTildeInPath }
        return String(path.dropFirst(cwd.count + 1))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Jump to \(session.hostLabel ?? "Session")") { Focuser.focus(session) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            if let cmd = session.resumeCommand {
                Button("Copy Resume Command") { copy(cmd) }
                    .controlSize(.small)
            }
            Spacer()
            Button { model.toggleMute(session) } label: {
                Image(systemName: model.isMuted(session) ? "bell.slash.fill" : "bell")
            }
            .controlSize(.small)
            .help(model.isMuted(session) ? "Unmute notifications for this session" : "Mute notifications for this session")
            .accessibilityLabel(model.isMuted(session) ? "Unmute notifications" : "Mute notifications")
        }
        .padding(.leading, 12)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
    }
}

private struct TimelineRow: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.at.formatted(date: .omitted, time: .standard))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 62, alignment: .leading)
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.kind).font(.system(size: 11, weight: .semibold))
                    if let note = entry.note {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(entry.tone == .error ? Color.red : .secondary)
                    }
                }
                if let d = entry.detail, !d.isEmpty {
                    Text(d)
                        .font(entry.tone == .prompt || entry.tone == .done ? .system(size: 10.5)
                              : .system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var color: Color {
        switch entry.tone {
        case .normal: Color(nsColor: .tertiaryLabelColor)
        case .prompt: .blue
        case .attention: .orange
        case .error: .red
        case .done: .secondary
        case .running: .green
        }
    }
}

// MARK: - Search

/// The panel's search field: type to filter, ↑↓ to move, Return or ⌘1–9 to jump, Esc to close.
struct SearchField: View {
    let model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Find a session…", text: Binding(get: { model.query }, set: { model.query = $0; model.searchSelection = 0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(jump)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { model.endSearch(); return .handled }
                .onKeyPress(characters: .decimalDigits) { press in
                    guard press.modifiers.contains(.command), let n = Int(press.characters), n >= 1,
                          n <= model.searchResults.count else { return .ignored }
                    model.searchSelection = n - 1
                    jump()
                    return .handled
                }
            Keycap(text: "esc")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear { focused = true }
    }

    private func move(_ d: Int) {
        let n = model.searchResults.count
        guard n > 0 else { return }
        model.searchSelection = max(0, min(n - 1, model.searchSelection + d))
    }

    private func jump() {
        let rows = model.searchResults
        guard !rows.isEmpty else { return }
        let s = rows[min(model.searchSelection, rows.count - 1)]
        model.endSearch()
        Focuser.focus(s)
    }
}

// MARK: - Projects

/// One small circle per session, colored by its state, for a project row.
struct SessionDots: View {
    let states: [SessionState]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(states.prefix(8).enumerated()), id: \.offset) { _, st in
                Circle().fill(st.color).frame(width: 6, height: 6)
            }
            if states.count > 8 {
                Text("+\(states.count - 8)").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .fixedSize()
        .help(summary)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        var parts: [String] = []
        let n = states.filter { $0 == .needsInput }.count, w = states.filter { $0 == .running || $0 == .stale }.count
        if n > 0 { parts.append("\(n) need\(n == 1 ? "s" : "") you") }
        if w > 0 { parts.append("\(w) working") }
        let rest = states.count - n - w
        if rest > 0 { parts.append("\(rest) idle") }
        return parts.joined(separator: " · ")
    }
}

/// A session inside an expanded project row: compact, and clicking it jumps to that session.
struct ProjectSessionRow: View {
    let model: AppModel
    var controller: PanelController? = nil
    let session: Session
    @State private var hovering = false

    var body: some View {
        let state = model.displayState(session)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                StateDot(state: state, size: 6)
                Text(label(state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(state == .needsInput ? Color.orange : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let host = session.hostLabel { SourceChip(label: host) }
                Spacer(minLength: 4)
                Text(time(state))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(state == .needsInput ? Color.orange : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let d = detail(state) {
                Text(d)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if controller?.didDrag != true { Focuser.focus(session) } }
        .contextMenu { SessionMenu(model: model, session: session) }
        .help(session.cwd ?? "")
    }

    /// What tells this session apart from its siblings: why it waits, its subfolder, title, or last prompt.
    private func label(_ state: SessionState) -> String {
        if state == .needsInput, let p = session.primaryPending { return p.reason }
        if let sub = session.subpath { return "› " + sub }
        return session.title ?? session.lastPrompt ?? session.agent.displayName
    }

    private func detail(_ state: SessionState) -> String? {
        let d: String?
        switch state {
        case .needsInput: d = session.primaryPending?.detail
        case .running, .stale: d = session.currentDetail
        default: d = session.error ?? session.lastMessage
        }
        // Paths inside the project read shorter relative to it.
        guard let root = session.root else { return d }
        return d?.replacingOccurrences(of: root + "/", with: "")
    }

    private func time(_ state: SessionState) -> String {
        let d = shortDuration(model.now.timeIntervalSince(model.since(session)))
        switch state {
        case .needsInput: return "waiting \(d)"
        case .running: return d
        default: return "\(state.verb) \(d)"
        }
    }
}
