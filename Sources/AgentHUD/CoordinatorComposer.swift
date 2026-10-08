import AgentHUDCore
import AppKit
import SwiftUI

// MARK: - Composer

/// One box for every kind of session: what you type on top; under it, where it goes and how. While a
/// managed session works, the send button becomes Stop (until you start typing, which queues or steers).
struct RichComposer: View {
    let model: CoordinatorModel
    let session: Session

    private enum Route { case managed(ManagedSession), stopped(ManagedSession), codexBridge, editor, copy }

    private var route: Route {
        if let m = model.managed(session) {
            return model.control(session).capabilities.canSend ? .managed(m) : .stopped(m)
        }
        if model.canReplyToExistingCodex(session) { return .codexBridge }
        return EditorReply.scheme(session) != nil ? .editor : .copy
    }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[session.id] ?? "" }, set: { model.drafts[session.id] = $0 })
    }
    private var empty: Bool { (model.drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var host: String { session.hostLabel ?? "its app" }
    private var sending: Bool {
        guard let receipt = model.editorSends[session.id], !receipt.delivered, let status = receipt.bridgeStatus else { return false }
        return status != .failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if case .stopped(let m) = route {
                stopped(m)
            } else {
                box
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            if let n = model.notice {
                Text(n).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).padding(.leading, 4)
            }
            if case .codexBridge = route, model.codexOwners[session.id] == nil {
                Button("Retry Connection") { model.probeCodexBridge(force: true) }
                    .buttonStyle(.link).font(.system(size: 11)).padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...10)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .onSubmit(send)
            HStack(spacing: 6) {
                targetChip
                if case .managed(let m) = route, m.agent == .claude { modeChip(m) }
                if case .managed(let m) = route, let model = m.model { Chip(text: shortModel(model), symbol: "cpu") }
                if case .editor = route {
                    Toggle(isOn: Binding(get: { model.app.settings.editorAutoSend }, set: { model.setEditorAutoSend($0) })) {
                        Text("Press Return for me").font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Needs Accessibility. Agent HUD presses Return only in \(host), and only when it's in front.")
                }
                Button { attachFile() } label: { Image(systemName: "at") }
                    .buttonStyle(.borderless)
                    .help("Mention a file")
                moreMenu
                Spacer(minLength: 4)
                primaryButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 7)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.13)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private var placeholder: String {
        switch route {
        case .managed, .stopped: "Message \(session.projectName)…"
        case .codexBridge: "Reply to this Codex chat…"
        case .editor: "Draft a reply for \(host)…"
        case .copy: "Draft a reply…"
        }
    }

    private var hint: String {
        switch route {
        case .codexBridge:
            if model.codexOwners[session.id] != nil {
                return "Return sends to this existing chat · while working, your reply joins the running turn"
            }
            return model.codexBridgeErrors[session.id] ?? "Checking the connection to this existing Codex chat…"
        case .managed(let m):
            if m.status == .busy || m.status == .waiting {
                return m.capabilities.steerActiveTurn ? "Working · what you send now joins the running turn · ⌘. stops it"
                    : "Working · what you send now runs as the next turn · ⌘. stops it"
            }
            return "Return sends · ⌥Return adds a line"
        case .editor:
            return "Best-effort editor handoff · confirm delivery in the conversation · use Continue a Copy Here for broker execution"
        case .copy:
            return "\(host) can't take messages from here: Send copies your reply and brings \(host) forward"
        case .stopped:
            return ""
        }
    }

    private var targetChip: some View {
        switch route {
        case .managed: Chip(text: "Coordinator", symbol: "bubble.left.and.bubble.right", tint: .accentColor)
        case .codexBridge: Chip(text: "This Codex chat", symbol: "link", tint: model.codexOwners[session.id] != nil ? .accentColor : .secondary)
        case .editor: Chip(text: host, symbol: "arrow.up.forward.app", tint: .accentColor)
        case .copy: Chip(text: "Copy & open \(host)", symbol: "doc.on.clipboard")
        case .stopped: Chip(text: "Stopped", symbol: "pause.circle")
        }
    }

    private func modeChip(_ m: ManagedSession) -> some View {
        let current = m.permissionMode ?? "default"
        return Menu {
            ForEach(claudeModes, id: \.0) { mode in
                Button { model.setMode(session, mode.0) } label: {
                    if current == mode.0 { Label(mode.1, systemImage: "checkmark") } else { Text(mode.1) }
                }
            }
        } label: {
            Chip(text: claudeModes.first { $0.0 == current }?.1 ?? "Permissions", symbol: "lock.shield")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How this session handles permission prompts")
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy Conversation") { copy(model.conversationText(session)) }
            Divider()
            if let how = model.takeover(session) {
                Button(how == .move ? "Move Here…" : "Continue a Copy Here…") { model.continueHere(session) }
            }
            if case .managed(let m) = route {
                Button("Stop Session") { model.stopSession(session) }
                Button("Copy Session ID") { copy(m.sessionId ?? m.id) }
            } else {
                if case .codexBridge = route {
                    Button("Copy Reply & Open \(host)") { model.copyAndOpen(session) }
                }
                Button("Show in \(host)") { Focuser.focus(session) }
                if let cmd = session.resumeCommand { Button("Copy Resume Command") { copy(cmd) } }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var primaryButton: some View {
        if case .managed(let m) = route, m.status == .busy || m.status == .waiting, empty {
            Button { model.interrupt(session) } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop the current turn (⌘.)")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    .foregroundStyle(empty ? Color.secondary.opacity(0.5) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(empty || sending)
            .help(sendHelp)
        }
    }

    private var sendHelp: String {
        switch route {
        case .managed: "Send (Return)"
        case .codexBridge: "Send to this exact existing Codex conversation (Return)"
        case .editor: "Send to \(host) (Return)"
        case .copy: "Copy and open \(host)"
        case .stopped: ""
        }
    }

    private func send() {
        switch route {
        case .managed: model.send(session)
        case .codexBridge: model.sendToExistingCodex(session)
        case .editor: model.sendToEditor(session)
        case .copy: model.copyAndOpen(session)
        case .stopped: break
        }
    }

    @ViewBuilder private func stopped(_ m: ManagedSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                .foregroundStyle(m.status == .failed ? Color.red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(!model.broker.connected ? "Broker disconnected. Your task and draft are saved." : m.status == .failed ? "This session stopped with an error." : "This session isn't running.")
                    .font(.system(size: 12.5))
                if let e = m.error { Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            }
            Spacer()
            if !model.broker.connected { Button("Reconnect") { model.broker.connect { _ in } } }
            else if m.sessionId != nil { Button("Resume") { model.resume(session) }.keyboardShortcut(.defaultAction) }
            else { Button("Start Again") { model.newSessionFor = m.cwd; model.showingNewSession = true } }
            Button("Close") { model.broker.forget(m.id) }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Inserts `@path` (relative to the session's folder) for a file you pick.
    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let dir = session.cwd ?? session.root { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK else { return }
        let base = (session.cwd ?? session.root ?? "") + "/"
        let refs = panel.urls.map { url -> String in
            let p = url.path
            return "@" + (p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p)
        }
        let current = model.drafts[session.id] ?? ""
        model.drafts[session.id] = current + (current.isEmpty || current.hasSuffix(" ") ? "" : " ") + refs.joined(separator: " ") + " "
    }

    private func shortModel(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}

/// A small rounded label in the composer's bottom row.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.11)))
    }
}

// MARK: - Pinned prompt

/// Whatever this session is waiting on, pinned above the composer so scrolling never hides it.
/// Managed prompts answer here: ⌘Y allows, ⌥⌘Y allows for the session, ⌘N denies.
struct PinnedPrompt: View {
    let model: CoordinatorModel
    let session: Session

    var body: some View {
        let m = model.managed(session)
        Group {
            if let m, let p = m.pending.first {
                PendingCard(request: p, position: m.pending.count > 1 ? "1 of \(m.pending.count)" : nil, shortcuts: true) { decision, answers in
                    model.answer(session, p, decision: decision, answers: answers)
                }
            } else if m == nil, model.displayState(session) == .needsInput, let p = session.primaryPending {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(p.reason, systemImage: "hand.raised.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                        Spacer()
                        Text("waiting \(shortDuration(model.app.now.timeIntervalSince(p.since)))")
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let d = p.detail { CodeBox(text: d) }
                    HStack {
                        Text("This prompt can only be answered in \(session.hostLabel ?? "its app").").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Answer in \(session.hostLabel ?? "Its App")") { Focuser.focus(session) }
                            .keyboardShortcut("y", modifiers: .command)
                    }
                    .controlSize(.small)
                }
                .padding(11)
                .background(PromptBackground())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
    }
}

struct PromptBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.orange.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.45)))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// A prompt from a session the Coordinator runs: approve or deny it, or answer its questions.
struct PendingCard: View {
    let request: PendingRequest
    var position: String? = nil
    /// Bind ⌘Y / ⌥⌘Y / ⌘N (only one card on screen should).
    var shortcuts = false
    let answer: (_ decision: String, _ answers: [String: [String]]?) -> Void
    @State private var picks: [String: Set<String>] = [:]
    @State private var freeAnswers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(request.kind == .question ? "Question" : request.tool, systemImage: request.kind == .question ? "questionmark.bubble.fill" : "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                if let position { Text(position).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Spacer()
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text("waiting \(shortDuration(ctx.date.timeIntervalSince(request.since)))")
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if request.kind == .question { questions } else { permission }
        }
        .padding(11)
        .background(PromptBackground())
    }

    @ViewBuilder private var permission: some View {
        Text(request.summary).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
        if let d = request.detail, d != request.summary { CodeBox(text: d) }
        HStack(spacing: 6) {
            button("Allow", key: "y", mods: .command, decision: "allow", primary: true)
            button("Allow for Session", key: "y", mods: [.command, .option], decision: "allowSession")
            button("Deny", key: "n", mods: .command, decision: "deny")
            Spacer()
            if shortcuts { Text("⌘Y · ⌥⌘Y · ⌘N").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func button(_ title: String, key: Character, mods: EventModifiers, decision: String, primary: Bool = false) -> some View {
        let b = Button(title) { answer(decision, nil) }
        if shortcuts {
            if primary { b.keyboardShortcut(KeyEquivalent(key), modifiers: mods).buttonStyle(.borderedProminent) }
            else { b.keyboardShortcut(KeyEquivalent(key), modifiers: mods) }
        } else if primary {
            b.buttonStyle(.borderedProminent)
        } else {
            b
        }
    }

    @ViewBuilder private var questions: some View {
        ForEach(request.questions, id: \.id) { q in
            VStack(alignment: .leading, spacing: 5) {
                if let h = q.header { Text(h.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary) }
                Text(q.question).font(.system(size: 12.5))
                OptionList(options: q.options, selected: picks[q.id] ?? []) { option in pick(q, option) }
                TextField("Your answer", text: Binding(get: { freeAnswers[q.id] ?? "" }, set: { freeAnswers[q.id] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
        }
        if !request.questions.isEmpty {
            HStack {
                Button("Answer") { submit() }.buttonStyle(.borderedProminent)
                    .disabled(request.questions.contains { (picks[$0.id] ?? []).isEmpty && (freeAnswers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                Button("Skip") { answer("deny", nil) }
            }
            .controlSize(.small)
        }
    }

    private func pick(_ q: PendingQuestion, _ option: String) {
        var set = picks[q.id] ?? []
        if q.multiSelect { if set.contains(option) { set.remove(option) } else { set.insert(option) } } else { set = [option] }
        picks[q.id] = set
        if request.questions.count == 1 && !q.multiSelect { submit() }
    }

    private func submit() {
        var out: [String: [String]] = [:]
        for q in request.questions {
            let free = (freeAnswers[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out[q.id] = free.isEmpty ? q.options.filter { (picks[q.id] ?? []).contains($0) } : [free]
        }
        answer("allow", out)
    }
}

private struct OptionList: View {
    let options: [String]
    let selected: Set<String>
    let tap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { o in
                Button { tap(o) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: selected.contains(o) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(o) ? Color.accentColor : .secondary)
                        Text(o).multilineTextAlignment(.leading)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected.contains(o) ? 0.07 : 0.03)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
