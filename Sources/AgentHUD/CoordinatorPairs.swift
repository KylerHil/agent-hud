import AgentHUDCore
import AppKit
import SwiftUI

// MARK: - Pair thread

/// A pair reads as one thread: each handoff is a divider, each reply is the agent's message, and the
/// verdicts, test runs and commits sit between them.
struct PairChat: View {
    let model: CoordinatorModel
    let pair: PairState

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.slug).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text((pair.config.root as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                        AgentBadge(agent: pair.config.builder)
                        if pair.config.reviewer != pair.config.builder { AgentBadge(agent: pair.config.reviewer) }
                        if let b = pair.branch { SourceChip(label: b) }
                    }
                }
                Spacer()
                Text(pair.status == .done ? "Done" : pair.phase.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(pair.status == .waitingOnYou ? Color.orange : .secondary)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GOAL").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                            Text(pair.config.goal).font(.system(size: 12.5)).textSelection(.enabled)
                        }
                        ForEach(pair.events) { e in PairEventView(event: e) }
                        PairPrompts(model: model, pair: pair)
                        if pair.status == .running, let agent = pair.agent(for: pair.phase) {
                            PairWorking(agent: agent, pair: pair)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: pair.events.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: pair.id) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            PairActions(model: model, pair: pair)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct PairPrompts: View {
    let model: CoordinatorModel
    let pair: PairState

    var body: some View {
        ForEach(model.pairSessions(pair).filter { !$0.pending.isEmpty }) { m in
            ForEach(m.pending) { p in
                VStack(alignment: .leading, spacing: 4) {
                    AgentBadge(agent: m.agent)
                    PendingCard(request: p) { decision, answers in
                        model.broker.answer(m.id, request: p.id, decision: decision, answers: answers)
                    }
                }
            }
        }
    }
}

private struct PairWorking: View {
    let agent: AgentKind
    let pair: PairState

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(agent.displayName + " · " + pair.phase.label.lowercased() + (pair.round > 0 ? " · round \(pair.round)" : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct PairEventView: View {
    let event: PairEvent
    @State private var expanded = false

    var body: some View {
        switch event.kind {
        case .handoff:
            HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                HStack(spacing: 4) {
                    Text("To").foregroundStyle(.secondary)
                    if let a = event.agent { AgentBadge(agent: a) }
                    Text("· " + event.text).foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5))
                .fixedSize()
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            }
        case .reply:
            HStack(alignment: .top, spacing: 9) {
                if let a = event.agent { AgentAvatar(agent: a) }
                VStack(alignment: .leading, spacing: 4) {
                let text = Self.withoutVerdict(event.text)
                let long = text.count > 1500
                MarkdownText(text: long && !expanded ? String(text.prefix(1500)) + "…" : text)
                if long {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Color.accentColor)
                }
                }
            }
            .copyable(event.text)
        case .verdict:
            line(event.text.hasPrefix("Approved") ? "checkmark.seal.fill" : "exclamationmark.bubble.fill",
                 event.text.hasPrefix("Approved") ? .green : .orange)
        case .tests:
            line(event.text.hasPrefix("Tests passed") ? "checkmark.circle" : "xmark.circle",
                 event.text.hasPrefix("Tests passed") ? .green : .red)
        case .commit:
            line("arrow.triangle.branch", .secondary)
        case .you:
            line("person.fill", .accentColor)
        case .warning:
            line("exclamationmark.triangle.fill", .orange)
        case .note:
            line("info.circle", .secondary)
        }
    }

    /// The verdict block shows as its own line, so the reply doesn't repeat it as raw JSON.
    static func withoutVerdict(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "```(?:json)?\\s*\\{[\\s\\S]*?\"verdict\"[\\s\\S]*?\\}\\s*```") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func line(_ symbol: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11))
            Text(event.text).font(.system(size: 11.5)).textSelection(.enabled)
                .lineLimit(expanded ? nil : 6)
                .onTapGesture { expanded.toggle() }
            Spacer(minLength: 0)
            Text(event.at.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

/// What you can do with the pair right now.
private struct PairActions: View {
    let model: CoordinatorModel
    let pair: PairState

    private var draft: Binding<String> {
        Binding(get: { model.drafts["pair:" + pair.id] ?? "" }, set: { model.drafts["pair:" + pair.id] = $0 })
    }
    private var text: String { (model.drafts["pair:" + pair.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = pair.reason, pair.status != .running {
                Text(r).font(.system(size: 11.5, weight: .medium)).foregroundStyle(pair.status == .waitingOnYou ? Color.orange : .secondary)
            }
            switch pair.status {
            case .waitingOnYou where pair.phase == .approvePlan:
                if let plan = pair.plan {
                    ScrollView { MarkdownText(text: plan) }
                        .frame(maxHeight: 180)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                field("Notes for the builder (optional)")
                HStack {
                    Button("Approve Plan") { model.pairAction(pair, "approvePlan", text: text); model.drafts["pair:" + pair.id] = nil }
                        .keyboardShortcut(.defaultAction)
                    Button("Stop") { model.pairAction(pair, "stop") }
                }
            case .waitingOnYou, .paused:
                field("Or give the pair a new goal")
                HStack {
                    Button(pair.status == .paused ? "Resume" : "Try Again") { model.pairAction(pair, "resume") }
                        .keyboardShortcut(.defaultAction)
                        .help("Run the \(pair.phase.label.lowercased()) step again")
                    Button("New Goal") { keepGoing() }.disabled(text.isEmpty)
                    Button("Stop") { model.pairAction(pair, "stop") }
                    Spacer()
                    worktreeButtons
                }
            case .running:
                HStack(alignment: .bottom, spacing: 8) {
                    field("Message \(pair.agent(for: pair.phase)?.displayName ?? "the agent") (joins its turn)")
                    Button("Send") { message() }.disabled(text.isEmpty)
                }
                HStack {
                    Button(pair.pauseRequested ? "Pausing after this turn…" : "Pause After This Turn") { model.pairAction(pair, "pause") }
                        .disabled(pair.pauseRequested)
                    Button("Stop") { model.pairAction(pair, "stop") }
                    Spacer()
                    worktreeButtons
                }
            case .done, .stopped, .failed:
                field("Keep going: give the pair its next goal")
                HStack {
                    Button("Keep Going") { keepGoing() }.disabled(text.isEmpty)
                    if pair.worktree != nil, pair.status == .done {
                        Button("Merge into \(mainName)…") { merge() }
                    }
                    Spacer()
                    worktreeButtons
                    Menu("Remove") {
                        Button("Remove Pair") { model.pairAction(pair, "remove") }
                        if pair.worktree != nil { Button("Remove Pair and Worktree") { model.pairAction(pair, "remove", text: "worktree") } }
                    }
                    .fixedSize()
                }
            }
            if let n = model.notice { Text(n).font(.system(size: 10.5)).foregroundStyle(.red).lineLimit(3) }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mainName: String { "your checkout" }

    @ViewBuilder private var worktreeButtons: some View {
        Button("Open in VS Code") { model.openInEditor(pair.workDir) }
            .help(pair.workDir)
    }

    private func field(_ prompt: String) -> some View {
        TextField(prompt, text: draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(1...5)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func keepGoing() {
        model.pairAction(pair, "keepGoing", text: text)
        model.drafts["pair:" + pair.id] = nil
    }

    private func message() {
        guard let agent = pair.agent(for: pair.phase), let m = model.pairSession(pair, agent) else { return }
        model.broker.message(m.id, text, steer: agent == .codex)
        model.drafts["pair:" + pair.id] = nil
    }

    private func merge() {
        guard let branch = pair.branch else { return }
        let alert = NSAlert()
        alert.messageText = "Merge \(branch) into your checkout?"
        alert.informativeText = "Runs `git merge --no-ff \(branch)` in \(pair.config.root). Nothing is pushed. If the merge conflicts, it's aborted and your checkout is left as it was."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.pairAction(pair, "merge") }
    }
}

// MARK: - Pair column

struct PairColumn: View {
    let model: CoordinatorModel
    let pair: PairState

    private var steps: [(PairPhase, AgentKind?)] {
        var s: [(PairPhase, AgentKind?)] = [(.plan, pair.config.planner), (.reviewPlan, pair.config.reviewer)]
        if pair.events.contains(where: { $0.phase == .revisePlan }) { s.append((.revisePlan, pair.config.planner)) }
        if pair.config.approvePlan { s.append((.approvePlan, nil)) }
        s += [(.build, pair.config.builder), (.review, pair.config.reviewer)]
        if pair.round > 1 || pair.phase == .fix { s.insert((.fix, pair.config.builder), at: s.count - 1) }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader {
                Text("Pair").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(pair.status == .done ? "done" : pair.status == .waitingOnYou ? "waiting on you" : pair.status.rawValue)
                    .font(.system(size: 11)).foregroundStyle(pair.status == .waitingOnYou ? Color.orange : .secondary)
            }
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "Steps").padding(.top, 6)
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in stepRow(step.0, step.1) }
                    Divider().padding(.vertical, 4)
                    kv("Round", pair.round == 0 ? "—" : "\(pair.round) of \(pair.config.maxRounds)")
                    kv("Editing now", pair.phase.writes && pair.status == .running ? pair.config.builder.displayName : "nobody")
                    if let b = pair.branch { kv("Branch", b) }
                    if let w = pair.worktree { kv("Worktree", (w as NSString).lastPathComponent) }
                    if let t = pair.config.testCommand { kv("Tests", (pair.testsPassed.map { $0 ? "pass · " : "fail · " } ?? "") + t) }
                    if let v = pair.lastVerdict { kv("Last verdict", v.approved ? "approve" : "changes (\(v.findings.count))") }
                    Divider().padding(.vertical, 4)
                    SectionLabel(title: "Agents")
                    ForEach(model.pairSessions(pair)) { m in agentCard(m) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            Divider()
            Text(pair.status == .done ? "Finished \(pair.updatedAt.formatted(date: .omitted, time: .shortened))"
                 : "Stops for you after \(pair.config.maxRounds) rounds or two failing test runs")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func stepRow(_ phase: PairPhase, _ agent: AgentKind?) -> some View {
        let order: [PairPhase] = [.plan, .reviewPlan, .revisePlan, .approvePlan, .build, .fix, .review, .done]
        let current = pair.status == .done ? order.count : order.firstIndex(of: pair.phase) ?? 0
        let mine = order.firstIndex(of: phase) ?? 0
        let isNow = phase == pair.phase && pair.status != .done
        let doneStep = mine < current || pair.status == .done
        return HStack(spacing: 7) {
            ZStack {
                if isNow && pair.status == .running { ProgressView().controlSize(.mini) }
                else {
                    Circle().fill(doneStep ? Color.green : isNow ? Color.orange : Color.clear)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(doneStep || isNow ? 0 : 0.25)))
                    if doneStep { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white) }
                }
            }
            .frame(width: 14, height: 14)
            if let agent { AgentBadge(agent: agent) } else { Text("You").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor) }
            Text(phase.label).font(.system(size: 11.5, weight: isNow ? .semibold : .regular))
            Spacer()
            if phase == .review && pair.round > 0 { Text("round \(pair.round)").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func agentCard(_ m: ManagedSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AgentBadge(agent: m.agent)
                Text(m.status.rawValue).font(.system(size: 11)).foregroundStyle(m.status == .waiting ? Color.orange : .secondary)
                Spacer()
                Text("\(m.turns) turn\(m.turns == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let mode = m.permissionMode { Text(mode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
            if let e = m.error { Text(e).font(.system(size: 10)).foregroundStyle(.red).lineLimit(3) }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Sheets

/// Pick where a new session or pair works: a project agents ran in, or any folder.
private struct ProjectPicker: View {
    let model: CoordinatorModel
    @Binding var root: String

    var body: some View {
        HStack {
            Picker("Project", selection: $root) {
                if root.isEmpty { Text("Choose…").tag("") }
                ForEach(model.knownProjects, id: \.root) { p in Text(p.name).tag(p.root) }
                if !root.isEmpty, !model.knownProjects.contains(where: { $0.root == root }) {
                    Text((root as NSString).lastPathComponent).tag(root)
                }
            }
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { root = url.path }
            }
        }
    }
}

struct NewSessionSheet: View {
    let model: CoordinatorModel
    private func dismiss() { model.showingNewSession = false }
    @State private var root = ""
    @State private var agent: AgentKind = .claude
    @State private var prompt = ""
    @State private var mode = "default"
    @State private var modelName = ""
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign Work").font(.system(size: 15, weight: .bold))
            Text("Runs under the Coordinator, so you can message it, answer its prompts and stop its turns from here. It keeps running if Agent HUD quits.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ProjectPicker(model: model, root: $root)
                Picker("Agent", selection: $agent) {
                    Text("Claude").tag(AgentKind.claude)
                    Text("Codex").tag(AgentKind.codex)
                }
                .pickerStyle(.segmented)
                if agent == .claude {
                    Picker("Permissions", selection: $mode) {
                        ForEach(claudeModeChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } else {
                    Picker("Sandbox", selection: $mode) {
                        Text("Workspace write").tag("workspace-write")
                        Text("Read only").tag("read-only")
                    }
                }
                TextField("Model (optional)", text: $modelName, prompt: Text(agent == .claude ? "e.g. sonnet, opus" : "e.g. gpt-6.1-sol"))
            }
            .formStyle(.columns)
            Text("Task").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.system(size: 12.5))
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(starting)
                Button(starting ? "Starting…" : "Start") {
                    starting = true; error = nil
                    model.startSession(StartOptions(agent: agent, cwd: root, prompt: prompt.isEmpty ? nil : prompt,
                                                    permissionMode: mode, model: modelName.isEmpty ? nil : modelName,
                                                    title: prompt.isEmpty ? nil : String(prompt.prefix(80)))) { failure in
                        starting = false
                        if let failure { error = failure } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(root.isEmpty || starting)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { root = model.newSessionFor ?? model.knownProjects.first?.root ?? "" }
        .onChange(of: agent) { mode = agent == .claude ? "default" : "workspace-write" }
    }
}

private let claudeModeChoices: [(String, String)] = [("default", "Ask before edits"), ("acceptEdits", "Accept edits"),
                                                     ("auto", "Auto"), ("plan", "Plan only")]

struct NewPairSheet: View {
    let model: CoordinatorModel
    private func dismiss() { model.showingNewPair = false }
    @State private var root = ""
    @State private var goal = ""
    @State private var builderIsClaude = true
    @State private var approvePlan = true
    @State private var rounds = 3
    @State private var useWorktree = true
    @State private var testCommand = ""
    @State private var builderMode = "acceptEdits"
    @State private var pathGuard = ""

    var body: some View {
        let builder: AgentKind = builderIsClaude ? .claude : .codex
        let reviewer: AgentKind = builderIsClaude ? .codex : .claude
        VStack(alignment: .leading, spacing: 12) {
            Text("New Pair").font(.system(size: 15, weight: .bold))
            Text("Claude and Codex take turns on one goal: one plans and builds, the other reviews the plan and every diff, until the reviewer approves.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ProjectPicker(model: model, root: $root)
            }
            .formStyle(.columns)
            Text("Goal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: $goal)
                .font(.system(size: 12.5))
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack(spacing: 5) {
                step(builder, "Plan"); arrow; step(reviewer, "Review plan"); arrow
                if approvePlan { Text("You approve").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor); arrow }
                step(builder, "Build"); arrow; step(reviewer, "Review diff")
                Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
            }
            HStack {
                Button { builderIsClaude.toggle() } label: { Label("Swap Roles", systemImage: "arrow.left.arrow.right") }
                Spacer()
                Stepper("At most \(rounds) review round\(rounds == 1 ? "" : "s")", value: $rounds, in: 1...6)
            }
            .controlSize(.small)
            Form {
                Toggle("Stop for my approval after the plan is reviewed", isOn: $approvePlan)
                Toggle("Work in a new git worktree (your checkout stays untouched)", isOn: $useWorktree)
                if builder == .claude {
                    Picker("Builder permissions", selection: $builderMode) {
                        Text("Accept edits, ask for commands").tag("acceptEdits")
                        Text("Auto").tag("auto")
                        Text("Ask for everything").tag("default")
                    }
                } else {
                    Picker("Builder approvals", selection: $builderMode) {
                        Text("Don't ask inside the sandbox").tag("acceptEdits")
                        Text("Ask when it needs more access").tag("default")
                    }
                }
                TextField("Test command", text: $testCommand, prompt: Text("e.g. pnpm test (runs after every build; two failures stop the pair)"))
                TextField("Only change files under", text: $pathGuard, prompt: Text("optional, e.g. src"))
            }
            .formStyle(.columns)
            if !useWorktree {
                Text("Without a worktree the pair commits in your checkout, including any changes you have there.")
                    .font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            HStack {
                Text("The reviewer's turns are read-only; anything it changes is discarded.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Pair") {
                    model.startPair(PairConfig(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), root: root,
                                               planner: builder, builder: builder, reviewer: reviewer,
                                               approvePlan: approvePlan, maxRounds: rounds, useWorktree: useWorktree,
                                               testCommand: testCommand.isEmpty ? nil : testCommand, builderMode: builderMode,
                                               pathGuard: pathGuard.isEmpty ? nil : pathGuard))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(root.isEmpty || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { root = model.selectedRoot ?? model.knownProjects.first?.root ?? "" }
    }

    private func step(_ agent: AgentKind, _ label: String) -> some View {
        HStack(spacing: 4) { AgentBadge(agent: agent); Text(label).font(.system(size: 11, weight: .semibold)) }
    }

    private var arrow: some View { Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
}
