import AgentHUDCore
import AppKit
import SwiftUI

struct QuickAnswersView: View {
    let model: AppModel
    var forSnapshot = false
    private var questions: QuickAnswersModel { model.quickAnswers }
    private var sessions: [Session] { model.questionSessions }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                sourceList.frame(width: 190)
                Divider().opacity(0.5)
                Group {
                    if forSnapshot { detail } else { ScrollView { detail } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider().opacity(0.5)
            Text("Answers stay local. Copy, paste into the agent, and send when ready.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .onAppear {
            if !forSnapshot {
                questions.refresh(sessions: sessions, force: true)
                model.actions.focusPanel()
            }
        }
        .onDisappear { questions.save() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button { model.mode = .list } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).help("Back to sessions").accessibilityLabel("Back to sessions")
            Text("Quick answers").font(.system(size: 14, weight: .semibold))
            if questions.refreshing { ProgressView().controlSize(.small).scaleEffect(0.7) }
            Spacer()
            Menu {
                ForEach(sessions) { session in
                    Button("\(session.projectName) · \(session.agent.displayName) · \(String(session.sessionId.prefix(6)))") {
                        questions.attachPlan(to: session)
                    }
                }
            } label: { Label("Add plan…", systemImage: "doc.badge.plus") }
            .disabled(sessions.isEmpty).fixedSize()
            Button { questions.refresh(sessions: sessions, force: true) } label: {
                Image(systemName: "arrow.clockwise")
            }.help("Refresh questions").accessibilityLabel("Refresh questions").disabled(questions.refreshing)
        }
        .controlSize(.small).padding(12)
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Session", selection: Binding(get: { questions.sessionFilter ?? "" }, set: {
                questions.sessionFilter = $0.isEmpty ? nil : $0
                questions.selection = questions.visible.first
            })) {
                Text("All sessions").tag("")
                ForEach(sessions) { session in
                    Text("\(session.projectName) · \(session.agent.displayName) · \(String(session.sessionId.prefix(6)))").tag(session.id)
                }
            }.labelsHidden().controlSize(.small)
            Toggle("Show handled", isOn: Binding(get: { questions.showHandled }, set: {
                questions.showHandled = $0
                if let selected = questions.selection, !questions.visible.contains(where: { $0.id == selected.id }) {
                    questions.selection = questions.visible.first
                }
            }))
                .font(.system(size: 11)).toggleStyle(.checkbox)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(questions.visible) { source in
                        Button { questions.choose(source) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(source.title, systemImage: icon(source))
                                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                                if let session = model.store.sessions[source.sessionID] {
                                    Text("\(session.projectName) · \(session.agent.displayName)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    Text(session.title ?? session.lastPrompt ?? String(session.sessionId.prefix(8)))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text(questions.drafts.isHandled(source.id) ? "Handled" : "\(source.questions.count) questions")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(questions.selection?.id == source.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Detected questions may need your judgment. Plans aren’t changed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(11)
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = questions.persistenceError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let source = questions.selection {
                sourceHeader(source)
                if !questions.selectionIsCurrent {
                    Label("This source has changed or is no longer current. Your draft is kept; choose the updated source to continue.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if source.kind == .interactive {
                    Text("This is an interactive prompt. Use your prepared answers in the agent’s own choices; pasting a chat reply may not resolve it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(Array(source.questions.enumerated()), id: \.element.id) { index, question in
                    questionCard(question, number: question.number ?? String(index + 1), source: source)
                }
                if let reply = questions.reply(for: source) {
                    DisclosureGroup("Preview assembled reply") {
                        Text(reply).font(.system(size: 11)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
                    }.font(.system(size: 11))
                }
                answerActions(source)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 27)).foregroundStyle(.secondary)
                    Text("Questions, without the hunt").font(.system(size: 18, weight: .semibold))
                    Text("Questions from the latest Claude Code or Codex replies and linked Markdown plans appear here. Add a plan manually if it wasn’t linked.")
                    Text("For the clearest detection, use an “Open questions” heading and a numbered list. Ordinary desktop chats without a local coding transcript aren’t supported.")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 12)).lineSpacing(4).padding(.top, 28)
            }
            if let message = questions.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceHeader(_ source: QuickQuestionSource) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(source.title).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
            Text(source.kind == .markdown ? source.path : "Latest agent reply · \(source.questions.count) detected questions")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
            if let session = model.store.sessions[source.sessionID] {
                Text("\(session.agent.displayName) · \(session.title ?? session.lastPrompt ?? session.projectName) · \(String(session.sessionId.prefix(8)))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if source.kind == .markdown {
                Button("Open Markdown source") { NSWorkspace.shared.open(URL(fileURLWithPath: source.path)) }
                    .font(.system(size: 11)).buttonStyle(.link)
            }
        }
    }

    private func questionCard(_ question: QuickQuestion, number: String, source: QuickQuestionSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Text(number + ".").foregroundStyle(.secondary)
                Text(question.text).textSelection(.enabled)
            }.font(.system(size: 12, weight: .semibold))
            if source.kind == .markdown { Text("Line \(question.line)").font(.system(size: 10)).foregroundStyle(.tertiary) }
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                Button {
                    questions.setAnswer(option, question: question, source: source)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: questions.answer(question, in: source) == option ? "checkmark.circle.fill" : "circle")
                        Text(option).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.font(.system(size: 11)).padding(7)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("Use this option as your draft answer; edit below to add detail")
            }
            TextField("Your answer…", text: Binding(get: { questions.answer(question, in: source) }, set: {
                questions.setAnswer($0, question: question, source: source)
            }), axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .accessibilityLabel("Answer to question \(number): \(question.text)")
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func answerActions(_ source: QuickQuestionSource) -> some View {
        let session = model.store.sessions[source.sessionID]
        let canCopy = questions.reply(for: source) != nil && questions.selectionIsCurrent
        return VStack(alignment: .leading, spacing: 9) {
            if source.kind == .interactive {
                // A pasted reply doesn't resolve the pending tool call, so there's nothing to copy.
                Button("Open agent to answer") { if let session { model.jump(session) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(session == nil || session?.state == .ended)
            } else {
                HStack(spacing: 8) {
                    Button("Copy & open agent") { questions.copyReply(source, session: session, openSession: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCopy || session == nil || session?.state == .ended)
                    Button("Copy answers") { questions.copyReply(source, session: session, openSession: false) }
                        .disabled(!canCopy)
                }
                // Chat questions go stale by themselves at your next prompt; a plan stays until you say so.
                if source.kind == .markdown {
                    Button(questions.drafts.isHandled(source.id) ? "Reopen questions" : "Mark handled after sending") {
                        questions.handle(source)
                    }.buttonStyle(.link)
                }
                Text("Copying does not send. Editors open to the project; choose the conversation shown above before pasting. Unanswered questions keep their original numbers.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.controlSize(.small).font(.system(size: 11))
    }

    private func icon(_ source: QuickQuestionSource) -> String {
        switch source.kind { case .chat: "text.bubble"; case .markdown: "doc.text"; case .interactive: "questionmark.bubble" }
    }
}
