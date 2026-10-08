import AgentHUDCore
import AppKit
import Observation

/// State behind the Coordinator window: which project, session or pair is selected, and the selected
/// session's conversation, read incrementally from its transcript. Session state stays in `AppModel`
/// (hooks) and `BrokerClient` (sessions the Coordinator runs); this projects both into three columns.
@MainActor
@Observable
final class CoordinatorModel {
    let app: AppModel
    var broker: BrokerClient { app.broker }

    private(set) var selectedProject: String?
    private(set) var selectedSessionID: String?
    private(set) var selectedPairID: String?
    /// The selected session's conversation, oldest first.
    private(set) var items: [ChatItem] = []
    private(set) var truncated = false
    /// Unsent replies, per session or pair, kept while the app runs.
    var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "coordinatorDrafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts, forKey: "coordinatorDrafts") }
    }
    /// Sheets.
    var newSessionFor: String?
    var showingNewSession = false
    var showingNewPair = false
    var showingApprovals = false
    /// Sidebar filter text.
    var filter = ""
    /// Project folders the user opened or closed by hand (key → open). Others follow their state.
    var folderOpen: [String: Bool] = [:]
    /// A one-line message under the composer after something failed.
    var notice: String?
    /// Replies handed to an existing editor conversation, until its transcript confirms receipt.
    private(set) var editorSends: [String: EditorSend] = CoordinatorModel.restoredEditorSends() {
        didSet {
            if let data = try? JSONEncoder().encode(editorSends) {
                UserDefaults.standard.set(data, forKey: "coordinatorEditorSends")
            }
        }
    }
    private(set) var codexOwners: [String: CodexIPC.Owner] = [:]
    private(set) var codexBridgeErrors: [String: String] = [:]

    struct EditorSend: Equatable, Codable {
        enum BridgeStatus: String, Codable { case sending, sent, steered, queued, failed, uncertain }
        var text: String
        var at: Date
        /// Nil while the editor is being opened.
        var outcome: EditorReply.Outcome?
        var delivered = false
        var bridgeStatus: BridgeStatus?
        var error: String?
        var receiptID: String? = UUID().uuidString
        var priorUserItemIDs: [String]?
    }

    private static func restoredEditorSends() -> [String: EditorSend] {
        guard let data = UserDefaults.standard.data(forKey: "coordinatorEditorSends"),
              var sends = try? JSONDecoder().decode([String: EditorSend].self, from: data) else { return [:] }
        for id in sends.keys {
            if sends[id]?.receiptID == nil { sends[id]?.receiptID = UUID().uuidString }
            if sends[id]?.bridgeStatus == .sending {
                sends[id]?.bridgeStatus = .uncertain
                sends[id]?.error = "Agent HUD restarted before delivery was confirmed. Check this conversation before sending again."
            }
        }
        return sends
    }

    @ObservationIgnored private var transcripts: [String: ChatTranscript] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "agenthud.coordinator.transcripts", qos: .userInitiated)
    @ObservationIgnored private let bridgeQueue = DispatchQueue(label: "agenthud.coordinator.codex-ipc", qos: .userInitiated)
    @ObservationIgnored private var probingCodex = false
    @ObservationIgnored private var lastCodexProbe: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loading = false

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Sessions

    /// Hook-tracked sessions, plus managed ones the hooks haven't reported yet (or that have stopped).
    /// Pair sessions are shown under their pair instead.
    var live: [Session] {
        let pairSessions = Set(broker.sessions.values.filter { $0.pairID != nil }.compactMap(\.storeID))
        var list = app.sorted.filter { $0.state != .ended && !$0.isChat && !pairSessions.contains($0.id) }
            .map(labelled)
        let known = Set(list.map(\.id))
        for m in broker.sessions.values where m.pairID == nil {
            let id = m.storeID ?? "managed:" + m.id
            // Stopped ones stay a day, so they can be resumed.
            let stopped = m.status == .exited || m.status == .failed
            guard !known.contains(id), !stopped || app.now.timeIntervalSince(m.lastActivity) < 86400 else { continue }
            list.append(Self.session(for: m))
        }
        return list.sorted { (displayState($0).sortRank, -$0.lastEventAt.timeIntervalSince1970) < (displayState($1).sortRank, -$1.lastEventAt.timeIntervalSince1970) }
    }

    /// A row for a managed session the hooks haven't reported (or no longer track).
    static func session(for m: ManagedSession) -> Session {
        var s = Session(id: m.storeID ?? "managed:" + m.id, agent: m.agent, sessionId: m.sessionId ?? m.id,
                        base: [.busy, .starting, .waiting].contains(m.status) ? .running : .idle,
                        stateSince: m.lastActivity, lastEventAt: m.lastActivity)
        s.cwd = m.cwd
        s.launchDir = m.cwd
        s.root = ProjectRoot.root(of: m.cwd)
        s.transcriptPath = m.transcriptPath
        s.hostKind = "coordinator"
        s.title = m.title
        s.lastMessage = m.lastReply
        s.pid = m.pid
        s.error = m.error
        s.turnStartedAt = m.turnStartedAt
        s.lastTurnDuration = m.lastTurnDuration
        s.currentDetail = m.currentDetail
        return s
    }

    /// A session the broker runs lives in the Coordinator, whatever host its hooks reported.
    private func labelled(_ s: Session) -> Session {
        guard let m = broker.managed(storeID: s.id) else { return s }
        var s = s
        s.hostKind = "coordinator"
        s.hostApp = nil
        s.title = m.title ?? s.title
        s.error = m.error
        s.currentDetail = m.currentDetail ?? s.currentDetail
        s.lastMessage = m.lastReply ?? s.lastMessage
        s.lastTurnDuration = m.lastTurnDuration ?? s.lastTurnDuration
        s.turnStartedAt = m.turnStartedAt
        return s
    }

    /// The managed session behind a row, if the Coordinator runs it.
    func managed(_ s: Session) -> ManagedSession? {
        if s.id.hasPrefix("managed:") { return broker.sessions[String(s.id.dropFirst(8))] }
        return broker.managed(storeID: s.id)
    }

    /// Prompts the broker holds win: hooks don't see every prompt a managed session raises.
    func displayState(_ s: Session) -> SessionState {
        if let m = managed(s) {
            if !broker.connected { return .unknown }
            switch m.status {
            case .waiting: return .needsInput
            case .busy, .starting: return .running
            case .exited, .failed: return .idle
            case .idle: return .idle
            }
        }
        return app.displayState(s)
    }

    /// What the Coordinator can do with a session, from the bridge it has (docs/Coordinator-Plan.md §9.6).
    func control(_ s: Session) -> SessionControl {
        guard let m = managed(s) else {
            if let owner = codexOwners[s.id] {
                return SessionControl(mode: .nativeConnected, capabilities: SessionCapabilities(sendNextTurn: true, steerActiveTurn: true), connectionID: owner.clientID)
            }
            return .observed
        }
        if !broker.connected || m.status == .exited || m.status == .failed {
            return SessionControl(mode: .brokerManaged, capabilities: SessionCapabilities(reconnect: true), connectionID: m.id)
        }
        return SessionControl(mode: .brokerManaged, capabilities: m.capabilities, connectionID: m.id)
    }

    func statusLabel(_ s: Session) -> String {
        if let m = managed(s) { return m.coordinationStatus(connected: broker.connected).label }
        switch displayState(s) {
        case .running: return "Running"
        case .needsInput: return "Waiting on you"
        case .idle: return s.error != nil ? "Failed" : s.lastTurnDuration != nil ? "Completed" : "Idle"
        case .ended: return "Disconnected"
        case .stale, .unknown: return "Unconfirmed"
        }
    }

    var selectedRoot: String? { project?.primary.root ?? selectedProject }

    var editorProjects: [(name: String, root: String, editor: EditorWorkspace)] {
        var seen = Set<String>()
        return broker.editors.filter { $0.connected && $0.remote == nil }.flatMap { editor in
            editor.folders.compactMap { folder in
                let root = ProjectRoot.root(of: folder)
                guard seen.insert(root).inserted else { return nil }
                return (name: (root as NSString).lastPathComponent, root: root, editor: editor)
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func openEditor(_ s: Session, action: String = "reveal") {
        guard let cwd = s.launchDir ?? s.cwd ?? s.root else { return }
        broker.editorAction(action, cwd: cwd, session: managed(s)?.id) { [weak self] error in self?.notice = error }
    }

    // MARK: Sidebar folders

    struct Folder: Identifiable {
        var id: String
        var name: String
        /// Most urgent first.
        var sessions: [Session]
        var state: SessionState
    }

    /// Projects as folders, most urgent first; the filter matches project names, titles and prompts.
    var folders: [Folder] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return Session.groupedByProject(live).compactMap { group -> Folder? in
            let matches = q.isEmpty ? group : group.filter { s in
                [s.projectName, s.title ?? "", s.lastPrompt ?? "", s.hostLabel ?? ""].contains { $0.lowercased().contains(q) }
            }
            guard !matches.isEmpty else { return nil }
            return Folder(id: matches[0].projectKey, name: matches[0].projectName, sessions: matches,
                          state: matches.map(displayState).min { $0.sortRank < $1.sortRank } ?? .idle)
        }
    }

    /// Open when you opened it, or when something in it needs you or is selected.
    func isOpen(_ f: Folder) -> Bool {
        if let manual = folderOpen[f.id] { return manual || f.sessions.contains { displayState($0) == .needsInput } }
        return f.sessions.contains { displayState($0) == .needsInput || $0.id == selectedSessionID }
    }

    func toggle(_ f: Folder) { folderOpen[f.id] = !isOpen(f) }

    /// A short name for a session inside its folder: its title, else its first words.
    func sessionLabel(_ s: Session) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let p = s.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            if p.hasPrefix("<send_user_message_question_reply>") { return "Follow-up answer" }
            return String(ChatTranscript.strippingContext(p).prefix(60))
        }
        return "\(s.agent.displayName) session"
    }

    // MARK: Approvals

    /// Something waiting on you, anywhere: a managed prompt you can answer here, or a watched one you can't.
    struct Approval: Identifiable {
        var id: String
        var session: Session
        var request: PendingRequest?
        /// The broker key that answers it.
        var key: String?
        var pairID: String?
        var reason: String
        var since: Date
    }

    var approvals: [Approval] {
        var out: [Approval] = []
        for m in broker.sessions.values where !m.pending.isEmpty {
            let s = app.store.sessions[m.storeID ?? ""].map(labelled) ?? Self.session(for: m)
            for p in m.pending {
                out.append(Approval(id: p.id, session: s, request: p, key: m.id, pairID: m.pairID,
                                    reason: p.kind == .question ? "Question" : p.tool, since: p.since))
            }
        }
        for s in live where managed(s) == nil && displayState(s) == .needsInput {
            if let p = s.primaryPending {
                out.append(Approval(id: "hook:" + s.id, session: s, request: nil, key: nil, pairID: nil, reason: p.reason, since: p.since))
            }
        }
        for p in broker.pairs.values where p.status == .waitingOnYou {
            out.append(Approval(id: "pair:" + p.id, session: Self.pairSession(p), request: nil, key: nil, pairID: p.id,
                                reason: p.phase == .approvePlan ? "Plan to approve" : "Pair needs you", since: p.updatedAt))
        }
        return out.sorted { $0.since < $1.since }
    }

    /// A row stand-in for a pair, for lists that show sessions.
    static func pairSession(_ p: PairState) -> Session {
        var s = Session(id: "pair:" + p.id, agent: p.config.builder, sessionId: p.id, base: .idle, stateSince: p.updatedAt, lastEventAt: p.updatedAt)
        s.root = p.config.root
        s.cwd = p.workDir
        s.title = p.slug
        s.hostKind = "coordinator"
        return s
    }

    /// The last few messages of a session, for context beside an approval.
    func context(for s: Session, done: @escaping ([ChatItem]) -> Void) {
        guard let path = s.transcriptPath ?? managed(s)?.transcriptPath else { return done([]) }
        let agent = s.agent
        queue.async {
            let t = ChatTranscript(path: path, agent: agent, initialBytes: 1 << 20, limit: 60)
            t.update()
            let items = Array(t.items.filter { $0.kind != .tool }.suffix(6))
            DispatchQueue.main.async { done(items) }
        }
    }

    func answer(_ a: Approval, decision: String, answers: [String: [String]]? = nil) {
        guard let key = a.key, let r = a.request else { return }
        broker.answer(key, request: r.id, decision: decision, answers: answers)
    }

    // MARK: Board

    struct Project: Identifiable {
        var id: String
        /// Most urgent first.
        var sessions: [Session]
        var primary: Session { sessions[0] }
    }

    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var projects: [Project]
    }

    /// The rail: one row per project, grouped like the panel (Needs you, Just finished, Working, Idle).
    var sections: [Section] {
        let projects = Session.groupedByProject(live).map { Project(id: $0[0].projectKey, sessions: $0) }
        var needs: [Project] = [], finished: [Project] = [], working: [Project] = [], idle: [Project] = []
        for p in projects {
            let state = displayState(p.primary)
            if state == .needsInput { needs.append(p) }
            else if p.sessions.contains(where: app.isJustFinished) && state != .running && state != .stale { finished.append(p) }
            else if state == .running || state == .stale { working.append(p) }
            else { idle.append(p) }
        }
        return [("Needs you", needs), ("Just finished", finished), ("Working", working), ("Idle", idle)]
            .filter { !$0.1.isEmpty }
            .map { Section(title: $0.0, projects: $0.1) }
    }

    var pairList: [PairState] {
        broker.pairs.values.sorted { ($0.status == .waitingOnYou ? 0 : $0.status == .running ? 1 : 2, -$0.updatedAt.timeIntervalSince1970)
            < ($1.status == .waitingOnYou ? 0 : $1.status == .running ? 1 : 2, -$1.updatedAt.timeIntervalSince1970) }
    }

    /// The right column: every agent working or waiting, in any project (pair agents included).
    var running: [Session] {
        var list = live.filter { [.running, .stale, .needsInput].contains(displayState($0)) }
        for m in broker.sessions.values where m.pairID != nil && [.busy, .waiting, .starting].contains(m.status) {
            list.append(app.store.sessions[m.storeID ?? ""] ?? Self.session(for: m))
        }
        return list
    }

    /// Turns finished today that are now idle, newest first.
    var finishedToday: [Session] {
        let start = Calendar.current.startOfDay(for: app.now)
        return live.filter { displayState($0) == .idle && $0.lastTurnDuration != nil && $0.stateSince >= start }
            .sorted { $0.stateSince > $1.stateSince }
            .prefix(8).map { $0 }
    }

    var project: Project? {
        guard let key = selectedProject else { return nil }
        let sessions = live.filter { $0.projectKey == key }
        return sessions.isEmpty ? nil : Project(id: key, sessions: sessions)
    }

    var session: Session? {
        guard let id = selectedSessionID else { return nil }
        return app.store.sessions[id].flatMap { $0.state == .ended && managed($0) == nil ? nil : labelled($0) }
            ?? live.first { $0.id == id }
            ?? broker.sessions.values.first { "managed:" + $0.id == id || $0.storeID == id }.map(Self.session(for:))
    }

    var pair: PairState? { selectedPairID.flatMap { broker.pairs[$0] } }

    /// Projects the user can start sessions and pairs in: where agents ran, newest first.
    var knownProjects: [(name: String, root: String)] {
        var seen = Set<String>(), out: [(String, String)] = []
        for p in editorProjects { if seen.insert(p.root).inserted { out.append((p.name + " · VS Code", p.root)) } }
        for s in live { if let r = s.root, seen.insert(r).inserted { out.append((s.projectName, r)) } }
        for p in app.history.report?.projects.sorted(by: { $0.last > $1.last }) ?? [] where FileManager.default.fileExists(atPath: p.root) {
            if seen.insert(p.root).inserted { out.append((p.name, p.root)) }
        }
        return out
    }

    // MARK: Selection

    func select(project key: String) {
        selectedProject = key
        selectedPairID = nil
        let sessions = live.filter { $0.projectKey == key }
        if !sessions.contains(where: { $0.id == selectedSessionID }) {
            select(session: sessions.first?.id)
        }
    }

    func select(session id: String?) {
        selectedPairID = nil
        guard id != selectedSessionID else { return }
        selectedSessionID = id
        if let s = session { selectedProject = s.projectKey }
        items = []
        truncated = false
        refresh()
        probeCodexBridge(force: true)
    }

    func select(pair id: String) {
        selectedPairID = id
        selectedSessionID = nil
        selectedProject = nil
        items = []
    }

    /// Opens on what needs you most: a waiting pair, else the most urgent project.
    func selectDefault() {
        if pair != nil { return }
        if let s = session, s.state != .ended || managed(s) != nil { return }
        if let p = pairList.first(where: { $0.status == .waitingOnYou }) { return select(pair: p.id) }
        if let first = sections.first?.projects.first { select(project: first.id) }
        else if let p = pairList.first { select(pair: p.id) }
    }

    // MARK: Transcript

    func start() {
        broker.connect { [weak self] error in
            if let error { self?.notice = error }
        }
        selectDefault()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        transcripts = [:]
    }

    private func tick() {
        if selectedPairID != nil, pair == nil { selectedPairID = nil }
        if selectedPairID == nil, session == nil, selectedSessionID != nil || selectedProject == nil { selectedSessionID = nil; selectDefault() }
        if let id = selectedSessionID, id.hasPrefix("managed:"), let m = broker.sessions[String(id.dropFirst(8))], let storeID = m.storeID {
            if let draft = drafts[id] { drafts[storeID] = draft; drafts[id] = nil }
            select(session: storeID)
        }
        refresh()
        probeCodexBridge()
    }

    func canReplyToExistingCodex(_ s: Session) -> Bool {
        managed(s) == nil && s.agent == .codex && !s.isChat && UUID(uuidString: s.sessionId) != nil
            && ["vscode", "cursor", "windsurf", "codex-desktop", "chatgpt"].contains(s.hostKind ?? "")
    }

    /// Probe only the selected conversation, off the UI thread. Sending always rediscovers its owner.
    func probeCodexBridge(force: Bool = false) {
        guard !probingCodex, let s = session, canReplyToExistingCodex(s),
              force || Date().timeIntervalSince(lastCodexProbe[s.id] ?? .distantPast) > 5 else { return }
        let id = s.id, thread = s.sessionId
        probingCodex = true
        lastCodexProbe[id] = Date()
        bridgeQueue.async { [weak self] in
            let result = Result { try CodexIPC.probe(threadID: thread) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probingCodex = false
                switch result {
                case .success(let owner):
                    self.codexOwners[id] = owner
                    self.codexBridgeErrors[id] = owner == nil ? "This chat has no connected Codex owner. Open it in Codex, then Retry Connection." : nil
                case .failure(let error):
                    self.codexOwners[id] = nil
                    self.codexBridgeErrors[id] = error.localizedDescription
                }
            }
        }
    }

    /// Deliver to the live owner of the exact watched thread. Never resume a second copy to send a reply.
    func sendToExistingCodex(_ s: Session) {
        let text = (drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canReplyToExistingCodex(s) else { return }
        if let pending = editorSends[s.id], !pending.delivered, let status = pending.bridgeStatus, status != .failed {
            notice = "Check the previous reply's delivery before sending again."
            return
        }
        let id = s.id, thread = s.sessionId
        notice = nil
        editorSends[id] = EditorSend(text: text, at: Date(), outcome: nil, bridgeStatus: .sending,
                                    priorUserItemIDs: selectedSessionID == id ? items.filter { $0.kind == .user }.map(\.id) : [])
        let receipt = editorSends[id]?.receiptID
        bridgeQueue.async { [weak self] in
            let result = Result { try CodexIPC.send(threadID: thread, text: text, mode: .auto) }
            DispatchQueue.main.async {
                guard let self, self.editorSends[id]?.receiptID == receipt else { return }
                switch result {
                case .success(let delivery):
                    switch delivery {
                    case .sent: self.editorSends[id]?.bridgeStatus = .sent
                    case .steered: self.editorSends[id]?.bridgeStatus = .steered
                    case .queued: self.editorSends[id]?.bridgeStatus = .queued
                    }
                    if self.drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.drafts[id] = nil }
                    self.codexBridgeErrors[id] = nil
                    self.refresh()
                case .failure(let error):
                    if self.editorSends[id]?.delivered == true {
                        if self.drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.drafts[id] = nil }
                        return
                    }
                    let uncertain = (error as? CodexIPC.Error)?.uncertain == true
                    self.editorSends[id]?.bridgeStatus = uncertain ? .uncertain : .failed
                    self.editorSends[id]?.error = error.localizedDescription
                    self.notice = error.localizedDescription
                    self.codexOwners[id] = nil
                }
            }
        }
    }

    /// Reads what the selected session's transcript gained since the last read, off the main thread.
    func refresh() {
        guard !loading, let s = session, let path = s.transcriptPath ?? managed(s)?.transcriptPath else { return }
        let transcript: ChatTranscript
        if let t = transcripts[s.id], t.path == path { transcript = t } else {
            transcript = ChatTranscript(path: path, agent: s.agent)
            transcripts[s.id] = transcript
        }
        let id = s.id
        loading = true
        queue.async { [weak self] in
            let changed = transcript.update()
            let items = transcript.items, truncated = transcript.truncated
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard self.selectedSessionID == id, changed || self.items.isEmpty else { return }
                self.items = items
                self.truncated = truncated
                self.confirmEditorSend(id, items)
            }
        }
    }

    // MARK: Talking to sessions

    /// Sends the draft to a managed session: a new turn when idle; while busy, Codex steers the running turn
    /// and Claude queues it as the next turn.
    func send(_ s: Session) {
        guard let m = managed(s), m.status != .exited, m.status != .failed else { return }
        let text = (drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard broker.connected else { notice = "Reconnect the broker before sending. Your draft is saved."; return }
        notice = nil
        broker.message(m.id, text, steer: m.capabilities.steerActiveTurn && [.busy, .waiting].contains(m.status)) { [weak self] error in
            guard let self else { return }
            if let error { self.notice = error }
            else if self.drafts[s.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.drafts[s.id] = nil }
        }
    }

    func interrupt(_ s: Session) {
        if let m = managed(s) { broker.interrupt(m.id) }
    }

    func answer(_ s: Session, _ request: PendingRequest, decision: String, answers: [String: [String]]? = nil) {
        guard let m = managed(s) else { return }
        broker.answer(m.id, request: request.id, decision: decision, answers: answers)
    }

    func stopSession(_ s: Session) {
        if let m = managed(s) { broker.stop(m.id) }
    }

    func setMode(_ s: Session, _ mode: String) {
        if let m = managed(s) { broker.setMode(m.id, mode) }
    }

    /// Starts a stopped managed session again on the same conversation.
    func resume(_ s: Session) {
        guard let m = managed(s), let sid = m.sessionId else { return }
        let o = StartOptions(agent: m.agent, cwd: m.cwd, resume: sid, permissionMode: m.permissionMode, model: m.model, title: m.title)
        broker.start(o) { [weak self] error, key in
            guard let self else { return }
            if let error { self.notice = error; return }
            self.broker.forget(m.id)
            if let key { self.selectManaged(key) }
        }
    }

    /// Claude in VS Code: open its conversation with the reply typed in (and send it, when allowed).
    func sendToEditor(_ s: Session) {
        let text = (drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, EditorReply.scheme(s) != nil else { return }
        drafts[s.id] = nil
        notice = nil
        let auto = app.settings.editorAutoSend
        editorSends[s.id] = EditorSend(text: text, at: Date(), outcome: nil)
        EditorReply.deliver(s, text: text, pressReturn: auto) { [weak self] outcome in
            self?.editorSends[s.id]?.outcome = outcome
        }
    }

    /// A timestamped matching message in this exact conversation confirms delivery.
    private func confirmEditorSend(_ id: String, _ items: [ChatItem]) {
        guard let send = editorSends[id], !send.delivered else { return }
        let after = send.bridgeStatus == nil ? send.at.addingTimeInterval(-2) : send.at
        let prior = Set(send.priorUserItemIDs ?? [])
        let seen = items.contains { $0.kind == .user && $0.text == send.text && !prior.contains($0.id) && ($0.at ?? .distantPast) >= after }
        guard seen else { return }
        editorSends[id]?.delivered = true
        if drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) == send.text { drafts[id] = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.editorSends[id]?.receiptID == send.receiptID, self?.editorSends[id]?.delivered == true { self?.editorSends[id] = nil }
        }
    }

    func clearEditorSend(_ s: Session) { editorSends[s.id] = nil }

    /// The selected conversation as plain text (you and the agent, tool calls left out).
    func conversationText(_ s: Session) -> String {
        guard s.id == selectedSessionID else { return "" }
        return items.compactMap { item -> String? in
            switch item.kind {
            case .user: "You:\n" + item.text
            case .assistant: "\(s.agent.displayName):\n" + item.text
            case .interrupted: "(interrupted)"
            case .tool: nil
            }
        }.joined(separator: "\n\n")
    }

    func setEditorAutoSend(_ on: Bool) {
        app.settings.editorAutoSend = on
        if on && !EditorReply.canPressReturn { ChatWatcher.requestAccess() }
    }

    /// The observed-session reply: copy the draft and bring the agent's window forward to paste it.
    func copyAndOpen(_ s: Session) {
        let text = (drafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Focuser.focus(s)
    }

    /// How a watched session can come under the Coordinator: moved (its process stopped, then resumed here)
    /// when it runs in a terminal we can stop cleanly, else continued as a copy. Only while idle.
    enum Takeover { case move, copy }

    func takeover(_ s: Session) -> Takeover? {
        guard managed(s) == nil, !s.isChat, !s.isDesktop, !s.sessionId.hasPrefix("pid-"),
              [.idle, .unknown].contains(displayState(s)), (s.launchDir ?? s.cwd) != nil else { return nil }
        return .copy
    }

    func continueHere(_ s: Session) {
        guard let how = takeover(s), let cwd = s.launchDir ?? s.cwd else { return }
        let alert = NSAlert()
        let host = s.hostLabel ?? "its app"
        if how == .move {
            alert.messageText = "Move this session to the Coordinator?"
            alert.informativeText = "Agent HUD stops Claude in \(host) and continues the same conversation here. The \(host) tab stays open at its shell."
            alert.addButton(withTitle: "Move Here")
        } else {
            alert.messageText = "Continue a copy here?"
            alert.informativeText = "\(s.agent.displayName) in \(host) keeps running untouched. The Coordinator continues a copy of the conversation from this point; replies here don't show up in \(host)."
            alert.addButton(withTitle: "Continue Copy")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let start = { [weak self] in
            guard let self else { return }
            let o = StartOptions(agent: s.agent, cwd: cwd, resume: s.sessionId, fork: how == .copy, title: s.title)
            self.broker.start(o) { error, key in
                if let error { self.notice = error; return }
                if let key { self.selectManaged(key) }
            }
        }
        guard how == .move, let pid = s.pid else { return start() }
        kill(pid, SIGTERM)
        // Resume only once the old process is gone: two processes must never run one conversation.
        var waited = 0.0
        func check() {
            if kill(pid, 0) != 0 { return start() }
            waited += 0.25
            if waited >= 6 { notice = "Claude in \(host) didn't stop, so nothing was moved."; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { check() }
        }
        check()
    }

    func startSession(_ o: StartOptions, done: @escaping (String?) -> Void = { _ in }) {
        broker.start(o) { [weak self] error, key in
            guard let self else { return }
            if let error { self.notice = error; done(error); return }
            if let key { self.selectManaged(key) }
            done(nil)
        }
    }

    /// Selects a managed session once the broker has reported it (it may not have a conversation id yet).
    private func selectManaged(_ key: String, tries: Int = 0) {
        if let m = broker.sessions[key] {
            select(session: m.storeID ?? "managed:" + key)
        } else if tries < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.selectManaged(key, tries: tries + 1) }
        }
    }

    // MARK: Pairs

    func startPair(_ config: PairConfig) {
        broker.startPair(config) { [weak self] error, key in
            guard let self else { return }
            if let error { self.notice = error; return }
            if let key { self.select(pair: key) }
        }
    }

    func pairAction(_ p: PairState, _ action: String, text: String? = nil) {
        broker.pairAction(p.id, action, text: text) { [weak self] error in
            if let error { self?.notice = error }
        }
    }

    func pairSession(_ p: PairState, _ agent: AgentKind) -> ManagedSession? {
        p.sessions[agent.rawValue].flatMap { broker.sessions[$0] }
    }

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let code = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: code, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
