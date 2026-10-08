import AgentHUDCore
import AppKit
import SwiftUI

/// The Coordinator window, Mail-style: a sidebar of projects (as folders) and pairs running up under the
/// traffic lights, the selected conversation in the middle, live activity (or the pair's timeline) on the right.
struct CoordinatorView: View {
    @Bindable var model: CoordinatorModel
    /// Back to the session list (the Coordinator lives in the panel).
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            CoordinatorSidebar(model: model, onBack: onBack)
                .frame(width: 252)
            Divider()
            middle
                .frame(minWidth: 440, maxWidth: .infinity)
            Divider()
            right
                .frame(width: 270)
        }
        .frame(minWidth: 900, minHeight: 500)
        // Overlays rather than sheets: the panel is borderless and never activates the app.
        .overlay {
            if model.showingNewSession {
                Modal { model.showingNewSession = false } content: { NewSessionSheet(model: model) }
            } else if model.showingNewPair {
                Modal { model.showingNewPair = false } content: { NewPairSheet(model: model) }
            } else if model.showingApprovals {
                Modal { model.showingApprovals = false } content: { ApprovalsSheet(model: model) }
            }
        }
    }

    @ViewBuilder private var middle: some View {
        if let p = model.pair { PairChat(model: model, pair: p) } else { CoordinatorChat(model: model) }
    }

    @ViewBuilder private var right: some View {
        if let p = model.pair { PairColumn(model: model, pair: p) } else { ActivityColumn(model: model) }
    }
}

/// A dialog over the Coordinator: dims it, and Escape or a click outside closes it.
struct Modal<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            content
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                .onExitCommand(perform: close)
        }
        .transition(.opacity)
    }
}

extension CoordinatorModel {
    func pairSessions(_ p: PairState) -> [ManagedSession] {
        p.sessions.values.compactMap { broker.sessions[$0] }
    }
}

/// The strip across the top of a pane, level with the traffic lights.
struct PaneHeader<Content: View>: View {
    @Environment(\.panelController) private var panelController
    var leadingInset: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.leading, leadingInset)
            .padding(.trailing, 12)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in panelController?.dragChanged() }
                    .onEnded { _ in panelController?.dragEnded() }
            )
    }
}

// MARK: - Sidebar

private struct CoordinatorSidebar: View {
    @Bindable var model: CoordinatorModel
    var onBack: (() -> Void)?

    private var selection: Binding<String?> {
        Binding(get: { model.selectedPairID.map { "pair:" + $0 } ?? model.selectedSessionID },
                set: { id in
                    guard let id else { return }
                    if id.hasPrefix("pair:") { model.select(pair: String(id.dropFirst(5))) } else { model.select(session: id) }
                })
    }

    var body: some View {
        let folders = model.folders, pairs = model.pairList, approvals = model.approvals.count
        VStack(spacing: 0) {
            PaneHeader(leadingInset: 12) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Back to sessions")
                    .accessibilityLabel("Back to sessions")
                }
                Text("Coordinator").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.showingApprovals = true } label: {
                    Image(systemName: "tray.full")
                        .overlay(alignment: .topTrailing) {
                            if approvals > 0 {
                                Text("\(approvals)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                                    .background(Capsule().fill(Color.orange)).offset(x: 9, y: -7)
                            }
                        }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Approvals: everything waiting on you (⇧⌘A)")
                Menu {
                    Button("New Session…") { model.newSessionFor = model.selectedRoot; model.showingNewSession = true }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("New Pair…") { model.showingNewPair = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                } label: { Image(systemName: "square.and.pencil") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session or pair")
            }
            TextField("Filter", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if let e = model.broker.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Reconnect broker") { model.broker.connect { _ in } }.controlSize(.small)
                }.padding(.horizontal, 12).padding(.bottom, 4)
            }
            List(selection: selection) {
                if !pairs.isEmpty {
                    Section("Pairs") {
                        ForEach(pairs) { p in PairLeaf(model: model, pair: p).tag("pair:" + p.id) }
                    }
                }
                Section("Open in VS Code") {
                    ForEach(model.editorProjects, id: \.root) { p in
                        Button {
                            model.select(project: p.root)
                            model.newSessionFor = p.root
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(p.name, systemImage: "macwindow").font(.system(size: 12, weight: .semibold))
                                Text("Connected · \(model.live.filter { $0.projectKey == p.root }.count) agents").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    if model.editorProjects.isEmpty {
                        Text("Install Agent HUD Workspace Bridge in VS Code to discover open folders.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Agent sessions") {
                    ForEach(folders) { f in
                        DisclosureGroup(isExpanded: Binding(get: { model.isOpen(f) }, set: { model.folderOpen[f.id] = $0 })) {
                            ForEach(f.sessions) { s in SessionLeaf(model: model, session: s).tag(s.id) }
                        } label: {
                            FolderLabel(model: model, folder: f)
                        }
                    }
                    if folders.isEmpty {
                        Text(model.filter.isEmpty ? "No sessions yet. Start one with ⌘N." : "Nothing matches.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(VisualEffect(material: .sidebar))
    }
}

/// AppKit's sidebar material, which SwiftUI's own materials don't match exactly.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

private struct FolderLabel: View {
    let model: CoordinatorModel
    let folder: CoordinatorModel.Folder

    var body: some View {
        let waiting = folder.sessions.filter { model.displayState($0) == .needsInput }.count
        HStack(spacing: 7) {
            StateDot(state: folder.state, halo: folder.state == .needsInput)
            Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if folder.sessions.count > 1 { SessionDots(states: folder.sessions.map(model.displayState)) }
            if waiting > 0 {
                Text("\(waiting)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(minHeight: 15).background(Capsule().fill(Color.orange))
            } else {
                Text("\(folder.sessions.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking a project opens it on its most urgent session.
            model.folderOpen[folder.id] = true
            model.select(session: folder.sessions.first?.id)
        }
    }
}

private struct SessionLeaf: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        let state = model.displayState(session)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StateDot(state: state, size: 7)
                    .overlay { if model.app.isJustFinished(session) && state == .idle { Circle().fill(Color.accentColor).frame(width: 7, height: 7) } }
                Text(model.sessionLabel(session)).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(timeLabel(state)).font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(state == .needsInput ? Color.orange : .secondary)
            }
            HStack(spacing: 4) {
                AgentBadge(agent: session.agent)
                if let host = session.hostLabel { SourceChip(label: host) }
                if let line = activity(state) {
                    Text(line).font(.system(size: 10.5)).foregroundStyle(state == .needsInput ? Color.orange : .secondary).lineLimit(1)
                }
            }
            .padding(.leading, 13)
        }
        .padding(.vertical, 2)
    }

    private func timeLabel(_ state: SessionState) -> String {
        model.statusLabel(session)
    }

    private func activity(_ state: SessionState) -> String? {
        if state == .needsInput {
            if let p = model.managed(session)?.pending.first { return p.tool + ": " + p.summary }
            return session.primaryPending?.reason
        }
        if state == .running || state == .stale { return AppModel.activity(session.currentDetail) }
        return nil
    }
}

private struct PairLeaf: View {
    let model: CoordinatorModel
    let pair: PairState

    var body: some View {
        let waiting = pair.status == .waitingOnYou || model.pairSessions(pair).contains { !$0.pending.isEmpty }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(pairColor(pair, waiting: waiting))
                Text(pair.slug).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(pair.status == .done ? "done" : pair.phase.label.lowercased())
                    .font(.system(size: 10.5)).foregroundStyle(waiting ? Color.orange : .secondary)
            }
            HStack(spacing: 4) {
                AgentBadge(agent: pair.config.builder)
                if pair.config.reviewer != pair.config.builder { AgentBadge(agent: pair.config.reviewer) }
                Text(line).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 15)
        }
        .padding(.vertical, 2)
    }

    private var line: String {
        let p = pair
        if let r = p.reason, p.status != .running { return r }
        if p.status == .done { return "\(p.round) round\(p.round == 1 ? "" : "s") · approved" }
        return (p.agent(for: p.phase)?.displayName ?? "") + (p.round > 0 ? " · round \(p.round)" : "")
    }
}

func pairColor(_ p: PairState, waiting: Bool) -> Color {
    if waiting { return .orange }
    switch p.status {
    case .running: return .green
    case .done: return .accentColor
    case .failed: return .red
    default: return Color(nsColor: .tertiaryLabelColor)
    }
}

// MARK: - Session chat

private struct CoordinatorChat: View {
    let model: CoordinatorModel

    var body: some View {
        if let s = model.session {
            VStack(spacing: 0) {
                ChatHeader(model: model, session: s)
                Divider()
                ChatMessages(model: model, session: s)
                PinnedPrompt(model: model, session: s)
                RichComposer(model: model, session: s)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(model.selectedRoot.map { ($0 as NSString).lastPathComponent } ?? "Select a project").font(.title3.weight(.semibold))
                Text("Select an open VS Code project, assign a task, then follow its progress and answer requests here.").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                if let root = model.selectedRoot { Text(root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button("Assign Work") { model.newSessionFor = model.selectedRoot; model.showingNewSession = true }.buttonStyle(.borderedProminent)
                    Button("New Pair") { model.showingNewPair = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

let claudeModes: [(String, String)] = [("default", "Ask before edits"), ("acceptEdits", "Accept edits"),
                                       ("plan", "Plan only"), ("auto", "Auto"), ("bypassPermissions", "Bypass permissions")]

private struct ChatHeader: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        PaneHeader {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.sessionLabel(session)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.projectName + (session.subpath.map { " › " + $0 } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    AgentBadge(agent: session.agent)
                    if let host = session.hostLabel { SourceChip(label: host) }
                    Text(model.statusLabel(session)).font(.system(size: 11)).foregroundStyle(model.statusLabel(session) == "Failed" ? Color.red : .secondary)
                }
            }
            Spacer(minLength: 8)
            if EditorWorkspace.best(in: model.broker.editors, for: session.launchDir ?? session.cwd ?? "") != nil {
                Menu("VS Code") {
                    Button("Show Tasks") { model.openEditor(session) }
                    Button("Review Changes") { model.openEditor(session, action: "review") }
                    if model.managed(session) != nil { Button("Open Result") { model.openEditor(session, action: "result") } }
                }.menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
            if let f = model.app.contextFraction(session) {
                ContextGauge(fraction: f, tokens: model.app.context[session.id]?.tokens, window: model.app.contextWindow(session))
            }
        }
    }
}

/// Consecutive tool calls collapse into one block, so a long turn reads as messages, not a log.
private enum ChatRow: Identifiable {
    case message(ChatItem)
    case tools([ChatItem])

    var id: String {
        switch self {
        case .message(let i): i.id
        case .tools(let t): "tools:" + (t.first?.id ?? "")
        }
    }

    static func rows(_ items: [ChatItem]) -> [ChatRow] {
        var rows: [ChatRow] = []
        for item in items {
            if item.kind == .tool, case .tools(var t)? = rows.last {
                t.append(item)
                rows[rows.count - 1] = .tools(t)
            } else if item.kind == .tool {
                rows.append(.tools([item]))
            } else {
                rows.append(.message(item))
            }
        }
        return rows
    }
}

private struct ChatMessages: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        let rows = ChatRow.rows(model.items)
        let state = model.displayState(session)
        let m = model.managed(session)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.truncated {
                        Text("Earlier messages aren't shown.").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    if session.transcriptPath == nil && m?.transcriptPath == nil {
                        Text(m?.status == .starting ? "Starting…" : "No transcript available yet. Confirmed progress and results appear below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .message(let item): MessageView(item: item, agent: session.agent)
                        case .tools(let tools): ToolBlock(tools: tools)
                        }
                    }
                    if let m {
                        ForEach(m.outbox.filter { $0.state != .observed }) { o in PendingMessage(message: o) }
                    }
                    if let send = model.editorSends[session.id] { EditorSendView(model: model, session: session, send: send) }
                    StatusFooter(model: model, session: session, state: state)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.id) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: state) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: m?.outbox.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private func bubbleShape() -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16)
}

/// A message sent from the Coordinator that the agent hasn't picked up yet, with its delivery state.
private struct PendingMessage: View {
    let message: OutboxMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Spacer(minLength: 80)
                Text(message.text).font(.system(size: 13))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.opacity(message.state == .failed ? 0.35 : 0.6), in: bubbleShape())
            }
            Text(label).font(.caption2).foregroundStyle(message.state == .failed ? Color.red : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var label: String {
        switch message.state {
        case .queued: return "Sending…"
        case .forwarded: return message.steer ? "Added to the running turn" : "Delivered · runs when the current turn ends"
        case .observed: return "Received"
        case .failed: return "Not sent: " + (message.error ?? "unknown error")
        }
    }
}

/// A reply sent to an existing conversation, until its transcript confirms receipt.
private struct EditorSendView: View {
    let model: CoordinatorModel
    let session: Session
    let send: CoordinatorModel.EditorSend

    var body: some View {
        let host = session.hostLabel ?? "the editor"
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Spacer(minLength: 80)
                Text(send.text).font(.system(size: 13))
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.opacity(send.delivered ? 1 : 0.6), in: bubbleShape())
            }
            HStack(spacing: 8) {
                Text(status(host))
                    .font(.caption2).foregroundStyle(.secondary)
                if !send.delivered {
                    if send.bridgeStatus == .uncertain {
                        Button("Check Delivery") { model.refresh() }.buttonStyle(.link).font(.caption2)
                    }
                    Button("Show \(host)") { Focuser.focus(session) }.buttonStyle(.link).font(.caption2)
                    if send.bridgeStatus != .sending {
                        Button("Dismiss") { model.clearEditorSend(session) }.buttonStyle(.link).font(.caption2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func status(_ host: String) -> String {
        if send.delivered { return "Delivered" }
        if let status = send.bridgeStatus {
            switch status {
            case .sending: return "Sending to this existing Codex chat…"
            case .sent: return "Codex accepted your reply · waiting for transcript confirmation"
            case .steered: return "Added to the running Codex turn · waiting for transcript confirmation"
            case .queued: return "Queued in this existing Codex chat · runs when its current turn ends"
            case .failed: return "Not sent: " + (send.error ?? "Reconnect to Codex and try again.")
            case .uncertain: return "Delivery uncertain: " + (send.error ?? "Check this conversation before resending.")
            }
        }
        switch send.outcome {
        case nil: return "Opening the conversation in \(host)…"
        case .sent?: return "Sent in \(host) · waiting for Claude to pick it up"
        case .typed?: return "Typed into \(host) · press Return there to send"
        case .clipboard?:
            return EditorReply.canPressReturn
                ? "It was already open in \(host), so it couldn't be typed in · it's on your clipboard: ⌘V, Return"
                : "If \(host) says the session is already open, your reply is on the clipboard: ⌘V, Return · allow Accessibility to skip this"
        }
    }
}

struct MessageView: View {
    let item: ChatItem
    let agent: AgentKind
    private static let maxChars = 8000

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(clipped).font(.system(size: 13)).textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: bubbleShape())
                    .copyable(item.text)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 9) {
                AgentAvatar(agent: agent)
                MarkdownText(text: clipped)
            }
            .copyable(item.text)
        case .interrupted:
            Label("Interrupted", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 31)
        case .tool:
            EmptyView()
        }
    }

    private var clipped: String {
        item.text.count > Self.maxChars ? String(item.text.prefix(Self.maxChars)) + "…" : item.text
    }
}

extension View {
    /// Right-click → Copy for a message (the whole text, even past what's shown).
    func copyable(_ text: String) -> some View {
        contextMenu {
            Button("Copy") { copy(text) }
        }
    }
}

/// A small round mark in the agent's colour, beside its messages.
struct AgentAvatar: View {
    let agent: AgentKind

    var body: some View {
        Text(agent == .codex ? "Cx" : "C")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(agent.tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(agent.tint.opacity(0.16)))
    }
}

/// Inline Markdown for prose, with fenced code blocks set apart in monospace.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                            .padding(8)
                    }
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(Self.attributed(block.text))
                        .font(.system(size: 13)).lineSpacing(2.5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Splits on ``` fences; an unclosed fence runs to the end.
    static func blocks(_ text: String) -> [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var current: [Substring] = [], inCode = false
        func flush() {
            let t = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append((inCode, t)) }
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }
}

/// A run of tool calls: one summary line, expandable to the calls themselves.
private struct ToolBlock: View {
    let tools: [ChatItem]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(summary).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded || tools.count <= 2 {
                ForEach(tools) { t in
                    HStack(spacing: 6) {
                        Text(t.text).font(.system(size: 11, weight: .semibold))
                        if let d = t.detail {
                            Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.leading, 13)
                }
            }
        }
        .padding(.leading, 31)
    }

    /// "Read 3 files, edited 2, ran 4 commands"
    private var summary: String {
        var counts: [(String, Int)] = []
        func add(_ k: String) { if let i = counts.firstIndex(where: { $0.0 == k }) { counts[i].1 += 1 } else { counts.append((k, 1)) } }
        for t in tools {
            switch t.text {
            case "Read", "NotebookRead": add("read")
            case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": add("edited")
            case "Bash", "Shell", "shell", "exec_command", "exec": add("ran")
            case "Grep", "Glob", "WebSearch": add("searched")
            default: add("used")
            }
        }
        return counts.map { k, n in
            switch k {
            case "read": "read \(n) file\(n == 1 ? "" : "s")"
            case "edited": "edited \(n) file\(n == 1 ? "" : "s")"
            case "ran": "ran \(n) command\(n == 1 ? "" : "s")"
            case "searched": "searched \(n)×"
            default: "\(n) other tool\(n == 1 ? "" : "s")"
            }
        }.joined(separator: ", ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// What the session is doing now: working, or the report of the turn it just finished. Prompts are pinned
/// above the composer instead (PinnedPrompt).
private struct StatusFooter: View {
    let model: CoordinatorModel
    let session: Session
    let state: SessionState

    var body: some View {
        let m = model.managed(session)
        if let m, !model.broker.connected {
            Text("Disconnected · last confirmed state: " + m.coordinationStatus().label).font(.callout).foregroundStyle(.orange)
        } else if let m, m.status == .idle, m.turns > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label(m.coordinationStatus().label, systemImage: m.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(m.error == nil ? Color.green : .red)
                if let error = m.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let reply = m.lastReply, model.items.isEmpty { Text(reply).font(.callout).textSelection(.enabled) }
                HStack {
                    Button("Review in VS Code") { model.openEditor(session, action: "review") }
                    Text("Send a follow-up below to continue.").font(.caption).foregroundStyle(.secondary)
                }.controlSize(.small)
            }.padding(11).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        } else { switch state {
        case .running, .stale:
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Working · \(longDuration(model.app.now.timeIntervalSince(session.turnStartedAt ?? session.stateSince)))"
                     + (session.currentDetail.map { " · " + $0 } ?? ""))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 31)
        case .idle:
            if let took = session.lastTurnDuration, m == nil || m?.status == .idle {
                ReportCard(session: session, took: took).padding(.leading, 31)
            } else if let m, let e = m.error {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.leading, 31)
            }
        default:
            EmptyView()
        } }
    }
}

struct CodeBox: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .fixedSize(horizontal: false, vertical: true)
        .padding(7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ReportCard: View {
    let session: Session
    let took: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: session.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(session.error == nil ? Color.green : Color.red)
                Text(session.error == nil ? "Turn finished" : "Turn ended with an error").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(longDuration(took)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            if !session.turnFiles.isEmpty { row("Edited", files, mono: true) }
            if let t = session.turnTest {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Tests").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                    Text((t.passed ? "passed · " : "failed · ") + t.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(t.passed ? Color.green : Color.red).lineLimit(1)
                }
            }
            if session.turnCommands > 0 { row("Ran", "\(session.turnCommands) command\(session.turnCommands == 1 ? "" : "s")") }
            if let e = session.error { Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var files: String {
        session.turnFiles.prefix(6).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            + (session.turnFiles.count > 6 ? " and \(session.turnFiles.count - 6) more" : "")
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(value).font(.system(size: 11, design: mono ? .monospaced : .default))
        }
    }
}

// MARK: - Activity column

private struct ActivityColumn: View {
    let model: CoordinatorModel

    var body: some View {
        let running = model.running, finished = model.finishedToday
        let today = model.app.today()
        VStack(spacing: 0) {
            PaneHeader {
                Text("Activity").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(running.count) running").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "Running now", count: running.count)
                    if running.isEmpty {
                        Text("Nothing running.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    ForEach(running) { s in RunCard(model: model, session: s) }
                    if !finished.isEmpty {
                        SectionLabel(title: "Finished today", count: finished.count)
                        ForEach(finished) { s in FinishedRow(model: model, session: s) }
                    }
                }
                .padding(12)
            }
            Divider()
            Text("\(shortDuration(today.working)) agent time today · \(shortDuration(today.waiting)) waiting on you")
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SectionLabel: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if let count { Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
}

private struct RunCard: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        let state = model.displayState(session)
        let m = model.managed(session)
        let selected = model.selectedSessionID == session.id
        Button {
            if let pid = m?.pairID { model.select(pair: pid) } else { model.select(session: session.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    StateDot(state: state, halo: true)
                    Text(session.projectName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(shortDuration(model.app.now.timeIntervalSince(model.app.since(session))))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    AgentBadge(agent: session.agent)
                    SourceChip(label: m?.pairID != nil ? "Pair" : session.hostLabel ?? "?")
                    Spacer(minLength: 4)
                    if let f = model.app.contextFraction(session) {
                        ContextGauge(fraction: f, tokens: model.app.context[session.id]?.tokens, window: model.app.contextWindow(session))
                    }
                }
                Text(activity(state, m))
                    .font(.system(size: 10.5, design: state == .needsInput ? .default : .monospaced))
                    .foregroundStyle(state == .needsInput ? Color.orange : .secondary)
                    .lineLimit(1)
                ForEach(session.sortedSubagents.filter(\.running).prefix(3)) { sub in SubagentLine(model: model, sub: sub) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activity(_ state: SessionState, _ m: ManagedSession?) -> String {
        if state == .needsInput {
            if let p = m?.pending.first { return "Waiting on you · \(p.tool): \(p.summary)" }
            return "Waiting on you · " + (session.primaryPending?.reason ?? "")
        }
        return AppModel.activity(session.currentDetail)
    }
}

private struct SubagentLine: View {
    let model: CoordinatorModel
    let sub: Subagent

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(.tertiary)
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(sub.type).font(.system(size: 10.5))
            Spacer()
            Text(shortDuration(model.app.now.timeIntervalSince(sub.since)))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }
}

private struct FinishedRow: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        Button { model.select(session: session.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    Text(session.projectName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.stateSince.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(session.turnSummary ?? "Took \(shortDuration(session.lastTurnDuration ?? 0))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 14)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
