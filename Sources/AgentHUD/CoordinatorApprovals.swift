import AgentHUDCore
import SwiftUI

/// Everything waiting on you, across sessions and pairs, oldest first. J/K moves; the selected prompt answers
/// with ⌘Y / ⌥⌘Y / ⌘N, and shows the conversation leading up to it so nothing is approved blind.
struct ApprovalsSheet: View {
    let model: CoordinatorModel
    private func dismiss() { model.showingApprovals = false }
    @State private var selected: String?
    @State private var context: [ChatItem] = []
    @State private var contextFor: String?

    var body: some View {
        let items = model.approvals
        let current = items.first { $0.id == selected } ?? items.first
        VStack(spacing: 0) {
            HStack {
                Text("Approvals").font(.system(size: 15, weight: .bold))
                Text("\(items.count) waiting").foregroundStyle(.secondary)
                Spacer()
                Text("J / K to move").font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.green)
                    Text("Nothing is waiting on you.").font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { current?.id }, set: { selected = $0 })) {
                        ForEach(items) { a in ApprovalRow(model: model, approval: a).tag(a.id) }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 270)
                    Divider()
                    if let a = current {
                        detail(a)
                            .id(a.id)
                            .onAppear { load(a) }
                            .onChange(of: a.id) { load(a) }
                    }
                }
            }
        }
        .frame(width: 860, height: 560)
        .background {
            // J / K without a text field to type into.
            Group {
                Button("") { move(items, by: 1) }.keyboardShortcut("j", modifiers: [])
                Button("") { move(items, by: -1) }.keyboardShortcut("k", modifiers: [])
            }
            .opacity(0)
        }
    }

    private func move(_ items: [CoordinatorModel.Approval], by step: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selected } ?? 0
        selected = items[max(0, min(items.count - 1, i + step))].id
    }

    private func load(_ a: CoordinatorModel.Approval) {
        guard contextFor != a.session.id else { return }
        contextFor = a.session.id
        context = []
        model.context(for: a.session) { items in
            if contextFor == a.session.id { context = items }
        }
    }

    @ViewBuilder private func detail(_ a: CoordinatorModel.Approval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(a.session.projectName).font(.system(size: 13, weight: .semibold))
                AgentBadge(agent: a.session.agent)
                if let host = a.session.hostLabel { SourceChip(label: a.pairID != nil ? "Pair" : host) }
                Text(model.sessionLabel(a.session)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Open") { open(a) }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if context.isEmpty {
                            Text("Loading the conversation…").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(context) { item in MessageView(item: item, agent: a.session.agent) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: context.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            Group {
                if let r = a.request {
                    PendingCard(request: r, shortcuts: true) { decision, answers in model.answer(a, decision: decision, answers: answers) }
                } else if let pid = a.pairID, let p = model.broker.pairs[pid] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(p.reason ?? "The pair is waiting for you.").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.orange)
                        HStack {
                            if p.phase == .approvePlan {
                                Button("Approve Plan") { model.pairAction(p, "approvePlan") }
                                    .buttonStyle(.borderedProminent).keyboardShortcut("y", modifiers: .command)
                            } else {
                                Button("Try Again") { model.pairAction(p, "resume") }.keyboardShortcut("y", modifiers: .command)
                            }
                            Button("Open Pair") { open(a) }
                        }
                        .controlSize(.small)
                    }
                    .padding(11)
                    .background(PromptBackground())
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(a.reason).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.orange)
                        if let d = a.session.primaryPending?.detail { CodeBox(text: d) }
                        HStack {
                            Text("It runs in \(a.session.hostLabel ?? "another app"), so it's answered there.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Answer in \(a.session.hostLabel ?? "Its App")") { Focuser.focus(a.session) }
                                .keyboardShortcut("y", modifiers: .command)
                        }
                        .controlSize(.small)
                    }
                    .padding(11)
                    .background(PromptBackground())
                }
            }
            .padding(14)
        }
    }

    private func open(_ a: CoordinatorModel.Approval) {
        if let pid = a.pairID { model.select(pair: pid) } else { model.select(session: a.session.id) }
        dismiss()
    }
}

private struct ApprovalRow: View {
    let model: CoordinatorModel
    let approval: CoordinatorModel.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StateDot(state: .needsInput, size: 7)
                Text(approval.session.projectName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                AgentBadge(agent: approval.session.agent)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 10)) { ctx in
                    Text(shortDuration(ctx.date.timeIntervalSince(approval.since))).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(line).font(.system(size: 11, design: approval.request?.kind == .permission ? .monospaced : .default))
                .foregroundStyle(.secondary).lineLimit(2)
                .padding(.leading, 13)
            if approval.request == nil && approval.pairID == nil {
                Text("Answer in \(approval.session.hostLabel ?? "its app")").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 13)
            }
        }
        .padding(.vertical, 3)
    }

    private var line: String {
        if let r = approval.request { return r.kind == .question ? r.summary : r.tool + ": " + r.summary }
        return approval.reason
    }
}
